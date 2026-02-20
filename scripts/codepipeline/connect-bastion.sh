#!/bin/bash
#
# From the regional cluster account, 
# connect to the bastion ECS task
# to access the regional cluster
#
set -euo pipefail

function create_ecs_task_command() {
  local cluster=$1
  
  aws ecs run-task \
    --cluster $cluster \
    --task-definition $cluster \
    --launch-type FARGATE \
    --enable-execute-command \
    --network-configuration 'awsvpcConfiguration={subnets=[subnet-044a31dd1e91a9655,subnet-08ab393004fc41a12,subnet-02189a8443a6409cf],securityGroups=[sg-0743322c001a7e0a8],assignPublicIp=DISABLED}'
}

CLUSTER=$(aws ecs list-clusters --query 'clusterArns[0]' --output text | awk -F'/' '{print $NF}')
TASK_ID=$(aws ecs list-tasks --cluster $CLUSTER --query 'taskArns[0]' --output text | awk -F'/' '{print $NF}')

if [[ -z "$TASK_ID" || "$TASK_ID" == "None" || "$TASK_ID" == "null" ]]; then
  echo "Error: Try 1: No task found for cluster $CLUSTER"
  create_ecs_task_command $CLUSTER
  sleep 60
  TASK_ID=$(aws ecs list-tasks --cluster $CLUSTER --query 'taskArns[0]' --output text | awk -F'/' '{print $NF}')
  if [[ -z "$TASK_ID" || "$TASK_ID" == "None" || "$TASK_ID" == "null" ]]; then
    echo "Error: Try 2: No task found for cluster $CLUSTER"
    exit 1
  fi
fi

echo "Cluster: $CLUSTER"
echo "Task ID: $TASK_ID"
echo "Connecting to bastion..."

aws ecs execute-command \
--cluster $CLUSTER \
--task $TASK_ID \
--container bastion \
--interactive \
--command '/bin/bash'
