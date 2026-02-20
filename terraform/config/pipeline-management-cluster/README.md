# Management Cluster Pipeline

This Terraform module provisions AWS CodePipeline and CodeBuild infrastructure for managing Management Cluster deployments in the ROSA Regional Platform. Management clusters host customer control planes via HyperShift operators.

## Overview

The Management Cluster Pipeline automates the deployment, validation, and destruction of EKS-based management clusters through a GitOps-driven workflow. Each management cluster pipeline is uniquely identified by a `target_alias` and operates independently.

## Pipeline Architecture

### CodePipeline Stages

The pipeline consists of three sequential stages:

1. **Source** - Retrieves cluster configuration from GitHub
2. **Validate** - Validates Terraform configuration and plans changes
3. **Apply** - Applies infrastructure changes and bootstraps ArgoCD

### CodeBuild Projects

The pipeline uses four CodeBuild projects:

| Project | Purpose | Buildspec | Trigger |
|---------|---------|-----------|---------|
| `mc-val-*` | Terraform validation and planning | `buildspec-validate.yml` | Automatic (on config changes) |
| `mc-app-*` | Infrastructure provisioning | `buildspec-apply.yml` | Automatic (after validation) |
| `mc-boot-*` | ArgoCD bootstrap | `buildspec-bootstrap.yml` | Automatic (after apply) |
| `mc-dest-*` | Infrastructure destruction | `buildspec-destroy.yml` | Manual (requires `CONFIRM_DESTROY=true`) |

## Execution Flow

### Apply Pipeline Flow

```
┌─────────────────────────────────────────────────────────────┐
│ Source Stage                                                │
│ - GitHub webhook triggers on config changes                │
│ - Downloads repository artifacts                            │
└────────────────────┬────────────────────────────────────────┘
                     │
                     ▼
┌─────────────────────────────────────────────────────────────┐
│ Validate Stage                                             │
│ - Terraform init (S3 backend)                              │
│ - Terraform validate                                        │
│ - Terraform plan                                            │
│ - Output plan artifacts                                     │
└────────────────────┬────────────────────────────────────────┘
                     │
                     ▼
┌─────────────────────────────────────────────────────────────┐
│ Apply Stage                                                 │
│ - Terraform init (S3 backend)                              │
│ - Assume role in target account (if cross-account)        │
│ - Terraform apply                                           │
│   • EKS cluster                                             │
│   • VPC and networking                                      │
│   • IAM roles and policies                                  │
│   • ECS Fargate bastion (if enabled)                       │
│   • Maestro agent secrets                                   │
└────────────────────┬────────────────────────────────────────┘
                     │
                     ▼
┌─────────────────────────────────────────────────────────────┐
│ Bootstrap Stage                                             │
│ - Assume role in target account (if cross-account)        │
│ - Run ECS Fargate task to bootstrap ArgoCD               │
│ - Configure ArgoCD root application                        │
│ - Wait for ArgoCD sync completion                          │
└────────────────────────────────────────────────────────────┘
```

### Destroy Pipeline Flow

```
┌─────────────────────────────────────────────────────────────┐
│ Pre-Build Phase                                            │
│ 1. Safety Check                                            │
│    - Verify CONFIRM_DESTROY=true                            │
│    - Display target information                            │
│                                                             │
│ 2. IoT Cleanup                                             │
│    - Cleanup Maestro agent IoT resources                   │
│    - Remove IoT certificates and policies                   │
│                                                             │
│ 3. Bastion ECS Task Cleanup                                │
│    - Assume role in target account (if cross-account)    │
│    - List ECS clusters ending with "-bastion"             │
│    - Stop all running bastion tasks                        │
│    - Wait for tasks to stop (max 120s)                     │
└────────────────────┬────────────────────────────────────────┘
                     │
                     ▼
┌─────────────────────────────────────────────────────────────┐
│ Build Phase                                                 │
│ - Terraform init (S3 backend)                              │
│ - Resolve regional account ID (SSM or direct)              │
│ - Set Terraform variables                                   │
│ - Terraform destroy -auto-approve                           │
│   • EKS cluster                                             │
│   • VPC and networking                                      │
│   • IAM roles and policies                                  │
│   • ECS Fargate bastion (if enabled)                       │
└────────────────────┬────────────────────────────────────────┘
                     │
                     ▼
┌─────────────────────────────────────────────────────────────┐
│ Post-Build Phase                                           │
│ - Display completion message                                │
│ - Note: State file preserved in S3                          │
└────────────────────────────────────────────────────────────┘
```

## Key Features

### Cross-Account Support

- Supports deploying management clusters to different AWS accounts
- Uses `OrganizationAccountAccessRole` for cross-account access
- Terraform provider assumes role automatically via `assume_role` configuration

### GitOps Integration

- ArgoCD bootstrap automatically configures cluster for GitOps
- Root application points to cluster configuration in GitHub
- Changes to cluster config trigger automatic pipeline execution

### Bastion Support

- Optional ECS Fargate bastion for break-glass access
- Enabled via `enable_bastion` variable
- Provides kubectl, helm, and other tools pre-installed

### Maestro Integration

- Automatically creates Maestro agent secrets in target account
- Registers cluster with regional cluster's IoT Core
- Cleanup script removes IoT resources on destroy

### Safety Mechanisms

- Destroy operations require explicit `CONFIRM_DESTROY=true`
- Separate destroy buildspec prevents accidental destruction
- State files preserved in S3 for audit and recovery

## Variables

### Required Variables

| Variable | Description |
|----------|-------------|
| `github_repo_owner` | GitHub repository owner |
| `github_repo_name` | GitHub repository name |
| `github_connection_arn` | ARN of CodeStar GitHub connection |
| `repository_url` | Git repository URL for cluster configuration |
| `cluster_id` | Logical cluster ID for Maestro registration |
| `regional_aws_account_id` | AWS account ID where regional cluster is hosted |

### Optional Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `github_branch` | `main` | GitHub branch to track |
| `target_account_id` | `""` | Target AWS account ID (empty = central account) |
| `target_region` | `""` | Target AWS region |
| `target_alias` | `""` | Target alias for resource naming |
| `target_environment` | `integration` | Environment name (integration, staging, prod) |
| `app_code` | `infra` | Application code for tagging |
| `service_phase` | `dev` | Service phase (dev, staging, prod) |
| `cost_center` | `000` | Cost center code |
| `repository_branch` | `main` | Git branch for cluster configuration |
| `enable_bastion` | `false` | Enable ECS Fargate bastion |

## Resource Naming

Resources use hash-based naming to ensure uniqueness while staying within AWS length limits:

- **Hash Calculation**: `md5("management-${target_alias}-${account_id}")` (first 12 chars)
- **Pattern**: `mc-{type}-{hash}`
- **Examples**:
  - Pipeline: `mc-pipe-abc123def456`
  - CodeBuild Validate: `mc-val-abc123def456`
  - CodeBuild Apply: `mc-app-abc123def456`
  - CodeBuild Bootstrap: `mc-boot-abc123def456`
  - CodeBuild Destroy: `mc-dest-abc123def456`
  - Artifact Bucket: `mc-abc123def456-12345678`

## Usage

### Provisioning via Pipeline-Provisioner

The pipeline is typically provisioned automatically by the `pipeline-provisioner` when management cluster configurations are detected:

```bash
# Pipeline-provisioner automatically creates this pipeline when it finds:
# deploy/{environment}/{region}/terraform/management/{cluster-name}.json
```

### Manual Provisioning

```hcl
module "management_cluster_pipeline" {
  source = "./terraform/config/pipeline-management-cluster"

  github_repo_owner      = "openshift-online"
  github_repo_name       = "rosa-regional-platform"
  github_connection_arn   = "arn:aws:codestar-connections:..."
  repository_url         = "https://github.com/..."
  cluster_id             = "mc01-us-east-1"
  regional_aws_account_id = "123456789012"

  target_account_id      = "987654321098"
  target_region          = "us-east-1"
  target_alias           = "mc01-us-east-1"
  target_environment     = "staging"
  enable_bastion        = true
}
```

### Triggering Destroy

```bash
# Get project name
CENTRAL_ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
HASH_INPUT="management-mc01-us-east-1-${CENTRAL_ACCOUNT}"
RESOURCE_HASH=$(echo -n "${HASH_INPUT}" | md5sum | cut -c1-12)
BUILD_PROJECT="mc-dest-${RESOURCE_HASH}"

# Trigger destroy
aws codebuild start-build \
  --project-name "${BUILD_PROJECT}" \
  --environment-variables-override \
    name=CONFIRM_DESTROY,value=true,type=PLAINTEXT
```

## State Management

- **Backend**: S3 with lockfile-based locking
- **Location**: `s3://terraform-state-{central_account_id}/management-cluster/{target_alias}.tfstate`
- **Region**: Detected from bucket location or `tf_state_region` in config
- **Locking**: File-based locking (no DynamoDB required)

## Dependencies

- **Regional Cluster**: Management clusters depend on regional cluster infrastructure
- **GitHub Connection**: Requires CodeStar connection to GitHub repository
- **IAM Roles**: Requires `OrganizationAccountAccessRole` in target account for cross-account deployments

## Related Documentation

- [Destroy Procedures](../../../docs/destroy-procedures.md) - Detailed destroy workflow
- [Regional Cluster Pipeline](../pipeline-regional-cluster/README.md) - Regional cluster pipeline documentation
- [Pipeline Provisioner](../pipeline-provisioner/README.md) - Pipeline provisioning automation
