#!/bin/bash
# =============================================================================
# Generate Maestro Server Kubernetes Secret YAML from Terraform Outputs
# =============================================================================
# This script reads Terraform outputs from the regional cluster and generates
# Kubernetes secret YAML containing AWS resource references for Maestro Server.
#
# Usage (recommended - copy to clipboard):
#   ./scripts/create-maestro-server-secret.sh | pbcopy
#   # Then in bastion SSH: kubectl apply -f -
#   # Paste (Cmd+V) and press Ctrl+D
#
# Usage (save to file):
#   ./scripts/create-maestro-server-secret.sh > maestro-server-config.yaml
#
# Arguments:
#   namespace   - Kubernetes namespace for the secret (default: maestro)
#
# Prerequisites:
#   - Terraform has been applied in terraform/config/regional-cluster/

set -e

# Detect if stderr is a TTY and enable colors accordingly
if [ -t 2 ]; then
  # Colors for output (stderr is a TTY)
  RED='\033[0;31m'
  GREEN='\033[0;32m'
  YELLOW='\033[1;33m'
  BLUE='\033[0;34m'
  NC='\033[0m' # No Color
else
  # No colors (stderr is not a TTY)
  RED=''
  GREEN=''
  YELLOW=''
  BLUE=''
  NC=''
fi

# Configuration
SECRET_NAMESPACE="${1:-maestro}"
SECRET_NAME="maestro-server-config"
TERRAFORM_DIR="terraform/config/regional-cluster"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

printf "${GREEN}==============================================================================${NC}\n" >&2
printf "${GREEN}Maestro Server Kubernetes Secret YAML Generator${NC}\n" >&2
printf "${GREEN}==============================================================================${NC}\n" >&2
printf "\n" >&2

# Change to repository root
cd "${REPO_ROOT}"

# Check if Terraform directory exists
if [ ! -d "${TERRAFORM_DIR}" ]; then
    printf "${RED}Error: Terraform directory not found: ${TERRAFORM_DIR}${NC}\n" >&2
    exit 1
fi

printf "${YELLOW}Step 1: Validating Terraform state...${NC}\n" >&2

# Check if Terraform state exists
if [ ! -f "${TERRAFORM_DIR}/terraform.tfstate" ]; then
    printf "${RED}Error: No Terraform state found in ${TERRAFORM_DIR}${NC}\n" >&2
    printf "Have you run 'terraform apply'?\n" >&2
    exit 1
fi

printf "${GREEN}  ✓ Terraform state found${NC}\n" >&2
printf "\n" >&2

printf "${YELLOW}Step 2: Extracting Terraform outputs...${NC}\n" >&2

cd "${TERRAFORM_DIR}"

# Extract Terraform outputs
MQTT_SECRET_NAME=$(terraform output -raw maestro_server_mqtt_cert_secret_name 2>/dev/null || echo "")
DB_SECRET_NAME=$(terraform output -raw maestro_db_credentials_secret_name 2>/dev/null || echo "")
IOT_ENDPOINT=$(terraform output -raw maestro_iot_mqtt_endpoint 2>/dev/null || echo "")
CLUSTER_NAME=$(terraform output -raw cluster_name 2>/dev/null || echo "unknown")

# Validate outputs
if [ -z "${MQTT_SECRET_NAME}" ] || [ -z "${DB_SECRET_NAME}" ] || [ -z "${IOT_ENDPOINT}" ]; then
    printf "${RED}Error: Failed to retrieve required Terraform outputs${NC}\n" >&2
    printf "Make sure Terraform has been successfully applied with the maestro_infrastructure module.\n" >&2
    printf "\n" >&2
    printf "Required outputs:\n" >&2
    printf "  - maestro_server_mqtt_cert_secret_name: ${MQTT_SECRET_NAME:-<missing>}\n" >&2
    printf "  - maestro_db_credentials_secret_name: ${DB_SECRET_NAME:-<missing>}\n" >&2
    printf "  - maestro_iot_mqtt_endpoint: ${IOT_ENDPOINT:-<missing>}\n" >&2
    exit 1
fi

printf "  - MQTT Secret Name: ${MQTT_SECRET_NAME}\n" >&2
printf "  - DB Secret Name: ${DB_SECRET_NAME}\n" >&2
printf "  - IoT Endpoint: ${IOT_ENDPOINT}\n" >&2
printf "  - Cluster Name: ${CLUSTER_NAME}\n" >&2
printf "${GREEN}  ✓ Terraform outputs extracted successfully${NC}\n" >&2
printf "\n" >&2

cd "${REPO_ROOT}"

printf "${YELLOW}Step 3: Generating Kubernetes secret YAML...${NC}\n" >&2

# Base64 encode the values
MQTT_SECRET_NAME_B64=$(echo -n "${MQTT_SECRET_NAME}" | base64)
DB_SECRET_NAME_B64=$(echo -n "${DB_SECRET_NAME}" | base64)
IOT_ENDPOINT_B64=$(echo -n "${IOT_ENDPOINT}" | base64)
CLUSTER_NAME_B64=$(echo -n "${CLUSTER_NAME}" | base64)

printf "${GREEN}  ✓ Values base64 encoded${NC}\n" >&2
printf "\n" >&2

printf "${YELLOW}Step 4: Outputting secret YAML...${NC}\n" >&2
printf "\n" >&2

# Generate the Secret YAML
cat << EOF
apiVersion: v1
kind: Secret
metadata:
  name: ${SECRET_NAME}
  namespace: ${SECRET_NAMESPACE}
  labels:
    app: maestro
    component: maestro-server
    managed-by: terraform
type: Opaque
data:
  # AWS Secrets Manager secret names (for ASCP CSI driver)
  mqttCertSecretName: ${MQTT_SECRET_NAME_B64}
  dbCredentialsSecretName: ${DB_SECRET_NAME_B64}

  # AWS IoT Core MQTT endpoint
  mqttEndpoint: ${IOT_ENDPOINT_B64}

  # Cluster identifier (for reference)
  clusterName: ${CLUSTER_NAME_B64}
EOF

printf "\n" >&2
printf "${GREEN}  ✓ Secret YAML generated${NC}\n" >&2
printf "\n" >&2

printf "${YELLOW}Step 5: Apply the secret...${NC}\n" >&2
printf "\n" >&2
printf "  ${BLUE}Method 1: Copy to clipboard and paste in bastion SSH session (recommended)${NC}\n" >&2
printf "  ${GREEN}./scripts/create-maestro-server-secret.sh | pbcopy${NC}\n" >&2
printf "  ${GREEN}# Then in your bastion SSH session:${NC}\n" >&2
printf "  ${GREEN}kubectl apply -f -${NC}\n" >&2
printf "  ${GREEN}# Paste the YAML (Cmd+V) and press Ctrl+D${NC}\n" >&2
printf "\n" >&2
printf "  ${BLUE}Method 2: Save to file and transfer${NC}\n" >&2
printf "  ${GREEN}./scripts/create-maestro-server-secret.sh > maestro-server-config.yaml${NC}\n" >&2
printf "  ${GREEN}scp maestro-server-config.yaml bastion:~/${NC}\n" >&2
printf "  ${GREEN}ssh bastion 'kubectl apply -f maestro-server-config.yaml'${NC}\n" >&2
printf "\n" >&2
printf "  ${BLUE}Verify the secret was created:${NC}\n" >&2
printf "  ${GREEN}kubectl get secret ${SECRET_NAME} -n ${SECRET_NAMESPACE}${NC}\n" >&2
printf "\n" >&2
printf "  ${BLUE}The secret can be referenced in Helm charts using lookup:${NC}\n" >&2
printf "  ${GREEN}{{- \$secret := lookup \"v1\" \"Secret\" \"${SECRET_NAMESPACE}\" \"${SECRET_NAME}\" }}${NC}\n" >&2
printf "  ${GREEN}{{- \$endpoint := index \$secret.data \"mqttEndpoint\" | b64dec }}${NC}\n" >&2
printf "\n" >&2
printf "${GREEN}==============================================================================${NC}\n" >&2
printf "${GREEN}✓ Done! Secret YAML generated for ${SECRET_NAMESPACE}/${SECRET_NAME}${NC}\n" >&2
printf "${GREEN}==============================================================================${NC}\n" >&2
