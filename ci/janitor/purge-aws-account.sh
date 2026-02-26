#!/bin/bash
set -euo pipefail

# =============================================================================
# Purge all AWS resources from the current account using aws-nuke.
# =============================================================================
# Uses whatever AWS credentials are active in the environment (env vars,
# ~/.aws/config, instance profile, etc.). The caller is responsible for
# setting up credentials before running this script.
#
# Dry-run by default. Pass --no-dry-run to actually delete resources.
#
# Usage:
#   ./ci/janitor/purge-aws-account.sh              # dry-run (list only)
#   ./ci/janitor/purge-aws-account.sh --no-dry-run  # delete resources
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="${SCRIPT_DIR}/aws-nuke-config.yaml"

# ---------------------------------------------------------------------------
# Parse arguments
# ---------------------------------------------------------------------------
DRY_RUN=true
for arg in "$@"; do
  case "$arg" in
    --no-dry-run) DRY_RUN=false ;;
    -h|--help)
      echo "Usage: $0 [--no-dry-run]"
      echo ""
      echo "Purge all AWS resources from the current account (except CI identity)."
      echo "Dry-run by default; pass --no-dry-run to actually delete."
      exit 0
      ;;
    *)
      echo "Unknown argument: $arg" >&2
      echo "Usage: $0 [--no-dry-run]" >&2
      exit 1
      ;;
  esac
done

# ---------------------------------------------------------------------------
# Preflight checks
# ---------------------------------------------------------------------------
if ! command -v aws-nuke &>/dev/null; then
  echo "ERROR: aws-nuke is not installed. See https://github.com/ekristen/aws-nuke" >&2
  exit 1
fi

if ! command -v aws &>/dev/null; then
  echo "ERROR: aws CLI is not installed." >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Log current identity
# ---------------------------------------------------------------------------
echo "Detecting AWS account from current credentials..."
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
CALLER_ARN=$(aws sts get-caller-identity --query Arn --output text)
echo "Account ID: ${ACCOUNT_ID}"
echo "Caller ARN: ${CALLER_ARN}"

# ---------------------------------------------------------------------------
# Verify account is listed in the aws-nuke config
# ---------------------------------------------------------------------------
# --no-alias-check is global, so we verify the account is explicitly listed
# in the config to prevent accidentally nuking an unintended account.
if ! grep -q "\"${ACCOUNT_ID}\"" "${CONFIG}"; then
  echo "ERROR: Account ${ACCOUNT_ID} is not listed in ${CONFIG}." >&2
  echo "Add it to the accounts section before proceeding." >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Run aws-nuke
# ---------------------------------------------------------------------------
NUKE_ARGS=(
  run
  --config "${CONFIG}"
  --default-region us-east-1
  --no-alias-check
  --no-prompt
)

if [ "${DRY_RUN}" = true ]; then
  echo ""
  echo "=== DRY RUN (no resources will be deleted) ==="
  echo "Pass --no-dry-run to actually delete resources."
  echo ""
  # aws-nuke defaults to dry-run; no flag needed
else
  echo ""
  echo "=== LIVE RUN — resources WILL be deleted ==="
  echo ""
  NUKE_ARGS+=(--no-dry-run)
fi

aws-nuke "${NUKE_ARGS[@]}"
