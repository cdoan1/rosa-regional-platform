#!/bin/bash
# Run e2e API tests from rosa-regional-platform-api against the provisioned environment.
# Expects SHARED_DIR/api-url to exist (written by nightly.sh during provisioning).

set -euo pipefail

export BASE_URL="$(cat "${SHARED_DIR}/api-url")"
echo "Running API e2e tests against ${BASE_URL}"

git clone https://github.com/openshift-online/rosa-regional-platform-api.git /tmp/api
cd /tmp/api

go install github.com/onsi/ginkgo/v2/ginkgo@v2.28.1
export PATH="${GOPATH}/bin:${PATH}"

make test-e2e
