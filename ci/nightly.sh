#!/bin/bash
set -euo pipefail

export AWS_PAGER=""

# Credentials mounted at /var/run/rosa-credentials/ via ci-operator credentials mount

CREDS_DIR="/var/run/rosa-credentials"

# Function to setup AWS credentials and get account ID
switch_aws_account() {
  local creds_file="$1"
  local account_type="$2"
  
  export AWS_SHARED_CREDENTIALS_FILE="${creds_file}"
  aws sts get-caller-identity
  
  local account_id=$(aws sts get-caller-identity --query Account --output text)
  echo "Using ${account_type}_ACCOUNT_ID: ${account_id}"
  
  echo "${account_id}"
}

## ===============================
## Setup AWS Account 0 (regional)

REGIONAL_CREDS=$(mktemp)
cat > "${REGIONAL_CREDS}" <<EOF
[default]
aws_access_key_id = $(cat "${CREDS_DIR}/regional_access_key")
aws_secret_access_key = $(cat "${CREDS_DIR}/regional_secret_key")
EOF

REGIONAL_ACCOUNT_ID=$(switch_aws_account "${REGIONAL_CREDS}" "REGIONAL")

## ===============================
## Setup AWS Account 1 (management)

MGMT_CREDS=$(mktemp)
cat > "${MGMT_CREDS}" <<EOF
[default]
aws_access_key_id = $(cat "${CREDS_DIR}/management_access_key")
aws_secret_access_key = $(cat "${CREDS_DIR}/management_secret_key")
EOF

MANAGEMENT_ACCOUNT_ID=$(switch_aws_account "${MGMT_CREDS}" "MANAGEMENT")

## ===============================
## Run any e2e tests

echo "==== Regional E2E Tests ===="
export AWS_SHARED_CREDENTIALS_FILE="${REGIONAL_CREDS}"
aws sts get-caller-identity
REGIONAL_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
echo "Using REGIONAL_ACCOUNT_ID: ${REGIONAL_ACCOUNT_ID}"

RC_ACCOUNT_ID=$REGIONAL_ACCOUNT_ID RC_CREDS_FILE=$REGIONAL_CREDS ./ci/e2e-rc-test.sh

sleep 60

./ci/e2e-platform-api-test.sh

RC_ACCOUNT_ID=$REGIONAL_ACCOUNT_ID RC_CREDS_FILE=$REGIONAL_CREDS ./ci/e2e-rc-test.sh --destroy-regional
