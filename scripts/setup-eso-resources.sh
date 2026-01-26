#!/bin/bash
# =============================================================================
# Setup Kubernetes Resources for External Secrets Operator
# =============================================================================
# This script creates the Kubernetes resources needed for ESO to access
# AWS Secrets Manager using Pod Identity.
#
# Usage:
#   ./scripts/setup-eso-resources.sh [cluster-name] [namespace]
#
# Example:
#   ./scripts/setup-eso-resources.sh regional-1nij external-secrets
#
# Prerequisites:
#   - kubectl configured to access the cluster
#   - ./setup-eso-iam.sh has been run successfully
#   - External Secrets Operator is installed

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

echo -e "${GREEN}==============================================================================${NC}"
echo -e "${GREEN}External Secrets Operator Kubernetes Resources Setup${NC}"
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
echo ""

# Get AWS account ID and region
echo -e "${YELLOW}Step 1: Getting AWS information...${NC}"
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
AWS_REGION=$(aws configure get region || echo "us-east-1")
ROLE_NAME="${CLUSTER_NAME}-eso-secrets-manager"
ROLE_ARN="arn:aws:iam::${AWS_ACCOUNT_ID}:role/${ROLE_NAME}"

echo "  AWS Account ID: ${AWS_ACCOUNT_ID}"
echo "  AWS Region: ${AWS_REGION}"
echo "  IAM Role ARN: ${ROLE_ARN}"
echo ""

# Verify IAM role exists
echo -e "${YELLOW}Step 2: Verifying IAM role exists...${NC}"
if ! aws iam get-role --role-name "${ROLE_NAME}" &>/dev/null; then
    echo -e "${RED}Error: IAM role ${ROLE_NAME} does not exist${NC}"
    echo "Please run ./scripts/setup-eso-iam.sh first"
    exit 1
fi
echo -e "${GREEN}  ✓ IAM role exists${NC}"
echo ""

# Check if namespace exists
echo -e "${YELLOW}Step 3: Ensuring namespace exists...${NC}"
if ! kubectl get namespace "${ESO_NAMESPACE}" &>/dev/null; then
    echo "  Creating namespace ${ESO_NAMESPACE}..."
    kubectl create namespace "${ESO_NAMESPACE}"
    echo -e "${GREEN}  ✓ Namespace created${NC}"
else
    echo -e "${GREEN}  ✓ Namespace already exists${NC}"
fi
echo ""

# Create ServiceAccount with Pod Identity annotation
echo -e "${YELLOW}Step 4: Creating ServiceAccount with Pod Identity annotation...${NC}"
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ServiceAccount
metadata:
  name: ${ESO_SERVICE_ACCOUNT}
  namespace: ${ESO_NAMESPACE}
  annotations:
    eks.amazonaws.com/role-arn: ${ROLE_ARN}
  labels:
    app.kubernetes.io/name: external-secrets
    app.kubernetes.io/component: controller
EOF
echo -e "${GREEN}  ✓ ServiceAccount created/updated${NC}"
echo ""

# Create SecretStore for AWS Secrets Manager
echo -e "${YELLOW}Step 5: Creating SecretStore...${NC}"
cat <<EOF | kubectl apply -f -
apiVersion: external-secrets.io/v1beta1
kind: SecretStore
metadata:
  name: aws-secrets-manager
  namespace: ${ESO_NAMESPACE}
spec:
  provider:
    aws:
      service: SecretsManager
      region: ${AWS_REGION}
      auth:
        jwt:
          serviceAccountRef:
            name: ${ESO_SERVICE_ACCOUNT}
EOF
echo -e "${GREEN}  ✓ SecretStore created/updated${NC}"
echo ""

# Create ClusterSecretStore (optional - for cluster-wide access)
echo -e "${YELLOW}Step 6: Creating ClusterSecretStore (optional)...${NC}"
cat <<EOF | kubectl apply -f -
apiVersion: external-secrets.io/v1beta1
kind: ClusterSecretStore
metadata:
  name: aws-secrets-manager
spec:
  provider:
    aws:
      service: SecretsManager
      region: ${AWS_REGION}
      auth:
        jwt:
          serviceAccountRef:
            name: ${ESO_SERVICE_ACCOUNT}
            namespace: ${ESO_NAMESPACE}
EOF
echo -e "${GREEN}  ✓ ClusterSecretStore created/updated${NC}"
echo ""

# Verify ESO is running
echo -e "${YELLOW}Step 7: Verifying External Secrets Operator is running...${NC}"
if kubectl get deployment -n "${ESO_NAMESPACE}" external-secrets &>/dev/null; then
    echo -e "${GREEN}  ✓ ESO deployment found${NC}"

    # Patch the deployment to use our ServiceAccount
    echo "  Patching ESO deployment to use ${ESO_SERVICE_ACCOUNT}..."
    kubectl patch deployment external-secrets \
        -n "${ESO_NAMESPACE}" \
        --patch "{\"spec\":{\"template\":{\"spec\":{\"serviceAccountName\":\"${ESO_SERVICE_ACCOUNT}\"}}}}"
    echo -e "${GREEN}  ✓ Deployment patched${NC}"
else
    echo -e "${YELLOW}  Warning: ESO deployment not found in ${ESO_NAMESPACE}${NC}"
    echo "  Make sure External Secrets Operator is installed"
fi
echo ""

# Wait for ESO pods to restart
echo -e "${YELLOW}Step 8: Waiting for ESO pods to restart...${NC}"
sleep 5
kubectl wait --for=condition=ready pod \
    -l app.kubernetes.io/name=external-secrets \
    -n "${ESO_NAMESPACE}" \
    --timeout=60s || echo -e "${YELLOW}  Warning: Timeout waiting for pods${NC}"
echo ""

# Verify SecretStore is ready
echo -e "${YELLOW}Step 9: Checking SecretStore status...${NC}"
sleep 5
STORE_STATUS=$(kubectl get secretstore aws-secrets-manager -n "${ESO_NAMESPACE}" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "Unknown")
if [ "${STORE_STATUS}" = "True" ]; then
    echo -e "${GREEN}  ✓ SecretStore is ready${NC}"
else
    echo -e "${YELLOW}  Warning: SecretStore status is ${STORE_STATUS}${NC}"
    echo "  Check: kubectl describe secretstore aws-secrets-manager -n ${ESO_NAMESPACE}"
fi
echo ""

echo -e "${GREEN}==============================================================================${NC}"
echo -e "${GREEN}✓ Kubernetes Resources Setup Complete${NC}"
echo -e "${GREEN}==============================================================================${NC}"
echo ""
echo -e "${BLUE}Resources Created:${NC}"
echo "  ✓ Namespace: ${ESO_NAMESPACE}"
echo "  ✓ ServiceAccount: ${ESO_SERVICE_ACCOUNT} (with Pod Identity)"
echo "  ✓ SecretStore: aws-secrets-manager (namespace-scoped)"
echo "  ✓ ClusterSecretStore: aws-secrets-manager (cluster-wide)"
echo ""
echo -e "${BLUE}Next Steps:${NC}"
echo ""
echo "1. Verify SecretStore is ready:"
echo "   ${GREEN}kubectl get secretstore -n ${ESO_NAMESPACE}${NC}"
echo "   ${GREEN}kubectl describe secretstore aws-secrets-manager -n ${ESO_NAMESPACE}${NC}"
echo ""
echo "2. Create ExternalSecret to sync from AWS Secrets Manager:"
echo "   ${GREEN}./scripts/create-external-secret-example.sh ${CLUSTER_NAME}${NC}"
echo ""
echo "3. List available secrets in AWS Secrets Manager:"
echo "   ${GREEN}aws secretsmanager list-secrets --query 'SecretList[?starts_with(Name, \\\`${CLUSTER_NAME}/\\\`)].Name'${NC}"
echo ""
