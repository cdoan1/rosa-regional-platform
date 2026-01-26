#!/bin/bash
# =============================================================================
# Setup IAM Role and Policy for External Secrets Operator
# =============================================================================
# This script creates an IAM role with Pod Identity for ESO to access AWS
# Secrets Manager secrets.
#
# Usage:
#   ./scripts/setup-eso-iam.sh [cluster-name] [namespace]
#
# Example:
#   ./scripts/setup-eso-iam.sh regional-1nij external-secrets
#
# Prerequisites:
#   - AWS CLI configured with appropriate credentials
#   - EKS cluster already exists
#   - jq installed

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
CLUSTER_NAME="${1:-}"
ESO_NAMESPACE="${2:-external-secrets}"
ESO_SERVICE_ACCOUNT="external-secrets-sa"
ROLE_NAME="${CLUSTER_NAME}-eso-secrets-manager"

echo -e "${GREEN}==============================================================================${NC}"
echo -e "${GREEN}External Secrets Operator IAM Setup${NC}"
echo -e "${GREEN}==============================================================================${NC}"
echo ""

# Validate inputs
if [ -z "${CLUSTER_NAME}" ]; then
    echo -e "${RED}Error: Cluster name is required${NC}"
    echo "Usage: $0 <cluster-name> [namespace]"
    echo "Example: $0 regional-1nij external-secrets"
    exit 1
fi

echo -e "${BLUE}Configuration:${NC}"
echo "  Cluster Name: ${CLUSTER_NAME}"
echo "  ESO Namespace: ${ESO_NAMESPACE}"
echo "  Service Account: ${ESO_SERVICE_ACCOUNT}"
echo "  IAM Role Name: ${ROLE_NAME}"
echo ""

# Get AWS account ID and region
echo -e "${YELLOW}Step 1: Getting AWS account information...${NC}"
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
AWS_REGION=$(aws configure get region || echo "us-east-1")

echo "  AWS Account ID: ${AWS_ACCOUNT_ID}"
echo "  AWS Region: ${AWS_REGION}"
echo ""

# Create IAM policy document for Secrets Manager access
echo -e "${YELLOW}Step 2: Creating IAM policy for Secrets Manager access...${NC}"

POLICY_NAME="${CLUSTER_NAME}-eso-secrets-manager-policy"
POLICY_DOCUMENT=$(cat <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "secretsmanager:GetSecretValue",
        "secretsmanager:DescribeSecret"
      ],
      "Resource": "arn:aws:secretsmanager:${AWS_REGION}:${AWS_ACCOUNT_ID}:secret:${CLUSTER_NAME}/*"
    },
    {
      "Effect": "Allow",
      "Action": [
        "secretsmanager:ListSecrets"
      ],
      "Resource": "*"
    }
  ]
}
EOF
)

# Check if policy already exists
POLICY_ARN="arn:aws:iam::${AWS_ACCOUNT_ID}:policy/${POLICY_NAME}"
if aws iam get-policy --policy-arn "${POLICY_ARN}" &>/dev/null; then
    echo -e "${YELLOW}  Policy ${POLICY_NAME} already exists, updating...${NC}"

    # Create a new policy version
    DEFAULT_VERSION=$(aws iam get-policy --policy-arn "${POLICY_ARN}" --query 'Policy.DefaultVersionId' --output text)

    # List all versions and delete old ones if we're at the limit (5 versions max)
    VERSION_COUNT=$(aws iam list-policy-versions --policy-arn "${POLICY_ARN}" --query 'length(Versions)' --output text)
    if [ "${VERSION_COUNT}" -ge 5 ]; then
        echo "  Deleting oldest policy version to make room..."
        OLDEST_VERSION=$(aws iam list-policy-versions --policy-arn "${POLICY_ARN}" \
            --query 'Versions[?IsDefaultVersion==`false`]|[0].VersionId' --output text)
        aws iam delete-policy-version --policy-arn "${POLICY_ARN}" --version-id "${OLDEST_VERSION}"
    fi

    aws iam create-policy-version \
        --policy-arn "${POLICY_ARN}" \
        --policy-document "${POLICY_DOCUMENT}" \
        --set-as-default

    echo -e "${GREEN}  ✓ Policy updated${NC}"
else
    echo "  Creating new policy ${POLICY_NAME}..."
    aws iam create-policy \
        --policy-name "${POLICY_NAME}" \
        --policy-document "${POLICY_DOCUMENT}" \
        --description "Allows ESO to access Secrets Manager secrets for ${CLUSTER_NAME}"

    echo -e "${GREEN}  ✓ Policy created${NC}"
fi

echo "  Policy ARN: ${POLICY_ARN}"
echo ""

# Create IAM role for Pod Identity
echo -e "${YELLOW}Step 3: Creating IAM role for Pod Identity...${NC}"

# Trust policy for EKS Pod Identity
TRUST_POLICY=$(cat <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "pods.eks.amazonaws.com"
      },
      "Action": [
        "sts:AssumeRole",
        "sts:TagSession"
      ]
    }
  ]
}
EOF
)

# Check if role already exists
if aws iam get-role --role-name "${ROLE_NAME}" &>/dev/null; then
    echo -e "${YELLOW}  Role ${ROLE_NAME} already exists, updating trust policy...${NC}"
    aws iam update-assume-role-policy \
        --role-name "${ROLE_NAME}" \
        --policy-document "${TRUST_POLICY}"
    echo -e "${GREEN}  ✓ Trust policy updated${NC}"
else
    echo "  Creating new role ${ROLE_NAME}..."
    aws iam create-role \
        --role-name "${ROLE_NAME}" \
        --assume-role-policy-document "${TRUST_POLICY}" \
        --description "ESO Pod Identity role for ${CLUSTER_NAME}"
    echo -e "${GREEN}  ✓ Role created${NC}"
fi

ROLE_ARN="arn:aws:iam::${AWS_ACCOUNT_ID}:role/${ROLE_NAME}"
echo "  Role ARN: ${ROLE_ARN}"
echo ""

# Attach policy to role
echo -e "${YELLOW}Step 4: Attaching policy to role...${NC}"
aws iam attach-role-policy \
    --role-name "${ROLE_NAME}" \
    --policy-arn "${POLICY_ARN}"
echo -e "${GREEN}  ✓ Policy attached${NC}"
echo ""

# Create Pod Identity association
echo -e "${YELLOW}Step 5: Creating EKS Pod Identity association...${NC}"

# Check if association already exists
EXISTING_ASSOC=$(aws eks list-pod-identity-associations \
    --cluster-name "${CLUSTER_NAME}" \
    --namespace "${ESO_NAMESPACE}" \
    --service-account "${ESO_SERVICE_ACCOUNT}" \
    --query 'associations[0].associationId' \
    --output text 2>/dev/null || echo "None")

if [ "${EXISTING_ASSOC}" != "None" ]; then
    echo -e "${YELLOW}  Pod Identity association already exists: ${EXISTING_ASSOC}${NC}"
    echo "  Updating association..."
    aws eks update-pod-identity-association \
        --cluster-name "${CLUSTER_NAME}" \
        --association-id "${EXISTING_ASSOC}" \
        --role-arn "${ROLE_ARN}"
    echo -e "${GREEN}  ✓ Association updated${NC}"
else
    echo "  Creating new Pod Identity association..."
    ASSOCIATION_ID=$(aws eks create-pod-identity-association \
        --cluster-name "${CLUSTER_NAME}" \
        --namespace "${ESO_NAMESPACE}" \
        --service-account "${ESO_SERVICE_ACCOUNT}" \
        --role-arn "${ROLE_ARN}" \
        --query 'association.associationId' \
        --output text)
    echo -e "${GREEN}  ✓ Association created: ${ASSOCIATION_ID}${NC}"
fi

echo ""
echo -e "${GREEN}==============================================================================${NC}"
echo -e "${GREEN}✓ IAM Setup Complete${NC}"
echo -e "${GREEN}==============================================================================${NC}"
echo ""
echo -e "${BLUE}Next Steps:${NC}"
echo ""
echo "1. Run the Kubernetes resources setup script:"
echo "   ${GREEN}./scripts/setup-eso-resources.sh ${CLUSTER_NAME} ${ESO_NAMESPACE}${NC}"
echo ""
echo "2. Or manually create the resources with the following values:"
echo "   Namespace: ${ESO_NAMESPACE}"
echo "   ServiceAccount: ${ESO_SERVICE_ACCOUNT}"
echo "   Role ARN: ${ROLE_ARN}"
echo ""
echo -e "${BLUE}Summary:${NC}"
echo "  IAM Policy ARN: ${POLICY_ARN}"
echo "  IAM Role ARN: ${ROLE_ARN}"
echo "  Pod Identity Association: ✓"
echo ""
