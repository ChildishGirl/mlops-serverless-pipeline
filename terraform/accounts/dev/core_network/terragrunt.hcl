# Add resources from parent terragrunt.hcl
include "root" { path = find_in_parent_folders("envs.hcl") }

# Fetch module
terraform { source = "${get_repo_root()}/workloads/core_network_vpc//" }