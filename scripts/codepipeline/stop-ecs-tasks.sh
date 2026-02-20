#!/bin/bash
set -euo pipefail
#
# stop-ecs-tasks.sh - Stop all running bastion ECS tasks
#
# This script stops all running bastion ECS tasks in the target account and region.
# It is used to ensure clean teardown before Terraform destroy.
#
# Usage:
#   ./scripts/codepipeline/stop-ecs-tasks.sh <target-account-id> <target-region>
#
# Required Environment Variables:
#   TARGET_ACCOUNT_ID - The target AWS account ID
#   TARGET_REGION - The target AWS region
#   CENTRAL_ACCOUNT_ID - The central AWS account ID
#
# Exports:
#   AWS_ACCESS_KEY_ID - The target AWS account credentials
#   AWS_SECRET_ACCESS_KEY - The target AWS account credentials
#   AWS_SESSION_TOKEN - The target AWS account credentials


echo "=========================================="
echo "Stopping Bastion ECS Tasks"
echo "=========================================="
echo ""
echo "Stopping all running bastion ECS tasks in account ${TARGET_ACCOUNT_ID}, region ${TARGET_REGION}..."
echo "This ensures clean teardown before Terraform destroy."
echo ""

# Assume role in target account if needed
if [ "$TARGET_ACCOUNT_ID" != "$CENTRAL_ACCOUNT_ID" ]; then
    echo "Assuming role in target account ${TARGET_ACCOUNT_ID}..."
    ASSUMED_ROLE_ARN="arn:aws:iam::${TARGET_ACCOUNT_ID}:role/OrganizationAccountAccessRole"
    ASSUMED_CREDS=$(aws sts assume-role \
        --role-arn "$ASSUMED_ROLE_ARN" \
        --role-session-name "ecs-cleanup-$(date +%s)" \
        --query 'Credentials.[AccessKeyId,SecretAccessKey,SessionToken]' \
        --output text)

    if [ -z "$ASSUMED_CREDS" ] || [ "$ASSUMED_CREDS" == "None" ]; then
        echo "⚠️  Warning: Could not assume role in target account, skipping ECS cleanup"
        echo "   This may cause destroy to fail if bastion tasks are running"
    else
        read -r AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN <<< "$ASSUMED_CREDS"
        export AWS_ACCESS_KEY_ID
        export AWS_SECRET_ACCESS_KEY
        export AWS_SESSION_TOKEN
        echo "✅ Assumed role successfully"
    fi
fi

# Set region for AWS CLI
export AWS_DEFAULT_REGION="${TARGET_REGION}"
export AWS_REGION="${TARGET_REGION}"

# List all ECS clusters in the region and filter for bastion clusters
echo "Listing ECS clusters (filtering for bastion clusters ending with '-bastion')..."
ALL_CLUSTERS=$(aws ecs list-clusters --region "${TARGET_REGION}" --query 'clusterArns[]' --output text 2>/dev/null || echo "")

BASTION_FOUND=0

if [ -z "$ALL_CLUSTERS" ] || [ "$ALL_CLUSTERS" == "None" ]; then
    echo "✓ No ECS clusters found in region ${TARGET_REGION}"
else
    # Iterate through all clusters and process only bastion clusters
    for CLUSTER_ARN in $ALL_CLUSTERS; do
        if [ -n "$CLUSTER_ARN" ] && [ "$CLUSTER_ARN" != "None" ]; then
            CLUSTER_NAME=$(echo "$CLUSTER_ARN" | awk -F'/' '{print $NF}')
            
            # Only process clusters ending with "-bastion"
            if [[ "$CLUSTER_NAME" == *"-bastion" ]]; then
                BASTION_FOUND=1
                echo "Found bastion cluster: $CLUSTER_NAME"

                # List running tasks in this bastion cluster
                RUNNING_TASKS=$(aws ecs list-tasks \
                    --cluster "$CLUSTER_NAME" \
                    --desired-status RUNNING \
                    --region "${TARGET_REGION}" \
                    --query 'taskArns[]' \
                    --output text 2>/dev/null || echo "")

                if [ -n "$RUNNING_TASKS" ] && [ "$RUNNING_TASKS" != "None" ]; then
                    echo "  Stopping running bastion tasks..."
                    for TASK_ARN in $RUNNING_TASKS; do
                        if [ -n "$TASK_ARN" ] && [ "$TASK_ARN" != "None" ]; then
                            TASK_ID=$(echo "$TASK_ARN" | awk -F'/' '{print $NF}')
                            echo "    Stopping bastion task: $TASK_ID"
                            aws ecs stop-task \
                                --cluster "$CLUSTER_NAME" \
                                --task "$TASK_ARN" \
                                --reason "Terraform destroy - stopping bastion tasks before infrastructure teardown" \
                                --region "${TARGET_REGION}" \
                                2>/dev/null || echo "      ⚠️  Failed to stop task $TASK_ID"
                        fi
                    done

                    # Wait a moment for tasks to start stopping
                    echo "  Waiting for bastion tasks to stop..."
                    sleep 5

                    # Wait for all tasks to be stopped (with timeout)
                    MAX_WAIT=120
                    WAIT_TIME=0
                    while [ $WAIT_TIME -lt $MAX_WAIT ]; do
                        REMAINING_TASKS=$(aws ecs list-tasks \
                            --cluster "$CLUSTER_NAME" \
                            --desired-status RUNNING \
                            --region "${TARGET_REGION}" \
                            --query 'taskArns[]' \
                            --output text 2>/dev/null || echo "")

                        if [ -z "$REMAINING_TASKS" ] || [ "$REMAINING_TASKS" == "None" ]; then
                            echo "  ✓ All bastion tasks stopped"
                            break
                        fi

                        echo "  Waiting for bastion tasks to stop... ($WAIT_TIME/$MAX_WAIT seconds)"
                        sleep 5
                        WAIT_TIME=$((WAIT_TIME + 5))
                    done

                    if [ $WAIT_TIME -ge $MAX_WAIT ]; then
                        echo "  ⚠️  Warning: Some bastion tasks may still be running after timeout"
                        echo "  Continuing with destroy..."
                    fi
                else
                    echo "  ✓ No running bastion tasks found"
                fi
            fi
        fi
    done

    if [ $BASTION_FOUND -eq 0 ]; then
        echo "✓ No bastion ECS clusters found (clusters ending with '-bastion')"
    fi
fi

echo ""
echo "✓ Bastion ECS task cleanup complete"
echo ""