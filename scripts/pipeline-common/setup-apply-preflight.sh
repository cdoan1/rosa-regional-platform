#!/usr/bin/env bash
#
# setup-apply-preflight.sh - Common pre-flight setup for apply pipelines
#
# This script handles the common pre_build logic for both regional and management cluster
# apply pipelines:
# - Validates required environment variables
# - Initializes account credential helpers
# - Outputs configuration summary
#
# Expected environment variables:
#   TARGET_ACCOUNT_ID - The target AWS account ID
#   TARGET_REGION     - The target AWS region
#   TARGET_ALIAS      - The target cluster alias
#
# Exports:
#   CENTRAL_ACCOUNT_ID - Central account ID (via init_account_helpers)

set -euo pipefail

echo "=========================================="
echo "Pre-flight Setup"
echo "=========================================="

# Validate required environment variables
if [[ -z "${TARGET_ACCOUNT_ID:-}" || -z "${TARGET_REGION:-}" || -z "${TARGET_ALIAS:-}" ]]; then
    echo "ERROR: Required environment variables not set"
    echo "   TARGET_ACCOUNT_ID: ${TARGET_ACCOUNT_ID:-not set}"
    echo "   TARGET_REGION: ${TARGET_REGION:-not set}"
    echo "   TARGET_ALIAS: ${TARGET_ALIAS:-not set}"
    exit 1
fi

# Initialize account credential helpers (captures central creds)
source "$(dirname "${BASH_SOURCE[0]}")/account-helpers.sh"
init_account_helpers

echo "Configuration:"
echo "  Central Account: $CENTRAL_ACCOUNT_ID"
echo "  Target Account: $TARGET_ACCOUNT_ID"
echo "  Target Region: $TARGET_REGION"
echo "  Target Alias: $TARGET_ALIAS"
echo ""

# Export Terraform variables used by both regional and management apply pipelines
# Intentionally empty: pipelines already assume the target account role via
# use_mc_account/use_rc_account, so the provider should use ambient creds
# rather than attempting a second assume-role into the same account.
export TF_VAR_target_account_id=""
export TF_VAR_target_alias="${TARGET_ALIAS}"
