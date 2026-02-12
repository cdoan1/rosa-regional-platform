# HyperFleet System Helm Chart

This Helm chart deploys the complete HyperFleet cluster lifecycle management system to the Regional Cluster.

## Components

All components are deployed in the `hyperfleet-system` namespace:

### Infrastructure
- **PostgreSQL** - Database for HyperFleet API (StatefulSet with PVC)
- **RabbitMQ** - Message broker for event distribution (StatefulSet with PVC)

### HyperFleet Services
- **HyperFleet API** - REST API for cluster/nodepool management (2 replicas)
- **HyperFleet Sentinel** - Polling service that publishes events (1 replica)
- **HyperFleet Adapter** - Event consumer that processes cluster operations (2 replicas)

## Architecture

```
Sentinel (polls every 5s) → HyperFleet API → PostgreSQL
                                 ↓
                           CloudEvents
                                 ↓
                            RabbitMQ
                                 ↓
                         Adapter (consumes)
                                 ↓
                    Maestro + Status Updates
```

## Configuration

### Default Values

See `values.yaml` for all configuration options. Key settings:

- **Namespace**: `hyperfleet-system`
- **Storage Class**: `gp3` (EBS volumes)
- **PostgreSQL**: 20Gi persistent volume
- **RabbitMQ**: 10Gi persistent volume
- **API Replicas**: 2
- **Adapter Replicas**: 2
- **Sentinel Replicas**: 1

### Service Discovery

All components use same-namespace DNS for communication:
- PostgreSQL: `postgresql.hyperfleet-system.svc.cluster.local:5432`
- RabbitMQ: `rabbitmq.hyperfleet-system.svc.cluster.local:5672`
- HyperFleet API: `hyperfleet-api.hyperfleet-system.svc.cluster.local:8000`

### Secrets

Auto-generated secrets (using random passwords):
- `postgresql-credentials` - PostgreSQL username/password/database
- `rabbitmq-credentials` - RabbitMQ username/password/erlang-cookie

## Deployment

### Via ArgoCD (Recommended)

The chart is automatically discovered by ArgoCD's ApplicationSet:

1. Commit chart to git repository
2. ArgoCD detects new directory via git generator
3. ArgoCD creates Application `hyperfleet-system`
4. Application syncs and deploys all resources

### Manual Deployment

```bash
# Install chart
helm install hyperfleet-system . -n hyperfleet-system --create-namespace

# Upgrade chart
helm upgrade hyperfleet-system . -n hyperfleet-system

# Uninstall chart
helm uninstall hyperfleet-system -n hyperfleet-system
```

## Verification

### Check All Pods Running

```bash
kubectl get pods -n hyperfleet-system

# Expected:
# postgresql-0                        1/1     Running
# rabbitmq-0                          1/1     Running
# hyperfleet-api-xxx                  1/1     Running
# hyperfleet-api-yyy                  1/1     Running
# hyperfleet-sentinel-xxx             1/1     Running
# hyperfleet-adapter-xxx              1/1     Running
# hyperfleet-adapter-yyy              1/1     Running
```

### Check Services

```bash
kubectl get svc -n hyperfleet-system
```

### Test PostgreSQL

```bash
kubectl logs -n hyperfleet-system postgresql-0
# Should show: "database system is ready to accept connections"

kubectl exec -it -n hyperfleet-system postgresql-0 -- psql -U hyperfleet -c '\l'
# Should list 'hyperfleet' database
```

### Test RabbitMQ

```bash
kubectl logs -n hyperfleet-system rabbitmq-0
# Should show: "Server startup complete"

# Port-forward management UI
kubectl port-forward -n hyperfleet-system svc/rabbitmq 15672:15672
# Open http://localhost:15672 (credentials in rabbitmq-credentials secret)
```

### Test HyperFleet API

```bash
kubectl logs -n hyperfleet-system deployment/hyperfleet-api

# Port-forward API
kubectl port-forward -n hyperfleet-system svc/hyperfleet-api 8000:8000

# Test API endpoint
curl http://localhost:8000/api/v1/clusters
# Should return: {"items":[],"total":0}
```

### Test Sentinel

```bash
kubectl logs -n hyperfleet-system deployment/hyperfleet-sentinel -f

# Look for:
# - "connected to broker"
# - "polling clusters"
# - "published event to topic hyperfleet-cluster-events"
```

### Test Adapter

```bash
kubectl logs -n hyperfleet-system deployment/hyperfleet-adapter -f

# Look for:
# - "subscribed to queue hyperfleet-adapter-queue"
# - "listening for events"
# - "connected to HyperFleet API"
```

## End-to-End Test

```bash
# 1. Port-forward API
kubectl port-forward -n hyperfleet-system svc/hyperfleet-api 8000:8000 &

# 2. Create test cluster
curl -X POST http://localhost:8000/api/v1/clusters \
  -H "Content-Type: application/json" \
  -d '{
    "name": "test-cluster-1",
    "region": "us-east-2",
    "version": "4.14.0"
  }'

# 3. Watch Sentinel logs (should detect and publish event)
kubectl logs -n hyperfleet-system -f deployment/hyperfleet-sentinel

# 4. Watch Adapter logs (should consume and process event)
kubectl logs -n hyperfleet-system -f deployment/hyperfleet-adapter

# 5. Check RabbitMQ queue
kubectl exec -it -n hyperfleet-system rabbitmq-0 -- rabbitmqctl list_queues
```

## Customization

### Per-Region Overrides

Edit `argocd/config.yaml` to add shard-specific overrides:

```yaml
shards:
  - region: "us-east-2"
    environment: "integration"
    values:
      regional-cluster:
        hyperfleetSystem:
          api:
            replicas: 3  # More replicas in this region
          sentinel:
            config:
              pollInterval: 10s  # Slower polling
```

Then run the renderer:

```bash
cd argocd
./scripts/render.py
git add rendered/
git commit -m "Update HyperFleet overrides"
```

## Monitoring

All components expose metrics on port 9090:

```bash
# API metrics
kubectl port-forward -n hyperfleet-system svc/hyperfleet-api 9090:9090
curl http://localhost:9090/metrics

# RabbitMQ metrics
kubectl port-forward -n hyperfleet-system svc/rabbitmq 15692:15692
curl http://localhost:15692/metrics
```

## Troubleshooting

### Pods Not Starting

Check events:
```bash
kubectl get events -n hyperfleet-system --sort-by='.lastTimestamp'
```

### Database Connection Issues

Check PostgreSQL logs:
```bash
kubectl logs -n hyperfleet-system postgresql-0
```

Test connection from API pod:
```bash
kubectl exec -it -n hyperfleet-system deployment/hyperfleet-api -- \
  psql "postgresql://hyperfleet:password@postgresql.hyperfleet-system.svc.cluster.local:5432/hyperfleet?sslmode=disable"
```

### RabbitMQ Connection Issues

Check RabbitMQ logs:
```bash
kubectl logs -n hyperfleet-system rabbitmq-0
```

Check queue status:
```bash
kubectl exec -it -n hyperfleet-system rabbitmq-0 -- rabbitmqctl list_queues
kubectl exec -it -n hyperfleet-system rabbitmq-0 -- rabbitmqctl list_exchanges
```

### API Migration Failures

Check init container logs:
```bash
kubectl logs -n hyperfleet-system deployment/hyperfleet-api -c db-migrate
```

## Future Enhancements

- [ ] High availability PostgreSQL (multi-replica)
- [ ] High availability RabbitMQ (multi-replica with clustering)
- [ ] Migration to Amazon RDS
- [ ] Migration to Amazon MQ
- [ ] External Secrets Operator integration
- [ ] ServiceMonitor for Prometheus
- [ ] HorizontalPodAutoscaler for Adapter
- [ ] Backup/restore with Velero
