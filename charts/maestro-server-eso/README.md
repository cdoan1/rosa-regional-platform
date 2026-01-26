# Maestro Server ESO Helm Chart

This is a variant of the `maestro-server` Helm chart that uses a **standardized naming pattern** for AWS Secrets Manager secrets. This simplifies deployment by removing the need for intermediate Kubernetes secrets.

## Overview

This chart is designed for deploying **Maestro Server** on the Regional Cluster. It uses:
- **Automatic cluster name detection**: Reads cluster name from `kube-system/bootstrap-output` ConfigMap
- **Standardized AWS Secrets Manager naming**: `{clusterName}/maestro/server-mqtt-cert` and `{clusterName}/maestro/db-credentials`
- **AWS Secrets Store CSI Driver (ASCP)** to mount MQTT certificates and database credentials
- **AWS Pod Identity** for authentication to AWS Secrets Manager

## Differences from `maestro-server`

| Feature | maestro-server | maestro-server-eso |
|---------|----------------|-------------------|
| Configuration Source | values-override.yaml | values.yaml (clusterName + endpoint) |
| AWS Secret Names | From override file | Standardized pattern |
| Workflow | Terraform → script → values file | Terraform → Helm values |
| Automation-Friendly | Medium | High |

## Prerequisites

### 1. Terraform Infrastructure

Terraform must be applied to create:
- AWS IoT Core MQTT broker
- RDS PostgreSQL database
- AWS Secrets Manager secrets (with standard naming)
- IAM roles for Pod Identity

```bash
cd terraform/config/regional-cluster
terraform apply
```

Terraform creates AWS Secrets Manager secrets with these names:
- `{clusterName}/maestro/server-mqtt-cert` - MQTT certificates and private key
- `{clusterName}/maestro/db-credentials` - Database username, password, host, port

### 2. Bootstrap ConfigMap

The cluster name is automatically detected from the `bootstrap-output` ConfigMap in the `kube-system` namespace. This ConfigMap is created by the Terraform bootstrap process.

Verify it exists:
```bash
kubectl get configmap bootstrap-output -n kube-system
kubectl get configmap bootstrap-output -n kube-system -o jsonpath='{.data.cluster_name}'
```

### 3. Get MQTT Endpoint from Terraform

You'll need the MQTT endpoint from Terraform:

```bash
cd terraform/config/regional-cluster
terraform output -raw maestro_iot_mqtt_endpoint
```

### 4. AWS Secrets Store CSI Driver

Ensure the AWS Secrets Store CSI Driver (ASCP) is installed:

```bash
kubectl get pods -n kube-system | grep csi-secrets-store
```

If not installed, deploy it:
```bash
kubectl apply -f https://raw.githubusercontent.com/kubernetes-sigs/secrets-store-csi-driver/main/deploy/rbac-secretproviderclass.yaml
kubectl apply -f https://raw.githubusercontent.com/kubernetes-sigs/secrets-store-csi-driver/main/deploy/csidriver.yaml
kubectl apply -f https://raw.githubusercontent.com/kubernetes-sigs/secrets-store-csi-driver/main/deploy/secrets-store.csi.x-k8s.io_secretproviderclasses.yaml
kubectl apply -f https://raw.githubusercontent.com/kubernetes-sigs/secrets-store-csi-driver/main/deploy/secrets-store.csi.x-k8s.io_secretproviderclasspodstatuses.yaml
kubectl apply -f https://raw.githubusercontent.com/kubernetes-sigs/secrets-store-csi-driver/main/deploy/secrets-store-csi-driver.yaml

# Install AWS provider
kubectl apply -f https://raw.githubusercontent.com/aws/secrets-store-csi-driver-provider-aws/main/deployment/aws-provider-installer.yaml
```

## Installation

### Basic Installation (with inline values)

```bash
# Get MQTT endpoint from Terraform
MQTT_ENDPOINT=$(cd terraform/config/regional-cluster && terraform output -raw maestro_iot_mqtt_endpoint)

# Install with inline values (cluster name auto-detected from bootstrap-output ConfigMap)
helm install maestro-server charts/maestro-server-eso \
  --namespace maestro \
  --create-namespace \
  --set broker.endpoint="${MQTT_ENDPOINT}"
```

### Installation with Custom Values File

Create a `custom-values.yaml`:

```yaml
# REQUIRED: MQTT endpoint from Terraform
broker:
  endpoint: "xxxxx.iot.us-east-1.amazonaws.com"

# Optional: Override auto-detected cluster name
# clusterName: "regional-xyz"

# Optional customizations
deployment:
  replicas: 3
  requests:
    cpu: "500m"
    memory: "1Gi"

image:
  tag: "v0.2.0"

aws:
  region: "us-west-2"
```

Install with custom values:

```bash
helm install maestro-server charts/maestro-server-eso \
  --namespace maestro \
  --create-namespace \
  -f custom-values.yaml
```

## How It Works

### 1. Automatic Cluster Name Detection

The chart uses Helm's `lookup` function to read the cluster name from the `bootstrap-output` ConfigMap:

```yaml
# In secretproviderclass.yaml
{{- $bootstrapCM := lookup "v1" "ConfigMap" "kube-system" "bootstrap-output" }}
{{- $clusterName := index $bootstrapCM.data "cluster_name" }}
```

The ConfigMap is created by Terraform during cluster provisioning and contains the cluster name.

**Fallback:** If the ConfigMap is not found (e.g., during `helm template` for ArgoCD), the chart will use `.Values.clusterName` if provided, or fail with a helpful error message.

### 2. AWS Secrets Manager Naming Pattern

The chart constructs AWS Secrets Manager secret names from the detected cluster name:

```yaml
{{- $dbSecretName := printf "%s/maestro/db-credentials" $clusterName }}
{{- $mqttSecretName := printf "%s/maestro/server-mqtt-cert" $clusterName }}
```

For example, if cluster name is `"regional-xyz"`:
- MQTT cert secret: `regional-xyz/maestro/server-mqtt-cert`
- DB credentials secret: `regional-xyz/maestro/db-credentials`

### 3. SecretProviderClass

The chart creates a `SecretProviderClass` that references AWS Secrets Manager:

```yaml
spec:
  provider: aws
  parameters:
    usePodIdentity: "true"
    region: us-east-1
    objects: |
      - objectName: regional-xyz/maestro/server-mqtt-cert
        objectType: "secretsmanager"
      - objectName: regional-xyz/maestro/db-credentials
        objectType: "secretsmanager"
```

### 4. Volume Mounting

Pods mount the CSI volume to access secrets at `/mnt/secrets-store/`:
- `/mnt/secrets-store/certificate`
- `/mnt/secrets-store/privateKey`
- `/mnt/secrets-store/ca.crt`
- `/mnt/secrets-store/db.user`
- `/mnt/secrets-store/db.password`
- `/mnt/secrets-store/db.host`
- `/mnt/secrets-store/db.port`
- `/mnt/secrets-store/db.name`

## Configuration

### Required Values

| Parameter | Description | Example |
|-----------|-------------|---------|
| `broker.endpoint` | AWS IoT MQTT endpoint (from Terraform) | `xxxxx.iot.us-east-1.amazonaws.com` |

**Note:** `clusterName` is automatically detected from `kube-system/bootstrap-output` ConfigMap and does not need to be provided.

### Optional Values

| Parameter | Description | Default |
|-----------|-------------|---------|
| `clusterName` | Override auto-detected cluster name | Auto-detected from ConfigMap |
| `aws.region` | AWS region | `us-east-1` |
| `aws.podIdentity.enabled` | Enable AWS Pod Identity | `true` |
| `deployment.replicas` | Number of replicas | `2` |
| `deployment.zoneCount` | Availability zones | `3` |

## Workflow

### Complete Deployment Flow

```bash
# 1. Apply Terraform infrastructure (creates bootstrap-output ConfigMap)
cd terraform/config/regional-cluster
terraform apply

# 2. Get MQTT endpoint from Terraform
MQTT_ENDPOINT=$(terraform output -raw maestro_iot_mqtt_endpoint)

# 3. Install Helm chart (cluster name auto-detected)
cd ../../..
helm install maestro-server charts/maestro-server-eso \
  --namespace maestro \
  --create-namespace \
  --set broker.endpoint="${MQTT_ENDPOINT}"

# 4. Verify deployment
kubectl get pods -n maestro
kubectl logs -n maestro deployment/maestro -c service
```

### ArgoCD Deployment Flow

When using ArgoCD, provide only the MQTT endpoint (cluster name is auto-detected):

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: maestro-server
  namespace: argocd
spec:
  source:
    repoURL: https://github.com/openshift-online/rosa-regional-platform
    targetRevision: main
    path: charts/maestro-server-eso
    helm:
      values: |
        broker:
          endpoint: "xxxxx.iot.us-east-1.amazonaws.com"
  destination:
    server: https://kubernetes.default.svc
    namespace: maestro
```

Or use an external values file in Git:

```bash
# Create values file in Git repo
cat > argocd/regional-cluster/maestro-server-values.yaml << EOF
broker:
  endpoint: "xxxxx.iot.us-east-1.amazonaws.com"
EOF

# Reference in ArgoCD Application
spec:
  source:
    helm:
      valueFiles:
        - ../../argocd/regional-cluster/maestro-server-values.yaml
```

**Note:** When ArgoCD runs `helm template` (without cluster access), the `lookup` function returns nil. In this case, you must provide `clusterName` in values:

```yaml
helm:
  values: |
    clusterName: "regional-xyz"  # Required for ArgoCD template rendering
    broker:
      endpoint: "xxxxx.iot.us-east-1.amazonaws.com"
```

## Troubleshooting

### Error: Unable to determine cluster name

**Symptom:**
```
Error: INSTALLATION FAILED: execution error at (maestro-server-eso/templates/secretproviderclass.yaml:X:X): Unable to determine cluster name. ConfigMap kube-system/bootstrap-output not found and clusterName not provided in values
```

**Possible causes:**
1. The `bootstrap-output` ConfigMap doesn't exist in `kube-system` namespace
2. You're running `helm template` without cluster access (e.g., ArgoCD)

**Solution:**

1. Verify the ConfigMap exists:
   ```bash
   kubectl get configmap bootstrap-output -n kube-system
   ```

2. If using ArgoCD or `helm template`, provide clusterName explicitly:
   ```bash
   helm install maestro-server charts/maestro-server-eso \
     --set clusterName="regional-xyz" \
     --set broker.endpoint="xxxxx.iot.us-east-1.amazonaws.com"
   ```

3. If ConfigMap is missing, check Terraform outputs and provide clusterName:
   ```bash
   CLUSTER_NAME=$(cd terraform/config/regional-cluster && terraform output -raw cluster_name)
   helm install maestro-server charts/maestro-server-eso \
     --set clusterName="${CLUSTER_NAME}" \
     --set broker.endpoint="xxxxx.iot.us-east-1.amazonaws.com"
   ```

### Error: broker.endpoint is required

**Symptom:**
```
Error: INSTALLATION FAILED: execution error at (maestro-server-eso/templates/configmap.yaml:1:4): broker.endpoint is required
```

**Solution:**
Provide the MQTT endpoint from Terraform:
```bash
MQTT_ENDPOINT=$(cd terraform/config/regional-cluster && terraform output -raw maestro_iot_mqtt_endpoint)
helm install maestro-server charts/maestro-server-eso \
  --set broker.endpoint="${MQTT_ENDPOINT}"
```

### Error: Failed to mount secrets store

**Symptom:**
```
MountVolume.SetUp failed for volume "secrets-store" : rpc error: code = Unknown desc = failed to mount secrets store objects
```

**Possible causes:**
1. AWS Secrets Manager secrets don't exist with the expected names
2. Pod Identity is not configured correctly
3. CSI driver is not running

**Solution:**

1. Verify AWS Secrets Manager secrets exist:
   ```bash
   CLUSTER_NAME=$(cd terraform/config/regional-cluster && terraform output -raw cluster_name)
   aws secretsmanager describe-secret --secret-id "${CLUSTER_NAME}/maestro/server-mqtt-cert"
   aws secretsmanager describe-secret --secret-id "${CLUSTER_NAME}/maestro/db-credentials"
   ```

2. Check Pod Identity annotations:
   ```bash
   kubectl describe pod -n maestro -l component=maestro-server | grep -A 5 "Annotations"
   ```

3. Verify ASCP CSI driver is running:
   ```bash
   kubectl get pods -n kube-system | grep csi-secrets-store
   ```

### Wrong AWS secret names

**Symptom:**
Pods fail to start because secrets have different names than expected.

**Solution:**
Ensure your Terraform module creates secrets with the standard naming pattern:
```
{cluster_name}/maestro/server-mqtt-cert
{cluster_name}/maestro/db-credentials
```

Check `terraform/modules/maestro-infrastructure/secrets.tf`:
```hcl
resource "aws_secretsmanager_secret" "maestro_server_mqtt_cert" {
  name = "${var.resource_name_base}/maestro/server-mqtt-cert"
  # ...
}

resource "aws_secretsmanager_secret" "maestro_db_credentials" {
  name = "${var.resource_name_base}/maestro/db-credentials"
  # ...
}
```

## Upgrading

### Update Configuration

If the MQTT endpoint changes:

```bash
# Get new endpoint
MQTT_ENDPOINT=$(cd terraform/config/regional-cluster && terraform output -raw maestro_iot_mqtt_endpoint)

# Upgrade release (cluster name auto-detected)
helm upgrade maestro-server charts/maestro-server-eso \
  --namespace maestro \
  --set broker.endpoint="${MQTT_ENDPOINT}" \
  --reuse-values
```

### Update Chart Version

```bash
helm upgrade maestro-server charts/maestro-server-eso \
  --namespace maestro \
  -f custom-values.yaml
```

## Uninstalling

```bash
helm uninstall maestro-server -n maestro
```

## See Also

- [../maestro-server/](../maestro-server/) - Original chart using values-override.yaml
- [../../terraform/modules/maestro-infrastructure/](../../terraform/modules/maestro-infrastructure/) - Terraform module for Maestro infrastructure
