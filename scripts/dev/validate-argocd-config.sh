#!/bin/bash
# Quick validation for ArgoCD rendered config before provisioning
set -euo pipefail

CLUSTER_TYPE="${1:-}"

# Set defaults from environment variables
ENVIRONMENT="${ENVIRONMENT:-integration}"
REGION_ALIAS="${REGION_ALIAS:-}"

if [[ -z "$CLUSTER_TYPE" || -z "$REGION_ALIAS" ]]; then
    echo "Usage: ENVIRONMENT=<env> REGION_ALIAS=<region-alias> $0 <cluster-type>"
    echo ""
    echo "Arguments:"
    echo "  cluster-type: management-cluster or regional-cluster"
    echo ""
    echo "Required environment variables:"
    echo "  REGION_ALIAS: The region alias from config.yaml (e.g., us-east-1, us-east-1-fedramp)"
    echo ""
    echo "Optional environment variables:"
    echo "  ENVIRONMENT (default: integration)"
    exit 1
fi

REQUIRED_FILES=(
    "deploy/${ENVIRONMENT}/${REGION_ALIAS}/argocd/${CLUSTER_TYPE}-values.yaml"
    "deploy/${ENVIRONMENT}/${REGION_ALIAS}/argocd/${CLUSTER_TYPE}-manifests/applicationset.yaml"
)

missing_files=()
for file in "${REQUIRED_FILES[@]}"; do
    if [[ ! -f "$file" ]]; then
        missing_files+=("$file")
    fi
done

if [[ ${#missing_files[@]} -gt 0 ]]; then
    echo "ERROR: Missing rendered ArgoCD config for ${ENVIRONMENT}/${REGION_ALIAS}"
    echo ""
    echo "Missing: ${missing_files[*]}"
    echo ""
    echo "Fix: 1) Add ${ENVIRONMENT}/${REGION_ALIAS} to config.yaml"
    echo "     2) Run ./scripts/render.py"
    echo "     3) Commit and push to your target branch"
    exit 1
fi

echo "ArgoCD config exists for ${ENVIRONMENT}/${REGION_ALIAS}"
