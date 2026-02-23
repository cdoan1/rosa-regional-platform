#!/bin/bash

set -o errexit
set -o nounset
set -o pipefail

function waitBeforeExit() {
  local exit_code=$?
  echo "Waiting before exiting to ensure that logs are captured."
  sleep 10
  exit "$exit_code"
}

trap waitBeforeExit EXIT

## I'm not sure why this is here. But I don't want to remove it
## until I'm sure that we don't need it.
# if [ -z "${PROW_JOB_NAME:-}" ]; then
#   echo "PROW_JOB_NAME is not set. Exiting."
#   exit 254
# fi

echo "common.sh loaded"
