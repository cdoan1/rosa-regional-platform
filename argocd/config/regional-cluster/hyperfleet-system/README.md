# HyperFleet System

Unified Helm chart deploying all HyperFleet components into the `hyperfleet-system` namespace.

## Components

This chart deploys three main components:

1. **HyperFleet API** - REST API service with PostgreSQL backend
2. **HyperFleet Sentinel** - Polls API and publishes CloudEvents to RabbitMQ
3. **HyperFleet Adapter** - Consumes CloudEvents and creates Kubernetes resources

## Why Consolidated?

This chart consolidates three previously separate charts to avoid ArgoCD sync conflicts when multiple applications deploy to the same namespace.

## Configuration

All components are configured under their respective keys in `values.yaml`:

```yaml
# Global namespace (all components deploy here)
namespace: hyperfleet-system

# API configuration
hyperfleetApi:
  replicaCount: 1
  image:
    registry: quay.io/cdoan0
    repository: hyperfleet-api
    tag: "latest"
  database:
    postgresql:
      enabled: true
      password: "CHANGE_FOR_PRODUCTION"

# Sentinel configuration
hyperfleetSentinel:
  replicaCount: 1
  config:
    resourceType: clusters
    pollInterval: 5s
  broker:
    rabbitmq:
      url: "amqp://hyperfleet:password@rabbitmq.rabbitmq.svc.cluster.local:5672/"

# Adapter configuration
hyperfleetAdapter:
  replicaCount: 1
  rbac:
    create: true
    resources:
      - namespaces
      - serviceaccounts
```

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

## Dependencies

This chart depends on:
- **RabbitMQ** (deployed separately in `rabbitmq` namespace)

## Verification

```bash
# Check all pods
kubectl get pods -n hyperfleet-system

# Expected output:
# hyperfleet-api-xxx                1/1     Running
# hyperfleet-api-postgresql-xxx     1/1     Running
# hyperfleet-sentinel-xxx           1/1     Running
# hyperfleet-adapter-xxx            1/1     Running

# Test API health
kubectl port-forward -n hyperfleet-system svc/hyperfleet-api 8080:8080
curl http://localhost:8080/healthz

# View logs
kubectl logs -n hyperfleet-system -l app.kubernetes.io/name=hyperfleet-api
kubectl logs -n hyperfleet-system -l app.kubernetes.io/name=hyperfleet-sentinel
kubectl logs -n hyperfleet-system -l app.kubernetes.io/name=hyperfleet-adapter
```

## End-to-End Test

```bash
# 1. Create a cluster via API
kubectl port-forward -n hyperfleet-system svc/hyperfleet-api 8000:8000 &

curl -X POST http://localhost:8000/api/hyperfleet/v1/clusters \
  -H "Content-Type: application/json" \
  -d '{
    "kind": "Cluster",
    "name": "test-cluster",
    "spec": {
      "region": "us-east-1",
      "version": "4.14.0"
    }
  }'

# 2. Watch Sentinel detect and publish event
kubectl logs -f -n hyperfleet-system -l app.kubernetes.io/name=hyperfleet-sentinel

# 3. Watch Adapter consume event
kubectl logs -f -n hyperfleet-system -l app.kubernetes.io/name=hyperfleet-adapter

# 4. Verify namespace created
kubectl get namespaces | grep test-cluster
```

## Production Considerations

Before deploying to production:

1. **Change Passwords**:
   - PostgreSQL: `hyperfleetApi.database.postgresql.password`
   - RabbitMQ: Update URLs in `hyperfleetSentinel.broker.rabbitmq.url` and `hyperfleetAdapter.broker.rabbitmq.url`

2. **Use Specific Image Tags**:
   ```yaml
   hyperfleetApi:
     image:
       tag: "v1.0.0"  # Not "latest"
   ```

3. **Enable External Database**:
   ```yaml
   hyperfleetApi:
     database:
       postgresql:
         enabled: false
       external:
         enabled: true
         secretName: "rds-credentials"
   ```

4. **Enable Monitoring**:
   ```yaml
   hyperfleetApi:
     serviceMonitor:
       enabled: true
   ```

5. **Configure Resource Limits** based on observed usage

## Migration from Separate Charts

If migrating from the old separate charts:

1. Delete old ArgoCD applications:
   ```bash
   kubectl delete application hyperfleet-api -n argocd
   kubectl delete application hyperfleet-sentinel -n argocd
   kubectl delete application hyperfleet-adapter -n argocd
   ```

2. Deploy consolidated chart (pods will be recreated seamlessly)

3. Verify all components are running

## Troubleshooting

### Pods Not Starting

```bash
# Check events
kubectl get events -n hyperfleet-system --sort-by='.lastTimestamp'

# Check pod details
kubectl describe pod <pod-name> -n hyperfleet-system
```

### API Connection Issues

```bash
# Verify service DNS
kubectl run -it --rm debug --image=busybox --restart=Never -- \
  nslookup hyperfleet-api.hyperfleet-system.svc.cluster.local
```

### RabbitMQ Connection Issues

```bash
# Verify RabbitMQ is accessible
kubectl run -it --rm debug --image=busybox --restart=Never -- \
  nc -zv rabbitmq.rabbitmq.svc.cluster.local 5672
```

## Support

For issues or questions, see:
- Main documentation: `HYPERFLEET_DEPLOYMENT_STATUS.md`
- Validation scripts: `scripts/validate-hyperfleet.sh`
