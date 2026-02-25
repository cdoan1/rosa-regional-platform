#!/bin/bash
# This is a simple e2e platform api test script.
# It verifies the IoT Core setup and the platform api endpoints.
# It creates a management cluster and a test manifestwork.
# It then verifies the resource distribution.
# It is meant to be run from the regional account.
# It requires the following tools:
# - aws
# - jq
# - awscurl (https://github.com/okigan/awscurl)
# - date
# - cat
# - echo

set -euo pipefail

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

log_section() {
  echo ""
  echo "=== $* ==="
}

# Function to verify IoT Core endpoint and certificates
verify_iot_setup() {
  log_section "Verifying IoT Core Setup"
  
  echo "Checking IoT endpoint..."
  if ! aws iot describe-endpoint --endpoint-type iot:Data-ATS; then
    log_error "Failed to describe IoT endpoint"
    return 1
  fi
  
  echo ""
  echo "Checking certificates..."
  if ! aws iot list-certificates; then
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
  local MANAGEMENT_CLUSTER="${1:-mc01}"
  
  log_section "Testing Platform API"
  
  # 1. Get all matching API IDs
  local API_IDS=$(aws apigateway get-rest-apis --query "items[?starts_with(name, 'regional-cluster-')].id" --output text)
  if [ -z "$API_IDS" ] || [ "$API_IDS" == "None" ]; then
    log_error "Failed to get API IDs"
    return 1
  fi

  # Count the number of API IDs (handle space-separated values)
  local API_COUNT=$(echo "$API_IDS" | wc -w)
  if [ "$API_COUNT" -ne 1 ]; then
    log_error "Expected exactly one API ID, but found $API_COUNT: $API_IDS"
    return 1
  fi

  # Assign the single API ID
  local API_ID="$API_IDS"

  # 2. Get all stages for the API
  local STAGES_JSON=$(aws apigateway get-stages --rest-api-id "$API_ID" --output json)
  if [ -z "$STAGES_JSON" ]; then
    log_error "Failed to get stages for API ID: $API_ID"
    return 1
  fi

  # Count the number of stages
  local STAGE_COUNT=$(echo "$STAGES_JSON" | jq -r '.item | length')
  if [ "$STAGE_COUNT" -ne 1 ]; then
    log_error "Expected exactly one stage for API ID $API_ID, but found $STAGE_COUNT"
    return 1
  fi

  # Assign the single stage name
  local STAGE_NAME=$(echo "$STAGES_JSON" | jq -r '.item[0].stageName')
  if [ -z "$STAGE_NAME" ] || [ "$STAGE_NAME" == "null" ]; then
    log_error "Failed to extract stage name from stages response"
    return 1
  fi

  # 3. Get the Region (from your local config)
  local REGION=$(aws configure get region)
  if [ -z "$REGION" ]; then
    log_error "Failed to get AWS region"
    return 1
  fi

  # Final URL
  local API_URL="https://$API_ID.execute-api.$REGION.amazonaws.com/$STAGE_NAME"

  echo "Testing API URL: $API_URL with region: $REGION and API ID: $API_ID and Stage Name: $STAGE_NAME"
  echo ""

  # Test basic API endpoints
  log_section "Testing API Health Endpoints"
  awscurl --fail-with-body --service execute-api --region "$REGION" "$API_URL/v0/live"
  awscurl --fail-with-body --service execute-api --region "$REGION" "$API_URL/v0/ready"
  awscurl --fail-with-body --service execute-api --region "$REGION" "$API_URL/api/v0/management_clusters"
  awscurl --fail-with-body --service execute-api --region "$REGION" "$API_URL/api/v0/resource_bundles"
  # awscurl --fail-with-body --service execute-api --region "$REGION" "$API_URL/api/v0/work"
  # awscurl --fail-with-body --service execute-api --region "$REGION" "$API_URL/api/v0/clusters"
  echo ""

  # Create or verify management cluster
  log_section "Creating/Verifying Management Cluster"
  local RESPONSE=$(awscurl --fail-with-body -X POST "$API_URL/api/v0/management_clusters" \
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

  echo "Creating test manifestwork file: $TEST_FILE_MANIFESTWORK"
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

  awscurl --fail-with-body --service execute-api --region "$REGION" "$API_URL/api/v0/management_clusters"
  echo "Created ManifestWork file: maestro-payload-test-${TIMESTAMP}"
  echo ""

  # Create payload and post work
  log_section "Posting Work to API"
  cat > "$TEST_FILE_PAYLOAD" << EOF
{
  "cluster_id": "$MANAGEMENT_CLUSTER",
  "data": $(cat "$TEST_FILE_MANIFESTWORK")
}
EOF

  if ! awscurl --fail-with-body -X POST "$API_URL/api/v0/work" \
      --service execute-api --region "$REGION" \
      -H "Content-Type: application/json" \
      -d @"$TEST_FILE_PAYLOAD"; then
    log_error "Failed to post work to API"
    return 1
  fi
  echo ""

  # Verify resource distribution
  log_section "Verifying Resource Distribution"
  echo "Checking management cluster..."
  awscurl --fail-with-body --service execute-api --region "$REGION" "$API_URL/api/v0/management_clusters"
  echo ""

  echo "Checking resource bundles..."
  awscurl --fail-with-body --service execute-api --region "$REGION" "$API_URL/api/v0/resource_bundles" | jq -r '.'
  echo ""

  local RESOURCE_STATUS=$(awscurl --fail-with-body --service execute-api --region "$REGION" "$API_URL/api/v0/resource_bundles" 2>/dev/null | \
    jq -r '.items[] | select(.metadata.name == "maestro-payload-test-'"${TIMESTAMP}"'")' | jq -r '.status.resourceStatus[]' 2>/dev/null || echo "")

  if [ -z "$RESOURCE_STATUS" ]; then
    log_error "Resource status not found for manifestwork, check maestro configuration between server and agent"
    return 1
  fi

  log_success "Resource status found: $RESOURCE_STATUS"
  log_success "Platform API tests completed successfully"
}

# Verify IoT Core setup
verify_iot_setup

# Run Platform API tests
test_platform_api

echo "Done."
