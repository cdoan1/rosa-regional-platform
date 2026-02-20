# Destroy Procedures for ROSA Regional Platform

This document describes procedures for destroying ROSA Regional Platform infrastructure through CodePipeline-based automation. These procedures are designed for **development and testing environments** where rapid create/delete cycles are needed.

## Overview

The ROSA Regional Platform supports pipeline-based infrastructure destruction through dedicated destroy CodeBuild projects. This enables automated teardown of:

- **Regional Clusters** - EKS-based regional control plane infrastructure
- **Management Clusters** - EKS clusters hosting customer control planes
- **Pipeline Infrastructure** - CodePipeline and CodeBuild resources themselves

### Destroy Mechanisms

1. **Cluster Destroy** - Destroys actual infrastructure (EKS, VPC, RDS, etc.) via Terraform
2. **Pipeline Destroy** - Destroys CodePipeline infrastructure (buildspec-destroy.yml for pipeline-provisioner)

## Safety Mechanisms

Multiple safety mechanisms prevent accidental destruction:

### 1. CONFIRM_DESTROY Environment Variable

All destroy builds **require** `CONFIRM_DESTROY=true` to be explicitly set. Default value is `false`.

```bash
# This will FAIL (CONFIRM_DESTROY defaults to false)
aws codebuild start-build --project-name rc-dest-abc123def456

# This will succeed
aws codebuild start-build \
  --project-name rc-dest-abc123def456 \
  --environment-variables-override \
    name=CONFIRM_DESTROY,value=true,type=PLAINTEXT
```

### 2. Separate Buildspec Files

Destroy operations use dedicated buildspec files (`buildspec-destroy.yml`), completely separate from apply workflows. There is no risk of accidentally triggering destroy through normal apply pipelines.

### 3. Manual Invocation Required

Destroy builds must be manually triggered via AWS CLI. They are **not** triggered by GitHub webhooks or CodePipeline stages.

### 4. State Preservation

Terraform state files remain in S3 after destroy for audit and recovery purposes:
- Regional clusters: `s3://terraform-state-<account>/regional-cluster/<alias>.tfstate`
- Management clusters: `s3://terraform-state-<account>/management-cluster/<alias>.tfstate`

## Destroy Procedures

### Prerequisites

- AWS CLI installed and configured
- Credentials for the central account with CodeBuild permissions
- Cluster alias and environment name

### 1. Destroy Management Cluster

**IMPORTANT**: Always destroy management clusters **before** destroying regional clusters, as management clusters depend on regional infrastructure.

#### Option A: Using Helper Script (Recommended)

```bash
# Navigate to repository root
cd rosa-regional-platform

# Run trigger script
./scripts/trigger-pipeline-destroy.sh management mc01-us-east-1 cdoan-central

# Follow prompts to confirm destruction
```

#### Option B: Manual AWS CLI

```bash
# Step 1: Get central account ID
CENTRAL_ACCOUNT=$(aws sts get-caller-identity --query Account --output text)

# Step 2: Calculate resource hash (same logic as Terraform)
HASH_INPUT="management-mc01-us-east-1-${CENTRAL_ACCOUNT}"
RESOURCE_HASH=$(echo -n "${HASH_INPUT}" | md5sum | cut -c1-12)

# Step 3: Derive CodeBuild project name
BUILD_PROJECT="mc-dest-${RESOURCE_HASH}"

# Step 4: Start destroy build
aws codebuild start-build \
  --project-name "${BUILD_PROJECT}" \
  --environment-variables-override \
    name=CONFIRM_DESTROY,value=true,type=PLAINTEXT

# Step 5: Monitor build logs
aws logs tail /aws/codebuild/${BUILD_PROJECT} --follow
```

### 2. Destroy Regional Cluster

Destroy regional clusters **after** all management clusters in that region have been destroyed.

#### Option A: Using Helper Script (Recommended)

```bash
./scripts/trigger-pipeline-destroy.sh regional regional-us-east-1 cdoan-central
```

#### Option B: Manual AWS CLI

```bash
# Step 1: Get central account ID
CENTRAL_ACCOUNT=$(aws sts get-caller-identity --query Account --output text)

# Step 2: Calculate resource hash
HASH_INPUT="regional-regional-us-east-1-${CENTRAL_ACCOUNT}"
RESOURCE_HASH=$(echo -n "${HASH_INPUT}" | md5sum | cut -c1-12)

# Step 3: Derive CodeBuild project name
BUILD_PROJECT="rc-dest-${RESOURCE_HASH}"

# Step 4: Start destroy build
aws codebuild start-build \
  --project-name "${BUILD_PROJECT}" \
  --environment-variables-override \
    name=CONFIRM_DESTROY,value=true,type=PLAINTEXT

# Step 5: Monitor build logs
aws logs tail /aws/codebuild/${BUILD_PROJECT} --follow
```

### 3. Destroy Pipeline Infrastructure (Optional)

Destroys the CodePipeline and CodeBuild infrastructure for an entire environment. This is typically only done when completely decommissioning an environment.

```bash
# NOT YET IMPLEMENTED - Manual Terraform destroy required
cd terraform/config/pipeline-provisioner
terraform init
terraform destroy
```

## Order of Operations

When destroying a complete environment, follow this order:

```
1. Management Clusters (all clusters in all regions)
   └─ IoT resources cleaned automatically (Maestro agent)

2. Regional Clusters (after all management clusters)
   └─ EKS, VPC, RDS, API Gateway, Maestro server

3. Pipeline Infrastructure (optional - only if decommissioning environment)
   └─ CodePipeline, CodeBuild projects, S3 artifact buckets
```

### Example: Complete Environment Teardown

```bash
# Environment: cdoan-central
# Regions: us-east-1, us-east-2

# 1. Destroy all management clusters
./scripts/trigger-pipeline-destroy.sh management mc01-us-east-1 cdoan-central
./scripts/trigger-pipeline-destroy.sh management mc02-us-east-1 cdoan-central
./scripts/trigger-pipeline-destroy.sh management mc01-us-east-2 cdoan-central

# Wait for all management cluster destroys to complete

# 2. Destroy all regional clusters
./scripts/trigger-pipeline-destroy.sh regional regional-us-east-1 cdoan-central
./scripts/trigger-pipeline-destroy.sh regional regional-us-east-2 cdoan-central

# 3. (Optional) Destroy pipeline infrastructure
# Manual Terraform destroy in pipeline-provisioner directory
```

## Monitoring Destroy Progress

### CloudWatch Logs

Real-time monitoring of destroy operations:

```bash
# Get build project name from trigger script output
BUILD_PROJECT="rc-dest-abc123def456"

# Tail logs in real-time
aws logs tail /aws/codebuild/${BUILD_PROJECT} --follow
```

### CodeBuild Console

Monitor via AWS Console:
```
https://console.aws.amazon.com/codesuite/codebuild/projects/<project-name>/build/<build-id>
```

### Build Status

Check build status programmatically:

```bash
BUILD_ID="rc-dest-abc123def456:uuid"

aws codebuild batch-get-builds \
  --ids "${BUILD_ID}" \
  --query 'builds[0].buildStatus' \
  --output text
```

## Troubleshooting

### Common Destroy Failures

#### 1. RDS Deletion Protection Enabled

**Error**: `Cannot delete RDS instance with deletion protection enabled`

**Solution**: Disable deletion protection before destroy:

```bash
# Add to terraform.tfvars
enable_deletion_protection = false

# Re-run apply to update the setting
make pipeline-provision-regional

# Then run destroy
./scripts/trigger-pipeline-destroy.sh regional regional-us-east-1 cdoan-central
```

#### 2. VPC Dependency Errors

**Error**: `VPC has dependencies and cannot be deleted`

**Cause**: Resources (ENIs, ELBs, NAT Gateways) not properly cleaned up.

**Solution**:
1. Check for orphaned resources in AWS Console
2. Manually delete dependent resources
3. Retry destroy build

#### 3. IoT Certificate Deletion Failure

**Error**: `Cannot delete IoT certificate - still attached to policy`

**Cause**: IoT cleanup script failed or was skipped.

**Solution**: Run IoT cleanup manually:

```bash
# Interactive cleanup
./scripts/cleanup-maestro-agent-iot.sh terraform/config/management-cluster/terraform.tfvars

# Or retry destroy build (IoT cleanup runs automatically)
```

#### 4. EKS Cluster Deletion Timeout

**Error**: `EKS cluster deletion timed out`

**Cause**: Kubernetes resources (LoadBalancers, PVCs) not cleaned up before destroy.

**Solution**:
1. Clean up Kubernetes resources via kubectl before destroy
2. Use ArgoCD to delete applications first
3. Manually delete EKS-managed ENIs if needed

#### 5. S3 Bucket Not Empty

**Error**: `Cannot delete S3 bucket - not empty`

**Cause**: Terraform cannot delete non-empty buckets by default.

**Solution**: Add force_destroy flag or manually empty bucket:

```bash
# Empty bucket
aws s3 rm s3://bucket-name --recursive

# Then retry destroy
```

### Debugging Destroy Failures

1. **Check CloudWatch Logs** for detailed error messages
2. **Review Terraform state** to see what resources failed to destroy:
   ```bash
   # Download state file
   aws s3 cp s3://terraform-state-<account>/regional-cluster/<alias>.tfstate .

   # List resources
   terraform state list
   ```
3. **Manually clean up** failed resources via AWS Console or CLI
4. **Retry destroy** after manual cleanup

## Recovery Procedures

### Partial Destroy Failure

If destroy fails partway through:

1. **Review state file** to see remaining resources:
   ```bash
   terraform state list
   ```

2. **Manually delete** problematic resources via AWS Console

3. **Update state** to remove manually deleted resources:
   ```bash
   terraform state rm <resource-address>
   ```

4. **Retry destroy build** to clean up remaining resources

### Accidental Destroy

If infrastructure was accidentally destroyed:

1. **Locate state file** in S3 (preserved after destroy):
   ```bash
   aws s3 cp s3://terraform-state-<account>/regional-cluster/<alias>.tfstate .
   ```

2. **Re-provision** using the same configuration:
   ```bash
   # Regional cluster
   make pipeline-provision-regional

   # Management cluster
   make pipeline-provision-management
   ```

3. **Restore data** from backups (RDS snapshots, etc.)

### State File Corruption

If Terraform state becomes corrupted:

1. **Download previous version** from S3 versioning:
   ```bash
   aws s3api list-object-versions \
     --bucket terraform-state-<account> \
     --prefix regional-cluster/<alias>.tfstate

   aws s3api get-object \
     --bucket terraform-state-<account> \
     --key regional-cluster/<alias>.tfstate \
     --version-id <version-id> \
     terraform.tfstate
   ```

2. **Restore state file** to S3:
   ```bash
   aws s3 cp terraform.tfstate \
     s3://terraform-state-<account>/regional-cluster/<alias>.tfstate
   ```

3. **Verify state** matches actual infrastructure:
   ```bash
   terraform plan
   ```

## Best Practices

### Before Destroy

- [ ] **Clean up ArgoCD applications** - Delete apps before destroying clusters
- [ ] **Export critical data** - Backup RDS, export secrets, etc.
- [ ] **Notify team members** - Ensure no one is actively using the cluster
- [ ] **Document reason** - Record why infrastructure is being destroyed
- [ ] **Check dependencies** - Ensure no other clusters depend on this infrastructure

### During Destroy

- [ ] **Monitor logs** - Watch CloudWatch Logs for errors
- [ ] **Stay available** - Be ready to troubleshoot issues
- [ ] **Track progress** - Note how long each phase takes

### After Destroy

- [ ] **Verify completion** - Check AWS Console to ensure all resources removed
- [ ] **Check costs** - Ensure AWS costs drop as expected
- [ ] **Update documentation** - Record any issues encountered
- [ ] **Preserve state files** - Keep state files in S3 for audit trail

## Development Workflow: Create/Delete Cycles

For rapid development iteration:

```bash
# 1. Create infrastructure
make pipeline-provision-regional

# 2. Test changes
# ... run tests, validate configuration ...

# 3. Destroy infrastructure
./scripts/trigger-pipeline-destroy.sh regional regional-us-east-1 cdoan-central

# 4. Make code changes
# ... edit Terraform, update configs ...

# 5. Repeat cycle
make pipeline-provision-regional
```

## Limitations

- **No terraform plan preview** - Destroy uses `-auto-approve` for speed
- **Development-only** - Not designed for production safety requirements
- **Manual trigger only** - No GitOps-driven destroy workflow
- **No rollback** - Destroy is permanent (recovery requires reprovisioning)
- **ArgoCD manual cleanup** - Kubernetes resources should be cleaned before destroy

## Related Documentation

- [Architecture Overview](README.md) - Understanding regional platform architecture
- [Pipeline Provisioning](../terraform/config/pipeline-provisioner/README.md) - Creating pipelines
- [IoT Cleanup](../scripts/cleanup-maestro-agent-iot.sh) - Manual IoT resource cleanup
- [Terraform State Management](https://developer.hashicorp.com/terraform/language/state) - Understanding state files

## Support

For issues or questions:

1. Check CloudWatch Logs for detailed error messages
2. Review [Troubleshooting](#troubleshooting) section above
3. Consult with platform team for complex issues
4. Report bugs via GitHub Issues
