# Adapter-Lambda IAM Configuration: Technical Implementation Guide

This document provides the technical implementation details for configuring IAM roles, policies, and trust relationships required for the adapter-lambda infrastructure provisioning flow.

## Architecture Overview

The adapter-lambda flow involves two AWS accounts with cross-account access:

1. **Regional Platform Account**: Runs the Regional Cluster with the adapter service
2. **Customer Account**: Hosts Lambda functions that create cluster infrastructure

## Prerequisites

- Regional Platform AWS Account ID (example: `111111111111`)
- Customer AWS Account ID (example: `222222222222`)
- AWS Region (example: `us-east-1`)
- EKS Cluster name in Regional Platform Account (example: `rosa-regional-cluster`)

---

## Customer Account IAM Configuration

### 1. Lambda Execution Role (One per Lambda Function)

Three Lambda execution roles are required, one for each infrastructure provisioning Lambda function.

#### 1.1 cluster-iam Lambda Execution Role

**Role Name**: `rosa-lambda-cluster-iam-execution-role`

**Trust Policy**:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "lambda.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
```

**Permissions Policy**:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "CloudWatchLogsAccess",
      "Effect": "Allow",
      "Action": [
        "logs:CreateLogGroup",
        "logs:CreateLogStream",
        "logs:PutLogEvents"
      ],
      "Resource": "arn:aws:logs:*:*:*"
    },
    {
      "Sid": "CloudFormationAccess",
      "Effect": "Allow",
      "Action": [
        "cloudformation:CreateStack",
        "cloudformation:UpdateStack",
        "cloudformation:DeleteStack",
        "cloudformation:DescribeStacks",
        "cloudformation:DescribeStackEvents",
        "cloudformation:DescribeStackResources",
        "cloudformation:GetTemplate",
        "cloudformation:ValidateTemplate"
      ],
      "Resource": "arn:aws:cloudformation:*:*:stack/rosa-*-iam/*"
    },
    {
      "Sid": "IAMRoleManagement",
      "Effect": "Allow",
      "Action": [
        "iam:CreateRole",
        "iam:DeleteRole",
        "iam:GetRole",
        "iam:UpdateRole",
        "iam:UpdateAssumeRolePolicy",
        "iam:PutRolePolicy",
        "iam:DeleteRolePolicy",
        "iam:GetRolePolicy",
        "iam:AttachRolePolicy",
        "iam:DetachRolePolicy",
        "iam:ListAttachedRolePolicies",
        "iam:ListRolePolicies",
        "iam:TagRole",
        "iam:UntagRole"
      ],
      "Resource": [
        "arn:aws:iam::*:role/rosa-*-ingress",
        "arn:aws:iam::*:role/rosa-*-cloud-controller-manager",
        "arn:aws:iam::*:role/rosa-*-ebs-csi",
        "arn:aws:iam::*:role/rosa-*-image-registry",
        "arn:aws:iam::*:role/rosa-*-network-config",
        "arn:aws:iam::*:role/rosa-*-control-plane-operator",
        "arn:aws:iam::*:role/rosa-*-node-pool-management",
        "arn:aws:iam::*:role/rosa-*-ROSA-Worker-Role"
      ]
    },
    {
      "Sid": "IAMInstanceProfileManagement",
      "Effect": "Allow",
      "Action": [
        "iam:CreateInstanceProfile",
        "iam:DeleteInstanceProfile",
        "iam:GetInstanceProfile",
        "iam:AddRoleToInstanceProfile",
        "iam:RemoveRoleFromInstanceProfile",
        "iam:TagInstanceProfile",
        "iam:UntagInstanceProfile"
      ],
      "Resource": "arn:aws:iam::*:instance-profile/rosa-*-ROSA-Worker-Role"
    },
    {
      "Sid": "IAMPolicyReadAccess",
      "Effect": "Allow",
      "Action": [
        "iam:GetPolicy",
        "iam:GetPolicyVersion",
        "iam:ListPolicyVersions"
      ],
      "Resource": [
        "arn:aws:iam::*:policy/service-role/ROSA*",
        "arn:aws:iam::aws:policy/ROSA*"
      ]
    },
    {
      "Sid": "PassRoleForCloudFormation",
      "Effect": "Allow",
      "Action": "iam:PassRole",
      "Resource": "*",
      "Condition": {
        "StringEquals": {
          "iam:PassedToService": "cloudformation.amazonaws.com"
        }
      }
    }
  ]
}
```

#### 1.2 cluster-vpc Lambda Execution Role

**Role Name**: `rosa-lambda-cluster-vpc-execution-role`

**Trust Policy**: Same as cluster-iam Lambda

**Permissions Policy**:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "CloudWatchLogsAccess",
      "Effect": "Allow",
      "Action": [
        "logs:CreateLogGroup",
        "logs:CreateLogStream",
        "logs:PutLogEvents"
      ],
      "Resource": "arn:aws:logs:*:*:*"
    },
    {
      "Sid": "CloudFormationAccess",
      "Effect": "Allow",
      "Action": [
        "cloudformation:CreateStack",
        "cloudformation:UpdateStack",
        "cloudformation:DeleteStack",
        "cloudformation:DescribeStacks",
        "cloudformation:DescribeStackEvents",
        "cloudformation:DescribeStackResources",
        "cloudformation:GetTemplate",
        "cloudformation:ValidateTemplate"
      ],
      "Resource": "arn:aws:cloudformation:*:*:stack/rosa-*-vpc/*"
    },
    {
      "Sid": "VPCManagement",
      "Effect": "Allow",
      "Action": [
        "ec2:CreateVpc",
        "ec2:DeleteVpc",
        "ec2:DescribeVpcs",
        "ec2:ModifyVpcAttribute",
        "ec2:CreateTags",
        "ec2:DeleteTags",
        "ec2:DescribeTags"
      ],
      "Resource": "*"
    },
    {
      "Sid": "SubnetManagement",
      "Effect": "Allow",
      "Action": [
        "ec2:CreateSubnet",
        "ec2:DeleteSubnet",
        "ec2:DescribeSubnets",
        "ec2:ModifySubnetAttribute"
      ],
      "Resource": "*"
    },
    {
      "Sid": "InternetGatewayManagement",
      "Effect": "Allow",
      "Action": [
        "ec2:CreateInternetGateway",
        "ec2:DeleteInternetGateway",
        "ec2:DescribeInternetGateways",
        "ec2:AttachInternetGateway",
        "ec2:DetachInternetGateway"
      ],
      "Resource": "*"
    },
    {
      "Sid": "NATGatewayManagement",
      "Effect": "Allow",
      "Action": [
        "ec2:CreateNatGateway",
        "ec2:DeleteNatGateway",
        "ec2:DescribeNatGateways"
      ],
      "Resource": "*"
    },
    {
      "Sid": "ElasticIPManagement",
      "Effect": "Allow",
      "Action": [
        "ec2:AllocateAddress",
        "ec2:ReleaseAddress",
        "ec2:DescribeAddresses",
        "ec2:AssociateAddress",
        "ec2:DisassociateAddress"
      ],
      "Resource": "*"
    },
    {
      "Sid": "RouteTableManagement",
      "Effect": "Allow",
      "Action": [
        "ec2:CreateRouteTable",
        "ec2:DeleteRouteTable",
        "ec2:DescribeRouteTables",
        "ec2:CreateRoute",
        "ec2:DeleteRoute",
        "ec2:ReplaceRoute",
        "ec2:AssociateRouteTable",
        "ec2:DisassociateRouteTable",
        "ec2:ReplaceRouteTableAssociation"
      ],
      "Resource": "*"
    },
    {
      "Sid": "SecurityGroupManagement",
      "Effect": "Allow",
      "Action": [
        "ec2:CreateSecurityGroup",
        "ec2:DeleteSecurityGroup",
        "ec2:DescribeSecurityGroups",
        "ec2:AuthorizeSecurityGroupIngress",
        "ec2:RevokeSecurityGroupIngress",
        "ec2:AuthorizeSecurityGroupEgress",
        "ec2:RevokeSecurityGroupEgress",
        "ec2:UpdateSecurityGroupRuleDescriptionsIngress",
        "ec2:UpdateSecurityGroupRuleDescriptionsEgress"
      ],
      "Resource": "*"
    },
    {
      "Sid": "AvailabilityZoneInfo",
      "Effect": "Allow",
      "Action": ["ec2:DescribeAvailabilityZones"],
      "Resource": "*"
    },
    {
      "Sid": "Route53HostedZoneManagement",
      "Effect": "Allow",
      "Action": [
        "route53:CreateHostedZone",
        "route53:DeleteHostedZone",
        "route53:GetHostedZone",
        "route53:ListHostedZones",
        "route53:UpdateHostedZoneComment",
        "route53:ChangeTagsForResource",
        "route53:ListTagsForResource",
        "route53:AssociateVPCWithHostedZone",
        "route53:DisassociateVPCFromHostedZone"
      ],
      "Resource": "*"
    }
  ]
}
```

#### 1.3 cluster-oidc Lambda Execution Role

**Role Name**: `rosa-lambda-cluster-oidc-execution-role`

**Trust Policy**: Same as cluster-iam Lambda

**Permissions Policy**:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "CloudWatchLogsAccess",
      "Effect": "Allow",
      "Action": [
        "logs:CreateLogGroup",
        "logs:CreateLogStream",
        "logs:PutLogEvents"
      ],
      "Resource": "arn:aws:logs:*:*:*"
    },
    {
      "Sid": "CloudFormationAccess",
      "Effect": "Allow",
      "Action": [
        "cloudformation:CreateStack",
        "cloudformation:UpdateStack",
        "cloudformation:DeleteStack",
        "cloudformation:DescribeStacks",
        "cloudformation:DescribeStackEvents",
        "cloudformation:DescribeStackResources",
        "cloudformation:GetTemplate",
        "cloudformation:ValidateTemplate"
      ],
      "Resource": [
        "arn:aws:cloudformation:*:*:stack/rosa-*-oidc/*",
        "arn:aws:cloudformation:*:*:stack/rosa-*-iam/*"
      ]
    },
    {
      "Sid": "OIDCProviderManagement",
      "Effect": "Allow",
      "Action": [
        "iam:CreateOpenIDConnectProvider",
        "iam:DeleteOpenIDConnectProvider",
        "iam:GetOpenIDConnectProvider",
        "iam:UpdateOpenIDConnectProviderThumbprint",
        "iam:TagOpenIDConnectProvider",
        "iam:UntagOpenIDConnectProvider"
      ],
      "Resource": "arn:aws:iam::*:oidc-provider/*"
    },
    {
      "Sid": "UpdateIAMStackForOIDC",
      "Effect": "Allow",
      "Action": ["iam:GetRole", "iam:UpdateAssumeRolePolicy"],
      "Resource": [
        "arn:aws:iam::*:role/rosa-*-ingress",
        "arn:aws:iam::*:role/rosa-*-cloud-controller-manager",
        "arn:aws:iam::*:role/rosa-*-ebs-csi",
        "arn:aws:iam::*:role/rosa-*-image-registry",
        "arn:aws:iam::*:role/rosa-*-network-config",
        "arn:aws:iam::*:role/rosa-*-control-plane-operator",
        "arn:aws:iam::*:role/rosa-*-node-pool-management"
      ]
    }
  ]
}
```

---

### 2. Cross-Account Lambda Invocation Role

This role allows the Regional Platform adapter to invoke Lambda functions in the customer account.

**Role Name**: `rosa-adapter-lambda-invocation-role`

**Trust Policy**:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "AWS": "arn:aws:iam::111111111111:role/rosa-regional-adapter-pod-identity-role"
      },
      "Action": "sts:AssumeRole",
      "Condition": {
        "StringEquals": {
          "sts:ExternalId": "rosa-regional-platform"
        }
      }
    }
  ]
}
```

**Permissions Policy**:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "InvokeLambdaFunctions",
      "Effect": "Allow",
      "Action": ["lambda:InvokeFunction"],
      "Resource": [
        "arn:aws:lambda:*:222222222222:function:rosa-cluster-iam",
        "arn:aws:lambda:*:222222222222:function:rosa-cluster-vpc",
        "arn:aws:lambda:*:222222222222:function:rosa-cluster-oidc"
      ]
    },
    {
      "Sid": "GetLambdaFunctionInfo",
      "Effect": "Allow",
      "Action": ["lambda:GetFunction", "lambda:GetFunctionConfiguration"],
      "Resource": [
        "arn:aws:lambda:*:222222222222:function:rosa-cluster-iam",
        "arn:aws:lambda:*:222222222222:function:rosa-cluster-vpc",
        "arn:aws:lambda:*:222222222222:function:rosa-cluster-oidc"
      ]
    }
  ]
}
```

---

### 3. Lambda Function Configurations

#### 3.1 cluster-iam Lambda Function

**Function Name**: `rosa-cluster-iam`

**Runtime**: `provided.al2023` (custom runtime for Go binary)

**Handler**: `bootstrap`

**Execution Role**: `arn:aws:iam::222222222222:role/rosa-lambda-cluster-iam-execution-role`

**Environment Variables**:

```json
{
  "AWS_REGION": "us-east-1",
  "LOG_LEVEL": "info"
}
```

**Resource-based Policy** (allows cross-account invocation):

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "AllowAdapterInvocation",
      "Effect": "Allow",
      "Principal": {
        "AWS": "arn:aws:iam::111111111111:role/rosa-regional-adapter-pod-identity-role"
      },
      "Action": "lambda:InvokeFunction",
      "Resource": "arn:aws:lambda:us-east-1:222222222222:function:rosa-cluster-iam"
    }
  ]
}
```

#### 3.2 cluster-vpc Lambda Function

**Function Name**: `rosa-cluster-vpc`

**Runtime**: `provided.al2023`

**Handler**: `bootstrap`

**Execution Role**: `arn:aws:iam::222222222222:role/rosa-lambda-cluster-vpc-execution-role`

**Environment Variables**: Same as cluster-iam

**Resource-based Policy**: Same pattern as cluster-iam, update Resource ARN

#### 3.3 cluster-oidc Lambda Function

**Function Name**: `rosa-cluster-oidc`

**Runtime**: `provided.al2023`

**Handler**: `bootstrap`

**Execution Role**: `arn:aws:iam::222222222222:role/rosa-lambda-cluster-oidc-execution-role`

**Environment Variables**: Same as cluster-iam

**Resource-based Policy**: Same pattern as cluster-iam, update Resource ARN

---

## Regional Platform Account IAM Configuration

### 4. Adapter Pod Identity IAM Role

This role is assumed by the adapter service running in the Regional Cluster EKS.

**Role Name**: `rosa-regional-adapter-pod-identity-role`

**Trust Policy**:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "pods.eks.amazonaws.com"
      },
      "Action": ["sts:AssumeRole", "sts:TagSession"]
    }
  ]
}
```

**Permissions Policy**:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "AssumeCustomerAccountRole",
      "Effect": "Allow",
      "Action": "sts:AssumeRole",
      "Resource": "arn:aws:iam::*:role/rosa-adapter-lambda-invocation-role",
      "Condition": {
        "StringEquals": {
          "sts:ExternalId": "rosa-regional-platform"
        }
      }
    },
    {
      "Sid": "CloudWatchLogsAccess",
      "Effect": "Allow",
      "Action": [
        "logs:CreateLogGroup",
        "logs:CreateLogStream",
        "logs:PutLogEvents"
      ],
      "Resource": "arn:aws:logs:*:111111111111:log-group:/aws/eks/rosa-regional-cluster/*"
    },
    {
      "Sid": "SecretsManagerAccess",
      "Effect": "Allow",
      "Action": [
        "secretsmanager:GetSecretValue",
        "secretsmanager:DescribeSecret"
      ],
      "Resource": [
        "arn:aws:secretsmanager:*:111111111111:secret:hyperfleet-*",
        "arn:aws:secretsmanager:*:111111111111:secret:rosa-regional-*"
      ]
    }
  ]
}
```

---

### 5. EKS Pod Identity Association

**EKS Cluster**: `rosa-regional-cluster`

**Namespace**: `hyperfleet-system`

**Service Account**: `hyperfleet-adapter-sa`

**IAM Role ARN**: `arn:aws:iam::111111111111:role/rosa-regional-adapter-pod-identity-role`

**Configuration** (via Terraform):

```hcl
resource "aws_eks_pod_identity_association" "hyperfleet_adapter" {
  cluster_name    = "rosa-regional-cluster"
  namespace       = "hyperfleet-system"
  service_account = "hyperfleet-adapter-sa"
  role_arn        = aws_iam_role.rosa_regional_adapter_pod_identity_role.arn
}
```

**Kubernetes Service Account**:

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: hyperfleet-adapter-sa
  namespace: hyperfleet-system
  annotations:
    eks.amazonaws.com/role-arn: arn:aws:iam::111111111111:role/rosa-regional-adapter-pod-identity-role
```

---

## Cross-Account Invocation Flow

### Step-by-Step Authentication Flow

1. **Adapter Pod Authentication**:
   - Adapter pod runs with Kubernetes service account `hyperfleet-adapter-sa`
   - EKS Pod Identity injects temporary AWS credentials via the pod identity association
   - Adapter assumes the `rosa-regional-adapter-pod-identity-role` IAM role

2. **Cross-Account Role Assumption**:
   - Adapter calls `sts:AssumeRole` on the customer account role `rosa-adapter-lambda-invocation-role`
   - Provides external ID `rosa-regional-platform` for additional security
   - Receives temporary credentials scoped to the customer account

3. **Lambda Invocation**:
   - Adapter uses temporary customer account credentials to invoke Lambda functions
   - Lambda service validates the principal against the function's resource-based policy
   - Lambda function executes with its execution role

4. **CloudFormation Stack Creation**:
   - Lambda function assumes its execution role
   - Creates CloudFormation stack with embedded IAM policies
   - CloudFormation service provisions resources using the Lambda execution role's permissions

5. **Results Return**:
   - Lambda function returns CloudFormation stack outputs to adapter
   - Adapter uses outputs (VPC IDs, subnet IDs, IAM role ARNs) for cluster provisioning

---

## Security Considerations

### Least Privilege

- Lambda execution roles are scoped to specific resource patterns (`rosa-*`)
- CloudFormation stack names follow predictable patterns for resource restriction
- Cross-account role has no permissions beyond Lambda invocation
- External ID prevents confused deputy problem

### Audit Trail

- All actions logged to CloudTrail in both accounts
- Lambda function logs sent to CloudWatch Logs
- CloudFormation events provide detailed resource change tracking

### Credential Lifecycle

- EKS Pod Identity provides short-lived credentials (1 hour default TTL)
- STS AssumeRole tokens are time-limited (configurable, default 1 hour)
- No long-lived access keys or static credentials

### Network Isolation

- Lambda functions run in customer account (no VPC required for CloudFormation operations)
- Adapter runs in private EKS cluster in Regional Platform account
- No network path required between accounts (API-based invocation only)

---

## Account Setup Implementation

### Customer Account Setup (via `rosactl account setup`)

The `rosactl account setup` command performs the following operations:

1. **Package Lambda Functions**:
   - Compile Go binary for Lambda runtime
   - Create deployment package (ZIP file with bootstrap binary)

2. **Create CloudFormation Stack**:
   - Stack name: `rosa-account-setup`
   - Creates three Lambda functions with execution roles
   - Creates cross-account invocation role
   - Outputs: Lambda ARNs, role ARNs

3. **Register with Platform API**:
   - POST to `/api/v0/accounts` endpoint
   - Body: `{ "accountId": "222222222222", "privileged": true }`
   - Stores customer account metadata in CLM database

### Regional Platform Account Setup

1. **Create Adapter Pod Identity Role** (Terraform):
   - Deploy `rosa-regional-adapter-pod-identity-role` with STS AssumeRole permissions
   - Create EKS Pod Identity association

2. **Deploy Adapter Service** (ArgoCD):
   - Deploy hyperfleet-adapter Helm chart
   - Configure service account with Pod Identity annotation
   - Inject customer account ID and role ARN via ConfigMap

---

## Troubleshooting

### Common Issues

#### 1. Access Denied when Assuming Cross-Account Role

**Symptom**: `AccessDenied: User is not authorized to perform: sts:AssumeRole`

**Diagnosis**:

- Verify trust policy on `rosa-adapter-lambda-invocation-role` includes correct Regional Platform role ARN
- Check that external ID matches: `rosa-regional-platform`
- Confirm adapter Pod Identity role has `sts:AssumeRole` permission

**Resolution**:

```bash
# Verify trust policy
aws iam get-role --role-name rosa-adapter-lambda-invocation-role \
  --query 'Role.AssumeRolePolicyDocument' --output json

# Verify adapter role has AssumeRole permission
aws iam get-role-policy --role-name rosa-regional-adapter-pod-identity-role \
  --policy-name AssumeCustomerAccountRole --output json
```

#### 2. Lambda Invocation Fails

**Symptom**: `AccessDeniedException: User is not authorized to perform: lambda:InvokeFunction`

**Diagnosis**:

- Verify adapter has assumed customer account role successfully
- Check Lambda resource-based policy allows invocation from Regional Platform role
- Confirm cross-account invocation role has `lambda:InvokeFunction` permission

**Resolution**:

```bash
# Check Lambda resource-based policy
aws lambda get-policy --function-name rosa-cluster-iam --output json

# Verify cross-account role permissions
aws iam get-role-policy --role-name rosa-adapter-lambda-invocation-role \
  --policy-name InvokeLambdaFunctions --output json
```

#### 3. CloudFormation Stack Creation Fails

**Symptom**: `CREATE_FAILED` status on CloudFormation stack

**Diagnosis**:

- Check Lambda execution role has required permissions
- Review CloudFormation events for specific resource failures
- Verify resource naming follows `rosa-*` pattern

**Resolution**:

```bash
# View CloudFormation events
aws cloudformation describe-stack-events \
  --stack-name rosa-my-cluster-iam --max-items 10

# Check Lambda execution role permissions
aws iam get-role-policy --role-name rosa-lambda-cluster-iam-execution-role \
  --policy-name IAMRoleManagement --output json
```

---

## References

- [AWS Lambda Execution Role](https://docs.aws.amazon.com/lambda/latest/dg/lambda-intro-execution-role.html)
- [EKS Pod Identity](https://docs.aws.amazon.com/eks/latest/userguide/pod-identities.html)
- [Cross-Account Access with IAM Roles](https://docs.aws.amazon.com/IAM/latest/UserGuide/tutorial_cross-account-with-roles.html)
- [Lambda Resource-Based Policies](https://docs.aws.amazon.com/lambda/latest/dg/access-control-resource-based.html)
- [CloudFormation Service Role](https://docs.aws.amazon.com/AWSCloudFormation/latest/UserGuide/using-iam-servicerole.html)

---

**Document Version**: 1.0  
**Last Updated**: 2026-04-09
