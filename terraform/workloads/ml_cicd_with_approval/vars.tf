variable "subnet_private_id" {
  type        = string
  description = "Id of the private subnet."
}

variable "subnet_private2_id" {
  type        = string
  description = "Id of the second private subnet."
}

variable "feature_name" {
  type        = string
  description = "Name of the feature for which CI/CD process is created."
  default = "test"
}

variable "mlflow_alb_uri" {
  type        = string
  description = "URI of MLflow server Application load balancer."
}

variable "vpc_id" {
  type        = string
  description = "ID of the VPC."
}