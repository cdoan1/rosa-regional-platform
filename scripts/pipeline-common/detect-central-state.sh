#!/usr/bin/env bash
#
# detect-central-state.sh - Detect central account and S3 state bucket region
#
# This script detects the central AWS account ID and the region where the
# Terraform state bucket is located. Used by validation and other pipelines.
#
# Exports:
#   CENTRAL_ACCOUNT_ID - Central account ID (for S3 state bucket)
#   TF_STATE_REGION    - Region where S3 state bucket is located

set -euo pipefail

# Get central account ID for state bucket
CENTRAL_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
export CENTRAL_ACCOUNT_ID
echo "Central Account: $CENTRAL_ACCOUNT_ID"

# Detect S3 state bucket region (bucket is in central account)
TF_STATE_BUCKET="terraform-state-${CENTRAL_ACCOUNT_ID}"
BUCKET_REGION=$(aws s3api get-bucket-location --bucket "$TF_STATE_BUCKET" --region us-east-1 --query LocationConstraint --output text)
if [ "$BUCKET_REGION" == "None" ] || [ "$BUCKET_REGION" == "null" ] || [ -z "$BUCKET_REGION" ]; then
    BUCKET_REGION="us-east-1"
fi
export TF_STATE_REGION=$BUCKET_REGION
echo "State Bucket Region: $TF_STATE_REGION"
echo ""
