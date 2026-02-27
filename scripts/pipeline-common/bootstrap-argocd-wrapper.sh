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
# The script expects: ENVIRONMENT, REGION_DEPLOYMENT, AWS_REGION
# Both regional and management clusters use TARGET_REGION (AWS region) for REGION_DEPLOYMENT
# since the directory structure uses AWS region: deploy/<env>/<aws_region>/argocd/
export ENVIRONMENT="${ENVIRONMENT}"
export REGION_DEPLOYMENT="${TARGET_REGION}"
export AWS_REGION="${TARGET_REGION}"

echo "Bootstrap environment configuration:"
echo "  ENVIRONMENT: ${ENVIRONMENT}"
echo "  REGION_DEPLOYMENT: ${REGION_DEPLOYMENT}"
echo "  AWS_REGION: ${AWS_REGION}"
echo ""

# Call bootstrap script (ambient creds are already target account)
# Temporarily disable errexit so we can capture the exit code from PIPESTATUS
# before set -e terminates the script on a non-zero pipeline status.
set +e
./scripts/bootstrap-argocd.sh "$CLUSTER_TYPE" 2>&1 | tee /tmp/bootstrap.log
BOOTSTRAP_EXIT_CODE=${PIPESTATUS[0]}
set -e

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
