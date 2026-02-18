#!/usr/bin/env bash
#
# assume-target-role.sh - Assume role in target account for specific operations
#
# This script handles cross-account role assumption for target account operations
# (e.g., Secrets Manager, ECR). It saves the current (central) credentials and
# assumes the OrganizationAccountAccessRole in the target account if needed.
#
# Usage: source assume-target-role.sh "<operation-description>"
#   operation-description: Description of what these credentials will be used for
#                         (e.g., "Secrets Manager operations", "ECR operations")
#
# Expected environment variables:
#   TARGET_ACCOUNT_ID   - Target AWS account ID
#   TARGET_ALIAS        - Target cluster alias (for session naming)
#   CENTRAL_ACCOUNT_ID  - Central AWS account ID
#
# Exports:
#   CENTRAL_AWS_ACCESS_KEY_ID     - Saved central account credentials
#   CENTRAL_AWS_SECRET_ACCESS_KEY - Saved central account credentials
#   CENTRAL_AWS_SESSION_TOKEN     - Saved central account credentials
#   TARGET_AWS_ACCESS_KEY_ID   - Target account credentials (or same as central)
#   TARGET_AWS_SECRET_ACCESS_KEY - Target account credentials (or same as central)
#   TARGET_AWS_SESSION_TOKEN   - Target account credentials (or same as central)

set -euo pipefail

# Validate required argument
if [ $# -ne 1 ]; then
    echo "❌ ERROR: assume-target-role.sh requires exactly 1 argument"
    echo "Usage: source assume-target-role.sh \"<operation-description>\""
    exit 1
fi

OPERATION_DESC=$1

# Save central account credentials before assuming role
# These will be restored later for Terraform backend access
export CENTRAL_AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID:-}"
export CENTRAL_AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY:-}"
export CENTRAL_AWS_SESSION_TOKEN="${AWS_SESSION_TOKEN:-}"

# Prepare target account credentials for the specified operations
# NOTE: We assume role only for target account operations, then restore central creds for Terraform
if [ "$TARGET_ACCOUNT_ID" != "$CENTRAL_ACCOUNT_ID" ]; then
    ROLE_ARN="arn:aws:iam::${TARGET_ACCOUNT_ID}:role/OrganizationAccountAccessRole"
    echo "Assuming role for ${OPERATION_DESC}: $ROLE_ARN"

    if ! TEMP_CREDS=$(aws sts assume-role \
        --role-arn "$ROLE_ARN" \
        --role-session-name "pipeline-${TARGET_ALIAS}" \
        --query 'Credentials.[AccessKeyId,SecretAccessKey,SessionToken]' \
        --output text 2>&1); then
        echo "❌ ERROR: Failed to assume role $ROLE_ARN"
        echo "Error: $TEMP_CREDS"
        exit 1
    fi

    # Store assumed credentials for use in build phase (target account operations)
    export TARGET_AWS_ACCESS_KEY_ID=$(echo "$TEMP_CREDS" | awk '{print $1}')
    export TARGET_AWS_SECRET_ACCESS_KEY=$(echo "$TEMP_CREDS" | awk '{print $2}')
    export TARGET_AWS_SESSION_TOKEN=$(echo "$TEMP_CREDS" | awk '{print $3}')

    # Verify the assumed role credentials work
    ASSUMED_ACCOUNT=$(AWS_ACCESS_KEY_ID="$TARGET_AWS_ACCESS_KEY_ID" \
                      AWS_SECRET_ACCESS_KEY="$TARGET_AWS_SECRET_ACCESS_KEY" \
                      AWS_SESSION_TOKEN="$TARGET_AWS_SESSION_TOKEN" \
                      aws sts get-caller-identity --query Account --output text)
    if [ "$ASSUMED_ACCOUNT" != "$TARGET_ACCOUNT_ID" ]; then
        echo "❌ ERROR: Assumed wrong account. Expected $TARGET_ACCOUNT_ID, got $ASSUMED_ACCOUNT"
        exit 1
    fi

    echo "✅ Assumed role in account $TARGET_ACCOUNT_ID (credentials saved for ${OPERATION_DESC})"
else
    echo "✅ Target account same as central - using current credentials for both operations"
    # For same-account deployments, use current credentials for both
    export TARGET_AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID:-}"
    export TARGET_AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY:-}"
    export TARGET_AWS_SESSION_TOKEN="${AWS_SESSION_TOKEN:-}"
fi
echo ""
