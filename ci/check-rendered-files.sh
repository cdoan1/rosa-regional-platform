#!/bin/bash
# CI entrypoint for rendered files check.

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
make check-rendered-files
