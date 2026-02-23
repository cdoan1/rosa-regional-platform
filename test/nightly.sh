#!/bin/bash

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
export AWS_PAGER=""

## None of this will work now. This is purely a stub to give an idea
## of how this will work

## ===============================
## Setup AWS Account 1

export AWS_PROFILE=aws-acct-1
echo "Using AWS Profile $AWS_PROFILE"

aws sts get-caller-identity

echo "bootstrap the account to allow int-control account to assume into"

echo "Account 1 bootstrapped!"

## ===============================
## Setup AWS Account 2

export AWS_PROFILE=aws-acct-2
echo "Using AWS Profile $AWS_PROFILE"

aws sts get-caller-identity

echo "bootstrap the account to allow int-control account to assume into"

echo "Account 2 bootstrapped!"


## ===============================
## Region Provisioning Pipeline

unset AWS_PROFILE
# from here on we want to use the prow CI credentials

echo "call provision-new-region pipeline passing the two account IDs"

## how do we trigger the pipeline? SNS Topic publish? Direct AWS call?

# pseudocode:
#
# aws codepipeline start-pipeline-execution \
#   --name provision-new-region \
#   --variables \
#     name=regional-cluster-account-id,value=$ACCT_ID_1 \
#     name=management-cluster-account-id,value=$ACCT_ID_2 \
#     name=region,value=us-east-1 \
#   --region us-east-1

echo "waiting up to 1h for pipeline to provision..."
#...

echo "pipeline successfully provisioned!"

## ===============================
## Run any e2e tests

echo "running e2e tests..."
