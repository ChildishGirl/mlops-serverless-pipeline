#############################################################
# Parameters
#############################################################
data "aws_region" "current" {}
data "aws_caller_identity" "current" {}

#############################################################
# Create ECR repository with Docker image and push it to ECR
#############################################################
resource "aws_ecr_repository" "ml_repo" {
  name = "ml-mlflow-repository"
  force_delete = true
}
resource "null_resource" "push_mlflow_image" {
  triggers = { dir_sha1 = sha1(join("", [for f in fileset(".", "./assets/**") : filesha1(f)])) }
  provisioner "local-exec" {
    command = <<EOF
    docker login -u AWS -p $(aws ecr get-login-password --region ${data.aws_region.current.name}) ${data.aws_caller_identity.current.account_id}.dkr.ecr.${data.aws_region.current.name}.amazonaws.com && \
    docker build --platform linux/amd64 -t ${aws_ecr_repository.ml_repo.repository_url}:latest assets/ && \
    docker push ${aws_ecr_repository.ml_repo.repository_url}:latest
    EOF
  }
}

#############################################################
# Create ECS cluster with Fargate task and role
#############################################################
resource "aws_ecs_cluster" "mlflow_cluster" { name = "ml-mlflow" }
resource "aws_ecs_task_definition" "mlflow_task" {
  family                   = "ml_mlflow"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = 1024
  memory                   = 2048
  task_role_arn            = aws_iam_role.ecs_task_role.arn
  execution_role_arn       = aws_iam_role.ecs_execution_role.arn
  depends_on = [null_resource.push_mlflow_image]
  container_definitions    = jsonencode([{
    name  = "mlflow",
    image = "${aws_ecr_repository.ml_repo.repository_url}:latest",
    environment = [
      {"name" : "BUCKET", "value" : "s3://${aws_s3_bucket.aws_s3_bucket.bucket}" },
      {"name" : "DATABASE", "value" : aws_rds_cluster.mlflow_db.database_name},
      {"name" : "USERNAME", "value" : aws_rds_cluster.mlflow_db.master_username },
      {"name" : "HOST", "value" : aws_rds_cluster_instance.mlflow_db_instance[0].endpoint },
      {"name" : "PORT", "value" : "${tostring(aws_rds_cluster.mlflow_db.port)}" },
    ],
    secrets = [
      { name = "PASSWORD",
        valueFrom = data.aws_ssm_parameter.rds_password.arn }],
    essential = true,
    portMappings = [{
       appProtocol   = "http"
            containerPort = 80
            hostPort      = 80
            name          = "80-tcp"
            protocol      = "tcp"
    }]
    logConfiguration = {
        logDriver = "awslogs",
        options   = {
          "awslogs-group" : "ml-mlflow-server",
          "awslogs-region" : data.aws_region.current.name,
          "awslogs-create-group" : "true",
          "awslogs-stream-prefix" : "ml-mlflow"
        }
    }
  }])
  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "X86_64"
  }
}
resource "aws_ecs_service" "ml_framework_service" {
  name            = "ml-mlflow-service"
  task_definition = aws_ecs_task_definition.mlflow_task.arn
  cluster         = aws_ecs_cluster.mlflow_cluster.id
  desired_count   = 1
  launch_type     = "FARGATE"
  network_configuration {
    subnets          = [var.subnet_private_id, var.subnet_private2_id]
    security_groups  = [aws_security_group.mlflow_server_sg.id]
    assign_public_ip = false
  }
  load_balancer {
    target_group_arn = aws_lb_target_group.mlflow_alb_target.arn
    container_name   = "mlflow"
    container_port   = 80
  }
}
resource "aws_security_group" "mlflow_server_sg" {
  name        = "ml-mlflow-server-sg"
  description = "ML framework server security group."
  vpc_id      = var.vpc_id
  ingress {
    protocol        = "tcp"
    self            = true
    cidr_blocks     = [var.cidr_vpc]
    from_port       = 80
    to_port         = 80
    description     = "Communication channel to MLflow server."
  }
  ingress {
    protocol        = "tcp"
    self            = true
    security_groups = [aws_security_group.mlflow_alb_sg.id]
    from_port       = 80
    to_port         = 80
    description     = "Communication channel to MLflow server."
  }
  ingress {
    protocol    = "icmp"
    self        = true
    cidr_blocks = [var.cidr_vpc]
    from_port   = -1
    to_port     = -1
    description = "Communication channel to servers from jump instance."
  }
  egress {
    protocol    = "-1"
    from_port   = 0
    to_port     = 0
    cidr_blocks = ["0.0.0.0/0"]
  }
}
resource "aws_iam_role" "ecs_task_role" {
  name               = "ml-mlflow-task-role"
  assume_role_policy = data.aws_iam_policy_document.ecs_task_trust_policy.json
  inline_policy {
    name = "ml-mlflow-task-role-policy"
    policy = data.aws_iam_policy_document.ml_mlflow_policy_inline.json
  }
}
resource "aws_iam_role" "ecs_execution_role" {
  name               = "ml-mlflow-execution-role"
  assume_role_policy = data.aws_iam_policy_document.ecs_execution_trust_policy.json
  managed_policy_arns = [
    "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy",
    "arn:aws:iam::aws:policy/CloudWatchLogsFullAccess",
    "arn:aws:iam::aws:policy/AmazonSSMReadOnlyAccess"
  ]
}
data "aws_iam_policy_document" "ecs_task_trust_policy" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}
data "aws_iam_policy_document" "ecs_execution_trust_policy" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}
data "aws_iam_policy_document" "ml_mlflow_policy_inline" {
  statement {
    actions   = ["s3:*", "ecs:*", "ecr:*", "logs:*", "rds:*", "ssm:*"]
    resources = ["*"]
  }
}

#############################################################
# Create ALB for MLflow server
#############################################################
resource "aws_lb" "mlflow_alb" {
  name               = "ml-mlflow-alb"
  internal           = true
  load_balancer_type = "application"
  security_groups    = [aws_security_group.mlflow_alb_sg.id]
  subnets            = [var.subnet_private_id, var.subnet_private2_id]
}
resource "aws_lb_target_group" "mlflow_alb_target" {
  name        = "ml-mlflow-alb-target"
  port        = 80
  protocol    = "HTTP"
  ip_address_type = "ipv4"
  vpc_id      = var.vpc_id
  target_type = "ip"
  health_check {
    protocol            = "HTTP"
    port                = "traffic-port"
    matcher             = "200-299"
    path                = "/"
  }
}
resource "aws_lb_listener" "mlflow" {
  load_balancer_arn = aws_lb.mlflow_alb.arn
  port              = "80"
  protocol          = "HTTP"
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.mlflow_alb_target.arn
  }
}
resource "aws_security_group" "mlflow_alb_sg" {
  name        = "ml-mlflow-alb-sg"
  description = "Security group for MLflow server ALB."
  vpc_id      = var.vpc_id
  ingress {
    protocol        = "tcp"
    self            = true
    cidr_blocks     = [var.cidr_vpc]
    from_port       = 80
    to_port         = 80
    description     = "Allow inbound traffic."
  }
  ingress {
    protocol    = "icmp"
    self        = true
    cidr_blocks = [var.cidr_vpc]
    from_port   = -1
    to_port     = -1
    description = "Communication channel to servers from jump instance."
  }
  egress {
    protocol    = "tcp"
    from_port   = 80
    to_port     = 80
    cidr_blocks = ["0.0.0.0/0"]
  }
}

#############################################################
# Create S3 bucket
#############################################################
resource "aws_s3_bucket" "aws_s3_bucket" {
  bucket        = "ml-mlflow-bucket-${data.aws_caller_identity.current.account_id}"
  force_destroy = true
}

#############################################################
# Create RDS instance with a security group
#############################################################
resource "aws_rds_cluster" "mlflow_db" {
  cluster_identifier     = "ml-mlflow-cluster"
  database_name          = "ml_mlflow_db"
  engine                 = "aurora-mysql"
  engine_version         = "5.7.mysql_aurora.2.11.1"
  engine_mode            = "provisioned"
  master_username        = "admin"
  master_password        = data.aws_ssm_parameter.rds_password.value
  skip_final_snapshot    = true
  db_subnet_group_name   = aws_db_subnet_group.mlflow_subnet_group.name
  vpc_security_group_ids = [aws_security_group.mlflow_db_sg.id]
  port                   = 3306
  lifecycle { ignore_changes = [engine_version,] }
}
resource "aws_rds_cluster_instance" "mlflow_db_instance" {
  count                = 1
  identifier           = "ml-framework-mlflow-cluster-instance"
  cluster_identifier   = aws_rds_cluster.mlflow_db.id
  instance_class       = "db.t3.small"
  engine               = aws_rds_cluster.mlflow_db.engine
  engine_version       = aws_rds_cluster.mlflow_db.engine_version
  db_subnet_group_name = aws_db_subnet_group.mlflow_subnet_group.id
  apply_immediately    = true
}
resource "aws_db_subnet_group" "mlflow_subnet_group" {
  name       = "main"
  subnet_ids = [var.subnet_private_id, var.subnet_private2_id]
}
resource "aws_security_group" "mlflow_db_sg" {
  name        = "ml-mlfloe-db-sg"
  description = "ML framework database security group."
  vpc_id      = var.vpc_id
  ingress {
    protocol        = "tcp"
    self            = true
    security_groups = [aws_security_group.mlflow_server_sg.id]
    from_port       = 3306
    to_port         = 3306
    description     = "Allow inbound traffic from ML framework server to RDS."
  }
  egress {
    protocol    = "-1"
    from_port   = 0
    to_port     = 0
    cidr_blocks = ["0.0.0.0/0"]
  }
}

#############################################################
# Store password value in parameter store
#############################################################
data "aws_secretsmanager_random_password" "rds_master_password" {
  password_length     = 16
  exclude_punctuation = true
}
resource "aws_ssm_parameter" "rds_password" {
  name        = "/ml/mlflow/rds_password"
  description = "Password for MLflow backend database."
  type        = "SecureString"
  value       = data.aws_secretsmanager_random_password.rds_master_password.random_password
  lifecycle { ignore_changes = [value,] }
}
data "aws_ssm_parameter" "rds_password" {
  name = "/ml/mlflow/rds_password"
  depends_on = [aws_ssm_parameter.rds_password]
}

#############################################################
# Output variables
#############################################################
output "mlflow_alb_uri" { value = aws_lb.mlflow_alb.dns_name }

