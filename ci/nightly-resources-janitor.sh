#!/bin/bash
set -euo pipefail

# =============================================================================
# Nightly resource janitor — purge leaked AWS resources from both CI accounts.
# =============================================================================
# Fallback cleanup for when terraform destroy does not fully tear down
# resources after nightly e2e tests. Runs weekly via Prow cron (Sundays 12:00
# UTC) and uses aws-nuke to remove everything except the CI identity.
#
# Credentials are mounted at /var/run/rosa-credentials/ by ci-operator.
# =============================================================================

# TODO(Claudio): Set to false once we're confident
DRY_RUN=true

export AWS_PAGER=""

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CREDS_DIR="/var/run/rosa-credentials"
PURGE_SCRIPT="${SCRIPT_DIR}/janitor/purge-aws-account.sh"

PURGE_ARGS=()
if [ "${DRY_RUN}" = false ]; then
  PURGE_ARGS+=(--no-dry-run)
fi

## ===============================
## Purge regional account
## ===============================
echo "==== Purging Regional Account ===="

REGIONAL_CREDS=$(mktemp)
cat > "${REGIONAL_CREDS}" <<EOF
[default]
aws_access_key_id = $(cat "${CREDS_DIR}/regional_access_key")
aws_secret_access_key = $(cat "${CREDS_DIR}/regional_secret_key")
EOF

export AWS_SHARED_CREDENTIALS_FILE="${REGIONAL_CREDS}"
"${PURGE_SCRIPT}" "${PURGE_ARGS[@]+"${PURGE_ARGS[@]}"}"

## ===============================
## Purge management account
## ===============================
echo ""
echo "==== Purging Management Account ===="

MGMT_CREDS=$(mktemp)
cat > "${MGMT_CREDS}" <<EOF
[default]
aws_access_key_id = $(cat "${CREDS_DIR}/management_access_key")
aws_secret_access_key = $(cat "${CREDS_DIR}/management_secret_key")
EOF

export AWS_SHARED_CREDENTIALS_FILE="${MGMT_CREDS}"
"${PURGE_SCRIPT}" "${PURGE_ARGS[@]+"${PURGE_ARGS[@]}"}"

echo ""
echo "==== Janitor complete ===="
