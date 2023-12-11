#############################################################
# General data variables required for workload
#############################################################
data "aws_region" "region" {}
data "aws_caller_identity" "dev" {}
data "aws_caller_identity" "stage" {provider = aws.stage}
data "aws_caller_identity" "prod" {provider = aws.prod}

#############################################################
# Create Repository for ML feature and EventBridge rule for commits
#############################################################
resource "aws_codecommit_repository" "ml_repository" { repository_name = "ml-${var.feature_name}-repository" }
resource "aws_cloudwatch_event_rule" "repository_commit" {
  name        = "ml-${var.feature_name}-repository-commit"
  description = "Capture each commit to the main branch."
  event_pattern = jsonencode({
    detail-type = ["CodeCommit Repository State Change"]
    source      = ["aws.codecommit"]
    resources   = [aws_codecommit_repository.ml_repository.arn]
    detail = {
      event         = ["referenceUpdated"]
      referenceType = ["branch"]
    referenceName = ["main"] }
  })
}
resource "aws_cloudwatch_event_target" "event_target" {
  arn      = aws_sfn_state_machine.ml_cicd.arn
  rule     = aws_cloudwatch_event_rule.repository_commit.name
  role_arn = aws_iam_role.ml_event_bridge_role.arn
}
resource "aws_iam_role" "ml_event_bridge_role" {
  name               = "ml-${var.feature_name}-event-bridge-role"
  assume_role_policy = data.aws_iam_policy_document.ml_event_bridge_policy_trust.json
  inline_policy {
    name   = "cicd-event-bridge-role"
    policy = data.aws_iam_policy_document.ml_event_bridge_policy_inline.json
  }
}
data "aws_iam_policy_document" "ml_event_bridge_policy_trust" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["events.amazonaws.com"]
    }
  }
}
data "aws_iam_policy_document" "ml_event_bridge_policy_inline" {
  statement {
    actions   = ["states:StartExecution"]
    resources = [aws_sfn_state_machine.ml_cicd.arn]
  }
}

#############################################################
# Create ECR repository to store images for Lambda inference
#############################################################
resource "aws_ecr_repository" "feature_repository" {
  name         = "ml-${var.feature_name}-repo"
  force_delete = true
}
resource "aws_ecr_repository_policy" "ecr_policy" {
  repository = aws_ecr_repository.feature_repository.name
  policy     = data.aws_iam_policy_document.ecr_policy.json
}
data "aws_iam_policy_document" "ecr_policy" {
  statement {
    sid    = "CrossAccountPermission"
    effect = "Allow"
    principals {
      type        = "AWS"
      identifiers = [data.aws_caller_identity.stage.account_id,
                     data.aws_caller_identity.prod.account_id]
    }
    actions = [
      "ecr:GetDownloadUrlForLayer",
      "ecr:BatchGetImage"
    ]
  }
  statement {
    sid    = "LambdaECRImageCrossAccountRetrievalPolicy"
    effect = "Allow"
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
    actions = [
      "ecr:GetDownloadUrlForLayer",
      "ecr:BatchGetImage"
    ]
  }
}
resource "null_resource" "push_base_image" {
  provisioner "local-exec" {
    command = <<EOF
    docker login -u AWS -p $(aws ecr get-login-password --region ${data.aws_region.region.name}) ${data.aws_caller_identity.dev.account_id}.dkr.ecr.${data.aws_region.region.name}.amazonaws.com && \
    docker build --platform linux/amd64 -t ${aws_ecr_repository.feature_repository.repository_url}:base assets/ && \
    docker push ${aws_ecr_repository.feature_repository.repository_url}:base
    EOF
  }
}

#############################################################
# Create CI/CD workflow for ML inference deployment process
#############################################################
resource "aws_sfn_state_machine" "ml_cicd" {
  name     = "ml-cicd-inference-${var.feature_name}"
  role_arn = aws_iam_role.ml_cicd_role.arn
  definition = jsonencode(
    {
    Comment = "CI/CD for the ${var.feature_name} ML inference deployment",
    StartAt = "CodeBuildTrain",
    States  = {
      "CodeBuildTrain": {
        "Type": "Task",
        "Resource": "arn:aws:states:::codebuild:startBuild.sync",
        "Parameters": {
      "ProjectName": aws_codebuild_project.codebuild_project.name,
        "EnvironmentVariablesOverride": [
          {
            "Name": "COMMIT_ID",
            "Type": "PLAINTEXT",
            "Value.$": "$.detail.commitId"
          }
        ]
    },
        "ResultPath": "$.detailscommitId",
        "Next" : "DeployLambdaStage"
  },

      "DeployLambdaStage" : {
        "Type"       : "Task",
        "Resource"   : aws_lambda_function.deploy_lambda.arn,
        "Parameters" : {
          "env": "stage",
          "commit.$": "$.detail.commitId"
    },
        "ResultPath": null
        "Next" : "WaitApproval"
  },

      "WaitApproval" : {
        "Type"     : "Task",
        "Resource" : "arn:aws:states:::lambda:invoke.waitForTaskToken"
        "Parameters" : {
         "FunctionName": aws_lambda_function.approve_lambda.function_name,
         "Payload": {
            "token.$": "$$.Task.Token"
     }
    },
        "ResultPath": null
        "Next" : "DeployLambdaProd"
  },

      "DeployLambdaProd" : {
        "Type"       : "Task",
        "Resource"   : aws_lambda_function.deploy_lambda.arn,
        "Parameters" : {
          "env": "prod",
          "commit.$": "$.detail.commitId"
      },
      "End" : true
    }
  }
})
}
resource "aws_iam_role" "ml_cicd_role" {
  name               = "ml-${var.feature_name}-cicd-role"
  assume_role_policy = data.aws_iam_policy_document.ml_cicd_policy_trust.json
  inline_policy {
    name   = "cicd-access-policy"
    policy = data.aws_iam_policy_document.ml_cicd_policy_inline.json
  }
}
data "aws_iam_policy_document" "ml_cicd_policy_trust" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["states.amazonaws.com"]
    }
  }
}
data "aws_iam_policy_document" "ml_cicd_policy_inline" {
  statement {
    actions   = ["s3:*", "ecr:*", "logs:*", "lambda:*", "ses:*", "events:*", "codebuild:*"]
    resources = ["*"]
  }
}

#############################################################
# Create CodeBuild project to train model and prepare image
#############################################################
resource "aws_codebuild_project" "codebuild_project" {
  name          = "ml-${var.feature_name}-codebuild"
  description   = "Codebuild project for training ${var.feature_name} model."
  build_timeout = "120"
  service_role  = aws_iam_role.codebuild_role.arn
  artifacts { type = "NO_ARTIFACTS" }
  vpc_config {
    vpc_id = var.vpc_id
    subnets = [ var.subnet_private_id, var.subnet_private2_id ]
    security_group_ids = [ aws_security_group.codebuild_sg.id ]
  }
  source {
    type     = "CODECOMMIT"
    location = aws_codecommit_repository.ml_repository.clone_url_http
  }
  environment {
    image                       = "aws/codebuild/standard:7.0"
    type                        = "LINUX_CONTAINER"
    compute_type                = "BUILD_GENERAL1_SMALL"
    image_pull_credentials_type = "CODEBUILD"
    privileged_mode             = true
    environment_variable {
      name  = "REPOSITORY_URL"
      value = aws_ecr_repository.feature_repository.repository_url
    }
    environment_variable {
      name  = "MODEL_NAME"
      value = var.feature_name
    }
    environment_variable {
      name  = "AWS_DEFAULT_REGION"
      value = data.aws_region.region.name
    }
    environment_variable {
      name  = "AWS_ACCOUNT_ID"
      value = data.aws_caller_identity.dev.account_id
    }
  environment_variable {
      name  = "MLFLOW_URI"
      value = var.mlflow_alb_uri
    }
  }
}
resource "aws_security_group" "codebuild_sg" {
  name        = "ml-${var.feature_name}-codebuild-sg"
  description = "ML framework server security group."
  vpc_id      = var.vpc_id
  egress {
    protocol    = "-1"
    from_port   = 0
    to_port     = 0
    cidr_blocks = ["0.0.0.0/0"]
  }
}
resource "aws_iam_role" "codebuild_role" {
  name               = "ml-${var.feature_name}-codebuild-role"
  assume_role_policy = data.aws_iam_policy_document.codebuild_policy_trust.json
  inline_policy {
    name   = "cicd-codebuild-policy"
    policy = data.aws_iam_policy_document.codebuild_policy_inline.json
  }
}
data "aws_iam_policy_document" "codebuild_policy_trust" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["codebuild.amazonaws.com"]
    }
  }
}
data "aws_iam_policy_document" "codebuild_policy_inline" {
  statement {
    actions   = ["s3:*", "ecr:*", "logs:*", "codecommit:*", "ec2:*"]
    resources = ["*"]
  }
}

#############################################################
# Create approval mechanism using API Gateway
#############################################################
resource "aws_api_gateway_rest_api" "ml_approval" {
  name        = "ml_approval_${var.feature_name}"
  description = "ML API for approval of ${var.feature_name} model deployment to Prod env."
  endpoint_configuration {
    types = ["REGIONAL"]
  }
}
resource "aws_api_gateway_resource" "resource_approve" {
  rest_api_id = aws_api_gateway_rest_api.ml_approval.id
  parent_id   = aws_api_gateway_rest_api.ml_approval.root_resource_id
  path_part   = "approve"
}
resource "aws_api_gateway_method" "get_approve" {
  rest_api_id        = aws_api_gateway_rest_api.ml_approval.id
  resource_id        = aws_api_gateway_resource.resource_approve.id
  http_method        = "GET"
  authorization      = "NONE"
  operation_name     = "approve"
  request_parameters = { "method.request.querystring.taskToken"=true }
}
resource "aws_api_gateway_integration" "approve_integration" {
  rest_api_id             = aws_api_gateway_rest_api.ml_approval.id
  resource_id             = aws_api_gateway_resource.resource_approve.id
  http_method             = aws_api_gateway_method.get_approve.http_method
  integration_http_method = "POST"
  type                    = "AWS"
  uri                     = "arn:aws:apigateway:${data.aws_region.region.name}:states:action/SendTaskSuccess"
  credentials             = aws_iam_role.approver_role.arn
  passthrough_behavior    = "WHEN_NO_TEMPLATES"
  request_templates = {
    "application/json" = jsonencode({
      output           = "\"Approve link was clicked.\"",
      taskToken = "$input.params('taskToken')"
    })
  }
}
resource "aws_api_gateway_method_response" "approve_200" {
  rest_api_id = aws_api_gateway_rest_api.ml_approval.id
  resource_id = aws_api_gateway_resource.resource_approve.id
  http_method = aws_api_gateway_method.get_approve.http_method
  status_code = "200"
}
resource "aws_api_gateway_integration_response" "approve_integration_200" {
  rest_api_id = aws_api_gateway_rest_api.ml_approval.id
  resource_id = aws_api_gateway_resource.resource_approve.id
  http_method = aws_api_gateway_method.get_approve.http_method
  status_code = aws_api_gateway_method_response.approve_200.status_code
  response_templates = {
    "application/xml" = <<EOF
    Model was approved.
EOF
  }
}
resource "aws_api_gateway_resource" "resource_reject" {
  rest_api_id = aws_api_gateway_rest_api.ml_approval.id
  parent_id   = aws_api_gateway_rest_api.ml_approval.root_resource_id
  path_part   = "reject"
}
resource "aws_api_gateway_method" "get_reject" {
  rest_api_id        = aws_api_gateway_rest_api.ml_approval.id
  resource_id        = aws_api_gateway_resource.resource_reject.id
  http_method        = "GET"
  authorization      = "NONE"
  operation_name     = "reject"
    request_parameters = { "method.request.querystring.taskToken"=true }
}
resource "aws_api_gateway_integration" "reject_integration" {
  rest_api_id             = aws_api_gateway_rest_api.ml_approval.id
  resource_id             = aws_api_gateway_resource.resource_reject.id
  http_method             = aws_api_gateway_method.get_reject.http_method
  integration_http_method = "POST"
  type                    = "AWS"
  uri                     = "arn:aws:apigateway:${data.aws_region.region.name}:states:action/SendTaskFailure"
  credentials             = aws_iam_role.approver_role.arn
  passthrough_behavior    = "WHEN_NO_TEMPLATES"
  request_templates = {
    "application/json" = jsonencode({
      output           = "\"Reject link was clicked.\"",
      taskToken = "$input.params('taskToken')"
    })
  }
}
resource "aws_api_gateway_method_response" "reject_200" {
  rest_api_id = aws_api_gateway_rest_api.ml_approval.id
  resource_id = aws_api_gateway_resource.resource_reject.id
  http_method = aws_api_gateway_method.get_reject.http_method
  status_code = "200"
}
resource "aws_api_gateway_integration_response" "reject_integration_200" {
  rest_api_id = aws_api_gateway_rest_api.ml_approval.id
  resource_id = aws_api_gateway_resource.resource_reject.id
  http_method = aws_api_gateway_method.get_reject.http_method
  status_code = aws_api_gateway_method_response.reject_200.status_code
  depends_on = [aws_api_gateway_integration.reject_integration]
  response_templates = {
    "application/xml" = <<EOF
    Model was rejected.
EOF
  }
}
resource "aws_api_gateway_deployment" "deploy" {
  rest_api_id = aws_api_gateway_rest_api.ml_approval.id
  triggers = {
    redeployment = sha1(jsonencode([
      aws_api_gateway_resource.resource_approve.id,
      aws_api_gateway_method.get_approve.id,
      aws_api_gateway_integration.approve_integration.id,
      aws_api_gateway_resource.resource_reject.id,
      aws_api_gateway_method.get_reject.id,
      aws_api_gateway_integration.reject_integration.id,
    ]))
  }
  lifecycle {
    create_before_destroy = true
  }
}
resource "aws_iam_role" "approver_role" {
  name               = "ml-approver-role"
  assume_role_policy = data.aws_iam_policy_document.approver_policy_trust.json
  managed_policy_arns = ["arn:aws:iam::aws:policy/AWSStepFunctionsFullAccess"]
}
resource "aws_api_gateway_stage" "approver_api_stage" {
  deployment_id = aws_api_gateway_deployment.deploy.id
  rest_api_id   = aws_api_gateway_rest_api.ml_approval.id
  stage_name    = "prod"
}
data "aws_iam_policy_document" "approver_policy_trust" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["apigateway.amazonaws.com"]
    }
  }
}

#############################################################
# Create Lambda functions for deploy step
#############################################################
resource "aws_lambda_function" "deploy_lambda" {
  filename         = "assets/deploy_lambda_payload.zip"
  function_name    = "ml-${var.feature_name}-deploy-lambda"
  role             = aws_iam_role.deploy_lambda_role.arn
  handler          = "handler.lambda_handler"
  source_code_hash = data.archive_file.deploy_lambda_payload.output_base64sha256
  runtime          = "python3.9"
  publish          = true
  timeout          = 600
  environment {
    variables = {
      ECR_REPO_URL             = aws_ecr_repository.feature_repository.repository_url
      DEPLOY_STAGE_ROLE_ARN    = aws_iam_role.stage_role_deploy_lambda.arn
      DEPLOY_PROD_ROLE_ARN     = aws_iam_role.prod_role_deploy_lambda.arn
      FUNCTION_NAME            = aws_lambda_function.stage_lambda_inference.function_name
      ALIAS_NAME               = aws_lambda_alias.stage_lambda_alias_inference.name
    }
  }
}
resource "aws_iam_role" "deploy_lambda_role" {
  name               = "ml-${var.feature_name}-deploy-role"
  assume_role_policy = data.aws_iam_policy_document.ml_lambda_policy_trust.json
  inline_policy {
    name   = "deploy-lambda-policy"
    policy = data.aws_iam_policy_document.ml_deploy_lambda_policy_inline.json
  }
}
data "archive_file" "deploy_lambda_payload" {
  type        = "zip"
  output_path = "assets/deploy_lambda_payload.zip"
  source {
    content  = file("assets/deploy.py")
    filename = "handler.py"
  }
}
data "aws_iam_policy_document" "ml_lambda_policy_trust" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}
data "aws_iam_policy_document" "ml_deploy_lambda_policy_inline" {
  statement {
    actions   = ["s3:*", "ecs:*", "ecr:*", "logs:*", "lambda:*", "ses:*", "sts:*"]
    resources = ["*"]
  }
}

#############################################################
# Create Lambda functions for approve step
#############################################################
resource "aws_lambda_function" "approve_lambda" {
  filename         = "assets/approve_lambda_payload.zip"
  function_name    = "ml-${var.feature_name}-approve-lambda"
  role             = aws_iam_role.approve_lambda_role.arn
  handler          = "handler.lambda_handler"
  source_code_hash = data.archive_file.approve_lambda_payload.output_base64sha256
  runtime          = "python3.9"
  publish          = true
  timeout          = 600
  environment {
    variables = {
      FEATURE_NAME      = var.feature_name
      API_DEPLOYMENT_ID = aws_api_gateway_deployment.deploy.invoke_url
      REGION            = data.aws_region.region.name
    }
  }
}
resource "aws_iam_role" "approve_lambda_role" {
  name               = "ml-${var.feature_name}-approve-role"
  assume_role_policy = data.aws_iam_policy_document.ml_lambda_policy_trust.json
  inline_policy {
    name   = "approve-lambda-policy"
    policy = data.aws_iam_policy_document.ml_approve_lambda_policy_inline.json
  }
}
data "archive_file" "approve_lambda_payload" {
  type        = "zip"
  output_path = "assets/approve_lambda_payload.zip"
  source {
    content  = file("assets/approve.py")
    filename = "handler.py"
  }
}
data "aws_iam_policy_document" "ml_approve_lambda_policy_inline" {
  statement {
    actions   = ["logs:*", "lambda:*"]
    resources = ["*"]
  }
}

#############################################################
# Create Lambda inference for stage environment
#############################################################
resource "aws_lambda_function" "stage_lambda_inference" {
  function_name    = "ml-${var.feature_name}-inference-lambda"
  role             = aws_iam_role.stage_role_inference.arn
  package_type     = "Image"
  image_uri        = "${aws_ecr_repository.feature_repository.repository_url}:base"
  publish          = true
  timeout          = 600
  memory_size      = 200 
  depends_on       = [null_resource.push_base_image]
  provider         = aws.stage
  environment {
    variables = {
      ECR_REPO_URL = aws_ecr_repository.feature_repository.repository_url
      FEATURE_NAME = var.feature_name
    }
  }
  lifecycle { ignore_changes = [image_uri,] }
}
resource "aws_lambda_alias" "stage_lambda_alias_inference" {
  name             = "ml-${var.feature_name}-inference-alias"
  description      = "Alias for Lambda inference for the ${var.feature_name} model."
  function_name    = aws_lambda_function.stage_lambda_inference.arn
  function_version = "$LATEST"
  provider         = aws.stage
  lifecycle { ignore_changes = [function_version,] }
}
resource "aws_iam_role" "stage_role_inference" {
  name               = "ml-${var.feature_name}-inference-role"
  assume_role_policy = data.aws_iam_policy_document.trust_policy_inference.json
  inline_policy {
    name = "ml-${var.feature_name}-inference-inline"
    policy = data.aws_iam_policy_document.inline_policy_inference.json
  }
  provider         = aws.stage
}
data "aws_iam_policy_document" "trust_policy_inference" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}
data "aws_iam_policy_document" "inline_policy_inference" {
  statement {
    actions   = ["ecr:*", "logs:*", "lambda:*"]
    resources = ["*"]
  }
}
resource "aws_iam_role" "stage_role_deploy_lambda" {
  name               = "ml-${var.feature_name}-deploy-inference-role"
  assume_role_policy = data.aws_iam_policy_document.trust_policy_deploy_lambda.json
  inline_policy {
    name = "ml-${var.feature_name}-deploy-inference-inline"
    policy = data.aws_iam_policy_document.inline_policy_deploy_lambda.json
  }
  provider         = aws.stage
}
data "aws_iam_policy_document" "trust_policy_deploy_lambda" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "AWS"
      identifiers = [aws_iam_role.deploy_lambda_role.arn, ]
    }
  }
}
data "aws_iam_policy_document" "inline_policy_deploy_lambda" {
  statement {
    actions   = ["ecr:*", "logs:*", "lambda:*"]
    resources = ["*"]
  }
}

#############################################################
# Create Lambda inference for prod environment
#############################################################
resource "aws_lambda_function" "prod_lambda_inference" {
  function_name    = "ml-${var.feature_name}-inference-lambda"
  role             = aws_iam_role.prod_role_inference.arn
  package_type     = "Image"
  image_uri        = "${aws_ecr_repository.feature_repository.repository_url}:base"
  publish          = true
  timeout          = 600
  memory_size      = 200 
  depends_on       = [null_resource.push_base_image]
  provider         = aws.prod
  environment {
    variables = {
      ECR_REPO_URL = aws_ecr_repository.feature_repository.repository_url
      FEATURE_NAME = var.feature_name
    }
  }
  lifecycle { ignore_changes = [image_uri,] }
}
resource "aws_lambda_alias" "prod_lambda_alias_inference" {
  name             = "ml-${var.feature_name}-inference-alias"
  description      = "Alias for Lambda inference for the ${var.feature_name} model."
  function_name    = aws_lambda_function.prod_lambda_inference.arn
  function_version = "$LATEST"
  provider         = aws.prod
  lifecycle { ignore_changes = [function_version,] }
}
resource "aws_iam_role" "prod_role_inference" {
  name               = "ml-${var.feature_name}-inference-role"
  assume_role_policy = data.aws_iam_policy_document.trust_policy_inference.json
  inline_policy {
    name = "ml-${var.feature_name}-inference-inline"
    policy = data.aws_iam_policy_document.inline_policy_inference.json
  }
  provider         = aws.prod
}
resource "aws_iam_role" "prod_role_deploy_lambda" {
  name               = "ml-${var.feature_name}-deploy-inference-role"
  assume_role_policy = data.aws_iam_policy_document.trust_policy_deploy_lambda.json
  inline_policy {
    name = "ml-${var.feature_name}-deploy-inference-inline"
    policy = data.aws_iam_policy_document.inline_policy_deploy_lambda.json
  }
  provider         = aws.prod
}

#############################################################
# Create notification mechanism for CI/CD pipeline statuses
#############################################################
resource "aws_sns_topic" "sns_cicd_monitoring" { name = "ml-${var.feature_name}-cicd-monitoring" }
resource "aws_sns_topic_policy" "sns_monitoring_policy" {
  arn    = aws_sns_topic.sns_cicd_monitoring.arn
  policy = data.aws_iam_policy_document.sns_topic_policy.json
}
data "aws_iam_policy_document" "sns_topic_policy" {
  statement {
    effect  = "Allow"
    actions = ["SNS:Publish"]
    principals {
      type        = "Service"
      identifiers = ["events.amazonaws.com"]
    }
    resources = [aws_sns_topic.sns_cicd_monitoring.arn]
  }
}
resource "aws_cloudwatch_event_rule" "cicd_monitoring" {
  name        = "ml-${var.feature_name}-cicd-monitoring"
  description = "Capture status changes in CI/CD pipeline."

  event_pattern = jsonencode({
    detail-type = [ "Step Functions Execution Status Change" ]
    source      = [ "aws.states" ]
    detail      = {
    status    = [ "FAILED", "TIMED_OUT", "SUCCEEDED" ]
    stateMachineArn = [ aws_sfn_state_machine.ml_cicd.arn ]}
  })
}
resource "aws_cloudwatch_event_target" "sns" {
  rule      = aws_cloudwatch_event_rule.cicd_monitoring.name
  target_id = "SendToSNS"
  arn       = aws_sns_topic.sns_cicd_monitoring.arn
}
