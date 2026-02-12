#!/bin/bash
# HyperFleet System Verification Script
#
# This script verifies that all HyperFleet components are deployed and healthy.

set -e

NAMESPACE="hyperfleet-system"
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo "========================================="
echo "HyperFleet System Verification"
echo "========================================="
echo ""

# Check if namespace exists
echo "1. Checking namespace..."
if kubectl get namespace $NAMESPACE &> /dev/null; then
    echo -e "${GREEN}✓ Namespace $NAMESPACE exists${NC}"
else
    echo -e "${RED}✗ Namespace $NAMESPACE does not exist${NC}"
    exit 1
fi
echo ""

# Check all pods are running
echo "2. Checking pods..."
kubectl get pods -n $NAMESPACE

EXPECTED_PODS=7
RUNNING_PODS=$(kubectl get pods -n $NAMESPACE --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l | tr -d ' ')

if [ "$RUNNING_PODS" -eq "$EXPECTED_PODS" ]; then
    echo -e "${GREEN}✓ All $EXPECTED_PODS pods are running${NC}"
else
    echo -e "${YELLOW}⚠ Expected $EXPECTED_PODS pods, found $RUNNING_PODS running${NC}"
fi
echo ""

# Check services
echo "3. Checking services..."
kubectl get svc -n $NAMESPACE
echo ""

# Check PostgreSQL
echo "4. Checking PostgreSQL..."
if kubectl logs -n $NAMESPACE postgresql-0 --tail=10 2>/dev/null | grep -q "database system is ready"; then
    echo -e "${GREEN}✓ PostgreSQL is ready${NC}"
else
    echo -e "${YELLOW}⚠ PostgreSQL may not be ready yet${NC}"
fi
echo ""

# Check RabbitMQ
echo "5. Checking RabbitMQ..."
if kubectl logs -n $NAMESPACE rabbitmq-0 --tail=20 2>/dev/null | grep -q "Server startup complete"; then
    echo -e "${GREEN}✓ RabbitMQ is ready${NC}"
else
    echo -e "${YELLOW}⚠ RabbitMQ may not be ready yet${NC}"
fi
echo ""

# Check HyperFleet API
echo "6. Checking HyperFleet API..."
API_PODS=$(kubectl get pods -n $NAMESPACE -l app.kubernetes.io/component=api --no-headers 2>/dev/null | wc -l | tr -d ' ')
if [ "$API_PODS" -ge 2 ]; then
    echo -e "${GREEN}✓ HyperFleet API has $API_PODS pods${NC}"
else
    echo -e "${YELLOW}⚠ HyperFleet API has $API_PODS pods (expected 2)${NC}"
fi
echo ""

# Check Sentinel
echo "7. Checking Sentinel..."
SENTINEL_PODS=$(kubectl get pods -n $NAMESPACE -l app.kubernetes.io/component=sentinel --no-headers 2>/dev/null | wc -l | tr -d ' ')
if [ "$SENTINEL_PODS" -ge 1 ]; then
    echo -e "${GREEN}✓ Sentinel has $SENTINEL_PODS pod(s)${NC}"
else
    echo -e "${RED}✗ Sentinel has no pods${NC}"
fi
echo ""

# Check Adapter
echo "8. Checking Adapter..."
ADAPTER_PODS=$(kubectl get pods -n $NAMESPACE -l app.kubernetes.io/component=adapter --no-headers 2>/dev/null | wc -l | tr -d ' ')
if [ "$ADAPTER_PODS" -ge 2 ]; then
    echo -e "${GREEN}✓ Adapter has $ADAPTER_PODS pods${NC}"
else
    echo -e "${YELLOW}⚠ Adapter has $ADAPTER_PODS pods (expected 2)${NC}"
fi
echo ""

# Check ArgoCD Application
echo "9. Checking ArgoCD Application..."
if kubectl get application hyperfleet-system -n argocd &> /dev/null; then
    APP_STATUS=$(kubectl get application hyperfleet-system -n argocd -o jsonpath='{.status.sync.status}')
    APP_HEALTH=$(kubectl get application hyperfleet-system -n argocd -o jsonpath='{.status.health.status}')

    if [ "$APP_STATUS" == "Synced" ] && [ "$APP_HEALTH" == "Healthy" ]; then
        echo -e "${GREEN}✓ ArgoCD Application is Synced and Healthy${NC}"
    else
        echo -e "${YELLOW}⚠ ArgoCD Application status: $APP_STATUS, health: $APP_HEALTH${NC}"
    fi
else
    echo -e "${YELLOW}⚠ ArgoCD Application 'hyperfleet-system' not found${NC}"
fi
echo ""

# Summary
echo "========================================="
echo "Verification Summary"
echo "========================================="
echo "Namespace: $NAMESPACE"
echo "Pods Running: $RUNNING_PODS / $EXPECTED_PODS"
echo ""
echo "Next Steps:"
echo "  1. Check logs: kubectl logs -n $NAMESPACE <pod-name>"
echo "  2. Port-forward API: kubectl port-forward -n $NAMESPACE svc/hyperfleet-api 8000:8000"
echo "  3. Test API: curl http://localhost:8000/api/v1/clusters"
echo "  4. View RabbitMQ UI: kubectl port-forward -n $NAMESPACE svc/rabbitmq 15672:15672"
echo ""
