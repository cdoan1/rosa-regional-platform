# Bastion

In ROSA Regionality Platform, the Regional Cluster and the Management Cluster are private. The only access to them will happen through ZOA processes.

This module creates an **ECS Fargate bastion task definition** that can be used to launch ephemeral bastion containers for accessing private EKS clusters. The bastion shares the ECS cluster created by the `ecs-bootstrap` module. This bastion should only be leveraged in the following scenarios:

- Emergency break-glass access to the Regional or Management Cluster (note that this is a temporary solution for break-glass that is not adequate since it has no auditing, etc.).
- Development purposes where a developer needs to access the Regional or Management Cluster for debugging purposes.

## Architecture

The bastion uses **ECS Fargate** with **ECS Exec** (built on SSM) for shell access. It creates a dedicated ECS cluster with ECS Exec enabled for session logging.

## Enabling the Bastion

The bastion is disabled by default. To enable it, set `enable_bastion: true` in your environment's config under `terraform_vars`:

```yaml
# config/environments/<env>.config.yaml
terraform_vars:
  enable_bastion: true
```

Then run `scripts/render.py` and apply the configuration via the provisioning pipeline (or manually via `terraform apply`).

## Requirements

Install the **Session Manager plugin** for AWS CLI: [documentation](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html)

## Pre-installed Tools

The bastion container includes a full SRE toolkit:

- **kubectl** - Kubernetes CLI
- **helm** - Kubernetes package manager
- **aws** - AWS CLI v2
- **k9s** - Terminal UI for Kubernetes
- **stern** - Multi-pod log tailing
- **oc** - OpenShift CLI
- **jq** / **yq** - JSON/YAML processors
- Standard utilities: git, vim, less, dig, etc.

The tools are installed at container startup and may take ~60 seconds to become available after connecting.

## Usage

### Prerequisites

Initialize the Terraform backend against remote state (from the repo root):

```bash
# Authenticate to the target AWS account, then:
scripts/dev/init-remote-backend.sh regional <environment> [region]

# Region is optional — defaults to the AWS CLI configured region.
# e.g. scripts/dev/init-remote-backend.sh regional integration
# e.g. scripts/dev/init-remote-backend.sh regional integration us-east-1
```

### Connect to the bastion

```bash
scripts/dev/bastion-connect.sh regional    # or: management
```

This starts a bastion ECS task (if not already running), waits for it to be ready, and opens an interactive shell. The bastion is pre-configured with kubectl access to the EKS cluster:

```bash
bash-5.2$ kubectl get namespaces
NAME              STATUS   AGE
argocd            Active   76m
default           Active   84m
kube-system       Active   84m
```

NOTE: If `kubectl: command not found`, wait a minute for tool installation to complete.

### Port-forward to Kubernetes services

```bash
# Interactive mode (requires fzf)
scripts/dev/bastion-port-forward.sh

# Or specify service and cluster type directly:
scripts/dev/bastion-port-forward.sh argocd regional
scripts/dev/bastion-port-forward.sh maestro regional
scripts/dev/bastion-port-forward.sh argocd management
```

The script handles the full two-hop chain automatically:

1. Starts/reuses a bastion ECS task
2. Runs `kubectl port-forward` inside the bastion (bastion -> K8s service)
3. Starts SSM port forwarding (laptop -> bastion)

For ArgoCD, it also fetches and displays the admin password.

### Stop when done

Stop the task when finished to avoid ongoing costs.

> **Cost note**: Fargate tasks are billed per-second while running (~$0.02/hour for this config).

```bash
CLUSTER=$(cd terraform/config/regional-cluster && terraform output -raw bastion_ecs_cluster_name)
TASK_ID=$(aws ecs list-tasks --cluster $CLUSTER --query 'taskArns[0]' --output text | awk -F'/' '{print $NF}')
aws ecs stop-task --cluster $CLUSTER --task $TASK_ID
```

## Troubleshooting

### Logs

View container logs to debug startup issues or check tool installation progress:

```bash
cd terraform/config/regional-cluster  # or management-cluster

# Tail logs (follow mode)
aws logs tail $(terraform output -raw bastion_log_group_name) --follow --since 5m

# Wait for bastion to be ready
aws logs tail $(terraform output -raw bastion_log_group_name) --follow --since 1m | grep -m1 "Bastion ready"
```

### Bastion not available

If bastion outputs are `null`, ensure `enable_bastion: true` is set in your config's `terraform_vars` and the infrastructure has been applied.
