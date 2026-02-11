#!/bin/bash
set -euo pipefail

REGION=${1:-$(aws configure get region 2>/dev/null || echo "us-east-1")}
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
BUCKET_NAME="terraform-state-${ACCOUNT_ID}"

echo "Bootstrapping Terraform State in $REGION..."
echo "Bucket: $BUCKET_NAME"
echo ""

# Function to apply bucket security settings
apply_bucket_security() {
    echo "Applying security settings to bucket $BUCKET_NAME..."

    aws s3api put-bucket-versioning \
        --bucket "$BUCKET_NAME" \
        --versioning-configuration Status=Enabled \
        --region "$REGION"

    aws s3api put-bucket-encryption \
        --bucket "$BUCKET_NAME" \
        --server-side-encryption-configuration '{"Rules": [{"ApplyServerSideEncryptionByDefault": {"SSEAlgorithm": "AES256"}}]}' \
        --region "$REGION"

    aws s3api put-public-access-block \
        --bucket "$BUCKET_NAME" \
        --public-access-block-configuration "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true" \
        --region "$REGION"

    echo "✅ Security settings applied"
}

# Create S3 Bucket
if aws s3api head-bucket --bucket "$BUCKET_NAME" 2>/dev/null; then
    echo "✅ Bucket $BUCKET_NAME already exists."
    apply_bucket_security
else
    echo "Creating bucket $BUCKET_NAME..."
    if [[ "$REGION" == "us-east-1" ]]; then
        aws s3api create-bucket --bucket "$BUCKET_NAME" --region "$REGION"
    else
        aws s3api create-bucket --bucket "$BUCKET_NAME" --create-bucket-configuration LocationConstraint="$REGION" --region "$REGION"
    fi
    echo "✅ Bucket created successfully"
    apply_bucket_security
fi

echo ""
echo "✅ Bootstrap complete."
echo "   State bucket: $BUCKET_NAME"
echo "   Locking: lockfile (stored in S3)"
