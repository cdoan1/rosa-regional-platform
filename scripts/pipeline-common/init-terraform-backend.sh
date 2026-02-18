#!/usr/bin/env bash
#
# init-terraform-backend.sh - Initialize Terraform with central account backend
#
# This script handles common Terraform backend initialization for bootstrap pipelines:
# - Restores central account credentials (for S3 backend access)
# - Configures Terraform backend (state in central account)
# - Initializes Terraform with backend configuration
#
# Usage: init-terraform-backend.sh <cluster-type> <region> <alias>
#   cluster-type: regional-cluster or management-cluster
#   region: AWS region for the cluster
#   alias: Cluster alias for state key
#
# Expected environment variables:
#   CENTRAL_AWS_ACCESS_KEY_ID     - Saved central account credentials
#   CENTRAL_AWS_SECRET_ACCESS_KEY - Saved central account credentials
#   CENTRAL_AWS_SESSION_TOKEN     - Saved central account credentials
#   CENTRAL_ACCOUNT_ID         - Central account ID (for S3 state bucket)
#   TF_STATE_REGION            - Region where S3 state bucket is located

set -euo pipefail

# Validate arguments
if [ $# -ne 3 ]; then
    echo "❌ ERROR: init-terraform-backend.sh requires exactly 3 arguments"
    echo "Usage: init-terraform-backend.sh <cluster-type> <region> <alias>"
    echo "  cluster-type: regional-cluster or management-cluster"
    echo "  region: AWS region for the cluster"
    echo "  alias: Cluster alias for state key"
    exit 1
fi

CLUSTER_TYPE=$1
REGION=$2
ALIAS=$3

# Validate cluster type
if [[ "$CLUSTER_TYPE" != "regional-cluster" && "$CLUSTER_TYPE" != "management-cluster" ]]; then
    echo "❌ ERROR: cluster-type must be 'regional-cluster' or 'management-cluster'"
    exit 1
fi

# Restore central account credentials for Terraform backend access
echo "Restoring central account credentials for Terraform backend access..."
export AWS_ACCESS_KEY_ID="${CENTRAL_AWS_ACCESS_KEY_ID}"
export AWS_SECRET_ACCESS_KEY="${CENTRAL_AWS_SECRET_ACCESS_KEY}"
export AWS_SESSION_TOKEN="${CENTRAL_AWS_SESSION_TOKEN}"

# Verify we're back to central account
CURRENT_ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
echo "Current account: $CURRENT_ACCOUNT (central: $CENTRAL_ACCOUNT_ID)"
echo ""

# Configure Terraform region via environment variable (HashiCorp recommended approach)
export TF_VAR_region="${REGION}"

# Configure Terraform backend (state in central account, region detected in pre_build)
export TF_STATE_BUCKET="terraform-state-${CENTRAL_ACCOUNT_ID}"
export TF_STATE_KEY="${CLUSTER_TYPE}/${ALIAS}.tfstate"

echo "Terraform backend configuration:"
echo "  Bucket: $TF_STATE_BUCKET (in central account)"
echo "  Key: $TF_STATE_KEY"
echo "  Region: $TF_STATE_REGION"
echo ""

# Initialize Terraform (uses central account credentials for S3 backend)
echo "Initializing Terraform (uses central account credentials for S3 backend)..."
(
    cd "terraform/config/${CLUSTER_TYPE}"
    terraform init -reconfigure \
        -backend-config="bucket=${TF_STATE_BUCKET}" \
        -backend-config="key=${TF_STATE_KEY}" \
        -backend-config="region=${TF_STATE_REGION}" \
        -backend-config="use_lockfile=true"
)

echo "✓ Terraform backend initialized successfully"

# Verify terraform outputs are available
echo "Checking terraform outputs are available..."
(
    cd "terraform/config/${CLUSTER_TYPE}"
    if ! terraform output -json > /tmp/tf-outputs.json 2>&1; then
        echo "❌ Failed to read terraform outputs"
        cat /tmp/tf-outputs.json
        exit 1
    fi
    echo "✓ Terraform outputs available:"
    jq 'keys' /tmp/tf-outputs.json
)
