#!/usr/bin/env bash
#
# bootstrap-argocd-wrapper.sh - Common ArgoCD bootstrap orchestration
#
# This script handles the common bootstrap logic for both regional and management clusters:
# - Validates environment variables
# - Exports standardized environment variables
# - Sets up cross-account role assumption if needed
# - Calls bootstrap-argocd.sh
# - Handles logging and exit code checking
#
# Usage: bootstrap-argocd-wrapper.sh <cluster-type> <target-account-id>
#   cluster-type: regional-cluster or management-cluster
#   target-account-id: AWS account ID for the target cluster
#
# Expected environment variables:
#   ENVIRONMENT or TARGET_ENVIRONMENT - Environment name
#   TARGET_ALIAS - Cluster alias
#   TARGET_REGION - AWS region
#   CENTRAL_ACCOUNT_ID - Central account ID
#   TARGET_ACCOUNT_ID - Target account ID (for cross-account check)

set -euo pipefail

# Validate arguments
if [ $# -ne 2 ]; then
    echo "❌ ERROR: bootstrap-argocd-wrapper.sh requires exactly 2 arguments"
    echo "Usage: bootstrap-argocd-wrapper.sh <cluster-type> <target-account-id>"
    exit 1
fi

CLUSTER_TYPE=$1
TARGET_ACCOUNT_ID=$2

# Validate cluster type
if [[ "$CLUSTER_TYPE" != "regional-cluster" && "$CLUSTER_TYPE" != "management-cluster" ]]; then
    echo "❌ ERROR: cluster-type must be 'regional-cluster' or 'management-cluster'"
    exit 1
fi

echo "Bootstrapping ArgoCD..."

# Initialize ENVIRONMENT with safe fallbacks (handles both ENVIRONMENT and TARGET_ENVIRONMENT)
ENVIRONMENT="${ENVIRONMENT:-${TARGET_ENVIRONMENT:-}}"

# Validate all required environment variables are set (using safe parameter expansion)
if [[ -z "${ENVIRONMENT:-}" ]]; then
    echo "❌ ERROR: ENVIRONMENT variable not set"
    exit 1
fi

# Export standardized environment variables for bootstrap script
# The script expects: ENVIRONMENT, REGION_ALIAS, AWS_REGION
export ENVIRONMENT="${ENVIRONMENT}"
export REGION_ALIAS="${TARGET_ALIAS}"
export AWS_REGION="${TARGET_REGION}"

# Set ASSUME_ROLE_ARN for cross-account bootstrap (if needed)
# The script will read terraform outputs with current (central) creds,
# then assume this role for ECS/EKS operations
if [ "$TARGET_ACCOUNT_ID" != "$CENTRAL_ACCOUNT_ID" ]; then
    export ASSUME_ROLE_ARN="arn:aws:iam::${TARGET_ACCOUNT_ID}:role/OrganizationAccountAccessRole"
    echo "Bootstrap will assume role for target account operations: $ASSUME_ROLE_ARN"
fi

echo "Bootstrap environment configuration:"
echo "  ENVIRONMENT: ${ENVIRONMENT}"
echo "  REGION_ALIAS: ${REGION_ALIAS}"
echo "  AWS_REGION: ${AWS_REGION}"
echo ""

# Call bootstrap script with central account credentials (for terraform output reading)
# The script will internally assume ASSUME_ROLE_ARN for ECS/EKS operations
./scripts/bootstrap-argocd.sh "$CLUSTER_TYPE" 2>&1 | tee /tmp/bootstrap.log
BOOTSTRAP_EXIT_CODE=${PIPESTATUS[0]}

echo ""
echo "=== Bootstrap Script Log ==="
cat /tmp/bootstrap.log
echo "=== End Bootstrap Log ==="
echo ""

if [ $BOOTSTRAP_EXIT_CODE -ne 0 ]; then
    echo "❌ Bootstrap script failed with exit code $BOOTSTRAP_EXIT_CODE"
    exit 1
fi

echo "✅ ArgoCD bootstrap complete!"
