output "container_image" {
  description = "Full container image reference (repository:tag)"
  value       = local.container_image
}

output "ecr_repository_url" {
  description = "ECR repository URL"
  value       = aws_ecr_repository.platform.repository_url
}

output "image_tag" {
  description = "Current image tag derived from Dockerfile SHA"
  value       = local.dockerfile_hash
}
