#!/bin/bash
# This is a simple e2e platform api test script.
# It verifies the IoT Core setup and the platform api endpoints.
# It creates a management cluster and a test manifestwork.
# It then verifies the resource distribution.
# It is meant to be run from the regional account.
# It requires the following tools:
# - aws
# - jq
# - awscurl
# - date
# - cat
# - echo

set -euo pipefail

# Use AWS_REGION from environment or default
REGION="${AWS_REGION:-${REGION:-us-east-1}}"
API_URL="${1}"
MANAGEMENT_CLUSTER="${2:-mc01}"

# Logger functions
log_error() {
  echo "❌ ERROR: $*" >&2
}

log_success() {
  echo "✅ $*"
}

log_info() {
  echo "ℹ️  $*"
}

log_msg() {
  echo "ℹ   $*"
}

log_section() {
  echo ""
  echo "=== $* ==="
}

# Function to verify IoT Core endpoint and certificates
verify_iot_setup() {
  log_section "Verifying IoT Core Setup"
  
  log_msg "Checking IoT endpoint..."
  if ! aws iot describe-endpoint --endpoint-type iot:Data-ATS --region "$REGION"; then
    log_error "Failed to describe IoT endpoint"
    return 1
  fi
  
  log_msg "Checking certificates..."
  if ! aws iot list-certificates --region "$REGION"; then
    log_error "Failed to list IoT certificates"
    return 1
  fi
  
  log_success "IoT Core setup verified"
  echo ""
}

# Function to test Platform API endpoints and Maestro distribution
test_platform_api() {

  local TEST_FILE_MANIFESTWORK=$(mktemp)
  local TEST_FILE_PAYLOAD=$(mktemp)
  local API_URL="${1}"
  local MANAGEMENT_CLUSTER="${2:-mc01}"
  
  log_section "Testing Platform API"
  
  log_msg "Testing API URL: $API_URL with region: $REGION"
  # Test basic API endpoints
  log_section "Testing API Health Endpoints"
  
  set +e # allow awscurl to fail without exiting (disable errexit)
  counter=0
  while true; do
    log_msg "Testing API URL: $API_URL/prod/v0/live"
    awscurl --fail-with-body --service execute-api --region "$REGION" "$API_URL/prod/v0/live"
    r=$?
    if [ "$r" -eq 0 ]; then
      log_success "API is healthy"
      break
    else
      log_msg "API is not healthy, retrying in 30 seconds"
      sleep 30
      counter=$((counter + 1))
      if [ $counter -ge 10 ]; then
        log_error "API is not healthy after 10 retries (5m), exiting"
        exit 1
      fi
    fi
  done
  set -e # re-enable exit on error (errexit)

  awscurl --fail-with-body --service execute-api --region "$REGION" "$API_URL/prod/v0/ready"
  awscurl --fail-with-body --service execute-api --region "$REGION" "$API_URL/prod/api/v0/management_clusters"
  awscurl --fail-with-body --service execute-api --region "$REGION" "$API_URL/prod/api/v0/resource_bundles"
  # awscurl --fail-with-body --service execute-api --region "$REGION" "$API_URL/api/v0/work"
  # awscurl --fail-with-body --service execute-api --region "$REGION" "$API_URL/api/v0/clusters"
  # Create or verify management cluster
  log_section "Creating/Verifying Management Cluster"
  local RESPONSE=$(awscurl --fail-with-body -X POST "$API_URL/prod/api/v0/management_clusters" \
    --service execute-api \
    --region "$REGION" \
    -H "Content-Type: application/json" \
    -d '{"name": "'$MANAGEMENT_CLUSTER'", "labels": {"cluster_type": "management", "cluster_id": "'$MANAGEMENT_CLUSTER'"}}' \
    2>&1)
  local EXIT_CODE=$?

  # Check if the consumer already exists (this is acceptable)
  if echo "$RESPONSE" | grep -qiE '"reason":"This Consumer already exists"'; then
    log_info "Management cluster already exists (this is acceptable)"
    echo "Response: $RESPONSE"
  elif [ $EXIT_CODE -ne 0 ]; then
    log_error "Failed to create management cluster (exit code: $EXIT_CODE)"
    echo "Response: $RESPONSE"
    return 1
  elif echo "$RESPONSE" | grep -qiE '(error|failed|exception|invalid)'; then
    log_error "API returned an error response"
    echo "Response: $RESPONSE"
    return 1
  else
    log_success "Management cluster created successfully"
    echo "Response: $RESPONSE"
  fi
  echo ""

  # Create a test ManifestWork JSON file
  log_section "Creating Test ManifestWork"
  local TIMESTAMP
  TIMESTAMP="$(date +%s)"

  log_msg "Creating test manifestwork file: $TEST_FILE_MANIFESTWORK"
  cat > "$TEST_FILE_MANIFESTWORK" << EOF
{
  "apiVersion": "work.open-cluster-management.io/v1",
  "kind": "ManifestWork",
  "metadata": {
    "name": "maestro-payload-test-${TIMESTAMP}"
  },
  "spec": {
    "workload": {
      "manifests": [
        {
          "apiVersion": "v1",
          "kind": "ConfigMap",
          "metadata": {
            "name": "maestro-payload-test",
            "namespace": "default",
            "labels": {
              "test": "maestro-distribution",
              "timestamp": "${TIMESTAMP}"
            }
          },
          "data": {
            "message": "Hello from Regional Cluster via Maestro MQTT",
            "cluster_source": "regional-cluster",
            "cluster_destination": "${MANAGEMENT_CLUSTER}",
            "transport": "aws-iot-core-mqtt",
            "test_id": "${TIMESTAMP}",
            "payload_size": "This tests MQTT payload distribution through AWS IoT Core"
          }
        }
      ]
    },
    "deleteOption": {
      "propagationPolicy": "Foreground"
    },
    "manifestConfigs": [
      {
        "resourceIdentifier": {
          "group": "",
          "resource": "configmaps",
          "namespace": "default",
          "name": "maestro-payload-test"
        },
        "feedbackRules": [
          {
            "type": "JSONPaths",
            "jsonPaths": [
              {
                "name": "status",
                "path": ".metadata"
              }
            ]
          }
        ],
        "updateStrategy": {
          "type": "ServerSideApply"
        }
      }
    ]
  }
}
EOF

  awscurl --fail-with-body --service execute-api --region "$REGION" "$API_URL/prod/api/v0/management_clusters"
  log_msg "Created ManifestWork file: maestro-payload-test-${TIMESTAMP}"

  # Create payload and post work
  log_section "Posting Work to API"
  cat > "$TEST_FILE_PAYLOAD" << EOF
{
  "cluster_id": "$MANAGEMENT_CLUSTER",
  "data": $(cat "$TEST_FILE_MANIFESTWORK")
}
EOF

  if ! awscurl --fail-with-body -X POST "$API_URL/prod/api/v0/work" \
      --service execute-api --region "$REGION" \
      -H "Content-Type: application/json" \
      -d @"$TEST_FILE_PAYLOAD"; then
    log_error "Failed to post work to API"
    return 1
  fi
  echo ""

  # Verify resource distribution
  log_section "Verifying Resource Distribution"
  log_msg "Checking management cluster..."
  awscurl --fail-with-body --service execute-api --region "$REGION" "$API_URL/prod/api/v0/management_clusters"

  log_msg "Checking resource bundles..."
  awscurl --fail-with-body --service execute-api --region "$REGION" "$API_URL/prod/api/v0/resource_bundles" | jq -r '.'

  # local RESOURCE_STATUS=$(awscurl --fail-with-body --service execute-api --region "$REGION" "$API_URL/api/v0/resource_bundles" 2>/dev/null | \
  #   jq -r '.items[] | select(.metadata.name == "maestro-payload-test-'"${TIMESTAMP}"'")' | jq -r '.status.resourceStatus[]' 2>/dev/null || echo "")

  # if [ -z "$RESOURCE_STATUS" ]; then
  #   log_error "Resource status not found for manifestwork, check maestro configuration between server and agent"
  #   return 1
  # fi

  # log_success "Resource status found: $RESOURCE_STATUS"
  # log_success "Platform API tests completed successfully"
}

# Verify IoT Core setup
verify_iot_setup

# Run Platform API tests
test_platform_api "${API_URL}" "${MANAGEMENT_CLUSTER}"

echo "Done."
