# Maestro Regional-to-Management Cluster Quickstart

This guide shows the minimal steps to establish Maestro MQTT connectivity between a Regional Cluster and a Management Cluster.

## Prerequisites

- AWS profiles configured for both regional and management accounts
- Terraform and AWS CLI installed

## Configuration

In `terraform/config/management-cluster/terraform.tfvars`:

```hcl
cluster_id              = "management-no5q"
regional_aws_account_id = "964610782567"
```

## Provisioning Steps

Execute commands in order, switching AWS profiles as indicated:

```bash
# 1. Regional AWS profile - Provision Regional Cluster
make provision-regional

# 2. Regional AWS profile - Provision Maestro IoT resources in regional account
MGMT_TFVARS=terraform/config/management-cluster/terraform.tfvars make provision-maestro-agent-iot-regional

# 3. Management AWS profile - Provision Maestro IoT resources in management account
MGMT_TFVARS=terraform/config/management-cluster/terraform.tfvars make provision-maestro-agent-iot-management

# 4. Management AWS profile - Provision Management Cluster
make provision-management
```

## Register Management Cluster as Consumer

From the Regional Cluster bastion:

```bash
# Port-forward to Maestro HTTP service
kubectl port-forward -n maestro-server svc/maestro-http 8080:8080 --address 0.0.0.0

# Register the consumer
curl -X POST http://localhost:8080/api/maestro/v1/consumers \
  -H "Content-Type: application/json" \
  -d '{
    "name": "management-no5q",
    "labels": {
      "cluster_type": "management",
      "cluster_id": "management-no5q"
    }
  }'
```

## Testing (Optional)

### Validate ConfigMap Distribution via Maestro

1. **Set up port forwarding** on Regional Cluster bastion:

```bash
kubectl port-forward -n maestro-server svc/maestro-grpc 8090:8090 --address 0.0.0.0 &
kubectl port-forward -n maestro-server svc/maestro-http 8080:8080 --address 0.0.0.0 &
```

2. **Port-forward locally**:

```bash
./scripts/port-forward-maestro.sh
```

3. **Clone Maestro repository**:

```bash
git clone https://github.com/openshift-online/maestro.git /tmp/maestro
```

4. **Create test manifest** (`test-configmap-manifestwork.json`):

```json
{
  "apiVersion": "work.open-cluster-management.io/v1",
  "kind": "ManifestWork",
  "metadata": {
    "name": "test-configmap"
  },
  "spec": {
    "workload": {
      "manifests": [
        {
          "apiVersion": "v1",
          "kind": "ConfigMap",
          "metadata": {
            "name": "hello-from-maestro",
            "namespace": "default"
          },
          "data": {
            "message": "Hello from Maestro Server via MQTT",
            "cluster_id": "management-no5q",
            "timestamp": "2026-01-30T00:00:00Z"
          }
        }
      ]
    }
  }
}
```

5. **Apply manifest using Maestro client**:

```bash
cd /tmp/maestro
go run examples/manifestwork/client.go apply test-configmap-manifestwork.json \
  --consumer-name=management-no5q \
  --maestro-server=http://localhost:8080 \
  --grpc-server=localhost:8090 \
  --insecure-skip-verify
```

6. **Verify on Management Cluster**:

```bash
kubectl get configmap hello-from-maestro -n default
```

## Architecture Notes

- **Regional Cluster**: Runs Maestro Server (MQTT broker and API)
- **Management Cluster**: Runs Maestro Agent (MQTT client)
- **Communication**: Agent connects to Server via AWS IoT Core for MQTT transport
- **Resource Distribution**: CLM pushes ManifestWork resources to consumers via Maestro
