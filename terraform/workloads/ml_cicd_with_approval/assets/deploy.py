import boto3
import os

# Get environmental variables
ecr_repo = os.environ['ECR_REPO_URL']
function_name = os.environ['FUNCTION_NAME']
alias_name = os.environ['ALIAS_NAME']
deploy_stage_role_arn = os.environ['DEPLOY_STAGE_ROLE_ARN']
deploy_prod_role_arn = os.environ['DEPLOY_PROD_ROLE_ARN']

# Create AWS resources sessions
sts_client = boto3.client('sts')

def update_function(role_arn, model_version):
    # Assume role in Stage account
    assumed_role = sts_client.assume_role(RoleArn=role_arn, RoleSessionName='DeployInference')

    # Deploy to stage environment
    lambda_client = boto3.client('lambda',
                                 aws_access_key_id=assumed_role['Credentials']['AccessKeyId'],
                                 aws_secret_access_key=assumed_role['Credentials']['SecretAccessKey'],
                                 aws_session_token=assumed_role['Credentials']['SessionToken'])
    response = lambda_client.update_function_code(FunctionName=function_name,
                                                  ImageUri=f'{ecr_repo}:{model_version}',
                                                  Publish=True)

    # Point alias to the new version
    version = response['Version']
    lambda_client.update_alias(FunctionName=function_name,
                               Name=alias_name,
                               FunctionVersion=version)
def lambda_handler(event, context):
    # Parse event
    env = event['env']
    model_version = event['commit']

    # Create Lambda function for model inference
    if env == 'stage':
        update_function(deploy_stage_role_arn, model_version)

    elif env == 'prod':
        update_function(deploy_prod_role_arn, model_version)

    return {"Response": 200}
