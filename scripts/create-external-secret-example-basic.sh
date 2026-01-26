#!/bin/bash
# =============================================================================
# Create Example ExternalSecret Resources (Bastion Script)
# =============================================================================
# This script creates Kubernetes resources for ESO to sync secrets from
# AWS Secrets Manager. Run this from the bastion host with kubectl access.
#
# Usage:
#   ./scripts/create-external-secret-example-basic.sh [cluster-name] [namespace]
#
# Example:
#   ./scripts/create-external-secret-example-basic.sh regional-1nij maestro
#
# Prerequisites (run these FIRST with AWS credentials):
#   1. ./scripts/setup-eso-iam.sh regional-1nij external-secrets
#      - Creates IAM role and policy
#      - Creates Pod Identity associations for external-secrets AND maestro namespaces
#   2. Secrets must exist in AWS Secrets Manager:
#      - {cluster-name}/maestro/db-credentials
#      - {cluster-name}/maestro/server-mqtt-cert
#
# This script only requires kubectl access (no AWS credentials needed)

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
CLUSTER_NAME="${1:-}"
TARGET_NAMESPACE="${2:-maestro}"
ESO_NAMESPACE="external-secrets"

echo -e "${GREEN}==============================================================================${NC}"
echo -e "${GREEN}Create ExternalSecret Examples${NC}"
echo -e "${GREEN}==============================================================================${NC}"
echo ""

# Validate inputs
if [ -z "${CLUSTER_NAME}" ]; then
    echo -e "${RED}Error: Cluster name is required${NC}"
    echo "Usage: $0 <cluster-name> [namespace]"
    echo "Example: $0 regional-1nij maestro"
    exit 1
fi

echo -e "${BLUE}Configuration:${NC}"
echo "  Cluster Name: ${CLUSTER_NAME}"
echo "  Target Namespace: ${TARGET_NAMESPACE}"
echo ""

# Get AWS region and role ARN
AWS_REGION=$(aws configure get region || echo "us-east-2")
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
ROLE_NAME="${CLUSTER_NAME}-eso-secrets-manager"
ROLE_ARN="arn:aws:iam::${AWS_ACCOUNT_ID}:role/${ROLE_NAME}"

echo "  AWS Region: ${AWS_REGION}"
echo "  IAM Role ARN: ${ROLE_ARN}"
echo ""

# Ensure target namespace exists
echo -e "${YELLOW}Step 1: Ensuring target namespace exists...${NC}"
if ! kubectl get namespace "${TARGET_NAMESPACE}" &>/dev/null; then
    echo "  Creating namespace ${TARGET_NAMESPACE}..."
    kubectl create namespace "${TARGET_NAMESPACE}"
    echo -e "${GREEN}  ✓ Namespace created${NC}"
else
    echo -e "${GREEN}  ✓ Namespace already exists${NC}"
fi
echo ""

# Create ServiceAccount in target namespace with Pod Identity
echo -e "${YELLOW}Step 2: Creating ServiceAccount in ${TARGET_NAMESPACE} namespace...${NC}"
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ServiceAccount
metadata:
  name: external-secrets-sa
  namespace: ${TARGET_NAMESPACE}
  annotations:
    eks.amazonaws.com/role-arn: ${ROLE_ARN}
  labels:
    app.kubernetes.io/name: external-secrets
    app.kubernetes.io/component: service-account
EOF
echo -e "${GREEN}  ✓ ServiceAccount created/updated${NC}"
echo ""

# Create SecretStore in target namespace
echo -e "${YELLOW}Step 3: Creating SecretStore in ${TARGET_NAMESPACE} namespace...${NC}"
cat <<EOF | kubectl apply -f -
apiVersion: external-secrets.io/v1
kind: SecretStore
metadata:
  name: aws-secrets-manager
  namespace: ${TARGET_NAMESPACE}
spec:
  provider:
    aws:
      service: SecretsManager
      region: ${AWS_REGION}
      auth:
        jwt:
          serviceAccountRef:
            name: external-secrets-sa
EOF
echo -e "${GREEN}  ✓ SecretStore created/updated${NC}"
echo ""

# Wait for SecretStore to be ready
echo -e "${YELLOW}Step 4: Waiting for SecretStore to be ready...${NC}"
sleep 5
STORE_STATUS=$(kubectl get secretstore aws-secrets-manager -n "${TARGET_NAMESPACE}" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "Unknown")
if [ "${STORE_STATUS}" = "True" ]; then
    echo -e "${GREEN}  ✓ SecretStore is ready${NC}"
else
    echo -e "${YELLOW}  Warning: SecretStore status is ${STORE_STATUS}${NC}"
    echo "  Check: kubectl describe secretstore aws-secrets-manager -n ${TARGET_NAMESPACE}"
fi
echo ""

# Create ExternalSecret for Maestro database credentials
echo -e "${YELLOW}Step 5: Creating ExternalSecret for Maestro DB credentials...${NC}"
cat <<EOF | kubectl apply -f -
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: maestro-db-credentials
  namespace: ${TARGET_NAMESPACE}
  labels:
    app: maestro
    component: database
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: aws-secrets-manager
    kind: SecretStore
  target:
    name: maestro-db-credentials
    creationPolicy: Owner
    template:
      engineVersion: v2
      data:
        # Individual keys from the AWS secret
        db.user: "{{ .username }}"
        db.password: "{{ .password }}"
        db.host: "{{ .host }}"
        db.port: "{{ .port }}"
        db.name: "{{ .database }}"
        # Connection string (optional)
        connection-string: "postgresql://{{ .username }}:{{ .password }}@{{ .host }}:{{ .port }}/{{ .database }}?sslmode=require"
  data:
  - secretKey: username
    remoteRef:
      key: ${CLUSTER_NAME}/maestro/db-credentials
      property: username
  - secretKey: password
    remoteRef:
      key: ${CLUSTER_NAME}/maestro/db-credentials
      property: password
  - secretKey: host
    remoteRef:
      key: ${CLUSTER_NAME}/maestro/db-credentials
      property: host
  - secretKey: port
    remoteRef:
      key: ${CLUSTER_NAME}/maestro/db-credentials
      property: port
  - secretKey: database
    remoteRef:
      key: ${CLUSTER_NAME}/maestro/db-credentials
      property: database
EOF
echo -e "${GREEN}  ✓ ExternalSecret created${NC}"
echo ""

# Create ExternalSecret for Maestro MQTT certificates
echo -e "${YELLOW}Step 6: Creating ExternalSecret for Maestro MQTT certificates...${NC}"
cat <<EOF | kubectl apply -f -
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: maestro-server-mqtt-cert
  namespace: ${TARGET_NAMESPACE}
  labels:
    app: maestro
    component: mqtt
spec:
  refreshInterval: 24h
  secretStoreRef:
    name: aws-secrets-manager
    kind: SecretStore
  target:
    name: maestro-server-mqtt-cert
    creationPolicy: Owner
    template:
      engineVersion: v2
      data:
        certificate: "{{ .certificate }}"
        privateKey: "{{ .privateKey }}"
        ca.crt: "{{ .caCert }}"
  data:
  - secretKey: certificate
    remoteRef:
      key: ${CLUSTER_NAME}/maestro/server-mqtt-cert
      property: certificate
  - secretKey: privateKey
    remoteRef:
      key: ${CLUSTER_NAME}/maestro/server-mqtt-cert
      property: privateKey
  - secretKey: caCert
    remoteRef:
      key: ${CLUSTER_NAME}/maestro/server-mqtt-cert
      property: caCert
EOF
echo -e "${GREEN}  ✓ ExternalSecret created${NC}"
echo ""

# Wait for secrets to be created
echo -e "${YELLOW}Step 7: Waiting for secrets to be synced...${NC}"
echo "  Waiting for maestro-db-credentials..."
kubectl wait --for=condition=ready externalsecret/maestro-db-credentials \
    -n "${TARGET_NAMESPACE}" \
    --timeout=60s || echo -e "${YELLOW}  Warning: Timeout waiting for db credentials${NC}"

echo "  Waiting for maestro-server-mqtt-cert..."
kubectl wait --for=condition=ready externalsecret/maestro-server-mqtt-cert \
    -n "${TARGET_NAMESPACE}" \
    --timeout=60s || echo -e "${YELLOW}  Warning: Timeout waiting for mqtt cert${NC}"
echo ""

# Verify secrets were created
echo -e "${YELLOW}Step 8: Verifying Kubernetes secrets were created...${NC}"
if kubectl get secret maestro-db-credentials -n "${TARGET_NAMESPACE}" &>/dev/null; then
    echo -e "${GREEN}  ✓ maestro-db-credentials secret exists${NC}"
    echo "    Keys: $(kubectl get secret maestro-db-credentials -n ${TARGET_NAMESPACE} -o jsonpath='{.data}' | jq -r 'keys[]' | tr '\n' ' ')"
else
    echo -e "${RED}  ✗ maestro-db-credentials secret not found${NC}"
fi

if kubectl get secret maestro-server-mqtt-cert -n "${TARGET_NAMESPACE}" &>/dev/null; then
    echo -e "${GREEN}  ✓ maestro-server-mqtt-cert secret exists${NC}"
    echo "    Keys: $(kubectl get secret maestro-server-mqtt-cert -n ${TARGET_NAMESPACE} -o jsonpath='{.data}' | jq -r 'keys[]' | tr '\n' ' ')"
else
    echo -e "${RED}  ✗ maestro-server-mqtt-cert secret not found${NC}"
fi
echo ""

# Show ExternalSecret status
echo -e "${YELLOW}Step 9: Checking ExternalSecret status...${NC}"
kubectl get externalsecret -n "${TARGET_NAMESPACE}"
echo ""

echo -e "${GREEN}==============================================================================${NC}"
echo -e "${GREEN}✓ ExternalSecret Examples Created${NC}"
echo -e "${GREEN}==============================================================================${NC}"
echo ""
echo -e "${BLUE}What was created (in this script):${NC}"
echo "  ✓ ServiceAccount: external-secrets-sa (in ${TARGET_NAMESPACE} namespace, with Pod Identity)"
echo "  ✓ SecretStore: aws-secrets-manager (namespace-scoped in ${TARGET_NAMESPACE})"
echo "  ✓ ExternalSecret: maestro-db-credentials"
echo "  ✓ ExternalSecret: maestro-server-mqtt-cert"
echo "  ✓ Kubernetes Secret: maestro-db-credentials (synced from AWS)"
echo "  ✓ Kubernetes Secret: maestro-server-mqtt-cert (synced from AWS)"
echo ""
echo -e "${BLUE}Prerequisites (created by setup-eso-iam.sh):${NC}"
echo "  • IAM Role: ${ROLE_NAME}"
echo "  • IAM Policy: Secrets Manager access for ${CLUSTER_NAME}/*"
echo "  • Pod Identity Association: ${TARGET_NAMESPACE}/external-secrets-sa → IAM Role"
echo ""
echo -e "${BLUE}Verification Commands:${NC}"
echo ""
echo "1. Check ExternalSecret status:"
echo "   ${GREEN}kubectl get externalsecret -n ${TARGET_NAMESPACE}${NC}"
echo "   ${GREEN}kubectl describe externalsecret maestro-db-credentials -n ${TARGET_NAMESPACE}${NC}"
echo ""
echo "2. Check synced Kubernetes secrets:"
echo "   ${GREEN}kubectl get secrets -n ${TARGET_NAMESPACE} | grep maestro${NC}"
echo ""
echo "3. View secret keys (not values):"
echo "   ${GREEN}kubectl get secret maestro-db-credentials -n ${TARGET_NAMESPACE} -o jsonpath='{.data}' | jq 'keys'${NC}"
echo ""
echo "4. Test reading a secret value:"
echo "   ${GREEN}kubectl get secret maestro-db-credentials -n ${TARGET_NAMESPACE} -o jsonpath='{.data.db\.user}' | base64 -d${NC}"
echo ""
echo -e "${BLUE}How ExternalSecret Works:${NC}"
echo "  1. ESO controller watches ExternalSecret resources"
echo "  2. Uses Pod Identity to authenticate to AWS"
echo "  3. Fetches secrets from AWS Secrets Manager"
echo "  4. Creates/updates Kubernetes secrets with the data"
echo "  5. Automatically refreshes based on refreshInterval (1h for DB, 24h for certs)"
echo ""
echo -e "${BLUE}AWS Secrets Being Synced:${NC}"
echo "  • ${CLUSTER_NAME}/maestro/db-credentials"
echo "  • ${CLUSTER_NAME}/maestro/server-mqtt-cert"
echo ""
