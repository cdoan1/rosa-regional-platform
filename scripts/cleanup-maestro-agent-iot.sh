#!/bin/bash
set -euo pipefail

# =============================================================================
# Cleanup IoT Resources for Management Cluster
# =============================================================================
# This script removes AWS IoT resources (certificates, policies) for a
# management cluster. Run this before re-provisioning.
#
# Prerequisites:
# - AWS credentials configured (regional OR management account)
# - AWS CLI installed
#
# Usage:
#   ./scripts/cleanup-maestro-agent-iot.sh <path-to-management-cluster-tfvars>
#
# Example:
#   ./scripts/cleanup-maestro-agent-iot.sh terraform/config/management-cluster/terraform.tfvars
#
# =============================================================================

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

# Extract a variable value from a Terraform tfvars file
extract_tfvar() {
  local file="$1"
  local var="$2"

  grep "^${var}[[:space:]]*=" "$file" | \
    sed -E 's/^[^=]+=[[:space:]]*"([^"]+)".*/\1/' | \
    tr -d '\n'
}

# =============================================================================
# Argument Validation
# =============================================================================

if [ $# -ne 1 ]; then
  log_error "Usage: $0 <path-to-management-cluster-tfvars>"
  log_info "Example: $0 terraform/config/management-cluster/terraform.tfvars"
  exit 1
fi

MGMT_TFVARS="$1"

if [ ! -f "$MGMT_TFVARS" ]; then
  log_error "Management cluster tfvars file not found: ${MGMT_TFVARS}"
  exit 1
fi

if ! command -v aws &> /dev/null; then
  log_error "AWS CLI is required but not installed"
  exit 1
fi

# =============================================================================
# Parse Management Cluster Configuration
# =============================================================================

log_info "Parsing management cluster configuration from: ${MGMT_TFVARS}"

CLUSTER_ID=$(extract_tfvar "$MGMT_TFVARS" "cluster_id")

if [ -z "$CLUSTER_ID" ]; then
  log_error "cluster_id not found in ${MGMT_TFVARS}"
  exit 1
fi

log_success "Configuration parsed successfully"
log_info "  Management Cluster: ${CLUSTER_ID}"
echo ""

# =============================================================================
# Verify AWS Context
# =============================================================================

log_info "Verifying AWS credentials..."
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text 2>/dev/null || echo "")
AWS_REGION=$(aws configure get region || echo "")

if [ -z "$AWS_ACCOUNT_ID" ]; then
  log_error "Unable to verify AWS credentials. Ensure you're authenticated."
  exit 1
fi

if [ -z "$AWS_REGION" ]; then
  log_error "AWS region not configured. Set it with: aws configure set region <region>"
  exit 1
fi

log_success "AWS credentials verified"
log_info "  Account ID: ${AWS_ACCOUNT_ID}"
log_info "  Region:     ${AWS_REGION}"
log_info "  Cluster ID: ${CLUSTER_ID}"
echo ""

# =============================================================================
# Find IoT Resources
# =============================================================================

POLICY_NAME="${CLUSTER_ID}-maestro-agent-policy"

log_info "Searching for IoT resources for cluster: ${CLUSTER_ID}"
echo ""

# Find policy
POLICY_EXISTS=$(aws iot get-policy --policy-name "$POLICY_NAME" 2>/dev/null || echo "")

if [ -z "$POLICY_EXISTS" ]; then
  log_info "No IoT policy found: ${POLICY_NAME}"
  POLICY_FOUND=false
else
  log_warning "Found IoT policy: ${POLICY_NAME}"
  POLICY_FOUND=true
fi

# Find certificates attached to the policy
CERTIFICATES=()
if [ "$POLICY_FOUND" = true ]; then
  log_info "Searching for certificates attached to policy..."

  # List all policy targets (certificates)
  TARGETS=$(aws iot list-policy-principals --policy-name "$POLICY_NAME" --output json 2>/dev/null || echo '{"principals":[]}')

  # Extract certificate ARNs
  while IFS= read -r cert_arn; do
    if [ -n "$cert_arn" ] && [ "$cert_arn" != "null" ]; then
      CERTIFICATES+=("$cert_arn")
      # Extract certificate ID from ARN
      CERT_ID=$(echo "$cert_arn" | sed 's|.*/cert/||')
      log_warning "  Found certificate: ${CERT_ID}"
    fi
  done < <(echo "$TARGETS" | jq -r '.principals[]? // empty')
fi

if [ ${#CERTIFICATES[@]} -eq 0 ]; then
  log_info "No certificates found"
fi

echo ""

# =============================================================================
# Confirm Deletion
# =============================================================================

if [ "$POLICY_FOUND" = false ] && [ ${#CERTIFICATES[@]} -eq 0 ]; then
  log_success "No IoT resources found for cluster: ${CLUSTER_ID}"
  log_info "Nothing to clean up"
  exit 0
fi

echo "=============================================================================="
echo -e "${YELLOW}RESOURCES TO BE DELETED${NC}"
echo "=============================================================================="
echo ""
echo "AWS Account: ${AWS_ACCOUNT_ID}"
echo "Region:      ${AWS_REGION}"
echo ""

if [ "$POLICY_FOUND" = true ]; then
  echo "IoT Policy:"
  echo "  - ${POLICY_NAME}"
  echo ""
fi

if [ ${#CERTIFICATES[@]} -gt 0 ]; then
  echo "IoT Certificates (${#CERTIFICATES[@]}):"
  for cert_arn in "${CERTIFICATES[@]}"; do
    CERT_ID=$(echo "$cert_arn" | sed 's|.*/cert/||')
    echo "  - ${CERT_ID}"
  done
  echo ""
fi

echo "=============================================================================="
echo ""

read -p "$(echo -e ${RED}Delete these resources? [y/N]:${NC} )" -n 1 -r
echo ""

if [[ ! $REPLY =~ ^[Yy]$ ]]; then
  log_warning "Cleanup cancelled"
  exit 0
fi

echo ""

# =============================================================================
# Delete Resources
# =============================================================================

log_info "Starting cleanup..."
echo ""

# Delete certificate attachments and certificates
for cert_arn in "${CERTIFICATES[@]}"; do
  CERT_ID=$(echo "$cert_arn" | sed 's|.*/cert/||')

  log_info "Processing certificate: ${CERT_ID}"

  # 1. Detach policy from certificate
  log_info "  Detaching policy from certificate..."
  if aws iot detach-policy --policy-name "$POLICY_NAME" --target "$cert_arn" 2>/dev/null; then
    log_success "  Policy detached"
  else
    log_warning "  Failed to detach policy (may already be detached)"
  fi

  # 2. Deactivate certificate
  log_info "  Deactivating certificate..."
  if aws iot update-certificate --certificate-id "$CERT_ID" --new-status INACTIVE 2>/dev/null; then
    log_success "  Certificate deactivated"
  else
    log_warning "  Failed to deactivate certificate"
  fi

  # 3. Delete certificate
  log_info "  Deleting certificate..."
  if aws iot delete-certificate --certificate-id "$CERT_ID" --force-delete 2>/dev/null; then
    log_success "  Certificate deleted"
  else
    log_error "  Failed to delete certificate"
  fi

  echo ""
done

# Delete policy
if [ "$POLICY_FOUND" = true ]; then
  log_info "Deleting IoT policy: ${POLICY_NAME}"

  # List all policy versions
  VERSIONS=$(aws iot list-policy-versions --policy-name "$POLICY_NAME" --output json 2>/dev/null || echo '{"policyVersions":[]}')

  # Delete non-default versions first
  while IFS= read -r version_id; do
    if [ -n "$version_id" ] && [ "$version_id" != "null" ]; then
      log_info "  Deleting policy version: ${version_id}"
      aws iot delete-policy-version --policy-name "$POLICY_NAME" --policy-version-id "$version_id" 2>/dev/null || true
    fi
  done < <(echo "$VERSIONS" | jq -r '.policyVersions[] | select(.isDefaultVersion == false) | .versionId')

  # Delete the policy itself
  if aws iot delete-policy --policy-name "$POLICY_NAME" 2>/dev/null; then
    log_success "  Policy deleted"
  else
    log_error "  Failed to delete policy"
  fi

  echo ""
fi

# =============================================================================
# Summary
# =============================================================================

echo "=============================================================================="
echo -e "${GREEN}Cleanup Complete!${NC}"
echo "=============================================================================="
echo ""
log_success "All IoT resources for ${CLUSTER_ID} have been removed"
echo ""
log_info "You can now re-run the provisioning script:"
echo ""
echo -e "${YELLOW}./scripts/provision-maestro-agent-iot-regional.sh \\"
echo -e "  ${MGMT_TFVARS}${NC}"
echo ""
echo "=============================================================================="
