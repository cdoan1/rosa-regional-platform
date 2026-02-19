# Complete Guide: Provision a New Central Pipeline

This comprehensive guide walks through all steps to provision a new central pipeline in the ROSA Regional Platform. Follow these steps in order to set up a central pipeline that will provision both Regional and Management Clusters with full ArgoCD configuration and Maestro connectivity.

---

## 1. Pre-Flight Checklist

Before starting, ensure your environment is properly configured.

### Required Tools
Verify all tools are installed and accessible:

```bash
# Check tool versions
aws --version
terraform --version
python --version  # or python3 --version
```

### Required AWS accounts

To provision a regional and management cluster, you require three AWS accounts. One account for Central, one account for the Regional Cluster, and one account for the Management Cluster.  Ensure you have access to the designated Central account via environment variables or ideally AWS profiles. 

The 2 accounts designated for the Regional Cluster and Management Cluster require additional configuration.  Add the Central AWS account number to the trust policy of `OrganizationAccountAccessRole` in the 2 regional and management accounts.

## 2. Configure a new Sector/Region Deployment

<details>
<summary>🔧 Configure New Region Deployment</summary>

**Note:** In case you are deploying clusters based on existing argocd configuration, you can skip this step.
Example: you want to spin up a development cluster and re-use the existing configuration for `env = integration` and `region = us-east-1`.

### Add Sector to Configuration

Edit `config.yaml` and add your new sector following this pattern:

```yaml
sectors:
  # ... existing entries ...
  - name: "brian-testing"
    environment: "brian"
    terraform_vars:
      app_code: "infra"
      service_phase: "dev"
      cost_center: "000"
      environment: "{{ environment }}"
    values:
      management-cluster:
        hypershift:
          oidcStorageS3Bucket:
            name: "hypershift-mc-{{ aws_region }}"
            region: "{{ aws_region }}"
          externalDns:
            domain: "dev.{{ aws_region }}.rosa.example.com"
```

### Add Region to Configuration

Edit `config.yaml` and add your new region following this pattern:

```yaml
region_deployments:
  # ... existing entries ...
  - name: "us-east-1"
    aws_region: "us-east-1"
    sector: "brian"
    account_id: "<Regional account>"
    terraform_vars:
      account_id: "{{ account_id }}"
      region: "{{ aws_region }}"
      alias: "regional-{{region_alias}}"
      region_alias: "{{ region_alias }}"
    management_clusters:
      - cluster_id: "mc01-{{ region_alias }}"
        account_id: "<Management Account>"
```

### Generate Rendered Configurations

Run the rendering script to generate the required files:

```bash
./scripts/render.py
```

**Verify rendered files were created:**

```bash
ls -la deploy/<sector>/<region>/  # Replace with your environment/name
```

You should see `argocd/` and `terraform/` subdirectories with generated configs.

### Commit and Push Changes

```bash
git add config.yaml deploy/
git commit -m "Add <region> region configuration

- Add <region>/<sector> to config.yaml
- Generate deploy configs (argocd + terraform)
- Prepare for regional cluster provisioning
git push origin <your-branch>
```

</details>

---

## 3. Central Pipeline Provisioning

Switch to your **central account** AWS profile and provision the pipeline.

### Execute central pipeline bootstrap

```bash
# Authenticate with central account (choose your preferred method)
export AWS_PROFILE=<central-profile>
# OR: aws configure set profile <regional-profile>
# OR: use your SSO/assume role method

# Bootstrap the pipeline
GITHUB_REPO_OWNER=<ORG> GITHUB_REPO_NAME=rosa-regional-platform GITHUB_BRANCH=<BRANCH> TARGET_ENVIRONMENT=<SECTOR> ./scripts/bootstrap-central-account.sh
```

### Accept the Codestar connection

As a single manual process, you must accept the CodeStar connection.  

Log into the Central AWS Account console.  

`Developer Tools` > `Settings` > `Connections` > `Accept the pending connection`

Since the pipeline was deployed before the connection was accepted, you must retrigger the `CodePipeline`.

The `pipeline-provisioner` will begin creating new pipelines for any configured regions in the specified sector.  You should expect to see 2 new pipelines.  One for the regional cluster deployment and 1 for the management cluster deployment.  

### Verify Regional Cluster Deployment (optional)

<details>
<summary>🔍 Verify Regional Cluster Deployment (optional)</summary>

```bash
# Check ArgoCD applications are synced
./scripts/dev/bastion-connect.sh regional
kubectl get applications -n argocd
```

Expected: ArgoCD applications "Synced" and "Healthy".

</details>

---

## 4. Verify Maestro Connectivity

Maestro uses AWS IoT Core for secure MQTT communication between Regional and Management Clusters. This requires a two-account certificate exchange process.

### Step 4a: Regional Account IoT Setup
**Completed during the pipeline -- Provision IoT resources in regional account:**

### Step 4b: Management Account Secret Setup
**Completed during the pipeline -- Create IoT secret in management account:**

**What this creates:**
- Kubernetes secret containing IoT certificate and endpoint
- Configuration for Maestro agent to connect to regional IoT endpoint

<details>
<summary>🔍 Verify IoT Resources (optional)</summary>

```bash
# Choose your preferred authentication method
export AWS_PROFILE=<regional-profile>
# OR: use --profile flag, SSO, assume role, etc.
```

```bash
# In regional account - verify IoT endpoint
aws iot describe-endpoint --endpoint-type iot:Data-ATS

# Check certificate is active
aws iot list-certificates
```

Expected: IoT endpoint URL should be returned and certificate should show "ACTIVE" status.

</details>

---

## 5. Management Cluster Provisioning
*** Completed During the pipeline deployment ***

### Verify Management Cluster Provisioning

<details>
<summary>🔍 Verify Management Cluster Deployment (optional)</summary>

```bash
# Authenticate with management account (choose your preferred method)
export AWS_PROFILE=<management-profile>
# OR: aws configure set profile <management-profile>
# OR: use your SSO/assume role method
```

```bash
# Check cluster is provisioned
./scripts/dev/bastion-connect.sh management

# Verify ArgoCD applications
kubectl get applications -n argocd
```

Expected: ArgoCD applications "Synced" and "Healthy".

</details>

---

## 6. Consumer Registration & Verification
*** The pipeline process currently ends here  ***
*** TODO: Will be added to the pipeline process ***

Register the Management Cluster as a consumer with the Regional Cluster's Maestro server.

```bash
API_GATEWAY_URL=$(make terraform-output-regional | jq -r '.api_gateway_invoke_url.value')

awscurl -X POST $API_GATEWAY_URL/api/v0/management_clusters \
--service execute-api \
--region $REGION \
-H "Content-Type: application/json" \
-d '{"name": "management-01", "labels": {"cluster_type": "management", "cluster_id": "management-01"}}'
```

---

## 7. End-to-End Verification

This section provides comprehensive validation that both Regional and Management clusters are running and can communicate properly via Maestro.

<details>
<summary>🔍 Consumer Registration Verification</summary>


```bash
# Verify the Management Cluster is properly registered
# Access the Platform API, and query the registered consumers.
# You can get the gateway api from the regional cluster terraform output

awscurl --service execute-api --region $REGION $API_GATEWAY_URL/api/v0/management_clusters

# example:
# awscurl --service execute-api --region us-east-2 https://z0l5l43or4.execute-api.us-east-2.amazonaws.com/prod/api/v0/management_clusters | jq -r '.items[] | "- \(.name) (labels: \(.labels))"'
```

**Expected Results:**
- Your Management Cluster name appears in the consumer list
- Consumer has appropriate labels (cluster_type, cluster_id)
- No connection errors when accessing Maestro API

</details>

<details>
<summary>🔍 Complete Maestro Payload Distribution Test</summary>

This comprehensive test validates end-to-end Maestro payload distribution from Regional to Management Cluster via AWS IoT Core MQTT using the proper gRPC client interface:

**Step 0: Ensure environment variables**

```bash
export API_GATEWAY_URL=$(make terraform-output-regional | jq -r '.api_gateway_invoke_url.value')
export REGION=<aws region goes here>

```

**Step 1: Create Test ManifestWork File**

```bash
# Create a test ManifestWork JSON file
TIMESTAMP=$(date +%s)

cat > /tmp/maestro-test-manifestwork.json << EOF
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

echo "Created ManifestWork file: maestro-payload-test-${TIMESTAMP}"

cat > payload.json << EOF
{
  "cluster_id": "management-01",
  "data": $(cat /tmp/maestro-test-manifestwork.json )
}
EOF
```

**Step 2: Post the payload**

```bash
awscurl -X POST $API_GATEWAY_URL/api/v0/work --service execute-api --region $REGION -d @payload.json
```

**Step 3: Monitor Distribution Status**

```bash
# List the current management_clusters
awscurl --service execute-api --region $REGION $API_GATEWAY_URL/api/v0/management_clusters

# List all ManifestWorks, jq to filter by consumer
awscurl --service execute-api --region $REGION $API_GATEWAY_URL/api/v0/resource_bundles

# Examples:
# awscurl --service execute-api --region us-east-2 https://z0l5l43or4.execute-api.us-east-2.amazonaws.com/prod/api/v0/management_clusters

# awscurl --service execute-api --region us-east-2 https://z0l5l43or4.execute-api.us-east-2.amazonaws.com/prod/api/v0/resource_bundles | jq -r '.items[].status.resourceStatus[]'
```

</details>

