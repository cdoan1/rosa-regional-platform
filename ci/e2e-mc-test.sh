#!/bin/bash
# This is a simple e2e regional cluster test script.
# This script runs in the AWS account id context of the regional cluster.
# The account id is only directly referenced in the S3 bucket name and the regional cluster name.

set -euo pipefail

# Script directory and repository root
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

source $REPO_ROOT/ci/utils.sh

# Test identification
# readonly TIMESTAMP=$(date +%s)
export HASH

if [[ -z "${MC_ACCOUNT_ID:-}" ]]; then
    HASH=$(date +%s)
else
    # use a unique hash, but not a timestamp
    # this will allow resources to not recreate if they exist
    HASH=$(echo $MC_ACCOUNT_ID | sha256sum | cut -c1-6)
fi

echo "Unique Hash: $HASH"

# Git configuration
export GITHUB_REPOSITORY="${GITHUB_REPOSITORY:-openshift-online/rosa-regional-platform}"
export GITHUB_BRANCH="${GITHUB_BRANCH:-main}"
export TEST_REGION="${TEST_REGION:-us-east-1}"
export REGION="${TEST_REGION}"
export AWS_REGION="${TEST_REGION}"

# Logging functions
log() { echo "[$(date +'%Y-%m-%d %H:%M:%S')] mc-test:$*"; }
log_info() { log "ℹ️ $1"; }
log_success() { log "✅ $1"; }
log_error() { log "❌ $1" >&2; }
log_phase() { echo ""; echo "=========================================="; log "$1"; echo "=========================================="; }


configure_mc_environment() {
    log_phase "Configuring Management Cluster Environment Variables"

    # Verify container_image is set (required for ECS bootstrap task)
    # This should have been set by create_platform_image() before this function is called
    if [[ -z "${TF_VAR_container_image:-}" ]]; then
        log_error "TF_VAR_container_image is not set. Image must be built before terraform apply."
        log_error "Make sure create_platform_image() is called before configure_rc_environment()."
        return 1
    fi
    log_info "Container image for ECS bootstrap: ${TF_VAR_container_image}"

    export TF_VAR_region="us-east-1"
    export TF_VAR_app_code="e2e"
    export TF_VAR_service_phase="test"
    export TF_VAR_cost_center="000"
    export TF_VAR_repository_url="https://github.com/openshift-online/rosa-regional-platform.git"
    export TF_VAR_repository_branch="main"
    export TF_STATE_BUCKET="e2e-rosa-regional-platform-${HASH}"
    export TF_STATE_REGION="us-east-1"
    export TF_STATE_KEY="e2e-rosa-regional-platform-${HASH}.tfstate"

    # export TF_VAR_target_account_id="${RC_ACCOUNT_ID:-}"
    export TF_VAR_target_alias="e2e-rc-${HASH}"

    # Database optimizations for test (smallest/cheapest instances)
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

    # Store cluster name for later use
    export MC_CLUSTER_NAME="e2e-mc-${HASH}"

    log_success "MC environment configured"
    # log_info "Target Account: ${TF_VAR_target_account_id:-<not set>}"
    log_info "State Bucket: ${TF_STATE_BUCKET}"
    log_info "State Key: ${TF_STATE_KEY}"
}

create_management_cluster() {
    log_phase "Provisioning Management Cluster"
    configure_mc_environment
    # Set environment variables for ArgoCD validation and bootstrap
    export ENVIRONMENT="e2e"
    export REGION_ALIAS="us-east-1"
    export CLUSTER_TYPE="management-cluster"
    log_info "State Bucket: ${TF_STATE_BUCKET}"
    log_info "State Key: ${TF_STATE_KEY}"
    log_info "Region: ${TF_VAR_region}"
    log_info "Target Alias: ${TF_VAR_target_alias}"

    $REPO_ROOT/scripts/dev/validate-argocd-config.sh management-cluster

    cd terraform/config/management-cluster

    terraform init -reconfigure \
        -backend-config="bucket=${TF_STATE_BUCKET}" \
        -backend-config="key=${TF_STATE_KEY}" \
        -backend-config="region=${TF_STATE_REGION}" \
        -backend-config="use_lockfile=false"

    terraform apply -auto-approve
    cd "$REPO_ROOT"
    $REPO_ROOT/scripts/bootstrap-argocd.sh management-cluster || { log_error "MC ArgoCD bootstrap failed"; return 1; }
}

destroy_management_cluster() {
    log_phase "Destroying Management Cluster"
    configure_mc_environment
    # Set environment variables for ArgoCD validation
    export ENVIRONMENT="e2e"
    export REGION_ALIAS="us-east-1"
    export CLUSTER_TYPE="management-cluster"

    log_info "Destroying infrastructure..."
    cd $REPO_ROOT/terraform/config/management-cluster
    terraform init -reconfigure \
        -backend-config="bucket=${TF_STATE_BUCKET}" \
        -backend-config="key=${TF_STATE_KEY}" \
        -backend-config="region=${TF_STATE_REGION}" \
        -backend-config="use_lockfile=false"

    terraform destroy -auto-approve || { log_error "RC destruction failed"; return 1; }
    cd "$REPO_ROOT"
    log_success "Management Cluster destroyed"
}

TEARDOWN=false
for arg in "$@"; do
  case "$arg" in
    --destroy-management) TEARDOWN=true ;;
    *)
      echo "Unknown argument: $arg" >&2
      echo "Usage: $0 [--destroy-management]" >&2
      exit 1
      ;;
  esac
done

export TF_VAR_container_image="018092638725.dkr.ecr.us-east-1.amazonaws.com/e2e-platform-7f0b54:3278a75292a3"
# create_platform_image || { log_error "Failed to create platform image"; exit 1; }

aws configure set region "${TEST_REGION}"

if [[ "$TEARDOWN" == "true" ]]; then
    log_phase "Starting E2E Management Cluster Destruction"
    create_s3_bucket || { log_error "Failed to setup S3 backend"; exit 1; }
    destroy_management_cluster || { log_error "Management Cluster destruction failed"; exit 1; }
    log_success "Management Cluster destroyed successfully"
    exit 0
fi

log_phase "Starting E2E Management Cluster Test"
create_s3_bucket || { log_error "Failed to setup S3 backend"; exit 1; }
log_success "Container image configured: ${TF_VAR_container_image}"
# IoT management secrets must exist before terraform apply (MC terraform reads them via data sources)
$REPO_ROOT/scripts/provision-maestro-agent-iot-management.sh \
    $REPO_ROOT/terraform/config/management-cluster/terraform.tfvars || { log_error "Failed to provision IoT resources"; exit 1; }
log_success "IoT resources provisioned successfully"
create_management_cluster || { log_error "Management cluster provisioning failed"; exit 1; }
log_success "E2E Management Cluster Test completed successfully"
log "Done creating e2e management cluster test"