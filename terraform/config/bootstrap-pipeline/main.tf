provider "aws" {
  region = var.region
}

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

# Shared GitHub Connection - authorize once, use everywhere
resource "aws_codestarconnections_connection" "github_shared" {
  name          = "rosa-regional-github-shared"
  provider_type = "GitHub"
}

# Platform Image ECR Repository
module "platform_image" {
  source = "../../modules/platform-image"

  resource_name_base = "rosa-regional"
  tags = {
    Name        = "rosa-regional-platform-image"
    Environment = var.environment
  }
}

module "pipeline_provisioner" {
  source = "../pipeline-provisioner"

  github_repo_owner     = var.github_repo_owner
  github_repo_name      = var.github_repo_name
  github_branch         = var.github_branch
  region                = var.region
  environment           = var.environment
  github_connection_arn = aws_codestarconnections_connection.github_shared.arn
}
