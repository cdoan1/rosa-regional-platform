#!/bin/bash
# CI entrypoint for Helm chart linting.

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
make helm-lint
