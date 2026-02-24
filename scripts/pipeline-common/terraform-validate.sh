#!/usr/bin/env bash
#
# terraform-validate.sh - Run Terraform validation and plan for cluster configs
#
# Usage: ./scripts/pipeline-common/terraform-validate.sh <cluster-type>
#   cluster-type: "regional" or "management"
#
# This script iterates over configuration files and runs terraform validate/plan.

set -euo pipefail

CLUSTER_TYPE=${1:-}
if [[ -z "$CLUSTER_TYPE" ]]; then
    echo "Usage: $0 <regional|management>"
    exit 1
fi

# Validate CLUSTER_TYPE is one of the allowed values
if [[ "$CLUSTER_TYPE" != "regional" && "$CLUSTER_TYPE" != "management" ]]; then
    echo "❌ ERROR: Invalid cluster type: $CLUSTER_TYPE"
    echo "Usage: $0 <regional|management>"
    exit 1
fi

echo "=========================================="
echo "Validating $CLUSTER_TYPE Cluster Configurations"
echo "=========================================="

# Function to run validation for a single target
validate_target() {
    local ACCOUNT_ID=$1
    local REGION=$2
    local ALIAS=$3
    local EXTRA_VARS=${4:-}

    echo "---------------------------------------------------"
    echo "Validating Target: $ALIAS ($ACCOUNT_ID) in $REGION"
    if [ "$ACCOUNT_ID" != "$CENTRAL_ACCOUNT_ID" ]; then
        echo "  Terraform will assume OrganizationAccountAccessRole"
    else
        echo "  Using central account credentials"
    fi
    echo ""

    # Configure state bucket/key based on cluster type
    export TF_STATE_BUCKET="terraform-state-${CENTRAL_ACCOUNT_ID}"
    if [ "$CLUSTER_TYPE" == "regional" ]; then
        export TF_STATE_KEY="regional-cluster/${ALIAS}.tfstate"
        TERRAFORM_DIR="terraform/config/regional-cluster"
    elif [ "$CLUSTER_TYPE" == "management" ]; then
        export TF_STATE_KEY="management-cluster/${ALIAS}.tfstate"
        TERRAFORM_DIR="terraform/config/management-cluster"
    else
        echo "❌ ERROR: Invalid CLUSTER_TYPE: $CLUSTER_TYPE"
        exit 1
    fi

    # Export Common Terraform variables
    export TF_VAR_region="$REGION"
    export TF_VAR_target_account_id="$ACCOUNT_ID"
    export TF_VAR_target_alias="$ALIAS"
    export TF_VAR_app_code="${APP_CODE:-infra}"
    export TF_VAR_service_phase="${SERVICE_PHASE:-prod}"
    export TF_VAR_cost_center="${COST_CENTER:-000}"
    export TF_VAR_repository_url="${REPOSITORY_URL:-https://github.com/${GITHUB_REPOSITORY}.git}"
    export TF_VAR_repository_branch="${REPOSITORY_BRANCH:-${GITHUB_BRANCH:-main}}"

    # Export Cluster-Specific Variables
    if [ "$CLUSTER_TYPE" == "regional" ]; then
        export TF_VAR_api_additional_allowed_accounts="$ACCOUNT_ID"
    elif [ "$CLUSTER_TYPE" == "management" ]; then
        # Check for CLUSTER_ID and REGIONAL_AWS_ACCOUNT_ID in environment
        # These are usually exported by the caller loop logic or manual override env vars
        if [ -n "${CLUSTER_ID:-}" ]; then export TF_VAR_cluster_id="$CLUSTER_ID"; fi
        if [ -n "${REGIONAL_AWS_ACCOUNT_ID:-}" ]; then export TF_VAR_regional_aws_account_id="$REGIONAL_AWS_ACCOUNT_ID"; fi
    else
        echo "❌ ERROR: Invalid CLUSTER_TYPE: $CLUSTER_TYPE"
        exit 1
    fi

    # Run terraform operations in subshell
    (
        echo "Initializing Terraform in $TERRAFORM_DIR..."
        cd "$TERRAFORM_DIR"
        terraform init \
            -reconfigure \
            -backend-config="bucket=$TF_STATE_BUCKET" \
            -backend-config="key=$TF_STATE_KEY" \
            -backend-config="region=${TF_STATE_REGION:-us-east-1}" \
            -backend-config="use_lockfile=true"

        echo "Validating Terraform configuration..."
        terraform validate

        echo "Running Terraform plan..."
        terraform plan -out=tfplan

        # Save plan summary
        terraform show -no-color tfplan > plan-summary.txt
        echo "✓ Plan summary saved to plan-summary.txt"
    )
}

# ------------------------------------------------------------------------------
# Manual Override Logic
# ------------------------------------------------------------------------------
if [[ -n "${TARGET_ACCOUNT_ID:-}" && -n "${TARGET_REGION:-}" && -n "${TARGET_ALIAS:-}" ]]; then
    echo "Detected Manual Configuration Override."
    
    # For management override, we need extra variables
    if [ "$CLUSTER_TYPE" == "management" ]; then
        # Resolve SSM if needed for manual override
        if [[ "${REGIONAL_AWS_ACCOUNT_ID:-}" =~ ^ssm:/ ]]; then
            SSM_PARAM_NAME="${REGIONAL_AWS_ACCOUNT_ID#ssm:}"
            echo "Resolving SSM parameter: $SSM_PARAM_NAME"
            REGIONAL_AWS_ACCOUNT_ID=$(aws ssm get-parameter --name "$SSM_PARAM_NAME" --with-decryption --query 'Parameter.Value' --output text --region "${TARGET_REGION}")
        fi

        # Validate REGIONAL_AWS_ACCOUNT_ID is set for management clusters
        if [[ -z "${REGIONAL_AWS_ACCOUNT_ID:-}" ]]; then
            echo "❌ ERROR: REGIONAL_AWS_ACCOUNT_ID is required for CLUSTER_TYPE=management"
            echo "   Set REGIONAL_AWS_ACCOUNT_ID environment variable (direct value or ssm:/path/to/param)"
            exit 1
        fi

        # Validate REGIONAL_AWS_ACCOUNT_ID format (12-digit AWS account ID)
        if [[ ! "$REGIONAL_AWS_ACCOUNT_ID" =~ ^[0-9]{12}$ ]]; then
            echo "❌ ERROR: Invalid REGIONAL_AWS_ACCOUNT_ID: $REGIONAL_AWS_ACCOUNT_ID"
            echo "   Must be a 12-digit AWS account ID"
            exit 1
        fi

        export REGIONAL_AWS_ACCOUNT_ID
        export CLUSTER_ID="${CLUSTER_ID:-mgmt-cluster-01}" # Default for manual run
    fi

    validate_target "$TARGET_ACCOUNT_ID" "$TARGET_REGION" "$TARGET_ALIAS"
    exit 0
fi

# ------------------------------------------------------------------------------
# Loop Logic (Iterate over JSON files)
# ------------------------------------------------------------------------------

# Resolve ENVIRONMENT (with fallback to TARGET_ENVIRONMENT)
ENVIRONMENT="${ENVIRONMENT:-${TARGET_ENVIRONMENT:-}}"
if [[ -z "${ENVIRONMENT:-}" ]]; then
    echo "❌ ERROR: ENVIRONMENT variable not set"
    echo "Set ENVIRONMENT or TARGET_ENVIRONMENT to specify the deployment environment"
    exit 1
fi

# Define search pattern
if [ "$CLUSTER_TYPE" == "regional" ]; then
    SEARCH_PATTERN="deploy/${ENVIRONMENT}/*/terraform/regional.json"
elif [ "$CLUSTER_TYPE" == "management" ]; then
    SEARCH_PATTERN="deploy/${ENVIRONMENT}/*/terraform/management/*.json"
else
    echo "❌ ERROR: Invalid CLUSTER_TYPE: $CLUSTER_TYPE"
    exit 1
fi

echo "Searching for config files: $SEARCH_PATTERN"

# Track how many valid config files are found
MATCHED_COUNT=0

# Enable globstar if supported/needed, but standard glob works for fixed depth
# deploy/ENV/REGION/terraform/...
for file in $SEARCH_PATTERN; do
    [ -e "$file" ] || continue

    # Increment counter for matched files
    MATCHED_COUNT=$((MATCHED_COUNT + 1))

    echo "Processing config: $file"

    # Extract Common Fields
    ACCOUNT_ID=$(jq -r '.account_id // ""' "$file")
    REGION=$(jq -r '.region // .target_region // ""' "$file")
    ALIAS=$(jq -r '.alias // ""' "$file")

    # Extract Optional Overrides from JSON
    APP_CODE=$(jq -r '.app_code // "infra"' "$file")
    SERVICE_PHASE=$(jq -r '.service_phase // "prod"' "$file")
    COST_CENTER=$(jq -r '.cost_center // "000"' "$file")
    
    # Export these for validate_target to pick up
    export APP_CODE SERVICE_PHASE COST_CENTER

    # Skip invalid configs
    if [[ -z "$ACCOUNT_ID" || -z "$REGION" || -z "$ALIAS" ]]; then
        echo "⚠️  Skipping $file (missing account_id, region, or alias)"
        continue
    fi

    # Handle SSM Account ID resolution (if present in JSON, though typically handled by render.py, pipeline might see ssm:)
    if [[ "$ACCOUNT_ID" =~ ^ssm:/ ]]; then
       # We resolve it relative to the pipeline region (current region), or the target region?
       # Usually Account ID parameters are in the Central account (where pipeline runs).
       # detect-central-state.sh sets AWS_REGION.
       PARAM_NAME="${ACCOUNT_ID#ssm:}"
       ACCOUNT_ID=$(aws ssm get-parameter --name "$PARAM_NAME" --with-decryption --query 'Parameter.Value' --output text --region "$REGION")
    fi

    if [[ ! "$ACCOUNT_ID" =~ ^[0-9]{12}$ ]]; then
        echo "⚠️  Skipping $file (invalid account_id: $ACCOUNT_ID)"
        continue
    fi

    # Handle Management Specifics
    if [ "$CLUSTER_TYPE" == "management" ]; then
        CLUSTER_ID=$(jq -r '.cluster_id // ""' "$file")
        [ -z "$CLUSTER_ID" ] && CLUSTER_ID="${ALIAS}"
        
        REGIONAL_AWS_ACCOUNT_ID=$(jq -r '.regional_aws_account_id // ""' "$file")
        
        # Resolve SSM for Regional Account ID
        if [[ "$REGIONAL_AWS_ACCOUNT_ID" =~ ^ssm:/ ]]; then
            SSM_PARAM_NAME="${REGIONAL_AWS_ACCOUNT_ID#ssm:}"
            echo "Resolving SSM parameter for Regional Account: $SSM_PARAM_NAME"
            REGIONAL_AWS_ACCOUNT_ID=$(aws ssm get-parameter --name "$SSM_PARAM_NAME" --with-decryption --query 'Parameter.Value' --output text --region "$REGION")
        fi
        
        if [[ -z "$REGIONAL_AWS_ACCOUNT_ID" ]]; then
             echo "⚠️  Skipping $file (missing regional_aws_account_id)"
             continue
        fi
        
        export CLUSTER_ID REGIONAL_AWS_ACCOUNT_ID
    fi

    validate_target "$ACCOUNT_ID" "$REGION" "$ALIAS"
done

# Validate that at least one configuration file was found
if [ "$MATCHED_COUNT" -eq 0 ]; then
    echo "❌ ERROR: No configuration files found matching pattern: $SEARCH_PATTERN"
    echo "   Environment: $ENVIRONMENT"
    echo "   Cluster Type: $CLUSTER_TYPE"
    echo ""
    echo "   Expected directory structure:"
    if [ "$CLUSTER_TYPE" == "regional" ]; then
        echo "     deploy/${ENVIRONMENT}/<region-alias>/terraform/regional.json"
    else
        echo "     deploy/${ENVIRONMENT}/<region-alias>/terraform/management/*.json"
    fi
    echo ""
    echo "   Ensure configuration files exist for environment '${ENVIRONMENT}'"
    exit 1
fi

echo "✓ Validated $MATCHED_COUNT configuration file(s)"
echo "Validation process complete."