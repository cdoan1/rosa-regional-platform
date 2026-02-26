#!/bin/bash
set -euo pipefail

export AWS_PAGER=""

# Credentials mounted at /var/run/rosa-credentials/ via ci-operator credentials mount

CREDS_DIR="/var/run/rosa-credentials"

## ===============================
## Parse arguments
## ===============================

TEARDOWN=false
for arg in "$@"; do
  case "$arg" in
    --teardown) TEARDOWN=true ;;
    *)
      echo "Unknown argument: $arg" >&2
      echo "Usage: $0 [--teardown]" >&2
      exit 1
      ;;
  esac
done

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
## Teardown mode
## ===============================

if [ "${TEARDOWN}" = true ]; then
  echo "==== Teardown ===="
  export AWS_SHARED_CREDENTIALS_FILE="${REGIONAL_CREDS}"

  # Destroy regional cluster via terraform
  RC_ACCOUNT_ID=$REGIONAL_ACCOUNT_ID ./ci/e2e-rc-test.sh --destroy-regional

  # TODO: Add management cluster teardown when MC tests are added

  echo "==== Teardown complete ===="
  exit 0
fi

## ===============================
## Run any e2e tests

echo "TODO: Implement me - run e2e tests"

echo "==== Regional E2E Tests ===="
export AWS_SHARED_CREDENTIALS_FILE="${REGIONAL_CREDS}"
aws sts get-caller-identity
REGIONAL_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
echo "Using REGIONAL_ACCOUNT_ID: ${REGIONAL_ACCOUNT_ID}"

# provision the regional cluster
RC_ACCOUNT_ID=$REGIONAL_ACCOUNT_ID ./ci/e2e-rc-test.sh

sleep 60

# trigger simple rc api test, no mc just yet
./ci/e2e-platform-api-test.sh

# tear down the regional cluster
RC_ACCOUNT_ID=$REGIONAL_ACCOUNT_ID ./ci/e2e-rc-test.sh --destroy-regional
