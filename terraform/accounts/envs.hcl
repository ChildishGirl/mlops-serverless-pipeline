remote_state {
  backend  = "s3"
  generate = {
    path      = "backend.tf"
    if_exists = "overwrite"
  }
  config = {
    bucket  = "tf-state-mlops"
    key     = "${path_relative_to_include()}.tfstate"
    region  = "eu-central-1"
    encrypt = true
  }
}

generate "provider" {
  path      = "providers.tf"
  if_exists = "overwrite"
  contents  = <<EOF
    provider "aws" {
      region = "eu-central-1"
}
    provider "aws" {
      alias  = "stage"
      region = "eu-central-1"
      profile = "wrkld1-dev"
      default_tags { tags = {"BelongsToWrkldInAnotherAcc" : "true"} }
}
    provider "aws" {
      alias  = "prod"
      region = "eu-central-1"
      profile = "wrkld1-prod"
      default_tags { tags = {"BelongsToWrkldInAnotherAcc" : "true"} }
}
EOF
}
generate "terraform_reqconf" {
  path      = "terraform_req_version.tf"
  if_exists = "overwrite"
  contents  = <<EOF
terraform { required_version = ">= 1.0.0, < 2.0.0" }
EOF
}