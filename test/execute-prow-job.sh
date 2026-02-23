#!/bin/bash

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

# "${PROW_JOB_EXECUTOR}" execute --job-name "$PROW_JOB_NAME" --region "$REGION" --dry-run="${DRY_RUN:-false}" --gate-promotion="${GATE_PROMOTION:-false}"

echo "hello prow"

