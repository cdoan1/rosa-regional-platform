#!/bin/bash
set -euo pipefail

export AWS_PAGER=""

# LEASED_RESOURCE: region from cluster_profile lease (e.g. us-east-1)
# SECOND_AWS_ACCOUNT: region from additional lease (e.g. us-east-1)
# CLUSTER_PROFILE_DIR: directory containing .awscred and other cluster profile secrets

## ===============================
## Setup AWS Account 1

export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"
echo "Using credentials from cluster profile for Account 1"
echo "Leased resource (region): ${LEASED_RESOURCE}"

aws sts get-caller-identity
ACCT_ID_1=$(aws sts get-caller-identity --query Account --output text)
echo "Account 1 ID: ${ACCT_ID_1}"

echo "bootstrap the account to allow int-control account to assume into"

echo "Account 1 bootstrapped!"

## ===============================
## Setup AWS Account 2

export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred_second"
echo "Using credentials from cluster profile for Account 2"
echo "Second leased resource (region): ${SECOND_AWS_ACCOUNT}"

aws sts get-caller-identity
ACCT_ID_2=$(aws sts get-caller-identity --query Account --output text)
echo "Account 2 ID: ${ACCT_ID_2}"

echo "bootstrap the account to allow int-control account to assume into"

echo "Account 2 bootstrapped!"

## ===============================
## Region Provisioning Pipeline

# Switch back to primary credentials for pipeline orchestration
export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"

echo "call provision-new-region pipeline passing the two account IDs"

## how do we trigger the pipeline? SNS Topic publish? Direct AWS call?

# pseudocode:
#
# aws codepipeline start-pipeline-execution \
#   --name provision-new-region \
#   --variables \
#     name=regional-cluster-account-id,value=$ACCT_ID_1 \
#     name=management-cluster-account-id,value=$ACCT_ID_2 \
#     name=region,value=${LEASED_RESOURCE} \
#   --region ${LEASED_RESOURCE}

echo "waiting up to 1h for pipeline to provision..."
#...

echo "pipeline successfully provisioned!"

## ===============================
## Run any e2e tests

echo "running e2e tests..."
