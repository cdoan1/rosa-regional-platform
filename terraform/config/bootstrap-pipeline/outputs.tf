# =============================================================================
# Pipeline Provisioner Outputs
# =============================================================================

output "provisioner_pipeline_name" {
  description = "Name of the Pipeline Provisioner CodePipeline"
  value       = module.pipeline_provisioner.provisioner_pipeline_name
}

output "provisioner_pipeline_arn" {
  description = "ARN of the Pipeline Provisioner CodePipeline"
  value       = module.pipeline_provisioner.provisioner_pipeline_arn
}

output "github_connection_arn" {
  description = "ARN of the GitHub connection for Pipeline Provisioner"
  value       = module.pipeline_provisioner.github_connection_arn
}

output "github_connection_status" {
  description = "Status of the GitHub connection (requires manual authorization)"
  value       = module.pipeline_provisioner.github_connection_status
}

output "provisioner_role_arn" {
  description = "ARN of the IAM role used by the provisioner CodeBuild project"
  value       = module.pipeline_provisioner.provisioner_role_arn
}

# =============================================================================
# General Information
# =============================================================================

output "central_account_id" {
  description = "AWS Account ID where pipelines are deployed"
  value       = data.aws_caller_identity.current.account_id
}

output "deployment_region" {
  description = "AWS Region where pipelines are deployed"
  value       = data.aws_region.current.id
}
