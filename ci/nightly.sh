#!/bin/bash
set -euo pipefail

export AWS_PAGER=""

# Credentials mounted at /var/run/rosa-credentials/ via ci-operator credentials mount

CREDS_DIR="/var/run/rosa-credentials"

## ===============================
## Setup AWS Account 0 (regional)

REGIONAL_CREDS=$(mktemp)
cat > "${REGIONAL_CREDS}" <<EOF
[default]
aws_access_key_id = $(cat "${CREDS_DIR}/regional_access_key")
aws_secret_access_key = $(cat "${CREDS_DIR}/regional_secret_key")
EOF

export AWS_SHARED_CREDENTIALS_FILE="${REGIONAL_CREDS}"
aws sts get-caller-identity

REGIONAL_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
echo "Using REGIONAL_ACCOUNT_ID: ${REGIONAL_ACCOUNT_ID}"

## ===============================
## Setup AWS Account 1 (management)

MGMT_CREDS=$(mktemp)
cat > "${MGMT_CREDS}" <<EOF
[default]
aws_access_key_id = $(cat "${CREDS_DIR}/management_access_key")
aws_secret_access_key = $(cat "${CREDS_DIR}/management_secret_key")
EOF

export AWS_SHARED_CREDENTIALS_FILE="${MGMT_CREDS}"
aws sts get-caller-identity

MANAGEMENT_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
echo "Using MANAGEMENT_ACCOUNT_ID: ${MANAGEMENT_ACCOUNT_ID}"

## ===============================
## Run any e2e tests

echo "==== Regional E2E Tests ===="
export AWS_SHARED_CREDENTIALS_FILE="${REGIONAL_CREDS}"
aws sts get-caller-identity
REGIONAL_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
echo "Using REGIONAL_ACCOUNT_ID: ${REGIONAL_ACCOUNT_ID}"

# passing these bits in, but AWS_SHARED_CREDENTIALS_FILE is what is being used
RC_ACCOUNT_ID=$REGIONAL_ACCOUNT_ID RC_CREDS_FILE=$REGIONAL_CREDS ./ci/e2e-rc-test.sh

# ./e2e-platform-api-test.sh
sleep 60

## ===============================
## Tear down the regional cluster
RC_ACCOUNT_ID=$REGIONAL_ACCOUNT_ID MC_ACCOUNT_ID=$MANAGEMENT_ACCOUNT_ID RC_CREDS_FILE=$REGIONAL_CREDS MC_CREDS_FILE=$MGMT_CREDS ./ci/e2e-rc-test.sh --destroy-regional
