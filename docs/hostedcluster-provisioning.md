# Provision a New Hosted Cluster

## Get the CLI

```bash
# Clone the repository
git clone https://github.com/openshift-online/rosa-regional-platform-cli.git
cd rosa-regional-platform-cli

# Build
make build

# Install globally (optional)
make install
```

## Set AWS account

```bash
# assume role into the customer acccount
# you can create hcp from any aws account, but just to ensure separation
# you can use the customer account
export AWS_PROFILE=rrp-customer-dev
```

## Using the rosactl command

```bash
# 1. set the reference to the platform api
rosactl login --url $API_URL

# 1. setup iam in the customer account
rosactl cluster-iam create cdoan-t1 --region us-east-1

# 2. setup vpc for the hosted cluster. Currently, we only support HCP with 1 az.
rosactl cluster-vpc create cdoan-t1 --region us-east-1 --availability-zones us-east-1a

# 3. submit the cluster creationt o the platform api
# --placement (required only in ephemeral environment)
PLACEMENT=$(awscurl --service execute-api $API_URL/api/v0/management_clusters | jq -r '.items[0].name')

rosactl cluster create cdoan-t1 --region us-east-1 --placement $PLACEMENT

# export CLOUDURL with the value of cloudUrl in the response above
# 4. create the oidc for the hcp
rosactl cluster-oidc create cdoan-t1 --region us-east-1 --oidc-issuer-url $CLOUDURL
```

# Notes

1. if you create more than 5 hcp, make sure your account has more than nat gateway quota. The default is 5.
