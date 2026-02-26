#!/bin/bash
# This is a simple e2e regional cluster test script.
# This script runs in the AWS account id context of the regional cluster.
# The account id is only directly referenced in the S3 bucket name and the regional cluster name.

set -euo pipefail

# Script directory and repository root
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

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
log() { echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*"; }
log_info() { log "ℹ️  $1"; }
log_success() { log "✅ $1"; }
log_error() { log "❌ $1" >&2; }
log_phase() { echo ""; echo "=========================================="; log "$1"; echo "=========================================="; }

# Setup S3 bucket for Terraform state
# This bucket will be used for terraform state files for e2e tests
# The bucket should be created in the central account (current account)
# The bucket should be created in the us-east-1 region (or TF_STATE_REGION)
# The bucket should have proper security settings (encryption, versioning, public access block)
# The bucket should have proper permissions (bucket policy for cross-account access if in org)
create_s3_bucket() {
    # Use environment variable if set, otherwise use default
    local bucket_name="e2e-rosa-regional-platform-${HASH}"
    local region="${TF_STATE_REGION:-us-east-1}"
    local account_id
    account_id="$(aws sts get-caller-identity --query Account --output text)" || return 1
    
    log_info "Setting up S3 backend: bucket=${bucket_name}, region=${region}, account=${account_id}"
    
    # Check if bucket exists
    if aws s3api head-bucket --bucket "$bucket_name" 2>/dev/null; then
        log_info "Bucket ${bucket_name} already exists"
        
        # Verify bucket is in the expected region
        local bucket_region=$(aws s3api get-bucket-location --bucket "$bucket_name" --region us-east-1 --query LocationConstraint --output text 2>/dev/null || echo "")
        if [[ "$bucket_region" == "None" ]] || [[ "$bucket_region" == "null" ]] || [[ -z "$bucket_region" ]]; then
            bucket_region="us-east-1"
        fi
        if [[ "$bucket_region" != "$region" ]]; then
            log_error "Bucket ${bucket_name} exists in region ${bucket_region}, but expected ${region}"
            return 1
        fi
    else
        log_info "Creating bucket ${bucket_name} in region ${region}..."
        if [[ "$region" == "us-east-1" ]]; then
            # us-east-1 doesn't support LocationConstraint
            if ! aws s3api create-bucket --bucket "$bucket_name" --region "$region" 2>/dev/null; then
                # Check if bucket was created by another process
                if aws s3api head-bucket --bucket "$bucket_name" 2>/dev/null; then
                    log_info "Bucket ${bucket_name} was created by another process"
                else
                    log_error "Failed to create bucket ${bucket_name}"
                    return 1
                fi
            else
                log_success "Bucket ${bucket_name} created"
            fi
        else
            if ! aws s3api create-bucket \
                --bucket "$bucket_name" \
                --create-bucket-configuration LocationConstraint="$region" \
                --region "$region" 2>/dev/null; then
                # Check if bucket was created by another process
                if aws s3api head-bucket --bucket "$bucket_name" 2>/dev/null; then
                    log_info "Bucket ${bucket_name} was created by another process"
                else
                    log_error "Failed to create bucket ${bucket_name}"
                    return 1
                fi
            else
                log_success "Bucket ${bucket_name} created"
            fi
        fi
    fi
    
    # Apply security settings (idempotent operations)
    log_info "Applying security settings to bucket ${bucket_name}..."
    
    # Enable versioning
    aws s3api put-bucket-versioning \
        --bucket "$bucket_name" \
        --versioning-configuration Status=Enabled \
        --region "$region" 2>/dev/null || log_info "Versioning already enabled"
    
    # Enable encryption
    aws s3api put-bucket-encryption \
        --bucket "$bucket_name" \
        --server-side-encryption-configuration '{"Rules": [{"ApplyServerSideEncryptionByDefault": {"SSEAlgorithm": "AES256"}}]}' \
        --region "$region" 2>/dev/null || log_info "Encryption already enabled"
    
    # Block public access
    aws s3api put-public-access-block \
        --bucket "$bucket_name" \
        --public-access-block-configuration "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true" \
        --region "$region" 2>/dev/null || log_info "Public access block already configured"
    
    # Apply bucket policy for cross-account access (if in AWS Organization)
    log_info "Applying bucket policy for cross-account access..."
    local org_id=$(aws organizations describe-organization --query 'Organization.Id' --output text 2>/dev/null || echo "")
    
    local policy_file=$(mktemp)
    if [[ -n "$org_id" ]]; then
        log_info "Detected AWS Organization: ${org_id}"
        cat > "$policy_file" <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "AllowOrganizationAccountAccess",
      "Effect": "Allow",
      "Principal": "*",
      "Action": [
        "s3:GetObject",
        "s3:PutObject",
        "s3:DeleteObject",
        "s3:ListBucket"
      ],
      "Resource": [
        "arn:aws:s3:::${bucket_name}",
        "arn:aws:s3:::${bucket_name}/*"
      ],
      "Condition": {
        "StringEquals": {
          "aws:PrincipalOrgID": "${org_id}"
        }
      }
    }
  ]
}
EOF
    else
        log_info "Not in AWS Organization - applying account-restricted policy"
        cat > "$policy_file" <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "DenyAllExceptAccount",
      "Effect": "Deny",
      "Principal": "*",
      "Action": "s3:*",
      "Resource": [
        "arn:aws:s3:::${bucket_name}",
        "arn:aws:s3:::${bucket_name}/*"
      ],
      "Condition": {
        "StringNotEquals": {
          "aws:PrincipalAccount": "${account_id}"
        }
      }
    }
  ]
}
EOF
    fi
    
    aws s3api put-bucket-policy \
        --bucket "$bucket_name" \
        --policy "file://${policy_file}" \
        --region "$region" 2>/dev/null || log_info "Bucket policy already configured"
    
    rm -f "$policy_file"
    
    log_success "S3 backend configured: ${bucket_name} in ${region}"
}

create_platform_image() {
    log_phase "Setting up ECR repository and building platform image"
    
    local region="${TEST_REGION}"
    # Use a stable repository name for e2e tests (not timestamp-based) so images can be reused
    local repo_name="e2e-platform-${HASH}"
    local account_id=$(aws sts get-caller-identity --query Account --output text)
    local repo_uri="${account_id}.dkr.ecr.${region}.amazonaws.com/${repo_name}"
    
    # Detect container runtime
    local container_runtime="${CONTAINER_RUNTIME:-}"
    if [[ -z "$container_runtime" ]]; then
        if command -v docker &>/dev/null; then
            container_runtime="docker"
        elif command -v podman &>/dev/null; then
            container_runtime="podman"
        else
            log_error "Neither docker nor podman found. Install one or set CONTAINER_RUNTIME."
            return 1
        fi
    fi
    log_info "Using container runtime: ${container_runtime}"
    
    # Check if repository already exists
    if aws ecr describe-repositories \
        --region "$region" \
        --repository-names "$repo_name" \
        --query 'repositories[0].repositoryUri' \
        --output text 2>/dev/null | grep -q .; then
        log_info "ECR repository ${repo_name} already exists"
    else
        log_info "Creating private ECR repository ${repo_name} in ${region}..."
        if ! aws ecr create-repository \
            --region "$region" \
            --repository-name "$repo_name" \
            --image-scanning-configuration scanOnPush=true \
            --encryption-configuration encryptionType=AES256 \
            --output text >/dev/null 2>&1; then
            # Check if repository was created by another process
            if ! aws ecr describe-repositories \
                --region "$region" \
                --repository-names "$repo_name" \
                --query 'repositories[0].repositoryUri' \
                --output text 2>/dev/null | grep -q .; then
                log_error "Failed to create ECR repository ${repo_name}"
                return 1
            fi
            log_info "Repository was created by another process"
        else
            log_success "ECR repository ${repo_name} created"
        fi
    fi
    
    # Compute image tag from Dockerfile hash (matches Terraform's approach)
    local dockerfile="${REPO_ROOT}/terraform/modules/platform-image/Dockerfile"
    if [[ ! -f "$dockerfile" ]]; then
        log_error "Dockerfile not found: ${dockerfile}"
        return 1
    fi
    
    local image_tag
    if command -v sha256sum &>/dev/null; then
        image_tag=$(sha256sum "$dockerfile" | cut -c1-12)
    elif command -v shasum &>/dev/null; then
        image_tag=$(shasum -a 256 "$dockerfile" | cut -c1-12)
    else
        log_error "Neither sha256sum nor shasum found."
        return 1
    fi
    
    local full_image_uri="${repo_uri}:${image_tag}"
    
    log_info "Checking if platform image already exists..."
    log_info "  Repository: ${repo_name}"
    log_info "  Image tag: ${image_tag}"
    log_info "  Full URI: ${full_image_uri}"
    
    # Check if image already exists in ECR
    local image_exists=false
    if aws ecr describe-images \
        --region "$region" \
        --repository-name "$repo_name" \
        --image-ids imageTag="$image_tag" \
        --query 'imageDetails[0].imageTags' \
        --output text 2>/dev/null | grep -q "$image_tag"; then
        image_exists=true
    fi
    
    if [[ "$image_exists" == "true" ]]; then
        log_success "Image ${full_image_uri} already exists in ECR. Reusing existing image."
        export TF_VAR_container_image="${full_image_uri}"
        log_info "Using existing image: ${TF_VAR_container_image}"
        return 0
    fi
    
    log_info "Image not found in ECR. Building new image..."
    
    # Authenticate with ECR (use registry URI, not full repo URI)
    log_info "Authenticating with ECR..."
    local registry_uri="${account_id}.dkr.ecr.${region}.amazonaws.com"
    aws ecr get-login-password --region "$region" | \
        $container_runtime login --username AWS --password-stdin "$registry_uri" || {
        log_error "Failed to authenticate with ECR"
        return 1
    }
    
    # Build the image
    log_info "Building image from ${dockerfile}..."
    local dockerfile_dir="${REPO_ROOT}/terraform/modules/platform-image"
    if ! $container_runtime build --platform linux/amd64 -t "${full_image_uri}" "$dockerfile_dir"; then
        log_error "Failed to build image"
        return 1
    fi
    
    # Push the image
    log_info "Pushing image to ECR..."
    if ! $container_runtime push "${full_image_uri}"; then
        log_error "Failed to push image"
        return 1
    fi
    
    log_success "Platform image built and pushed: ${full_image_uri}"
    export TF_VAR_container_image="${full_image_uri}"
    log_info "Exported TF_VAR_container_image=${TF_VAR_container_image}"
}

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

# Main execution function
main() {
    local destroy_mode=false
    
    # Parse command line arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            --destroy|--destroy-regional|-d)
                destroy_mode=true
                shift
                ;;
            --help|-h)
                echo "Usage: $0 [OPTIONS]"
                echo ""
                echo "Options:"
                echo "  --destroy, --destroy-regional, -d    Destroy regional cluster instead of provisioning"
                echo "  --help, -h                           Show this help message"
                echo ""
                echo "Required environment variables:"
                echo "  RC_ACCOUNT_ID                        Regional cluster AWS account ID (optional for destroy)"
                echo ""
                echo "Optional environment variables:"
                echo "  TEST_REGION                          AWS region (default: us-east-1)"
                echo "  GITHUB_BRANCH                        Git branch (default: main)"
                exit 0
                ;;
            *)
                log_error "Unknown option: $1"
                echo "Use --help for usage information"
                exit 1
                ;;
        esac
    done
    
    if [[ "$destroy_mode" == "true" ]]; then
        log_phase "Starting E2E Regional Cluster Destruction"
        
        # Setup S3 backend (required for terraform destroy)
        create_s3_bucket || { log_error "Failed to setup S3 backend"; exit 1; }
        # create_platform_image || { log_error "Failed to setup and build platform image"; exit 1; }
        export TF_VAR_container_image="633630779107.dkr.ecr.us-east-1.amazonaws.com/e2e-platform-01c48e:3278a75292a3"

        destroy_regional_cluster || { log_error "Regional Cluster destruction failed"; exit 1; }
        log_success "Regional Cluster destroyed successfully"
    else
        log_phase "Starting E2E Regional Cluster Test"
        
        # Step 1: Setup S3 backend
        create_s3_bucket || { log_error "Failed to setup S3 backend"; exit 1; }
        # Step 2: Build and push platform image to ECR (MUST happen before configure_rc_environment)
        # This exports TF_VAR_container_image with the full ECR URI

        export TF_VAR_container_image="633630779107.dkr.ecr.us-east-1.amazonaws.com/e2e-platform-01c48e:3278a75292a3"
        # create_platform_image || { log_error "Failed to setup and build platform image"; exit 1; }

        # Verify container image is set with ECR URI
        if [[ -z "${TF_VAR_container_image:-}" ]]; then
            log_error "TF_VAR_container_image is not set after create_platform_image(). Cannot proceed."
            exit 1
        fi
        if [[ ! "${TF_VAR_container_image}" =~ \.dkr\.ecr\. ]]; then
            log_error "TF_VAR_container_image does not appear to be an ECR URI: ${TF_VAR_container_image}"
            log_error "Expected format: ACCOUNT.dkr.ecr.REGION.amazonaws.com/REPO:TAG"
            exit 1
        fi
        log_success "Container image configured: ${TF_VAR_container_image}"
        # Step 3: Provision regional cluster (calls configure_rc_environment which uses TF_VAR_container_image)
        create_regional_cluster || { log_error "Regional cluster provisioning failed"; exit 1; }
        log_success "E2E Regional Cluster Test completed successfully"
    fi
}

main "$@"
