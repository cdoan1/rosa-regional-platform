#!/bin/bash

set -euo pipefail

echo "=========================================="
echo "🔥 DESTROY SAFETY CHECK"
echo "=========================================="

# Require explicit confirmation
if [ "${CONFIRM_DESTROY:-false}" != "true" ]; then
    echo "❌ ERROR: CONFIRM_DESTROY must be set to 'true' to proceed with destroy"
    echo ""
    echo "This is a safety mechanism to prevent accidental infrastructure destruction."
    echo ""
    echo "To proceed, override the environment variable:"
    echo "  aws codebuild start-build \\"
    echo "    --project-name <project-name> \\"
    echo "    --environment-variables-override \\"
    echo "      name=CONFIRM_DESTROY,value=true,type=PLAINTEXT"
    echo ""
    exit 1
fi

echo "⚠️  DESTROY CONFIRMED - Proceeding with infrastructure destruction"
echo ""
echo "Target:"
echo "  Account: ${TARGET_ACCOUNT_ID}"
echo "  Region: ${TARGET_REGION}"
echo "  Alias: ${TARGET_ALIAS}"
echo ""

# Regional cluster uses Terraform provider assume_role for cross-account access
if [ "$TARGET_ACCOUNT_ID" != "$CENTRAL_ACCOUNT_ID" ]; then
    echo "✅ Terraform will assume OrganizationAccountAccessRole in account $TARGET_ACCOUNT_ID"
else
    echo "✅ Destroying in central account - no role assumption needed"
fi
echo ""
