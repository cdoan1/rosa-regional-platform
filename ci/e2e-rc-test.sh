#!/bin/bash
# This is a simple e2e regional cluster test script.
# This script runs in the AWS account id context of the regional cluster.
# The account id is only directly referenced in the S3 bucket name and the regional cluster name.

set -euo pipefail

# Default SHARED_DIR for local runs (CI sets this automatically)
export SHARED_DIR="${SHARED_DIR:-/tmp/rosa-e2e-shared}"
mkdir -p "${SHARED_DIR}"

# Script directory and repository root
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

source $REPO_ROOT/ci/utils.sh

# Test identification
# readonly TIMESTAMP=$(date +%s)
export HASH

if [[ -z "${RC_ACCOUNT_ID:-}" ]]; then
    HASH=$(date +%s)
else
    # use a unique hash, but not a timestamp
    # this will allow resources to not recreate if they exist
    HASH=$(echo $RC_ACCOUNT_ID | sha256sum | cut -c1-6)
fi

echo "Unique Hash: $HASH"

# Git configuration
export GITHUB_REPOSITORY="${GITHUB_REPOSITORY:-openshift-online/rosa-regional-platform}"
export GITHUB_BRANCH="${GITHUB_BRANCH:-main}"
export TEST_REGION="${TEST_REGION:-us-east-1}"
export REGION="${TEST_REGION}"
export AWS_REGION="${TEST_REGION}"

# Logging functions
log() { echo "[$(date +'%Y-%m-%d %H:%M:%S')] rc-test:$*"; }
log_info() { log "ℹ️ $1"; }
log_success() { log "✅ $1"; }
log_error() { log "❌ $1" >&2; }
log_phase() { echo ""; echo "=========================================="; log "$1"; echo "=========================================="; }


configure_rc_environment() {
    log_phase "Configuring Regional Cluster Environment Variables"

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
    export RC_CLUSTER_NAME="e2e-rc-${HASH}"

    log_success "RC environment configured"
    log_info "Cluster Name: ${RC_CLUSTER_NAME}"
    # log_info "Target Account: ${TF_VAR_target_account_id:-<not set>}"
    log_info "State Bucket: ${TF_STATE_BUCKET}"
    log_info "State Key: ${TF_STATE_KEY}"
}

create_regional_cluster() {
    log_phase "Provisioning Regional Cluster"

    configure_rc_environment

    # Set environment variables for ArgoCD validation and bootstrap
    export ENVIRONMENT="e2e"
    export REGION_ALIAS="us-east-1"
    export CLUSTER_TYPE="regional-cluster"
    log_info "State Bucket: ${TF_STATE_BUCKET}"
    log_info "State Key: ${TF_STATE_KEY}"
    log_info "Region: ${TF_VAR_region}"
    log_info "Target Alias: ${TF_VAR_target_alias}"

    $REPO_ROOT/scripts/dev/validate-argocd-config.sh regional-cluster

    cd terraform/config/regional-cluster

    terraform init -reconfigure \
        -backend-config="bucket=${TF_STATE_BUCKET}" \
        -backend-config="key=${TF_STATE_KEY}" \
        -backend-config="region=${TF_STATE_REGION}" \
        -backend-config="use_lockfile=true"

    terraform apply -auto-approve
    cd "$REPO_ROOT"
    $REPO_ROOT/scripts/bootstrap-argocd.sh regional-cluster || { log_error "RC ArgoCD bootstrap failed"; return 1; }
}

destroy_regional_cluster() {
    log_phase "Destroying Regional Cluster"
    configure_rc_environment
    # Set environment variables for ArgoCD validation
    export ENVIRONMENT="e2e"
    export REGION_ALIAS="us-east-1"
    export CLUSTER_TYPE="regional-cluster"

    log_info "Destroying infrastructure..."
    cd terraform/config/regional-cluster
    terraform init -reconfigure \
        -backend-config="bucket=${TF_STATE_BUCKET}" \
        -backend-config="key=${TF_STATE_KEY}" \
        -backend-config="region=${TF_STATE_REGION}" \
        -backend-config="use_lockfile=true"

    terraform destroy -auto-approve || { log_error "RC destruction failed"; return 1; }
    cd "$REPO_ROOT"
    log_success "Regional Cluster destroyed"
}

create_iot_resources() {
    if [[ -z "${RC_ACCOUNT_ID:-}" ]]; then
        log_error "RC_ACCOUNT_ID is required for IoT resource creation"
        return 1
    fi    
    log_info "Creating management cluster terraform.tfvars..."
    mkdir -p "${SHARED_DIR}/terraform/config/management-cluster"
    cat > "${SHARED_DIR}/terraform/config/management-cluster/terraform.tfvars" <<EOF
cluster_id = "management-01"
app_code = "e2e"
service_phase = "test"
cost_center = "000"
repository_url = "https://github.com/openshift-online/rosa-regional-platform.git"
repository_branch = "main"
enable_bastion = false
region = "${TEST_REGION}"
regional_aws_account_id = "${RC_ACCOUNT_ID}"
EOF
    log_info "Running IoT provisioning script..."
    # Set AUTO_APPROVE to avoid interactive prompts
    export AUTO_APPROVE=true
    if ! "$REPO_ROOT/scripts/provision-maestro-agent-iot-regional.sh" "${SHARED_DIR}/terraform/config/management-cluster/terraform.tfvars"; then
        log_error "IoT provisioning script failed"
        return 1
    fi
}

destroy_iot_resources() {
    export AUTO_APPROVE=true
    export AWS_REGION="us-east-1"
    $REPO_ROOT/scripts/cleanup-maestro-agent-iot.sh ${SHARED_DIR}/terraform/config/management-cluster/terraform.tfvars \
        || { log_error "Failed to cleanup IoT resources"; return 1; }
}

TEARDOWN=false
for arg in "$@"; do
  case "$arg" in
    --destroy-regional) TEARDOWN=true ;;
    *)
      echo "Unknown argument: $arg" >&2
      echo "Usage: $0 [--destroy-regional]" >&2
      exit 1
      ;;
  esac
done

# todo: codepipeline will be able to build the platform for each or use public image
export TF_VAR_container_image="633630779107.dkr.ecr.us-east-1.amazonaws.com/e2e-platform-01c48e:3278a75292a3"

aws configure set region "${TEST_REGION}"

if [[ "$TEARDOWN" == "true" ]]; then
    log_phase "Starting E2E Regional Cluster Destruction"        
    # Setup S3 backend (required for terraform destroy)
    create_s3_bucket || { log_error "Failed to setup S3 backend"; exit 1; }
    destroy_iot_resources || { log_error "IoT resources cleanup failed"; exit 1; }
    destroy_regional_cluster || { log_error "Regional Cluster destruction failed"; exit 1; }
    log_success "Regional Cluster destroyed successfully"
    exit 0
fi

log_phase "Starting E2E Regional Cluster Test"
# Step 1: Setup S3 backend
create_s3_bucket || { log_error "Failed to setup S3 backend"; exit 1; }
# Step 2: Build and push platform image to ECR (MUST happen before configure_rc_environment)
# This exports TF_VAR_container_image with the full ECR URI
log_success "Container image configured: ${TF_VAR_container_image}"
# Step 3: Provision regional cluster (calls configure_rc_environment which uses TF_VAR_container_image)
create_regional_cluster || { log_error "Regional cluster provisioning failed"; exit 1; }
log_success "Regional Cluster creation completed successfully"
create_iot_resources || { log_error "IoT resources creation failed"; exit 1; }
log_success "IoT resources creation completed successfully"
log "Done creating e2e regional cluster test"
