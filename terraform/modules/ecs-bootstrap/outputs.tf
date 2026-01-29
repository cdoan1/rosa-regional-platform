# Outputs for ECS Bootstrap Module

output "ecs_cluster_arn" {
  description = "ARN of the ECS cluster for bootstrap tasks"
  value       = aws_ecs_cluster.bootstrap.arn
}

output "ecs_cluster_name" {
  description = "Name of the ECS cluster for bootstrap tasks"
  value       = aws_ecs_cluster.bootstrap.name
}

output "task_definition_arn" {
  description = "ARN of the ECS task definition for bootstrap execution"
  value       = aws_ecs_task_definition.bootstrap.arn
}

output "task_definition_family" {
  description = "Family name of the ECS task definition"
  value       = aws_ecs_task_definition.bootstrap.family
}

output "log_group_name" {
  description = "CloudWatch log group name for bootstrap operations"
  value       = aws_cloudwatch_log_group.bootstrap.name
}

output "log_group_arn" {
  description = "CloudWatch log group ARN for bootstrap operations"
  value       = aws_cloudwatch_log_group.bootstrap.arn
}

output "task_role_arn" {
  description = "ARN of the ECS task role used for bootstrap execution"
  value       = aws_iam_role.task.arn
}

output "execution_role_arn" {
  description = "ARN of the ECS execution role used for bootstrap tasks"
  value       = aws_iam_role.execution.arn
}

output "bootstrap_security_group_id" {
  description = "Security group ID for bootstrap ECS tasks"
  value       = aws_security_group.bootstrap_task.id
}

output "private_subnets" {
  description = "Private subnet IDs where bootstrap tasks will run"
  value       = var.private_subnets
}

output "repository_url" {
  description = "Git repository URL for cluster configuration"
  value       = var.repository_url
}

output "repository_branch" {
  description = "Git branch for cluster configuration"
  value       = var.repository_branch
}