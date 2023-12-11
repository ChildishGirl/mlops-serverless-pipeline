# Add resources from parent terragrunt.hcl
include "root" { path = find_in_parent_folders("envs.hcl") }

# Fetch module
terraform { source = "${get_repo_root()}/workloads/ml_mlflow_server//" }

# Add dependencies and inputs
dependency "vpc" { config_path = "../core_network" }
inputs = {
  vpc_id                = dependency.vpc.outputs.vpc_id
  cidr_vpc              = dependency.vpc.outputs.cidr_vpc
  subnet_private_id     = dependency.vpc.outputs.subnet_private_id
  subnet_private_az     = dependency.vpc.outputs.subnet_private_az
  subnet_private2_id    = dependency.vpc.outputs.subnet_private2_id
}