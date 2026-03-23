#!/bin/bash
set -euo pipefail

# =============================================================================
# Ephemeral resource janitor — purge leaked AWS resources from ephemeral CI accounts.
# =============================================================================
# Fallback cleanup for when terraform destroy does not fully tear down
# resources after ephemeral tests.
#
# Credentials are mounted at /var/run/rosa-credentials/ by ci-operator.
#
# All three account purges run in parallel to reduce wall-clock time.
# Per-account logs are written to ARTIFACT_DIR for the Prow artifacts UI.
# =============================================================================

DRY_RUN=false

export AWS_PAGER=""

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CREDS_DIR="/var/run/rosa-credentials"
PURGE_SCRIPT="${SCRIPT_DIR}/janitor/purge-aws-account.sh"

LOG_DIR="${ARTIFACT_DIR:-/tmp}/janitor-logs"
mkdir -p "${LOG_DIR}"

PURGE_ARGS=()
if [ "${DRY_RUN}" = false ]; then
  PURGE_ARGS+=(--no-dry-run)
fi

# Track background PIDs and their labels for final status reporting.
declare -A PIDS=()
FAILED=0

# purge_regional runs aws-nuke against the regional ephemeral account.
purge_regional() {
  AWS_ACCESS_KEY_ID="$(cat "${CREDS_DIR}/regional_access_key")" \
  AWS_SECRET_ACCESS_KEY="$(cat "${CREDS_DIR}/regional_secret_key")" \
    "${PURGE_SCRIPT}" "${PURGE_ARGS[@]+"${PURGE_ARGS[@]}"}"
}

# purge_management runs aws-nuke against the management ephemeral account.
purge_management() {
  AWS_ACCESS_KEY_ID="$(cat "${CREDS_DIR}/management_access_key")" \
  AWS_SECRET_ACCESS_KEY="$(cat "${CREDS_DIR}/management_secret_key")" \
    "${PURGE_SCRIPT}" "${PURGE_ARGS[@]+"${PURGE_ARGS[@]}"}"
}

# purge_central assumes the central CI role and runs aws-nuke.
purge_central() {
  local key secret token
  read -r key secret token <<< "$(
    AWS_ACCESS_KEY_ID="$(cat "${CREDS_DIR}/central_access_key")" \
    AWS_SECRET_ACCESS_KEY="$(cat "${CREDS_DIR}/central_secret_key")" \
    aws sts assume-role \
      --role-arn "$(cat "${CREDS_DIR}/central_assume_role_arn")" \
      --role-session-name "JanitorCentralPurge" \
      --query 'Credentials.[AccessKeyId,SecretAccessKey,SessionToken]' \
      --output text)"

  AWS_ACCESS_KEY_ID="${key}" \
  AWS_SECRET_ACCESS_KEY="${secret}" \
  AWS_SESSION_TOKEN="${token}" \
    "${PURGE_SCRIPT}" "${PURGE_ARGS[@]+"${PURGE_ARGS[@]}"}"
}

# Launch all three purges in parallel, logging output to artifact files.
echo "Starting parallel account purges (logs in ${LOG_DIR}/)"

purge_regional  &> "${LOG_DIR}/regional.log" &
PIDS["regional"]=$!

purge_management &> "${LOG_DIR}/management.log" &
PIDS["management"]=$!

purge_central &> "${LOG_DIR}/central.log" &
PIDS["central"]=$!

# Wait for all background jobs and report results.
for label in regional management central; do
  if wait "${PIDS[${label}]}"; then
    echo ">> ${label} account purge succeeded"
  else
    mv "${LOG_DIR}/${label}.log" "${LOG_DIR}/${label}.FAILED.log"
    echo ">> ${label} account purge FAILED (see ${LOG_DIR}/${label}.FAILED.log)" >&2
    FAILED=1
  fi
done

echo ""
echo "==== Janitor complete ===="

exit "${FAILED}"
