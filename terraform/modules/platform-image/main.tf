# Platform Image Module
# Manages the shared ECR repository and image tag for the platform container image.
# This image is used by both the bastion and ecs-bootstrap modules.

data "aws_region" "current" {}
data "aws_caller_identity" "current" {}

locals {
  dockerfile_hash = substr(sha256(file("${path.module}/Dockerfile")), 0, 12)
  container_image = "${aws_ecr_repository.platform.repository_url}:${local.dockerfile_hash}"
}

# =============================================================================
# ECR Repository
# =============================================================================

resource "aws_ecr_repository" "platform" {
  name                 = "${var.resource_name_base}/platform"
  image_tag_mutability = "IMMUTABLE"
  force_delete         = true

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = var.tags
}

resource "aws_ecr_lifecycle_policy" "platform" {
  repository = aws_ecr_repository.platform.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Keep last 2 images"
        selection = {
          tagStatus   = "any"
          countType   = "imageCountMoreThan"
          countNumber = 2
        }
        action = {
          type = "expire"
        }
      }
    ]
  })
}
