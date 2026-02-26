#!/usr/bin/env bash
# Provision regional and management cluster pipelines from deploy/ directory structure.
#
# Reads region and management cluster configs from deploy/<environment>/<region>/terraform/
# and runs terraform to create/update the corresponding CodePipeline pipelines.
#
# Required environment variables:
#   ENVIRONMENT          - Target environment (e.g., staging, production)
#   GITHUB_REPOSITORY    - GitHub repository in owner/name format (e.g., 'octocat/hello-world')
#   GITHUB_BRANCH        - GitHub branch to track
#   GITHUB_CONNECTION_ARN - CodeStar connection ARN
#   PLATFORM_IMAGE       - Platform container image URI for CodeBuild projects

set -euo pipefail
trap 'echo "FAILED: line $LINENO, exit code $?" >&2' ERR

# Get central account ID for state bucket
CENTRAL_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
TF_STATE_BUCKET="terraform-state-${CENTRAL_ACCOUNT_ID}"

# Determine which environment to process (prefer existing, fall back to TARGET_ENVIRONMENT, then staging)
ENVIRONMENT="${ENVIRONMENT:-${TARGET_ENVIRONMENT:-staging}}"

# Validate and sanitize ENVIRONMENT to prevent path traversal and injection
if [[ -z "$ENVIRONMENT" ]]; then
    echo "❌ ERROR: ENVIRONMENT is empty" >&2
    exit 1
fi
if [[ "$ENVIRONMENT" == *"/"* ]]; then
    echo "❌ ERROR: ENVIRONMENT contains invalid character '/': $ENVIRONMENT" >&2
    exit 1
fi
if [[ "$ENVIRONMENT" == *".."* ]]; then
    echo "❌ ERROR: ENVIRONMENT contains path traversal sequence '..': $ENVIRONMENT" >&2
    exit 1
fi
if [[ "$ENVIRONMENT" =~ [[:space:]] ]]; then
    echo "❌ ERROR: ENVIRONMENT contains whitespace: $ENVIRONMENT" >&2
    exit 1
fi
if [[ ! "$ENVIRONMENT" =~ ^[A-Za-z0-9._-]+$ ]]; then
    echo "❌ ERROR: ENVIRONMENT contains invalid characters: $ENVIRONMENT" >&2
    echo "   Only alphanumeric, dot (.), underscore (_), and hyphen (-) are allowed" >&2
    exit 1
fi

# Try to read tf_state_region from config.yaml via the first regional.json file found
# This allows sectors to configure tf_state_region in their terraform_vars
TF_STATE_REGION=""
if [ -d "deploy/${ENVIRONMENT}" ]; then
    # Find first regional.json file in this environment
    FIRST_REGIONAL_JSON=$(find "deploy/${ENVIRONMENT}" -name "regional.json" -type f | head -n 1)
    if [ -n "$FIRST_REGIONAL_JSON" ]; then
        TF_STATE_REGION=$(jq -r '.tf_state_region // empty' "$FIRST_REGIONAL_JSON" 2>/dev/null || echo "")
    fi
fi

# If not found in config, try to detect from bucket location
if [ -z "$TF_STATE_REGION" ]; then
    BUCKET_REGION=$(aws s3api get-bucket-location --bucket "$TF_STATE_BUCKET" --region us-east-1 --query LocationConstraint --output text 2>/dev/null || echo "")
    if [ "$BUCKET_REGION" == "None" ] || [ "$BUCKET_REGION" == "null" ] || [ -z "$BUCKET_REGION" ]; then
        TF_STATE_REGION="us-east-1"
    else
        TF_STATE_REGION="$BUCKET_REGION"
    fi
fi

echo "Using state bucket: $TF_STATE_BUCKET"
echo "Using state bucket region: $TF_STATE_REGION"
echo "Using lockfile-based state locking"

# Helper function: Retry terraform apply with exponential backoff
# Usage: retry_terraform_apply "${TF_ARGS[@]}"
retry_terraform_apply() {
    local max_attempts=3
    local attempt=1
    local wait_time=30

    while [ $attempt -le $max_attempts ]; do
        echo "📝 Attempt $attempt/$max_attempts: Running terraform apply..."

        if terraform apply -auto-approve "$@"; then
            echo "✅ Terraform apply succeeded"
            return 0
        else
            if [ $attempt -lt $max_attempts ]; then
                echo "⚠️  Attempt $attempt failed, waiting ${wait_time}s before retry..."
                sleep $wait_time
                wait_time=$((wait_time * 2))  # Exponential backoff
                attempt=$((attempt + 1))
            else
                echo "❌ All $max_attempts attempts failed"
                return 1
            fi
        fi
    done
}

# Helper function: Resolve SSM parameter if value starts with "ssm:"
resolve_ssm_param() {
    local value="$1"
    local region="${2:-${AWS_REGION}}"  # Optional region parameter, defaults to AWS_REGION
    if [[ "$value" == ssm:* ]]; then
        local param_name="${value#ssm:}"
        echo "Resolving SSM parameter: $param_name in region ${region}" >&2
        aws ssm get-parameter \
            --name "$param_name" \
            --with-decryption \
            --query 'Parameter.Value' \
            --output text \
            --region "${region}"
    else
        echo "$value"
    fi
}

# Helper function: Trigger pipeline destruction
# Arguments: pipeline_type (regional/management)
destroy_pipeline() {
    local pipeline_type="$1"
    
    echo "⚠️  Processing DELETE request for $pipeline_type pipeline..."

    # Note: We skip triggering infrastructure destruction via CodeBuild because
    # CodeBuild projects with CODEPIPELINE artifacts can't be started directly.
    # The actual infrastructure (EKS cluster, VPC, etc.) should be destroyed
    # separately using the pipeline's destroy mode or manual cleanup.

    echo "⚠️  WARNING: This will only destroy the pipeline resources (CodePipeline, CodeBuild, S3)."
    echo "   The actual infrastructure (EKS cluster, VPC, etc.) must be destroyed separately."
    echo "   To destroy infrastructure, trigger the pipeline with IS_DESTROY=true or use manual cleanup."
    
    # Destroy the pipeline resources
    echo "Destroying pipeline resources (CodePipeline, CodeBuild, S3)..."
    if terraform destroy -auto-approve "${TF_ARGS[@]}"; then
        echo "✅ Pipeline resources destroyed."
        return 0
    else
        echo "❌ Failed to destroy pipeline resources."
        return 1
    fi
}

echo "Processing environment: $ENVIRONMENT"
echo ""

# Validate environment directory exists
if [ ! -d "deploy/${ENVIRONMENT}" ]; then
    echo "❌ ERROR: Environment directory does not exist: deploy/${ENVIRONMENT}" >&2
    echo "   Available environments:" >&2
    ls -d deploy/*/ 2>/dev/null | sed 's|deploy/||g; s|/$||g' | sed 's/^/   - /' >&2 || echo "   (none found)" >&2
    exit 1
fi

# Validate at least one region directory exists
shopt -s nullglob
region_dirs=("deploy/${ENVIRONMENT}"/*/)
shopt -u nullglob

if [ ${#region_dirs[@]} -eq 0 ]; then
    echo "❌ ERROR: No region directories found in deploy/${ENVIRONMENT}/" >&2
    echo "   Expected at least one directory matching: deploy/${ENVIRONMENT}/*/" >&2
    echo "   Ensure config.yaml has shards for environment '${ENVIRONMENT}' and run scripts/render.py" >&2
    exit 1
fi

echo "Found ${#region_dirs[@]} region(s) in environment '${ENVIRONMENT}'"
echo ""

# Process each region_alias directory in the target environment
for region_dir in deploy/${ENVIRONMENT}/*/; do
    [ -d "$region_dir" ] || continue

    # Extract region_alias from directory path
    # e.g., deploy/integration/us-east-1/ -> REGION_ALIAS=us-east-1
    REGION_ALIAS=$(basename "$region_dir")

    echo "=========================================="
    echo "Processing: $ENVIRONMENT / $REGION_ALIAS"
    echo "=========================================="

    # 1. Check for regional.json in this region
    if [ -f "${region_dir}terraform/regional.json" ]; then
        echo "Found regional.json for ${ENVIRONMENT}-${REGION_ALIAS}"

        REGIONAL_CONFIG="${region_dir}terraform/regional.json"

        # Extract configuration from JSON
        AWS_REGION=$(jq -r '.region // .target_region // "us-east-1"' "$REGIONAL_CONFIG")
        TARGET_ACCOUNT_ID=$(jq -r '.account_id // ""' "$REGIONAL_CONFIG")
        TARGET_ACCOUNT_ID=$(resolve_ssm_param "$TARGET_ACCOUNT_ID")
        TARGET_ALIAS=$(jq -r '.alias // ""' "$REGIONAL_CONFIG")

        # Extract terraform vars with defaults
        APP_CODE=$(jq -r '.app_code // "infra"' "$REGIONAL_CONFIG")
        SERVICE_PHASE=$(jq -r '.service_phase // "dev"' "$REGIONAL_CONFIG")
        COST_CENTER=$(jq -r '.cost_center // "000"' "$REGIONAL_CONFIG")
        ENABLE_BASTION=$(jq -r '.enable_bastion // false' "$REGIONAL_CONFIG")
        DELETE_FLAG=$(jq -r '.delete // false' "$REGIONAL_CONFIG")

        echo "  AWS Region: $AWS_REGION"
        [ -n "$TARGET_ACCOUNT_ID" ] && echo "  Target Account ID: $TARGET_ACCOUNT_ID"
        [ -n "$TARGET_ALIAS" ] && echo "  Target Alias: $TARGET_ALIAS"
        echo "  Terraform Vars: app_code=$APP_CODE, service_phase=$SERVICE_PHASE, cost_center=$COST_CENTER, enable_bastion=$ENABLE_BASTION"
        echo "  Delete Flag: $DELETE_FLAG"

        echo "Processing Regional Cluster Pipeline for ${ENVIRONMENT}-${REGION_ALIAS}..."

        cd terraform/config/pipeline-regional-cluster

        terraform init \
            -reconfigure \
            -backend-config="bucket=$TF_STATE_BUCKET" \
            -backend-config="key=pipelines/regional-${ENVIRONMENT}-${REGION_ALIAS}.tfstate" \
            -backend-config="region=$TF_STATE_REGION" \
            -backend-config="use_lockfile=true"

        # Build terraform apply command with variables (array for safe expansion)
        TF_ARGS=(
            -var="github_repository=${GITHUB_REPOSITORY}"
            -var="github_branch=${GITHUB_BRANCH}"
            -var="region=${AWS_REGION}"
        )
        [ -n "$GITHUB_CONNECTION_ARN" ] && TF_ARGS+=( -var="github_connection_arn=${GITHUB_CONNECTION_ARN}" )
        [ -n "$TARGET_ACCOUNT_ID" ] && TF_ARGS+=( -var="target_account_id=${TARGET_ACCOUNT_ID}" )
        [ -n "$AWS_REGION" ] && TF_ARGS+=( -var="target_region=${AWS_REGION}" )
        [ -n "$TARGET_ALIAS" ] && TF_ARGS+=( -var="target_alias=${TARGET_ALIAS}" )
        [ -n "$ENVIRONMENT" ] && TF_ARGS+=( -var="target_environment=${ENVIRONMENT}" )
        [ -n "$APP_CODE" ] && TF_ARGS+=( -var="app_code=${APP_CODE}" )
        [ -n "$SERVICE_PHASE" ] && TF_ARGS+=( -var="service_phase=${SERVICE_PHASE}" )
        [ -n "$COST_CENTER" ] && TF_ARGS+=( -var="cost_center=${COST_CENTER}" )
        # Handle enable_bastion (boolean, convert to Terraform boolean)
        if [ "$ENABLE_BASTION" == "true" ] || [ "$ENABLE_BASTION" == "1" ]; then
            TF_ARGS+=( -var="enable_bastion=true" )
        else
            TF_ARGS+=( -var="enable_bastion=false" )
        fi
        # Repository URL and branch for cluster configuration
        TF_ARGS+=(
            -var="repository_url=https://github.com/${GITHUB_REPOSITORY}.git"
            -var="repository_branch=${GITHUB_BRANCH}"
            -var="codebuild_image=${PLATFORM_IMAGE}"
        )

        if [ "$DELETE_FLAG" == "true" ]; then
            if destroy_pipeline "regional"; then
                cd ../../..
                echo "✅ Regional pipeline cleanup complete for ${ENVIRONMENT}-${REGION_ALIAS}"
            else
                cd ../../..
                echo "❌ Failed to destroy regional pipeline for ${ENVIRONMENT}-${REGION_ALIAS}"
                echo "   Destroy failure requires manual intervention. Aborting."
                exit 1
            fi
        else
            # Apply with retry logic
            if retry_terraform_apply "${TF_ARGS[@]}"; then
                cd ../../..
                echo "✅ Regional pipeline created for ${ENVIRONMENT}-${REGION_ALIAS}"
            else
                cd ../../..
                echo "❌ Failed to create regional pipeline for ${ENVIRONMENT}-${REGION_ALIAS} after retries"
                echo "⏭️  Continuing with next region..."
                continue
            fi
        fi
    else
        echo "No terraform/regional.json found in $region_dir, skipping regional pipeline..."
    fi

    # 2. Check for management/*.json files in this region
    if [ -d "${region_dir}terraform/management" ]; then
        echo "Checking for management cluster configs in ${ENVIRONMENT}-${REGION_ALIAS}..."

        for mc_config in ${region_dir}terraform/management/*.json; do
            [ -e "$mc_config" ] || continue

            # Extract cluster name from filename (e.g., mc01-us-east-1.json -> mc01-us-east-1)
            CLUSTER_NAME=$(basename "$mc_config" .json)

            echo "Found management cluster config: $CLUSTER_NAME"

            # Extract configuration from JSON
            AWS_REGION=$(jq -r '.region // .target_region // "us-east-1"' "$mc_config")
            TARGET_ACCOUNT_ID=$(jq -r '.account_id // ""' "$mc_config")
            TARGET_ACCOUNT_ID=$(resolve_ssm_param "$TARGET_ACCOUNT_ID")
            TARGET_ALIAS=$(jq -r '.alias // ""' "$mc_config")

            # Extract terraform vars with defaults
            APP_CODE=$(jq -r '.app_code // "infra"' "$mc_config")
            SERVICE_PHASE=$(jq -r '.service_phase // "dev"' "$mc_config")
            COST_CENTER=$(jq -r '.cost_center // "000"' "$mc_config")
            CLUSTER_ID=$(jq -r '.cluster_id // ""' "$mc_config")
            REGIONAL_AWS_ACCOUNT_ID=$(jq -r '.regional_aws_account_id // ""' "$mc_config")
            ENABLE_BASTION=$(jq -r '.enable_bastion // false' "$mc_config")
            DELETE_FLAG=$(jq -r '.delete // false' "$mc_config")

            # Use TARGET_ALIAS as cluster_id default if not specified
            [ -z "$CLUSTER_ID" ] && CLUSTER_ID="${TARGET_ALIAS}"

            # Resolve REGIONAL_AWS_ACCOUNT_ID using the helper function
            REGIONAL_AWS_ACCOUNT_ID=$(resolve_ssm_param "$REGIONAL_AWS_ACCOUNT_ID" "${AWS_REGION}")

            # Validate that REGIONAL_AWS_ACCOUNT_ID is non-empty
            if [[ -z "$REGIONAL_AWS_ACCOUNT_ID" ]]; then
                echo "❌ ERROR: REGIONAL_AWS_ACCOUNT_ID must be provided for region ${AWS_REGION}"
                echo "   Set regional_aws_account_id in your management cluster config (either direct account ID or ssm:/path/to/param)"
                exit 1
            fi

            echo "  AWS Region: $AWS_REGION"
            [ -n "$TARGET_ACCOUNT_ID" ] && echo "  Target Account ID: $TARGET_ACCOUNT_ID"
            [ -n "$TARGET_ALIAS" ] && echo "  Target Alias: $TARGET_ALIAS"
            echo "  Terraform Vars: app_code=$APP_CODE, service_phase=$SERVICE_PHASE, cost_center=$COST_CENTER, cluster_id=$CLUSTER_ID, regional_aws_account_id=$REGIONAL_AWS_ACCOUNT_ID, enable_bastion=$ENABLE_BASTION"
            echo "  Delete Flag: $DELETE_FLAG"

            echo "Processing Management Cluster Pipeline for $CLUSTER_NAME in ${ENVIRONMENT}-${REGION_ALIAS}..."

            cd terraform/config/pipeline-management-cluster

            terraform init \
                -reconfigure \
                -backend-config="bucket=$TF_STATE_BUCKET" \
                -backend-config="key=pipelines/management-${ENVIRONMENT}-${REGION_ALIAS}-${CLUSTER_NAME}.tfstate" \
                -backend-config="region=$TF_STATE_REGION" \
                -backend-config="use_lockfile=true"

            # Build terraform apply command with variables (array for safe expansion)
            TF_ARGS=(
                -var="github_repository=${GITHUB_REPOSITORY}"
                -var="github_branch=${GITHUB_BRANCH}"
                -var="region=${AWS_REGION}"
            )
            [ -n "$GITHUB_CONNECTION_ARN" ] && TF_ARGS+=( -var="github_connection_arn=${GITHUB_CONNECTION_ARN}" )
            [ -n "$TARGET_ACCOUNT_ID" ] && TF_ARGS+=( -var="target_account_id=${TARGET_ACCOUNT_ID}" )
            [ -n "$AWS_REGION" ] && TF_ARGS+=( -var="target_region=${AWS_REGION}" )
            [ -n "$TARGET_ALIAS" ] && TF_ARGS+=( -var="target_alias=${TARGET_ALIAS}" )
            [ -n "$ENVIRONMENT" ] && TF_ARGS+=( -var="target_environment=${ENVIRONMENT}" )
            [ -n "$APP_CODE" ] && TF_ARGS+=( -var="app_code=${APP_CODE}" )
            [ -n "$SERVICE_PHASE" ] && TF_ARGS+=( -var="service_phase=${SERVICE_PHASE}" )
            [ -n "$COST_CENTER" ] && TF_ARGS+=( -var="cost_center=${COST_CENTER}" )
            [ -n "$CLUSTER_ID" ] && TF_ARGS+=( -var="cluster_id=${CLUSTER_ID}" )
            [ -n "$REGIONAL_AWS_ACCOUNT_ID" ] && TF_ARGS+=( -var="regional_aws_account_id=${REGIONAL_AWS_ACCOUNT_ID}" )
            # Handle enable_bastion (boolean, convert to Terraform boolean)
            if [ "$ENABLE_BASTION" == "true" ] || [ "$ENABLE_BASTION" == "1" ]; then
                TF_ARGS+=( -var="enable_bastion=true" )
            else
                TF_ARGS+=( -var="enable_bastion=false" )
            fi
            # Repository URL and branch for cluster configuration
            TF_ARGS+=(
                -var="repository_url=https://github.com/${GITHUB_REPOSITORY}.git"
                -var="repository_branch=${GITHUB_BRANCH}"
                -var="codebuild_image=${PLATFORM_IMAGE}"
            )

            if [ "$DELETE_FLAG" == "true" ]; then
                if destroy_pipeline "management"; then
                    cd ../../..
                    echo "✅ Management pipeline cleanup complete for $CLUSTER_NAME"
                else
                    cd ../../..
                    echo "❌ Failed to destroy management pipeline for $CLUSTER_NAME"
                    echo "   Destroy failure requires manual intervention. Aborting."
                    exit 1
                fi
            else
                # Apply with retry logic
                if retry_terraform_apply "${TF_ARGS[@]}"; then
                    cd ../../..
                    echo "✅ Management pipeline created for $CLUSTER_NAME in ${ENVIRONMENT}-${REGION_ALIAS}"
                else
                    cd ../../..
                    echo "❌ Failed to create management pipeline for $CLUSTER_NAME after retries"
                    echo "⏭️  Continuing with next management cluster..."
                    continue
                fi
            fi
        done
    else
        echo "No terraform/management/ directory in $region_dir, skipping management pipelines..."
    fi

    echo ""
done
