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
# Usage:
#   ./ci/ephemeral-resources-janitor.sh                    # purge all accounts
#   ./ci/ephemeral-resources-janitor.sh customer            # purge customer only
#   ./ci/ephemeral-resources-janitor.sh regional customer   # purge regional + customer
#
# Valid accounts: regional, management, central, customer
#
# Selected account purges run in parallel to reduce wall-clock time.
# Per-account logs are written to ARTIFACT_DIR for the Prow artifacts UI.
# =============================================================================

DRY_RUN=false

ALL_ACCOUNTS=(regional management central customer)
ACCOUNTS=("${@:-}")
if [ ${#ACCOUNTS[@]} -eq 0 ] || [ -z "${ACCOUNTS[0]}" ]; then
  ACCOUNTS=("${ALL_ACCOUNTS[@]}")
fi

# Validate requested accounts.
for acct in "${ACCOUNTS[@]}"; do
  valid=false
  for known in "${ALL_ACCOUNTS[@]}"; do
    if [ "${acct}" = "${known}" ]; then
      valid=true
      break
    fi
  done
  if [ "${valid}" = false ]; then
    echo "ERROR: unknown account '${acct}'. Valid accounts: ${ALL_ACCOUNTS[*]}" >&2
    exit 1
  fi
done

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

# purge_customer runs aws-nuke against the HCP customer ephemeral account.
purge_customer() {
  AWS_ACCESS_KEY_ID="$(cat "${CREDS_DIR}/customer_access_key")" \
  AWS_SECRET_ACCESS_KEY="$(cat "${CREDS_DIR}/customer_secret_key")" \
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

# Launch selected purges in parallel, logging output to artifact files.
echo "Starting parallel account purges: ${ACCOUNTS[*]} (logs in ${LOG_DIR}/)"

for label in "${ACCOUNTS[@]}"; do
  "purge_${label}" &> "${LOG_DIR}/${label}.log" &
  PIDS["${label}"]=$!
done

# Wait for all background jobs and report results.
for label in "${ACCOUNTS[@]}"; do
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
