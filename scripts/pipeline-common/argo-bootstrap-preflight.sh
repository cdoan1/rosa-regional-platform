#!/usr/bin/env bash
#
# argo-bootstrap-preflight.sh - Pre-flight setup for ArgoCD bootstrap pipelines
#
# This script handles the common pre_build logic for both regional and management cluster
# bootstrap pipelines:
# - Validates required environment variables
# - Detects central account and S3 state bucket region
# - Saves central account credentials for Terraform backend access
# - Assumes role in target account (if cross-account)
# - Builds platform image in target account
#
# Expected environment variables:
#   TARGET_ACCOUNT_ID - The target AWS account ID
#   TARGET_REGION     - The target AWS region
#   TARGET_ALIAS      - The target cluster alias
#
# Exports:
#   CENTRAL_ACCOUNT_ID           - Central account ID (for S3 state bucket)
#   TF_STATE_REGION              - Region where S3 state bucket is located
#   CENTRAL_AWS_ACCESS_KEY_ID       - Saved central account credentials
#   CENTRAL_AWS_SECRET_ACCESS_KEY   - Saved central account credentials
#   CENTRAL_AWS_SESSION_TOKEN       - Saved central account credentials
#   TARGET_AWS_ACCESS_KEY_ID     - Target account credentials (for ECR/ECS/EKS)
#   TARGET_AWS_SECRET_ACCESS_KEY - Target account credentials
#   TARGET_AWS_SESSION_TOKEN     - Target account credentials
#   TF_VAR_target_account_id     - Terraform variable for target account
#   TF_VAR_target_alias          - Terraform variable for target alias

set -euo pipefail

echo "=========================================="
echo "Pre-flight Setup"
echo "=========================================="

# Validate required environment variables
if [[ -z "${TARGET_ACCOUNT_ID:-}" || -z "${TARGET_REGION:-}" || -z "${TARGET_ALIAS:-}" ]]; then
    echo "❌ ERROR: Required environment variables not set"
    echo "   TARGET_ACCOUNT_ID: ${TARGET_ACCOUNT_ID:-not set}"
    echo "   TARGET_REGION: ${TARGET_REGION:-not set}"
    echo "   TARGET_ALIAS: ${TARGET_ALIAS:-not set}"
    exit 1
fi

# Detect central account and S3 state bucket region
source "$(dirname "${BASH_SOURCE[0]}")/detect-central-state.sh"

echo "Configuration:"
echo "  Central Account: $CENTRAL_ACCOUNT_ID"
echo "  Target Account: $TARGET_ACCOUNT_ID"
echo "  Target Region: $TARGET_REGION"
echo "  Target Alias: $TARGET_ALIAS"
echo "  State Bucket Region: $TF_STATE_REGION"
echo ""

# Assume role in target account for target-specific operations (ECR, ECS, EKS)
source "$(dirname "${BASH_SOURCE[0]}")/assume-target-role.sh" "target account operations"

# Pass target account to Terraform for consistency
export TF_VAR_target_account_id="${TARGET_ACCOUNT_ID}"
export TF_VAR_target_alias="${TARGET_ALIAS}"

# Build platform image (uses target account credentials to push to target ECR)
echo "Building platform image (if needed)..."
AWS_ACCESS_KEY_ID="$TARGET_AWS_ACCESS_KEY_ID" \
AWS_SECRET_ACCESS_KEY="$TARGET_AWS_SECRET_ACCESS_KEY" \
AWS_SESSION_TOKEN="$TARGET_AWS_SESSION_TOKEN" \
make build-platform-image
echo ""

echo "✅ Pre-flight setup complete"
