#!/usr/bin/env bash
#
# setup-apply-preflight.sh - Common pre-flight setup for apply pipelines
#
# This script handles the common pre_build logic for both regional and management cluster
# apply pipelines:
# - Validates required environment variables
# - Detects central account ID (for S3 state bucket access)
# - Detects S3 state bucket region
# - Outputs configuration summary
#
# Expected environment variables:
#   TARGET_ACCOUNT_ID - The target AWS account ID
#   TARGET_REGION     - The target AWS region
#   TARGET_ALIAS      - The target cluster alias
#
# Exports:
#   CENTRAL_ACCOUNT_ID - Central account ID (for S3 state bucket)
#   TF_STATE_REGION    - Region where S3 state bucket is located

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

# Export Terraform variables used by both regional and management apply pipelines
export TF_VAR_target_account_id="${TARGET_ACCOUNT_ID}"
export TF_VAR_target_alias="${TARGET_ALIAS}"
