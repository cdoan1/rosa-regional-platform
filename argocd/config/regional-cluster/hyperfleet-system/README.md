# HyperFleet System

Unified Helm chart deploying all HyperFleet components into the `hyperfleet-system` namespace using AWS managed services.

## Components

This chart deploys three main components:

1. **HyperFleet API** - REST API service with Amazon RDS for PostgreSQL backend
2. **HyperFleet Sentinel** - Polls API and publishes CloudEvents to Amazon MQ for RabbitMQ
3. **HyperFleet Adapter** - Consumes CloudEvents from Amazon MQ and creates Kubernetes resources

## Why Consolidated?

This chart consolidates three previously separate charts to avoid ArgoCD sync conflicts when multiple applications deploy to the same namespace.

## Architecture

HyperFleet uses AWS managed services with Pod Identity authentication:

- **Database**: Amazon RDS for PostgreSQL (managed, automated backups, Multi-AZ support)
- **Message Queue**: Amazon MQ for RabbitMQ (managed, AMQPS encrypted)
- **Authentication**: AWS Pod Identity (no hardcoded credentials)
- **Secrets**: AWS Secrets Manager with CSI driver for secure credential mounting

## Configuration

All components use AWS managed services with Pod Identity authentication:

```yaml
namespace: hyperfleet-system

# API configuration with AWS RDS
hyperfleetApi:
  replicaCount: 1
  image:
    registry: quay.io/cdoan0
    repository: hyperfleet-api
    tag: "v1.0.0" # Use specific version, not "latest"

  database:
    # Disable in-cluster PostgreSQL
    postgresql:
      enabled: false

    # Enable AWS RDS with Pod Identity
    external:
      enabled: true
      usePodIdentity: true
      secretMountPath: /mnt/secrets-store
      sslMode: require # Enforce TLS connections

  # AWS Pod Identity configuration
  aws:
    region: us-east-2
    podIdentity:
      enabled: true
      roleArn: "arn:aws:iam::ACCOUNT_ID:role/hyperfleet-api" # From Terraform

# Sentinel configuration with Amazon MQ
hyperfleetSentinel:
  replicaCount: 1
  config:
    resourceType: clusters
    pollInterval: 5s

  broker:
    # Disable in-cluster RabbitMQ
    rabbitmq:
      enabled: false

    # Enable Amazon MQ with Pod Identity
    external:
      enabled: true
      usePodIdentity: true
      secretMountPath: /mnt/secrets-store
      useTLS: true # AMQPS encryption
      exchange: "hyperfleet-clusters"
      exchangeType: "topic"

  # AWS Pod Identity configuration
  aws:
    region: us-east-2
    podIdentity:
      enabled: true
      roleArn: "arn:aws:iam::ACCOUNT_ID:role/hyperfleet-sentinel" # From Terraform

# Adapter configuration with Amazon MQ
hyperfleetAdapter:
  replicaCount: 1
  rbac:
    create: true
    resources:
      - namespaces
      - serviceaccounts

  broker:
    # Disable in-cluster RabbitMQ
    rabbitmq:
      enabled: false

    # Enable Amazon MQ with Pod Identity
    external:
      enabled: true
      usePodIdentity: true
      secretMountPath: /mnt/secrets-store
      useTLS: true # AMQPS encryption
      queue: "hyperfleet-clusters-landing-zone"
      exchange: "hyperfleet-clusters"
      routingKey: "#"

  # AWS Pod Identity configuration
  aws:
    region: us-east-2
    podIdentity:
      enabled: true
      roleArn: "arn:aws:iam::ACCOUNT_ID:role/hyperfleet-adapter" # From Terraform
```

**Note**: Role ARNs are typically populated from Terraform outputs via `config.yaml` and the GitOps rendering process, not hardcoded in `values.yaml`.

## Deployment

### Via ArgoCD

This chart is designed to be deployed as a single ArgoCD Application:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: hyperfleet-system
  namespace: argocd
spec:
  project: default
  source:
    repoURL: <your-repo>
    path: argocd/config/regional-cluster/hyperfleet-system
    targetRevision: HEAD
  destination:
    server: https://kubernetes.default.svc
    namespace: hyperfleet-system
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```

### Via Helm

```bash
helm install hyperfleet-system ./argocd/config/regional-cluster/hyperfleet-system \
  --create-namespace \
  --namespace hyperfleet-system
```

## AWS Infrastructure Setup

Before deploying HyperFleet, provision the underlying AWS infrastructure (RDS, Amazon MQ, Secrets Manager, IAM roles) using Terraform. See the [HyperFleet Infrastructure module](../../../../terraform/modules/hyperfleet-infrastructure/README.md) for full details on resources created, configuration options, cost estimates, and troubleshooting.

```bash
cd terraform/config/regional-cluster
terraform apply
```

The ASCP CSI driver must be installed on the EKS cluster for Pod Identity secret mounting.

## Verification

### Check Pod Status

```bash
# Check all pods
kubectl get pods -n hyperfleet-system

# Expected output:
# hyperfleet-api-xxx          1/1     Running
# hyperfleet-sentinel-xxx     1/1     Running
# hyperfleet-adapter-xxx      1/1     Running

# Verify Pod Identity secrets are mounted
kubectl exec -n hyperfleet-system deployment/hyperfleet-api -- \
  ls -la /mnt/secrets-store/
# Expected: db.host, db.port, db.user, db.password, db.name

kubectl exec -n hyperfleet-system deployment/hyperfleet-sentinel -- \
  kubectl get secret hyperfleet-sentinel-mq-secret -o yaml
# Expected: BROKER_RABBITMQ_URL key exists
```

### Validate Infrastructure

Use the validation scripts from the bastion host:

```bash
# Kubernetes-only validation (no AWS CLI required)
./scripts/validate-hyperfleet-k8s.sh

# Full validation with AWS infrastructure checks (requires AWS CLI)
./scripts/validate-hyperfleet.sh
```

### Test API Endpoints

```bash
# Port-forward API service
kubectl port-forward -n hyperfleet-system svc/hyperfleet-api 8000:8000 8080:8080

# Health check
curl http://localhost:8080/healthz

# List clusters
curl http://localhost:8000/api/hyperfleet/v1/clusters | jq

# Create test cluster
curl -X POST http://localhost:8000/api/hyperfleet/v1/clusters \
  -H "Content-Type: application/json" \
  -d '{
    "kind": "Cluster",
    "name": "test-cluster",
    "region": "us-east-1",
    "version": "4.14.0"
  }'
```

### View Logs

```bash
# API logs
kubectl logs -n hyperfleet-system -l app.kubernetes.io/name=hyperfleet-api

# Sentinel logs (watch for event publishing)
kubectl logs -f -n hyperfleet-system -l app.kubernetes.io/name=hyperfleet-sentinel

# Adapter logs (watch for event consumption)
kubectl logs -f -n hyperfleet-system -l app.kubernetes.io/name=hyperfleet-adapter
```

### End-to-End Flow Test

```bash
# 1. Create a cluster via API
./scripts/test-create-cluster.sh

# 2. Watch Sentinel detect and publish event to Amazon MQ
kubectl logs -f -n hyperfleet-system deployment/hyperfleet-sentinel

# 3. Watch Adapter consume event from Amazon MQ
kubectl logs -f -n hyperfleet-system deployment/hyperfleet-adapter

# 4. Verify namespace created
kubectl get namespaces | grep test-cluster
```

## Production Considerations

1. **Provision AWS Infrastructure** with production-tier settings — see [HyperFleet Infrastructure module](../../../../terraform/modules/hyperfleet-infrastructure/README.md) for recommended instance sizes, Multi-AZ, and monitoring setup
2. **Configure Pod Identity Role ARNs** in `config.yaml` for your region deployment (role ARNs come from Terraform outputs)
3. **Use specific image tags** (not `latest`)
4. **Configure resource limits** based on observed usage

## Deployment Notes

**Note**: HyperFleet requires AWS managed services (RDS and Amazon MQ). In-cluster PostgreSQL and RabbitMQ are no longer supported.

## Troubleshooting

### Pods Not Starting

```bash
# Check events
kubectl get events -n hyperfleet-system --sort-by='.lastTimestamp'

# Check pod details
kubectl describe pod <pod-name> -n hyperfleet-system

# Check pod logs
kubectl logs <pod-name> -n hyperfleet-system
```

### Pod Identity / Secrets Mounting Issues

**Symptom**: `MountVolume.SetUp failed for volume 'db-secrets'`

```bash
# 1. Verify service account has role ARN annotation
kubectl get serviceaccount hyperfleet-api-sa -n hyperfleet-system -o yaml | grep role-arn

# Expected output:
#   eks.amazonaws.com/role-arn: arn:aws:iam::ACCOUNT:role/hyperfleet-api

# 2. Check Pod Identity associations in AWS
aws eks list-pod-identity-associations --cluster-name <cluster-name>

# 3. Verify SecretProviderClass exists
kubectl get secretproviderclass -n hyperfleet-system

# 4. Check CSI driver logs
kubectl logs -n kube-system -l app=secrets-store-csi-driver

# 5. Verify secrets exist in AWS Secrets Manager
aws secretsmanager list-secrets | grep hyperfleet

# 6. Test secret retrieval (from a pod with Pod Identity)
kubectl exec -n hyperfleet-system deployment/hyperfleet-api -- \
  ls -la /mnt/secrets-store/
# Should show: db.host, db.port, db.user, db.password, db.name
```

### Database Connection Issues

**Symptom**: `failed to connect to database` or `connection refused`

```bash
# 1. Verify RDS is running
aws rds describe-db-instances --db-instance-identifier <instance-id> \
  --query 'DBInstances[0].DBInstanceStatus'

# 2. Check if secrets are mounted correctly
kubectl exec -n hyperfleet-system deployment/hyperfleet-api -- \
  cat /mnt/secrets-store/db.host
# Should output: rds-endpoint.us-east-2.rds.amazonaws.com

# 3. Check API pod logs for connection errors
kubectl logs -n hyperfleet-system deployment/hyperfleet-api -c hyperfleet-api | grep -i database

# 4. Verify security group allows access from EKS
aws ec2 describe-security-groups --group-ids <rds-sg-id>

# 5. Test connection from within pod
kubectl exec -n hyperfleet-system deployment/hyperfleet-api -- \
  nc -zv $(cat /mnt/secrets-store/db.host) 5432
```

### RabbitMQ / Amazon MQ Connection Issues

**Symptom**: `cannot connect to AMQP` or `username or password not allowed`

```bash
# 1. Verify Amazon MQ broker is running
aws mq describe-broker --broker-id <broker-id> \
  --query 'BrokerState'

# 2. Check if MQ URL secret is correctly formatted
kubectl get secret hyperfleet-sentinel-mq-secret -n hyperfleet-system -o json | \
  jq -r '.data.BROKER_RABBITMQ_URL' | base64 --decode

# Expected format:
# amqps://username:PASSWORD@b-xxxxx.mq.us-east-2.on.aws:5671

# Common issues:
# - Duplicate protocol: amqps://...@amqps://... (WRONG)
# - Duplicate port: :5671:5671 (WRONG)
# - Unencoded special characters in password (? should be %3F)

# 3. Check Sentinel/Adapter logs for connection errors
kubectl logs -n hyperfleet-system deployment/hyperfleet-sentinel | grep -i rabbitmq
kubectl logs -n hyperfleet-system deployment/hyperfleet-adapter | grep -i rabbitmq

# 4. Verify exchange type matches (topic vs fanout)
# Error: "inequivalent arg 'type' for exchange"
# Solution: Ensure both Sentinel and Adapter use exchange_type: "topic"

# 5. Test AMQPS connectivity from pod
kubectl exec -n hyperfleet-system deployment/hyperfleet-sentinel -- \
  nc -zv <mq-endpoint> 5671
```

### Exchange Type Mismatch

**Symptom**: `PRECONDITION_FAILED - inequivalent arg 'type' for exchange`

This occurs when Sentinel creates an exchange as `topic` but Adapter tries to use it as `fanout` (or vice versa).

**Solution**:

1. Check broker ConfigMaps have `exchange_type: "topic"`:

   ```bash
   kubectl get configmap hyperfleet-sentinel-broker-config -n hyperfleet-system -o yaml | grep exchange_type
   kubectl get configmap hyperfleet-adapter-broker-config -n hyperfleet-system -o yaml | grep exchange_type
   ```

2. If missing or wrong, update values.yaml and sync

3. Delete and recreate the exchange in RabbitMQ Management Console, or delete all pods to recreate

### API Health Check

```bash
# Port-forward and test health endpoints
kubectl port-forward -n hyperfleet-system svc/hyperfleet-api 8000:8000 8080:8080

# Health check
curl http://localhost:8080/healthz
# Expected: HTTP 200

# Readiness check
curl http://localhost:8080/readyz
# Expected: HTTP 200

# List clusters (requires auth if JWT enabled)
curl http://localhost:8000/api/hyperfleet/v1/clusters
```

## Related Documentation

- **Terraform Infrastructure Module**: [terraform/modules/hyperfleet-infrastructure/README.md](../../../../terraform/modules/hyperfleet-infrastructure/README.md)
