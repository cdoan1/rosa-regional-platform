#!/bin/bash
set -euo pipefail

#
# trigger-pipeline-destroy.sh - Trigger pipeline-based infrastructure destroy
#
# This script triggers the destroy CodeBuild project for a regional or management
# cluster via AWS CLI. It automates the process of finding the correct CodeBuild
# project and starting the destroy build with CONFIRM_DESTROY=true.
#
# Usage:
#   ./scripts/trigger-pipeline-destroy.sh <cluster-type> <cluster-alias> <environment>
#
# Arguments:
#   cluster-type  - Type of cluster: "regional" or "management"
#   cluster-alias - The cluster alias (e.g., "regional-us-east-1" or "mc01-us-east-1")
#   environment   - The environment name (e.g., "cdoan-central", "integration", "staging")
#
# Examples:
#   # Destroy regional cluster
#   ./scripts/trigger-pipeline-destroy.sh regional regional-us-east-1 cdoan-central
#
#   # Destroy management cluster
#   ./scripts/trigger-pipeline-destroy.sh management mc01-us-east-1 cdoan-central
#
# Prerequisites:
#   - AWS CLI configured with credentials for the central account
#   - Appropriate permissions to start CodeBuild builds
#   - The destroy CodeBuild project must already exist (created by pipeline provisioner)
#

# Color codes for output
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly RED='\033[0;31m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m' # No Color

# =============================================================================
# Helper Functions
# =============================================================================

log_info() {
  echo -e "${BLUE}ℹ${NC} $1"
}

log_success() {
  echo -e "${GREEN}✓${NC} $1"
}

log_warning() {
  echo -e "${YELLOW}⚠${NC} $1"
}

log_error() {
  echo -e "${RED}✗${NC} $1" >&2
}

# =============================================================================
# Argument Validation
# =============================================================================

if [ $# -ne 3 ]; then
    log_error "Usage: $0 <cluster-type> <cluster-alias> <environment>"
    echo ""
    echo "Arguments:"
    echo "  cluster-type  - Type of cluster: 'regional' or 'management'"
    echo "  cluster-alias - The cluster alias (e.g., 'regional-us-east-1' or 'mc01-us-east-1')"
    echo "  environment   - The environment name (e.g., 'cdoan-central', 'integration', 'staging')"
    echo ""
    echo "Examples:"
    echo "  $0 regional regional-us-east-1 cdoan-central"
    echo "  $0 management mc01-us-east-1 cdoan-central"
    exit 1
fi

CLUSTER_TYPE=$1
CLUSTER_ALIAS=$2
ENVIRONMENT=$3

# Validate cluster type
if [ "$CLUSTER_TYPE" != "regional" ] && [ "$CLUSTER_TYPE" != "management" ]; then
    log_error "Invalid cluster type: ${CLUSTER_TYPE}"
    echo ""
    echo "Cluster type must be 'regional' or 'management'"
    exit 1
fi

# =============================================================================
# Derive CodeBuild Project Name
# =============================================================================

log_info "Finding destroy CodeBuild project for ${CLUSTER_TYPE} cluster: ${CLUSTER_ALIAS}"
echo ""

# Get central account ID
if ! CENTRAL_ACCOUNT=$(aws sts get-caller-identity --query Account --output text 2>/dev/null); then
    log_error "Failed to get AWS account ID"
    log_error "Ensure you have valid AWS credentials configured"
    exit 1
fi

log_success "Central account: ${CENTRAL_ACCOUNT}"

# Derive resource hash (same logic as Terraform)
# Hash input format: "<type>-<alias>-<account>"
HASH_INPUT="${CLUSTER_TYPE}-${CLUSTER_ALIAS}-${CENTRAL_ACCOUNT}"

# Use md5sum to generate hash and take first 12 characters
RESOURCE_HASH=$(echo -n "${HASH_INPUT}" | md5sum | cut -c1-12)

# Build project name based on cluster type
if [ "$CLUSTER_TYPE" == "regional" ]; then
    BUILD_PROJECT="rc-dest-${RESOURCE_HASH}"
elif [ "$CLUSTER_TYPE" == "management" ]; then
    BUILD_PROJECT="mc-dest-${RESOURCE_HASH}"
fi

log_success "Destroy CodeBuild project: ${BUILD_PROJECT}"
echo ""

# =============================================================================
# Verify Project Exists
# =============================================================================

log_info "Verifying CodeBuild project exists..."

if ! aws codebuild batch-get-projects \
    --names "${BUILD_PROJECT}" \
    --query 'projects[0].name' \
    --output text 2>/dev/null | grep -q "${BUILD_PROJECT}"; then

    log_error "CodeBuild project not found: ${BUILD_PROJECT}"
    echo ""
    log_warning "The destroy CodeBuild project does not exist yet."
    log_info "Ensure the pipeline provisioner has been run to create the destroy project:"
    echo ""
    echo "  make pipeline-provision-${CLUSTER_TYPE}"
    echo ""
    exit 1
fi

log_success "CodeBuild project verified"
echo ""

# =============================================================================
# Confirm Destroy
# =============================================================================

echo "=============================================================================="
echo -e "${YELLOW}⚠️  DESTROY CONFIRMATION${NC}"
echo "=============================================================================="
echo ""
echo "This will PERMANENTLY DESTROY the following infrastructure:"
echo ""
echo "  Cluster Type:  ${CLUSTER_TYPE}"
echo "  Cluster Alias: ${CLUSTER_ALIAS}"
echo "  Environment:   ${ENVIRONMENT}"
echo "  Account:       ${CENTRAL_ACCOUNT}"
echo "  Project:       ${BUILD_PROJECT}"
echo ""
echo "=============================================================================="
echo ""

read -p "$(echo -e ${RED}Are you sure you want to destroy this infrastructure? [y/N]:${NC} )" -n 1 -r
echo ""

if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    log_warning "Destroy cancelled"
    exit 0
fi

echo ""

# =============================================================================
# Trigger Destroy Build
# =============================================================================

log_info "Triggering destroy build: ${BUILD_PROJECT}"
echo ""

# Start CodeBuild with CONFIRM_DESTROY=true
# Note: source-version can be overridden to use a different branch
SOURCE_VERSION="${SOURCE_VERSION:-main}"

if BUILD_ID=$(aws codebuild start-build \
    --project-name "${BUILD_PROJECT}" \
    --source-version "${SOURCE_VERSION}" \
    --environment-variables-override \
        name=CONFIRM_DESTROY,value=true,type=PLAINTEXT \
    --query 'build.id' \
    --output text 2>&1); then

    log_success "Build started: ${BUILD_ID}"
    echo ""

    # Extract build number from build ID (format: project-name:uuid)
    BUILD_NUMBER=$(echo "${BUILD_ID}" | cut -d: -f2)

    echo "=============================================================================="
    echo -e "${GREEN}Destroy Build Initiated${NC}"
    echo "=============================================================================="
    echo ""
    echo "Monitor progress:"
    echo ""
    echo "  AWS CLI:"
    echo "    aws codebuild batch-get-builds --ids ${BUILD_ID}"
    echo ""
    echo "  CloudWatch Logs:"
    echo "    aws logs tail /aws/codebuild/${BUILD_PROJECT} --follow"
    echo ""
    echo "  AWS Console:"
    echo "    https://console.aws.amazon.com/codesuite/codebuild/projects/${BUILD_PROJECT}/build/${BUILD_ID}"
    echo ""
    echo "=============================================================================="

else
    log_error "Failed to start build: ${BUILD_ID}"
    exit 1
fi
