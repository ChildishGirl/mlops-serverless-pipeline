# Add resources from parent terragrunt.hcl
include "root" { path = find_in_parent_folders("envs.hcl") }

# Fetch module
terraform { source = "${get_repo_root()}/workloads/ml_cicd_with_approval//" }

# Add dependencies and inputs
dependency "vpc" { config_path = "../core_network" }
dependency "mlflow" { config_path = "../ml_mlflow_server" }
inputs = {
  subnet_private_id     = dependency.vpc.outputs.subnet_private_id
  subnet_private2_id    = dependency.vpc.outputs.subnet_private2_id
  vpc_id                = dependency.vpc.outputs.vpc_id
  mlflow_alb_uri        = dependency.mlflow.outputs.mlflow_alb_uri
}