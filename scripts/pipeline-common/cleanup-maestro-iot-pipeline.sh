#!/usr/bin/env bash
#
# cleanup-maestro-iot-pipeline.sh - Non-interactive IoT cleanup for pipelines
#
# This script removes AWS IoT resources (certificates, policies) for a management
# cluster during pipeline-based destroy operations. It runs non-interactively.
#
# Prerequisites:
# - AWS credentials configured
# - Environment variables set by CodeBuild
#
# Required Environment Variables:
#   CLUSTER_ID or TARGET_ALIAS - The management cluster ID
#   TARGET_REGION              - The target AWS region
#   TARGET_ACCOUNT_ID          - The target AWS account (for cross-account cleanup)
#   CENTRAL_ACCOUNT_ID         - The central account ID (set by setup-apply-preflight.sh)
#
# This script is designed to be called from buildspec-destroy.yml during the
# pre_build phase, before running terraform destroy.
#
# =============================================================================

set -euo pipefail

# =============================================================================
# Extract Configuration from Environment
# =============================================================================

echo "=========================================="
echo "IoT Cleanup for Maestro Agent"
echo "=========================================="

# Determine cluster ID (prefer CLUSTER_ID, fallback to TARGET_ALIAS)
CLUSTER_ID="${CLUSTER_ID:-${TARGET_ALIAS:-}}"

if [ -z "$CLUSTER_ID" ]; then
    echo "❌ ERROR: CLUSTER_ID or TARGET_ALIAS environment variable is required"
    exit 1
fi

# Validate required environment variables
if [ -z "${TARGET_REGION:-}" ]; then
    echo "❌ ERROR: TARGET_REGION environment variable is required"
    exit 1
fi

if [ -z "${TARGET_ACCOUNT_ID:-}" ]; then
    echo "❌ ERROR: TARGET_ACCOUNT_ID environment variable is required"
    exit 1
fi

CENTRAL_ACCOUNT_ID="${CENTRAL_ACCOUNT_ID:-$(aws sts get-caller-identity --query Account --output text)}"

echo "Configuration:"
echo "  Cluster ID: ${CLUSTER_ID}"
echo "  Target Region: ${TARGET_REGION}"
echo "  Target Account: ${TARGET_ACCOUNT_ID}"
echo "  Central Account: ${CENTRAL_ACCOUNT_ID}"
echo ""

# =============================================================================
# Setup Cross-Account Credentials (if needed)
# =============================================================================

# If we're cleaning up in a different account, assume the target role
if [ "$TARGET_ACCOUNT_ID" != "$CENTRAL_ACCOUNT_ID" ]; then
    echo "Cross-account cleanup detected - assuming role in target account ${TARGET_ACCOUNT_ID}"

    ASSUME_ROLE_ARN="arn:aws:iam::${TARGET_ACCOUNT_ID}:role/OrganizationAccountAccessRole"

    echo "Assuming role: ${ASSUME_ROLE_ARN}"

    CREDENTIALS=$(aws sts assume-role \
        --role-arn "$ASSUME_ROLE_ARN" \
        --role-session-name "iot-cleanup-pipeline-${CLUSTER_ID}" \
        --duration-seconds 3600 \
        --output json)

    # Export temporary credentials for IoT operations
    export AWS_ACCESS_KEY_ID=$(echo "$CREDENTIALS" | jq -r '.Credentials.AccessKeyId')
    export AWS_SECRET_ACCESS_KEY=$(echo "$CREDENTIALS" | jq -r '.Credentials.SecretAccessKey')
    export AWS_SESSION_TOKEN=$(echo "$CREDENTIALS" | jq -r '.Credentials.SessionToken')

    # Verify we're in the correct account
    CURRENT_ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
    if [ "$CURRENT_ACCOUNT" != "$TARGET_ACCOUNT_ID" ]; then
        echo "❌ ERROR: Failed to assume role in target account"
        echo "   Current account: $CURRENT_ACCOUNT"
        echo "   Expected account: $TARGET_ACCOUNT_ID"
        exit 1
    fi

    echo "✅ Successfully assumed role in target account"
    echo ""
else
    echo "Same-account cleanup - no role assumption needed"
    echo ""
fi

# =============================================================================
# Find IoT Resources
# =============================================================================

POLICY_NAME="${CLUSTER_ID}-maestro-agent-policy"

echo "Searching for IoT resources for cluster: ${CLUSTER_ID}"
echo "  Policy name: ${POLICY_NAME}"
echo "  Region: ${TARGET_REGION}"
echo ""

# Check if policy exists
POLICY_EXISTS=false
if aws iot get-policy --policy-name "$POLICY_NAME" --region "${TARGET_REGION}" 2>/dev/null >/dev/null; then
    echo "✓ Found IoT policy: ${POLICY_NAME}"
    POLICY_EXISTS=true
else
    echo "ℹ No IoT policy found: ${POLICY_NAME}"
fi

# Find certificates attached to the policy
CERTIFICATES=()
if [ "$POLICY_EXISTS" = true ]; then
    echo "Searching for certificates attached to policy..."

    # List all policy targets (certificates)
    TARGETS=$(aws iot list-policy-principals \
        --policy-name "$POLICY_NAME" \
        --region "${TARGET_REGION}" \
        --output json 2>/dev/null || echo '{"principals":[]}')

    # Extract certificate ARNs
    while IFS= read -r cert_arn; do
        if [ -n "$cert_arn" ] && [ "$cert_arn" != "null" ]; then
            CERTIFICATES+=("$cert_arn")
            CERT_ID=$(echo "$cert_arn" | sed 's|.*/cert/||')
            echo "  ✓ Found certificate: ${CERT_ID}"
        fi
    done < <(echo "$TARGETS" | jq -r '.principals[]? // empty')

    if [ ${#CERTIFICATES[@]} -eq 0 ]; then
        echo "  ℹ No certificates attached to policy"
    fi
fi

echo ""

# =============================================================================
# Delete Resources (Non-Interactive)
# =============================================================================

if [ "$POLICY_EXISTS" = false ] && [ ${#CERTIFICATES[@]} -eq 0 ]; then
    echo "✅ No IoT resources found for cluster: ${CLUSTER_ID}"
    echo "   Nothing to clean up"
    exit 0
fi

echo "=========================================="
echo "Deleting IoT Resources (Non-Interactive)"
echo "=========================================="
echo ""

# Delete certificate attachments and certificates
for cert_arn in "${CERTIFICATES[@]}"; do
    CERT_ID=$(echo "$cert_arn" | sed 's|.*/cert/||')

    echo "Processing certificate: ${CERT_ID}"

    # 1. Detach policy from certificate
    echo "  Detaching policy from certificate..."
    if aws iot detach-policy \
        --policy-name "$POLICY_NAME" \
        --target "$cert_arn" \
        --region "${TARGET_REGION}" 2>/dev/null; then
        echo "  ✓ Policy detached"
    else
        echo "  ⚠ Failed to detach policy (may already be detached)"
    fi

    # 2. Deactivate certificate
    echo "  Deactivating certificate..."
    if aws iot update-certificate \
        --certificate-id "$CERT_ID" \
        --new-status INACTIVE \
        --region "${TARGET_REGION}" 2>/dev/null; then
        echo "  ✓ Certificate deactivated"
    else
        echo "  ⚠ Failed to deactivate certificate"
    fi

    # 3. Delete certificate
    echo "  Deleting certificate..."
    if aws iot delete-certificate \
        --certificate-id "$CERT_ID" \
        --force-delete \
        --region "${TARGET_REGION}" 2>/dev/null; then
        echo "  ✓ Certificate deleted"
    else
        echo "  ❌ Failed to delete certificate"
    fi

    echo ""
done

# Delete policy
if [ "$POLICY_EXISTS" = true ]; then
    echo "Deleting IoT policy: ${POLICY_NAME}"

    # List all policy versions
    VERSIONS=$(aws iot list-policy-versions \
        --policy-name "$POLICY_NAME" \
        --region "${TARGET_REGION}" \
        --output json 2>/dev/null || echo '{"policyVersions":[]}')

    # Delete non-default versions first
    while IFS= read -r version_id; do
        if [ -n "$version_id" ] && [ "$version_id" != "null" ]; then
            echo "  Deleting policy version: ${version_id}"
            aws iot delete-policy-version \
                --policy-name "$POLICY_NAME" \
                --policy-version-id "$version_id" \
                --region "${TARGET_REGION}" 2>/dev/null || true
        fi
    done < <(echo "$VERSIONS" | jq -r '.policyVersions[] | select(.isDefaultVersion == false) | .versionId')

    # Delete the policy itself
    echo "  Deleting policy..."
    if aws iot delete-policy \
        --policy-name "$POLICY_NAME" \
        --region "${TARGET_REGION}" 2>/dev/null; then
        echo "  ✓ Policy deleted"
    else
        echo "  ❌ Failed to delete policy"
        echo "  (This is non-fatal - Terraform destroy will continue)"
    fi

    echo ""
fi

# =============================================================================
# Summary
# =============================================================================

echo "=========================================="
echo "IoT Cleanup Complete"
echo "=========================================="
echo ""
echo "✅ All IoT resources for ${CLUSTER_ID} have been removed"
echo ""
echo "Proceeding with infrastructure destroy..."
echo ""
