#!/bin/bash

set -euo pipefail

echo "Destroying in account: ${TARGET_ACCOUNT_ID}"
echo "  Region: ${TARGET_REGION}"
echo "  Alias: ${TARGET_ALIAS}"
echo ""

# Configure Terraform backend (state in central account, region detected in pre_build)
export TF_STATE_BUCKET="terraform-state-${CENTRAL_ACCOUNT_ID}"
export TF_STATE_KEY="regional-cluster/${TARGET_ALIAS}.tfstate"

echo "Terraform backend:"
echo "  Bucket: $TF_STATE_BUCKET (central account: $CENTRAL_ACCOUNT_ID)"
echo "  Key: $TF_STATE_KEY"
echo "  Region: $TF_STATE_REGION"
echo ""

# Change to regional cluster Terraform directory
cd terraform/config/regional-cluster

# Initialize Terraform with backend configuration
echo "Initializing Terraform..."
terraform init \
    -backend-config="bucket=${TF_STATE_BUCKET}" \
    -backend-config="key=${TF_STATE_KEY}" \
    -backend-config="region=${TF_STATE_REGION}"

# Set Terraform variables for destroy (same as apply)
export TF_VAR_region="${TARGET_REGION}"
export TF_VAR_target_account_id="${TARGET_ACCOUNT_ID}"
export TF_VAR_target_alias="${TARGET_ALIAS}"
export TF_VAR_app_code="${APP_CODE}"
export TF_VAR_service_phase="${SERVICE_PHASE}"
export TF_VAR_cost_center="${COST_CENTER}"

# Set repository variables with fallback handling
_REPO_BRANCH="${REPOSITORY_BRANCH:-${GITHUB_BRANCH:-main}}"
export TF_VAR_repository_url="${REPOSITORY_URL:-https://github.com/${GITHUB_REPO_OWNER}/${GITHUB_REPO_NAME}.git}"
export TF_VAR_repository_branch="${_REPO_BRANCH}"

export TF_VAR_api_additional_allowed_accounts="${TARGET_ACCOUNT_ID}"

# Enable bastion variable (default to false)
ENABLE_BASTION="${ENABLE_BASTION:-false}"
if [ "$ENABLE_BASTION" == "true" ] || [ "$ENABLE_BASTION" == "1" ]; then
    export TF_VAR_enable_bastion="true"
else
    export TF_VAR_enable_bastion="false"
fi

echo "Terraform variables configured for destroy"
echo ""

# Run Terraform destroy
echo "⚠️  Running terraform destroy -auto-approve..."
terraform destroy -auto-approve

echo ""
echo "✅ Regional cluster destroyed successfully."