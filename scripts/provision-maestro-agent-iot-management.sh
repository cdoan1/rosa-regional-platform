#!/bin/bash
set -euo pipefail

# =============================================================================
# Create Maestro Agent Certificate Secret (MANAGEMENT CONTEXT)
# =============================================================================
# This script creates an AWS Secrets Manager secret in the MANAGEMENT account
# containing the Maestro Agent certificate data provisioned in the regional
# account.
#
# Prerequisites:
# - AWS credentials configured for MANAGEMENT account
# - Certificate data file from regional provisioning step
# - AWS CLI installed
#
# Usage:
#   ./scripts/provision-maestro-agent-iot-management.sh <path-to-management-cluster-tfvars>
#
# Example:
#   ./scripts/provision-maestro-agent-iot-management.sh \
#     terraform/config/management-cluster/terraform.tfvars
#
# Input:
#   Certificate data from: .maestro-certs/{cluster_id}/certificate_data.json
# =============================================================================

# Color codes for output
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly RED='\033[0;31m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m' # No Color

# Script directory and paths
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
readonly CERTS_DIR="${REPO_ROOT}/.maestro-certs"

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
  log_error "aws CLI is required but not installed"
  log_info "Install from: https://aws.amazon.com/cli/"
  exit 1
fi

# =============================================================================
# Verify AWS Context (Management Account)
# =============================================================================

log_info "Verifying AWS credentials (should be MANAGEMENT account)..."
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
log_warning "  ⚠️  Ensure this is your MANAGEMENT account!"
echo ""

# =============================================================================
# Parse Management Cluster Configuration
# =============================================================================

log_info "Parsing management cluster configuration from: ${MGMT_TFVARS}"

CLUSTER_ID=$(extract_tfvar "$MGMT_TFVARS" "cluster_id")

if [ -z "$CLUSTER_ID" ]; then
  log_error "cluster_id not found in ${MGMT_TFVARS}"
  exit 1
fi

log_success "Configuration parsed: ${CLUSTER_ID}"
echo ""

# =============================================================================
# Verify Certificate and Config Data Exists
# =============================================================================

CERT_FILE="${CERTS_DIR}/${CLUSTER_ID}/agent_cert.json"
CONFIG_FILE="${CERTS_DIR}/${CLUSTER_ID}/agent_config.json"

log_info "Looking for certificate and configuration data..."

if [ ! -f "$CERT_FILE" ]; then
  log_error "Certificate data file not found: ${CERT_FILE}"
  log_info ""
  log_info "You must run the regional provisioning step first:"
  log_info "  make provision-maestro-agent-iot-regional MGMT_TFVARS=${MGMT_TFVARS}"
  exit 1
fi

if [ ! -f "$CONFIG_FILE" ]; then
  log_error "Configuration data file not found: ${CONFIG_FILE}"
  log_info ""
  log_info "You must run the regional provisioning step first:"
  log_info "  make provision-maestro-agent-iot-regional MGMT_TFVARS=${MGMT_TFVARS}"
  exit 1
fi

log_success "Certificate and configuration data files found"
echo ""

# =============================================================================
# Create Secrets in AWS Secrets Manager
# =============================================================================

CERT_SECRET_NAME="maestro/agent-cert"
CONFIG_SECRET_NAME="maestro/agent-config"

log_info "Creating secrets in AWS Secrets Manager..."
log_info "  Region: ${AWS_REGION}"
echo ""

# Create certificate secret (sensitive)
log_info "Creating certificate secret: ${CERT_SECRET_NAME}"

if cat "$CERT_FILE" | aws secretsmanager create-secret \
  --name "$CERT_SECRET_NAME" \
  --secret-string file:///dev/stdin \
  --region "$AWS_REGION" \
  --description "Maestro Agent MQTT certificate material for ${CLUSTER_ID}" \
  2>/dev/null; then

  log_success "Certificate secret created"

else
  log_warning "Certificate secret already exists, updating instead..."

  if cat "$CERT_FILE" | aws secretsmanager update-secret \
    --secret-id "$CERT_SECRET_NAME" \
    --secret-string file:///dev/stdin \
    --region "$AWS_REGION" \
    2>/dev/null; then

    log_success "Certificate secret updated"
  else
    log_error "Failed to create or update certificate secret"
    exit 1
  fi
fi

echo ""

# Create configuration secret (non-sensitive)
log_info "Creating configuration secret: ${CONFIG_SECRET_NAME}"

if cat "$CONFIG_FILE" | aws secretsmanager create-secret \
  --name "$CONFIG_SECRET_NAME" \
  --secret-string file:///dev/stdin \
  --region "$AWS_REGION" \
  --description "Maestro Agent MQTT configuration for ${CLUSTER_ID}" \
  2>/dev/null; then

  log_success "Configuration secret created"

else
  log_warning "Configuration secret already exists, updating instead..."

  if cat "$CONFIG_FILE" | aws secretsmanager update-secret \
    --secret-id "$CONFIG_SECRET_NAME" \
    --secret-string file:///dev/stdin \
    --region "$AWS_REGION" \
    2>/dev/null; then

    log_success "Configuration secret updated"
  else
    log_error "Failed to create or update configuration secret"
    exit 1
  fi
fi

echo ""

# =============================================================================
# Verify Secrets
# =============================================================================

log_info "Verifying secrets creation..."

if aws secretsmanager describe-secret \
  --secret-id "$CERT_SECRET_NAME" \
  --region "$AWS_REGION" \
  --query 'Name' \
  --output text &>/dev/null; then

  log_success "Certificate secret verified"
else
  log_error "Certificate secret verification failed"
  exit 1
fi

if aws secretsmanager describe-secret \
  --secret-id "$CONFIG_SECRET_NAME" \
  --region "$AWS_REGION" \
  --query 'Name' \
  --output text &>/dev/null; then

  log_success "Configuration secret verified"
else
  log_error "Configuration secret verification failed"
  exit 1
fi

echo ""

# =============================================================================
# Display Next Steps
# =============================================================================

echo "=============================================================================="
echo -e "${GREEN}Management Provisioning Complete!${NC}"
echo "=============================================================================="
echo ""
echo "Secrets created in MANAGEMENT account (${AWS_ACCOUNT_ID}):"
echo "  Certificate:   ${CERT_SECRET_NAME}"
echo "  Configuration: ${CONFIG_SECRET_NAME}"
echo "  Region:        ${AWS_REGION}"
echo ""
echo "Data uploaded:"
echo "  Certificate:   ${CERT_FILE} → ${CERT_SECRET_NAME} ✓"
echo "  Configuration: ${CONFIG_FILE} → ${CONFIG_SECRET_NAME} ✓"
echo ""
echo "=============================================================================="
echo "NEXT STEP"
echo "=============================================================================="
echo ""
echo "Deploy the management cluster infrastructure:"
echo ""
echo -e "${YELLOW}make provision-management${NC}"
echo ""
echo "Or if already deployed, update the Maestro Agent configuration and restart:"
echo "  kubectl rollout restart deployment maestro-agent -n maestro"
echo ""
echo "=============================================================================="
echo ""
echo "Optional: Clean up local data files (already in Secrets Manager):"
echo "  rm -rf ${CERTS_DIR}/${CLUSTER_ID}"
echo ""
