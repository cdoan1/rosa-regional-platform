#!/usr/bin/env bash
#
# e2e-provision-test.sh - Simplified E2E Provisioning Script
#
# Provisions Regional Cluster (RC) and Management Cluster (MC) infrastructure.
#
# Required: RC_ACCOUNT_ID, MC_ACCOUNT_ID, AWS credentials
# Optional: TEST_REGION (default: us-east-1), GITHUB_BRANCH (default: main)

set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
readonly TIMESTAMP=$(date +%s)
readonly GITHUB_REPOSITORY="openshift-online/rosa-regional-platform"

export TEST_REGION="${TEST_REGION:-us-east-1}"
readonly GITHUB_BRANCH="${GITHUB_BRANCH:-main}"

# Logging
log() { echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*"; }
log_phase() { echo ""; echo "=========================================="; log "$1"; echo "=========================================="; }
log_success() { log "✅ $1"; }
log_error() { log "❌ $1" >&2; }
log_info() { log "ℹ️  $1"; }

# Validation
validate_prerequisites() {
    [[ -z "${RC_ACCOUNT_ID:-}" ]] && { log_error "RC_ACCOUNT_ID required"; exit 1; }
    [[ -z "${MC_ACCOUNT_ID:-}" ]] && { log_error "MC_ACCOUNT_ID required"; exit 1; }
    for tool in aws terraform jq git make; do
        command -v "$tool" &>/dev/null || { log_error "$tool required"; exit 1; }
    done
    log_success "Prerequisites validated"
}

# Setup state configuration
setup_state() {
    export TF_STATE_BUCKET="terraform-state-e2e"
    export TF_STATE_KEY_RC="e2e-tests/regional-${TIMESTAMP}.tfstate"
    export TF_STATE_KEY_MC="e2e-tests/management-${TIMESTAMP}.tfstate"
    log_info "State bucket: ${TF_STATE_BUCKET}, region: ${TF_STATE_REGION}"
}

# Common Terraform variables
configure_common_vars() {
    export TF_STATE_BUCKET TF_STATE_REGION
    export TF_VAR_region="${TEST_REGION}"
    export TF_VAR_app_code="e2e"
    export TF_VAR_service_phase="test"
    export TF_VAR_cost_center="000"
    export TF_VAR_repository_url="https://github.com/${GITHUB_REPOSITORY}.git"
    export TF_VAR_repository_branch="${GITHUB_BRANCH}"
    export TF_VAR_enable_bastion="false"
    export TF_VAR_maestro_db_instance_class="db.t4g.micro"
    export TF_VAR_maestro_db_multi_az="false"
    export TF_VAR_maestro_db_deletion_protection="false"
    export TF_VAR_maestro_db_skip_final_snapshot="true"
    export TF_VAR_hyperfleet_db_instance_class="db.t4g.micro"
    export TF_VAR_hyperfleet_db_multi_az="false"
    export TF_VAR_hyperfleet_db_deletion_protection="false"
    export TF_VAR_hyperfleet_db_skip_final_snapshot="true"
    export TF_VAR_hyperfleet_mq_instance_type="mq.t3.micro"
    export TF_VAR_hyperfleet_mq_deployment_mode="SINGLE_INSTANCE"
    export TF_VAR_authz_deletion_protection="false"
}

configure_rc() {
    configure_common_vars
    export TF_STATE_KEY="${TF_STATE_KEY_RC}"
    export TF_VAR_target_account_id="${RC_ACCOUNT_ID}"
    export TF_VAR_target_alias="e2e-rc-${TIMESTAMP}"
    export TF_VAR_api_additional_allowed_accounts="${MC_ACCOUNT_ID}"
}

configure_mc() {
    configure_common_vars
    export TF_STATE_KEY="${TF_STATE_KEY_MC}"
    export TF_VAR_target_account_id="${MC_ACCOUNT_ID}"
    export TF_VAR_target_alias="e2e-mc-${TIMESTAMP}"
    export TF_VAR_cluster_id="e2e-mc-${TIMESTAMP}"
    export TF_VAR_regional_aws_account_id="${RC_ACCOUNT_ID}"
    export MC_CLUSTER_ID="e2e-mc-${TIMESTAMP}"
}

# Provisioning
provision_regional_cluster() {
    log_phase "Provisioning Regional Cluster"
    configure_rc
    export ENVIRONMENT="e2e" REGION_ALIAS="e2e" AWS_REGION="${TEST_REGION}" CLUSTER_TYPE="regional-cluster"
    
    log_info "Provisioning infrastructure..."
    
    $REPO_ROOT/scripts/dev/validate-argocd-config.sh regional-cluster
    
    cd $REPO_ROOT/terraform/config/regional-cluster && \
		terraform init -reconfigure \
			-backend-config="bucket=$${TF_STATE_BUCKET}" \
			-backend-config="key=$${TF_STATE_KEY}" \
			-backend-config="region=$${TF_STATE_REGION}" \
			-backend-config="use_lockfile=true" && \
        terraform apply -auto-approve || { log_error "RC provisioning failed"; return 1; }

    $REPO_ROOT/scripts/build-platform-image.sh || { log_error "Platform image build failed"; return 1; }

    $REPO_ROOT/scripts/bootstrap-argocd.sh regional-cluster || { log_error "RC ArgoCD bootstrap failed"; return 1; }

}

provision_iot_resources() {
    log_info "Provisioning IoT resources for ${MC_CLUSTER_ID}..."
    cd "$REPO_ROOT/terraform/config/maestro-agent-iot-provisioning"
    
    terraform init -backend=false || { log_error "IoT terraform init failed"; return 1; }
    terraform apply -auto-approve -var="cluster_id=${MC_CLUSTER_ID}" -var="region=${TEST_REGION}" || { log_error "IoT terraform apply failed"; return 1; }
    
    mkdir -p "$REPO_ROOT/.maestro-certs/${MC_CLUSTER_ID}"
    cat > "$REPO_ROOT/.maestro-certs/${MC_CLUSTER_ID}/certificate_data.json" <<EOF
{
  "iot_endpoint": "$(terraform output -raw iot_endpoint)",
  "certificate_pem": "$(terraform output -raw certificate_pem)",
  "private_key": "$(terraform output -raw private_key)",
  "ca_certificate": "$(terraform output -raw ca_certificate)"
}
EOF
    
    cd "$REPO_ROOT"
    log_success "IoT resources provisioned"
}

create_maestro_secrets() {
    log_info "Creating Maestro secrets..."
    local cert_file="$REPO_ROOT/.maestro-certs/${MC_CLUSTER_ID}/certificate_data.json"
    [[ ! -f "$cert_file" ]] && { log_error "Certificate data not found: $cert_file"; return 1; }
    
    local iot_endpoint=$(jq -r '.iot_endpoint' "$cert_file")
    local certificate_pem=$(jq -r '.certificate_pem' "$cert_file")
    local private_key=$(jq -r '.private_key' "$cert_file")
    local ca_cert=$(jq -r '.ca_certificate' "$cert_file")
    
    aws secretsmanager create-secret --name "maestro/agent-cert" \
        --secret-string "{\"certificate\":\"$certificate_pem\",\"private_key\":\"$private_key\",\"ca_certificate\":\"$ca_cert\"}" \
        --region "${TEST_REGION}" 2>/dev/null || log_info "Secret maestro/agent-cert may already exist"
    
    aws secretsmanager create-secret --name "maestro/agent-config" \
        --secret-string "{\"endpoint\":\"$iot_endpoint\"}" \
        --region "${TEST_REGION}" 2>/dev/null || log_info "Secret maestro/agent-config may already exist"
    
    log_success "Maestro secrets created"
}

provision_management_cluster() {
    log_phase "Provisioning Management Cluster"
    configure_mc
    export ENVIRONMENT="e2e" REGION_ALIAS="e2e" AWS_REGION="${TEST_REGION}" CLUSTER_TYPE="management-cluster"
    
    provision_iot_resources || { log_error "IoT provisioning failed"; return 1; }
    create_maestro_secrets || { log_error "Maestro secret creation failed"; return 1; }
    
    log_info "Provisioning infrastructure..."
    make pipeline-provision-management || { log_error "MC provisioning failed"; return 1; }
    
    log_info "Bootstrapping ArgoCD..."
    "$REPO_ROOT/scripts/bootstrap-argocd.sh" management-cluster || { log_error "MC ArgoCD bootstrap failed"; return 1; }
    
    log_success "Management Cluster provisioned"
}

# Main
main() {
    log_phase "Starting E2E Provisioning Test"
    log_info "Test ID: $TIMESTAMP"
    
    validate_prerequisites
    setup_state
    
    provision_regional_cluster || { log_error "Regional Cluster provisioning failed"; exit 1; }
    # provision_management_cluster || { log_error "Management Cluster provisioning failed"; exit 1; }
    
    # log_success "All clusters provisioned successfully"
}

main "$@"
