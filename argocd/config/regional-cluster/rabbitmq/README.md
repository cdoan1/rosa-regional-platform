# RabbitMQ Message Broker

RabbitMQ message broker for distributing HyperFleet CloudEvents between Sentinel and Adapters.

## Overview

This Helm chart deploys a single RabbitMQ instance with:
- AMQP protocol on port 5672 (message distribution)
- Management UI on port 15672 (monitoring and admin)

## Configuration

### Key Values

```yaml
rabbitmq:
  namespace: rabbitmq
  enabled: true

  image:
    repository: rabbitmq
    tag: 3-management

  auth:
    username: hyperfleet
    password: "CHANGE_ME"  # Change for production
```

## Connection URL

Components can connect using:
```
amqp://hyperfleet:hyperfleet-dev-password@rabbitmq.rabbitmq.svc.cluster.local:5672/
```

## Management UI

Access the management UI for monitoring:

```bash
kubectl port-forward -n rabbitmq svc/rabbitmq 15672:15672
# Open browser: http://localhost:15672
# Login: hyperfleet / hyperfleet-dev-password
```

## Verification

```bash
# Check pod status
kubectl get pods -n rabbitmq

# Test AMQP connectivity
kubectl port-forward -n rabbitmq svc/rabbitmq 5672:5672 &
nc -zv localhost 5672

# View logs
kubectl logs -n rabbitmq -l app.kubernetes.io/name=rabbitmq --tail=30
```

## Production Considerations

1. **Password**: Use proper secrets management
2. **Managed Service**: Consider AWS MQ for managed RabbitMQ
3. **TLS**: Enable TLS for AMQP connections
4. **Persistence**: Add persistent volume for message durability
5. **High Availability**: Deploy RabbitMQ cluster with multiple replicas
6. **Monitoring**: Enable Prometheus metrics export

## Dependencies

This must be deployed before:
- HyperFleet Sentinel (publishes events)
- HyperFleet Adapters (consume events)
