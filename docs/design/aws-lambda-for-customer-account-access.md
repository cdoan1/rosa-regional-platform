# AWS Lambda Functions for controlled access in customer account

**Last Updated Date**: 2026-02-18

## Summary

The regional platform CLI tool should create AWS Lambda functions in the customer account as part of the customer account setup. The regional platform can then access the lambda functions to create OIDC providers, perform preflight checks, and execute network verifications with granular, operation-specific IAM permissions.

## Context

In the ROSA HCP service today, customers use rosa cli tool to setup their AWS accounts in order to then be able to deploy ROSA HCP clusters. The cli tool creates an OIDC provider in the customer account which is then use in the OIDC/STS flow documented here: https://gist.github.com/jmelis/1b2de46a2401cc01f1822c629548ca22

- **Problem Statement**: The current ROSA HCP model grants Regional Platform services broad IAM role permissions in customer accounts via OIDC/STS trust relationships. For the Regional Platform architecture, we need:
  - **Operation-level granularity**: Each operation (OIDC setup, preflight checks, network verification) should execute with minimal, scoped IAM permissions
  - **Enhanced auditability**: Complete execution logs for compliance and debugging
  - **Version control**: Ability to update specific operations without changing IAM trust policies
  - **Reduced blast radius**: If credentials are compromised, limit scope to specific operations

This design proposes using AWS Lambda functions deployed in customer accounts to achieve these goals. Each Lambda function executes a specific operation with minimal IAM permissions, provides complete CloudWatch execution logs, and can be versioned/updated independently.

- **Constraints**:

* The ROSA Regional Platform repository ( this repo ) describe the gitops project that builds the infrastructure that implements this ROSA Regional HCP service.
* The platform is made up of these components:
  - platform-api, https://github.com/openshift-online/rosa-regional-platform-api
  - maestro, https://github.com/openshift-online/maestro
  - [To be created, as part of this design decision] rosa regional hcp cli tool, `rosactl`, will use the platform-api as the backend.
  - Distinguish this from the current cli, `rosa` tool used in the rosa hcp service today. The repository for the `rosa` cli tool is here: https://github.com/openshift/rosa
* The CLM component, is deployed as an argocd application named hyperfleet-system on the regional cluster, consists of three components:
  - hyperfleet-api, https://github.com/openshift-hyperfleet/hyperfleet-api
  - hyperfleet-sentinel, https://github.com/openshift-hyperfleet/hyperfleet-sentinel
  - hyperfleet-adapter, https://github.com/openshift-hyperfleet/hyperfleet-adapter
* Sketch of the lambda flow: docs/design/assets/lambda-flow.png

- **Assumptions**:
  - Customer AWS accounts have Lambda service enabled (standard for AWS accounts)
  - CLM can authenticate to customer accounts (authentication method TBD - see Technical Specifications)
  - Customer accounts accept Lambda functions deployed by `rosactl` CLI
  - Lambda execution logs must be retained for minimum 90 days for compliance
  - Network connectivity between RH Regional Platform account and customer accounts exists for Lambda invocation
  - Existing ROSA HCP customers will migrate to this Lambda-based model (see Migration Requirements)

## Alternatives Considered

### Option 1: Current OIDC/STS Model (Status Quo)

**Description**: OIDC provider in customer account, CLM assumes IAM roles via STS

**Pros**:
- Well-understood pattern, proven in current ROSA HCP
- No additional AWS services required
- Familiar to customers and operations teams
- Lower onboarding complexity

**Cons**:
- Broad IAM permissions per role (entire role assumed at once)
- Harder to audit specific operations (CloudTrail shows role assumption, not granular operations)
- Role assumption is coarse-grained (all-or-nothing access)
- Difficult to update permissions for specific operations without changing trust policies

### Option 2: Lambda-Based Controlled Access (Proposed)

**Description**: `rosactl` CLI deploys Lambda functions to customer account, CLM invokes them for specific operations

**Pros**:
- **Operation-level granularity**: Each Lambda has minimal IAM permissions for its specific task
- **Complete audit trail**: CloudWatch Logs capture every invocation with request/response data
- **Version control**: Update individual operations without redeploying CLM or changing IAM trust policies
- **Scoped IAM per Lambda**: OIDC creation lambda only needs `iam:CreateOIDCProvider`, not broader permissions
- **Execution isolation**: Each operation runs in isolated context, reducing blast radius

**Cons**:
- Additional infrastructure in customer accounts (3-5 Lambda functions)
- Lambda cold starts may add latency (500ms-3s for infrequent operations)
- Increased onboarding complexity (`rosactl` must deploy and configure Lambdas)
- Monitoring overhead (CloudWatch metrics, logs for each Lambda)
- Minimal cost overhead (~$0.20 per 1M invocations)

### Option 3: AWS Service Catalog

**Description**: Customer provisions pre-defined Service Catalog products for ROSA operations

**Pros**:
- AWS-native service, familiar to enterprise customers
- Enforces constraints via product definitions
- Self-service provisioning model
- Built-in approval workflows

**Cons**:
- Limited flexibility for complex operations
- Complex product definitions to maintain
- Not designed for programmatic invocation by external services
- Customer must manually provision products (not automated)
- Higher latency for operation execution

### Option 4: AWS Systems Manager (SSM) Automation

**Description**: SSM Automation documents execute operations in customer accounts, invoked cross-account by CLM

**Pros**:
- AWS-managed execution environment
- Good for runbooks and documented procedures
- Cross-account support built-in
- Integration with Parameter Store for secrets

**Cons**:
- Less flexible than Lambda (limited to automation document syntax)
- Harder to version and test automation documents
- Limited programming model (YAML-based, not full programming languages)
- More complex error handling and retry logic

### Decision

**Option 2 (Lambda-Based Controlled Access)** is selected because it provides the required operation-level granularity with complete audit trails while maintaining flexibility for complex operations. The trade-off of additional infrastructure is acceptable given the security and operational benefits.

## Design Rationale

### Justification

Lambda functions enable operation-specific IAM policies that enforce the principle of least privilege at a granular level:

- **OIDC Creation Lambda**: Only requires `iam:CreateOIDCProvider`, `iam:GetOIDCProvider`, `iam:UpdateOIDCProvider` - not broader IAM write permissions
- **Preflight Check Lambda**: Only needs read-only permissions (`ec2:Describe*`, `iam:Get*`, `servicequotas:Get*`) for validation
- **Network Verifier Lambda**: Only requires `ec2:Describe*` for VPCs, subnets, and route tables - no modification permissions

CloudWatch Logs provide complete audit trail for each invocation:
- Request parameters (VPC ID, subnet IDs, cluster configuration)
- Execution results (validation passed/failed, created resource ARNs)
- Execution duration and any errors
- Can help support compliance requirements for SOC2, ISO27001 audit trails (when properly configured)

Lambda versioning allows updating operations without redeploying CLM:
- CLM invokes Lambda by alias (`prod`, `staging`) rather than specific version
- `rosactl` can update Lambda code and promote to `prod` alias
- Rollback is immediate (repoint alias to previous version)
- No CLM redeployment or IAM trust policy changes required

Execution isolation reduces blast radius:
- Compromised credentials for one operation (e.g., network verification) don't grant access to other operations (e.g., OIDC creation)
- Each Lambda execution is isolated with its own runtime environment
- Lambda execution role is scoped to minimum permissions needed

### Evidence

- **AWS Lambda Security Best Practices**: https://docs.aws.amazon.com/lambda/latest/dg/lambda-security.html
  - Resource-based policies for cross-account invocation
  - IAM execution roles with least privilege
  - Encryption in transit and at rest

- **CloudWatch Logs for Compliance**:
  - Lambda execution logs can help support SOC2, ISO27001, and HIPAA compliance requirements
  - Log retention configurable (default 90 days, unlimited maximum)
  - Structured logging with JSON output for parsing and analysis
  - **Note on Shared Responsibility**: Compliance depends on customer configuration and controls, including proper log retention policies, appropriate access controls (IAM policies for CloudWatch Logs), encryption settings (KMS for logs at rest), and comprehensive logging configuration (ensuring all relevant events are captured)

- **Existing Precedent**:
  - AWS uses Lambda for Control Tower Account Factory operations (cross-account provisioning)
  - AWS Service Catalog uses Lambda for custom provisioning logic
  - Industry standard for cross-account automation with granular permissions

### Comparison

**vs. OIDC/STS (Option 1)**:
- **Granularity**: Lambdas provide operation-level permissions vs role-level (all permissions in assumed role)
- **Audit Trail**: CloudWatch Logs capture every invocation with request/response vs CloudTrail showing only role assumption
- **Versioning**: Lambda versions/aliases enable updates without changing IAM trust policies vs role policy updates affecting all operations
- **Blast Radius**: Compromised Lambda access limited to specific operation vs compromised role credentials grant all role permissions

**vs. Service Catalog (Option 3)**:
- **Flexibility**: Lambdas support full programming languages (Go, Python) vs limited Service Catalog product definitions
- **Invocation Model**: Programmatic invocation by CLM vs manual customer provisioning
- **Latency**: Direct Lambda invocation (<100ms warm) vs Service Catalog provisioning (minutes)
- **Complexity**: Lambda code simpler than Service Catalog product + portfolio management

**vs. SSM Automation (Option 4)**:
- **Programming Model**: Full Go/Python SDK vs limited YAML-based automation document syntax
- **Testing**: Standard unit/integration tests for Lambda code vs harder to test automation documents
- **Versioning**: Lambda versions and aliases vs automation document versions
- **Complexity**: Lambda error handling with retries in code vs complex automation document error handling

## Consequences

### Positive

* **Granular Access Control**: Each Lambda function has minimal IAM permissions for its specific operation (e.g., OIDC creation lambda only has `iam:CreateOIDCProvider`, not broader IAM write access). This enforces least privilege at operation level rather than role level.

* **Complete Audit Trail**: CloudWatch Logs capture every Lambda invocation with:
  - Input parameters (VPC ID, subnet IDs, cluster configuration)
  - Execution results (validation passed/failed, created resource ARNs)
  - Execution duration, memory usage, and any errors
  - Can help support compliance requirements for SOC2, ISO27001, and audit trails (when properly configured with retention policies, access controls, and encryption)

* **Operational Flexibility**: Update individual Lambda functions without redeploying Regional Cluster services:
  - `rosactl` can update Lambda code and promote to `prod` alias
  - CLM continues invoking same alias, automatically gets updated code
  - Rollback is immediate (repoint alias to previous version)
  - No CLM redeployment or IAM trust policy changes required

* **Reduced Attack Surface**: Compromised credentials limited to specific operations:
  - Network verification credentials can't create OIDC providers
  - OIDC creation credentials can't access customer VPC resources
  - Each Lambda execution is isolated with its own runtime environment
  - Blast radius reduced from entire role permissions to single operation

* **Versioning and Rollback**: Lambda versions and aliases enable:
  - Safe updates (test with `staging` alias before promoting to `prod`)
  - Quick rollback if issues arise (repoint alias to previous version)
  - Multiple environments (dev, staging, prod) using same Lambda ARN with different aliases
  - Version history for compliance and debugging

* **Enhanced Observability**: CloudWatch metrics and logs provide:
  - Invocation count, error rate, duration per Lambda
  - Throttling events and concurrent executions
  - Structured JSON logs for parsing and analysis
  - Integration with CloudWatch alarms for automated alerts

### Negative

* **Additional Infrastructure**: Customer accounts have 3-5 Lambda functions to manage:
  - Each Lambda requires deployment, configuration, and monitoring
  - Lambda execution roles and resource-based policies to manage
  - CloudWatch log groups and metric filters to configure
  - More components to troubleshoot when issues occur

* **Cold Start Latency**: Infrequent operations may experience Lambda cold starts:
  - Initial invocation: 500ms-3s delay for runtime initialization
  - Acceptable for cluster provisioning workflow (not on critical path)
  - Warm execution (<100ms) if invoked within 15 minutes
  - Can mitigate with provisioned concurrency if needed (additional cost)

* **Increased Complexity**: `rosactl` CLI must deploy and update Lambdas during account setup:
  - More onboarding steps for customers (deploy Lambdas, configure IAM)
  - Lambda deployment failures must be handled and retried
  - Version management adds complexity (which version is running?)
  - Customers must understand Lambda-based model vs simple OIDC/STS

* **Monitoring Overhead**: Operations teams must track Lambda metrics across customer accounts:
  - CloudWatch dashboards for invocation rate, errors, duration
  - Alerts for Lambda failures, throttling, timeout
  - Cost tracking for Lambda invocations and CloudWatch storage
  - Cross-account monitoring aggregation more complex

* **Cost Overhead**: Lambda invocations and CloudWatch storage add minimal cost:
  - Lambda: ~$0.20 per 1M requests (estimated 10 invocations per cluster lifecycle = negligible)
  - CloudWatch Logs: ~$0.50/GB ingested (estimated 1KB per invocation = <$1/month per customer)
  - Lambda free tier covers 400,000 GB-seconds (128MB lambda at 1s = 32,000 free invocations/month)
  - Trade-off: Lambda costs <1% of cluster infrastructure costs, acceptable for security benefits

## Cross-Cutting Concerns

[Address relevant architectural concerns. Include only the sections that are materially impacted by this decision. Delete sections that are not applicable.]

### Reliability

* **Scalability**:
  - **Concurrency**: Lambda supports 1000 concurrent executions per region by default (can request increase to 10,000+)
  - **Horizontal Scaling**: Lambdas automatically scale to handle concurrent invocations (no manual scaling required)
  - **Load Patterns**: Cluster provisioning operations are bursty (spikes during customer onboarding); Lambda auto-scaling handles this well
  - **Capacity Limits**: Reserved concurrency can be configured per Lambda to prevent one operation from exhausting account concurrency quota
  - **Regional Distribution**: Each AWS region has independent Lambda service; Regional Platform architecture aligns well with this
  - **Throttling**: Lambda throttles at concurrency limit; CLM retries with exponential backoff (acceptable for non-realtime operations)

* **Observability**:
  - **Logging**:
    - CloudWatch Logs capture all Lambda executions with structured JSON output
    - Log format includes: timestamp, request_id, operation, input_parameters, result, duration, errors
    - CloudWatch Logs Insights for querying (e.g., "find all failed OIDC creation operations in last 7 days")
    - Logs exported to S3 for long-term archival and analysis

  - **Metrics**:
    - CloudWatch metrics per Lambda: Invocations, Errors, Duration, Throttles, ConcurrentExecutions
    - Custom metrics published from Lambda code (e.g., "preflight_checks_failed", "network_validation_warnings")
    - Metrics aggregated across customer accounts for operational dashboards

  - **Tracing**:
    - AWS X-Ray integration for distributed tracing (optional, adds overhead)
    - Trace requests from CLM → Lambda → AWS APIs (e.g., IAM CreateOIDCProvider)
    - Useful for debugging performance issues and understanding operation flow

  - **Alerting**:
    - CloudWatch Alarms on error rate (e.g., >5% of invocations fail in 5-minute window)
    - CloudWatch Alarms on throttling (e.g., any throttled invocations in 5-minute window)
    - CloudWatch Alarms on duration (e.g., Lambda execution >30 seconds indicates performance issue)
    - Alerts sent to operations team via SNS/PagerDuty

* **Resiliency**:
  - **Fault Tolerance**:
    - Lambda service is managed by AWS with multi-AZ deployment (high availability)
    - CLM implements retry logic with exponential backoff (retry up to 3 times with 1s, 2s, 4s delays)
    - Idempotent operations (e.g., OIDC creation checks if provider exists before creating)

  - **Failure Modes**:
    - **Lambda Execution Failure**: CLM retries operation; if 3 retries fail, marks cluster provisioning as failed and alerts operations
    - **Lambda Throttling**: CLM retries with backoff; if persistent, indicates concurrency limit issue (increase reserved concurrency)
    - **Lambda Timeout**: Configure 5-minute timeout; if operation times out, retry with exponential backoff
    - **AWS Service Outage**: Lambda service outage affects all operations; CLM queues operations for retry when service recovers

  - **Disaster Recovery**:
    - Lambda code stored in S3 (multi-AZ by default) and version controlled in Git
    - `rosactl` can redeploy Lambdas from Git source if Lambda functions deleted
    - CloudWatch Logs backed up to S3 for recovery (logs retained even if CloudWatch Logs service unavailable)

  - **SLAs**:
    - Lambda service has 99.95% monthly uptime SLA (AWS commitment)
    - Regional Platform target: 99.9% uptime for cluster provisioning operations
    - Lambda cold starts (<3s) acceptable for non-realtime provisioning operations

  - **Failover Mechanisms**:
    - No failover needed (Lambda is regional service, Regional Platform is also regional)
    - If Lambda service unavailable in region, entire Regional Platform in that region is affected (acceptable risk)
    - Cross-region failover not in scope (Regional Platform operates independently per region)

### Security

* **Authentication**: CLM authenticates to customer account using **Lambda Resource Policy** (direct invocation without role assumption).

  **Selected Approach: Lambda Resource Policy**
  - Each Lambda has resource-based policy allowing invocation from RH Regional Platform account principals
  - CLM invokes Lambda directly using its own IAM service role credentials (no AssumeRole)
  - Principal scoped to specific CLM service role ARN (not entire RH account)
  - Principal ARN scoping prevents unauthorized access (only the specific CLM role can invoke)

  **Why Lambda Resource Policy** (vs AssumeRole with External ID):
  - Simpler architecture: No additional IAM roles in customer accounts
  - Better performance: No STS call overhead (saves 100-200ms per invocation, 500ms+ for sequential calls)
  - Easier operations: No temporary credential management or renewal
  - Sufficient security: Resource policy scoped to specific CLM role ARN provides equivalent protection

* **Authorization**: Each Lambda has resource-based policy restricting invocation:
  - Only specific RH Regional Platform account principals can invoke
  - Principal ARNs scoped to CLM service role (not entire account)
  - Resource policy explicitly lists the CLM service role ARN (`arn:aws:iam::123456789012:role/CLMServiceRole`)

* **IAM Permissions (Least Privilege)**: Each Lambda execution role has minimal permissions:
  - **OIDC Creation Lambda**: Only `iam:CreateOIDCProvider`, `iam:GetOIDCProvider`, `iam:UpdateOIDCProvider`, `iam:TagResource` for OIDC provider
  - **Preflight Check Lambda**: Only read-only permissions (`ec2:Describe*`, `iam:Get*`, `iam:List*`, `servicequotas:Get*`) for validation
  - **Network Verifier Lambda**: Only `ec2:DescribeVpcs`, `ec2:DescribeSubnets`, `ec2:DescribeRouteTables`, `ec2:DescribeSecurityGroups` for network checks
  - No Lambda has `*` permissions or broad write access

* **Audit Trail**: CloudWatch Logs retain execution logs for compliance:
  - Minimum 90-day retention (customer configurable to unlimited)
  - Logs include request parameters, execution results, errors
  - CloudWatch Logs Insights for querying and analysis
  - Logs exported to S3 for long-term archival and compliance

* **Encryption**:
  - **In Transit**: All Lambda invocations use TLS 1.2+ (AWS SDK default)
  - **At Rest**: Lambda environment variables encrypted with AWS KMS (customer-managed key option)
  - **Logs**: CloudWatch Logs encrypted with KMS (customer-managed key option)
  - **Code**: Lambda deployment packages encrypted in S3

* **Secret Management**:
  - No secrets stored in Lambda code or environment variables
  - If Lambda needs credentials, retrieve from AWS Secrets Manager at runtime
  - Secrets Manager integration uses Lambda execution role permissions
  - Automatic secret rotation supported

* **Network Isolation**:
  - Lambdas execute in customer VPC if network access needed (e.g., network verification Lambda)
  - Otherwise, no VPC attachment (better security posture, no VPC permissions needed)
  - VPC-attached Lambdas use security groups with minimal ingress/egress rules
  - No public internet access unless explicitly required (use VPC endpoints)

* **Threat Mitigation**:
  - **Confused Deputy**: Lambda resource policies explicitly specify CLM service role ARN as principal (not entire account or service)
  - **Privilege Escalation**: Lambda execution roles have no IAM write permissions (except OIDC Lambda, scoped to OIDC provider only)
  - **Data Exfiltration**: Lambdas log all operations to CloudWatch; no direct internet access without VPC NAT
  - **Tampering**: Lambda code integrity verified via SHA256 hash; `rosactl` validates hash before deployment

### Performance

* **Latency**:
  - **Cold Start**: Initial invocation 500ms-3s for runtime initialization (Go runtime fastest, Python slightly slower)
  - **Warm Execution**: <100ms for subsequent invocations if within 15 minutes (Lambda runtime reused)
  - **Target**: Lambda invocation should not add more than 5 seconds to cluster provisioning critical path
  - **Mitigation**: Provisioned concurrency can keep Lambdas warm (additional cost, ~$0.015/hour per Lambda), but likely not needed for infrequent provisioning operations

* **Throughput**:
  - Lambda supports 1000 concurrent executions per region by default
  - Each Lambda invocation handles one operation (OIDC creation, preflight check, etc.)
  - Cluster provisioning invokes 3-5 Lambdas sequentially (not parallel), so throughput = 1000 clusters/minute (far exceeds expected load)
  - Burst capacity: Up to 3000 concurrent executions for short spikes

* **Resource Utilization**:
  - **Memory**: Configure 128MB for simple operations (preflight checks), 256MB for complex operations (network verification)
  - **CPU**: Lambda CPU scales with memory (128MB = 0.08 vCPU, 256MB = 0.16 vCPU); sufficient for operations that are mostly AWS API calls
  - **Duration**: Most operations complete in <10 seconds (OIDC creation <5s, preflight checks <10s, network verification <15s)
  - **Timeout**: Configure 5-minute timeout for safety; actual execution much faster

* **Optimization Strategies**:
  - **Runtime Choice**: Use Go for fastest cold start (500ms-1s) vs Python (1s-2s)
  - **Package Size**: Minimize Lambda deployment package size (<10MB) for faster cold starts
  - **Connection Reuse**: Reuse AWS SDK clients across invocations (Lambda runtime caches connections)
  - **Concurrency Control**: Reserved concurrency prevents Lambda from exhausting account limits
  - **Async Operations**: For non-blocking operations, CLM can invoke Lambda asynchronously (fire-and-forget) and poll results
  - **Caching**: Lambda can cache AWS API responses (e.g., subnet details) in memory across invocations within same runtime

* **Benchmarks**:
  - OIDC Creation: 2-5s (cold start + AWS IAM CreateOIDCProvider API call)
  - Preflight Checks: 5-10s (cold start + multiple AWS API calls for validation)
  - Network Verification: 10-15s (cold start + VPC/subnet/route table queries)
  - Total provisioning overhead: ~20-30s (sequential Lambda invocations)
  - Acceptable impact: Cluster provisioning takes 10-15 minutes total; Lambda overhead <5% of total time

### Cost

* **Lambda Invocation Costs**:
  - Pricing: $0.20 per 1 million requests (after free tier)
  - Free Tier: 1 million requests per month (permanent free tier)
  - Estimated Usage: 10 invocations per cluster lifecycle (OIDC creation, preflight checks, network verification, updates, deletion)
  - Example: 100 clusters/month = 1,000 invocations = **$0.0002** (within free tier)
  - Conclusion: Lambda invocation costs negligible

* **Lambda Duration Costs**:
  - Pricing: $0.0000166667 per GB-second (after free tier)
  - Free Tier: 400,000 GB-seconds per month (permanent free tier)
  - Estimated Usage: 128MB Lambda, 5 seconds average execution, 1,000 invocations/month
  - Calculation: (128MB / 1024) * 5s * 1,000 = 625 GB-seconds = **$0.01**
  - Conclusion: Lambda duration costs negligible (within free tier for most customers)

* **CloudWatch Logs Costs**:
  - Ingestion: $0.50 per GB
  - Storage: $0.03 per GB per month
  - Estimated Usage: 1KB per Lambda invocation, 1,000 invocations/month
  - Calculation: 1KB * 1,000 = 1MB ingested/month = **$0.0005**
  - Storage (90-day retention): 1MB * 3 months = 3MB = **$0.0001**
  - Conclusion: CloudWatch Logs costs <$1 per year per customer

* **Provisioned Concurrency (Optional)**:
  - Pricing: $0.015 per hour per Lambda (keeps Lambda warm to avoid cold starts)
  - Use Case: Only if cold starts become issue (unlikely for infrequent provisioning operations)
  - Cost: 3 Lambdas * $0.015/hour * 730 hours/month = **$32.85/month**
  - Decision: **Not recommended** - cold starts acceptable for provisioning operations; cost not justified

* **API Gateway (If Option C Selected for Authentication)**:
  - Pricing: $3.50 per million API calls + $0.09 per GB data transfer
  - Estimated Usage: 1,000 invocations/month, 1KB per request
  - Cost: (1,000 / 1,000,000) * $3.50 + (1MB / 1024) * $0.09 = **$0.004**
  - Conclusion: API Gateway adds negligible cost if selected

* **Operational Costs**:
  - Lambda management: No additional operations headcount (automated via `rosactl`)
  - Monitoring: CloudWatch dashboards and alarms included in AWS costs (no additional license fees)
  - Troubleshooting: CloudWatch Logs Insights queries free for first 1GB scanned per month

* **Total Cost Estimate (Per Customer Account)**:
  - Lambda invocations: $0.0002
  - Lambda duration: $0.01
  - CloudWatch Logs: $0.001
  - **Total: ~$0.01 per month per customer account** (within AWS free tier for most customers)

* **Cost Comparison**:
  - vs. OIDC/STS: No additional AWS service costs (only CloudTrail for audit), but less granular
  - vs. Lambda: Adds <$1/month per customer (negligible compared to cluster infrastructure costs ~$500-$5000/month)
  - Trade-off: **Lambda costs <0.01% of cluster infrastructure costs** - acceptable for security and operational benefits

* **Cost Optimization Opportunities**:
  - Use S3 Lifecycle policies to archive CloudWatch Logs to S3 Glacier after 90 days (reduce storage costs by 80%)
  - Configure CloudWatch Logs retention to match compliance requirements (don't over-retain)
  - Monitor Lambda memory utilization; reduce memory allocation if consistently <50% utilized (reduces duration costs)
  - Reuse Lambda runtimes (avoid cold starts) to minimize duration costs

### Operability

* **Deployment**:
  - `rosactl init` or `rosactl setup-account` deploys Lambda functions to customer account
  - Lambda code packaged as deployment package (ZIP file with Go binary or Python code)
  - Deployment steps:
    1. `rosactl` authenticates to customer account (AWS IAM credentials)
    2. Creates Lambda execution roles with minimal IAM permissions (one role per Lambda)
    3. Uploads Lambda deployment packages to S3 (versioned)
    4. Creates Lambda functions with configuration (memory, timeout, environment variables)
    5. Adds resource-based policies for cross-account invocation
    6. Tags Lambdas with `rosa:component=<lambda-name>` for discovery
    7. Creates CloudWatch Log Groups with 90-day retention
    8. Validates deployment (test invocation)
  - Deployment automation: `rosactl` handles all steps; customer only runs single command

* **Versioning**:
  - Lambda version aliases (`prod`, `staging`, `dev`) control which version CLM invokes
  - `rosactl` publishes new Lambda version on each update
  - Promotion workflow:
    1. `rosactl update-lambdas --alias staging` updates staging alias to new version
    2. Test with staging environment
    3. `rosactl promote-lambdas --from staging --to prod` promotes staging version to prod
  - CLM always invokes `prod` alias (stable version)
  - Rollback: `rosactl rollback-lambdas` repoints `prod` alias to previous version (immediate, no redeployment)

* **Updates**:
  - `rosactl update-lambdas` updates Lambda code and configuration
  - Update types:
    - **Code Update**: New Lambda deployment package (bug fixes, new features)
    - **Configuration Update**: Memory, timeout, environment variables (no code change)
    - **IAM Policy Update**: Lambda execution role permissions (rare, should be minimal)
  - Update process:
    1. `rosactl` validates new Lambda code (syntax, dependencies)
    2. Publishes new Lambda version (immutable, versioned)
    3. Updates alias (e.g., `staging`) to point to new version
    4. Optionally runs smoke tests (test invocation)
    5. Promotes to `prod` alias after validation
  - Zero-downtime updates: Alias updates are atomic; CLM continues invoking same alias ARN

* **Error Handling**:
  - **Lambda Invocation Failure**: CLM retries with exponential backoff (1s, 2s, 4s delays)
  - **Retry Logic**: CLM retries up to 3 times; if 3 retries fail, marks cluster provisioning as failed
  - **Idempotent Operations**: Lambdas check if operation already completed before executing (e.g., OIDC provider exists)
  - **Partial Failure**: If one Lambda fails (e.g., network verification), CLM stops provisioning and reports error to customer
  - **Alert on Repeated Failures**: If 3 consecutive cluster provisioning operations fail, alert operations team (indicates Lambda code issue)

* **Monitoring**:
  - **CloudWatch Dashboards**: Per-region dashboard showing Lambda metrics across all customer accounts
    - Invocation count per Lambda (OIDC creation, preflight checks, network verification)
    - Error rate per Lambda (target: <1% error rate)
    - Duration per Lambda (p50, p99, max)
    - Throttle count per Lambda (should be zero; indicates concurrency limit issue)
  - **CloudWatch Alarms**: Automated alerts for operational issues
    - Error rate >5% in 5-minute window (indicates Lambda code issue)
    - Any throttled invocations (indicates concurrency limit reached)
    - Duration >30 seconds (indicates performance issue)
  - **Aggregated Metrics**: CloudWatch cross-account observability for aggregating metrics from all customer accounts

* **Debugging**:
  - **CloudWatch Logs**: Each Lambda invocation logged with structured JSON output
    - Log fields: timestamp, request_id, operation, input_parameters, result, duration, errors
    - CloudWatch Logs Insights queries for troubleshooting (e.g., "find all failed OIDC creation operations for customer X")
  - **X-Ray Tracing**: Optional distributed tracing for understanding operation flow (CLM → Lambda → AWS APIs)
  - **Test Invocations**: `rosactl test-lambda --name oidc-provisioner` invokes Lambda with test payload for validation
  - **Lambda Versions**: If issue suspected, identify which Lambda version is running (`aws lambda get-alias --name prod`)

* **Discovery**:
  - CLM queries customer account for Lambda ARNs by tag (`rosa:component=oidc-provisioner`)
  - Tag-based discovery enables flexible Lambda naming (customer can customize Lambda names if desired)
  - CLM caches Lambda ARNs per customer account (refreshes every 24 hours or on error)
  - If Lambda not found, CLM reports error to customer: "Lambda function rosa-oidc-provisioner not found; run `rosactl setup-account`"

* **Lifecycle Management**:
  - **Creation**: `rosactl setup-account` creates Lambdas during initial account setup
  - **Update**: `rosactl update-lambdas` updates Lambda code/configuration as needed
  - **Deletion**: `rosactl cleanup-account` removes Lambdas when customer offboards (optional)
  - **Upgrade Path**: If Lambda model changes (e.g., new Lambda added), `rosactl update-lambdas` deploys new Lambdas automatically

* **Tooling Requirements**:
  - **`rosactl` CLI**: New CLI tool for Regional Platform (distinct from existing `rosa` CLI)
  - **AWS CLI**: Used by `rosactl` for AWS API calls (Lambda, IAM, CloudWatch)
  - **CloudWatch Dashboard**: Pre-built dashboard template for operations team
  - **Runbooks**: Documented procedures for common operational tasks (Lambda deployment, rollback, troubleshooting)

## Technical Specifications

### Lambda Functions

Based on the diagram in `docs/design/assets/lambda-flow.png`, the following Lambda functions will be deployed to customer accounts:

#### 1. OIDC Provisioning Lambda (`rosa-oidc-provisioner`)

**Purpose**: Create and manage OIDC provider in customer account for cluster authentication

**IAM Permissions** (Execution Role):
```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "iam:CreateOIDCProvider",
        "iam:GetOIDCProvider",
        "iam:UpdateOIDCProvider",
        "iam:TagResource"
      ],
      "Resource": "arn:aws:iam::*:oidc-provider/*"
    }
  ]
}
```

**Input Parameters**:
- `issuer_url` (string): OIDC issuer URL (e.g., `https://oidc.example.com`)
- `thumbprint` (string): SHA1 thumbprint of OIDC provider certificate
- `cluster_id` (string): Unique cluster identifier for tagging

**Output**:
- `oidc_provider_arn` (string): ARN of created/updated OIDC provider
- `status` (string): `created`, `updated`, or `already_exists`

**Runtime**: Go 1.21 (fast cold start, ~500ms-1s)

**Memory**: 128MB (minimal memory for IAM API calls)

**Timeout**: 60 seconds (OIDC creation typically <5 seconds)

---

#### 2. Preflight Check Lambda (`rosa-preflight-checker`)

**Purpose**: Validate customer account prerequisites before cluster creation (quotas, IAM permissions, enabled services)

**IAM Permissions** (Execution Role):
```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "ec2:Describe*",
        "iam:Get*",
        "iam:List*",
        "servicequotas:GetServiceQuota",
        "servicequotas:ListServiceQuotas"
      ],
      "Resource": "*"
    }
  ]
}
```

**Input Parameters**:
- `region` (string): AWS region for cluster deployment
- `cluster_config` (object): Cluster configuration (instance types, node count, etc.)

**Output**:
- `validation_results` (array): List of validation checks with pass/fail status
  - `check_name` (string): Name of validation check (e.g., "ec2_quota_check")
  - `status` (string): `passed`, `failed`, or `warning`
  - `message` (string): Details about check result
  - `details` (object): Additional metadata (e.g., current quota, requested quota)

**Runtime**: Go 1.21

**Memory**: 256MB (multiple AWS API calls, JSON processing)

**Timeout**: 300 seconds (5 minutes for comprehensive checks)

---

#### 3. Network Verifier Lambda (`rosa-network-verifier`)

**Purpose**: Validate network configuration (VPC, subnets, route tables, security groups) for cluster deployment

**IAM Permissions** (Execution Role):
```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "ec2:DescribeVpcs",
        "ec2:DescribeSubnets",
        "ec2:DescribeRouteTables",
        "ec2:DescribeSecurityGroups",
        "ec2:DescribeNatGateways",
        "ec2:DescribeInternetGateways",
        "ec2:DescribeVpcEndpoints"
      ],
      "Resource": "*"
    }
  ]
}
```

**Input Parameters**:
- `vpc_id` (string): VPC ID for cluster deployment
- `subnet_ids` (array of strings): Subnet IDs for cluster nodes
- `requirements` (object): Network requirements (e.g., `private_subnets_required: true`)

**Output**:
- `network_validation_results` (array): List of network validation checks
  - `check_name` (string): Name of validation check (e.g., "subnet_has_nat_gateway")
  - `status` (string): `passed`, `failed`, or `warning`
  - `message` (string): Details about check result
  - `resource_id` (string): AWS resource ID (e.g., subnet ID)

**Runtime**: Go 1.21

**Memory**: 256MB (VPC topology analysis)

**Timeout**: 300 seconds (5 minutes for complex network topologies)

**VPC Configuration**: Attach to customer VPC for network testing (optional, if active connectivity tests required)

---

### Integration Flow

#### Account Setup Flow (Customer Onboarding)

1. **Customer runs `rosactl init`** (validation step)
   - `rosactl` is NEW CLI tool for Regional Platform (distinct from existing `rosa` CLI)
   - Validates AWS credentials are configured and valid (using standard AWS credential chain)
   - Verifies Platform API is reachable (authenticates via AWS IAM with SigV4 signing)
   - Verifies AWS region is valid/supported
   - Reports success or errors (e.g., "AWS credentials not found", "Platform API unreachable")

2. **Customer runs `rosactl setup-account`** (Lambda deployment + registration)
   - `rosactl` authenticates to customer AWS account (using standard AWS credential chain)
   - `rosactl` authenticates to Platform API using AWS IAM (SigV4 signing)

3. **`rosactl` deploys Lambda functions to customer account**
   - Authenticates to customer AWS account (AWS credentials from environment or profile)
   - Creates Lambda execution roles with minimal IAM permissions (one role per Lambda)
   - Uploads Lambda deployment packages to customer account (S3 bucket or inline for <50MB packages)
   - Creates Lambda functions with configuration (memory, timeout, environment variables)
   - Adds resource-based policies for cross-account invocation using **Lambda Resource Policy** approach:
     ```bash
     # Example: Add permission for CLM to invoke OIDC provisioner Lambda
     aws lambda add-permission \
       --function-name rosa-oidc-provisioner \
       --statement-id AllowRosaRegionalPlatformInvoke \
       --action lambda:InvokeFunction \
       --principal arn:aws:iam::123456789012:role/CLMServiceRole
     ```
   - Tags Lambdas with `rosa:component=<lambda-name>`, `rosa:version=<version>` for discovery
   - Creates CloudWatch Log Groups with 90-day retention

4. **`rosactl` validates Lambda deployment**
   - Test invocation of each Lambda with sample payload
   - Verifies CLM service role can successfully invoke Lambdas
   - Verifies CloudWatch Logs capture execution
   - Reports success/failure to customer

5. **`rosactl` registers customer account with Platform API**
   - API call to Platform API: `POST /api/v1/accounts`
   - Payload includes: account ID, region, Lambda ARNs, authentication method

#### Cluster Creation Flow

1. **Customer creates cluster via Platform API (or via `rosactl create cluster`)**
   - `rosactl create cluster` makes API call to Platform API: `POST /api/v1/clusters`
   - Platform API validates request and creates cluster resource

2. **Platform API → CLM creates cluster resource**
   - Platform API publishes cluster creation event to Maestro
   - Maestro distributes event to CLM in Regional Cluster

3. **CLM discovers Lambda ARNs**
   - CLM queries customer account for Lambda ARNs by tag (`rosa:component=<component-name>`)
   - Tag-based discovery using AWS Resource Groups Tagging API:
     ```bash
     # Example: Find OIDC provisioner Lambda by tag
     aws resourcegroupstaggingapi get-resources \
       --resource-type-filters "lambda:function" \
       --tag-filters "Key=rosa:component,Values=oidc-provisioner" \
       --query "ResourceTagMappingList[*].ResourceARN" \
       --output text
     ```
   - Alternative approach: Iterate over `aws lambda list-functions` and call `aws lambda list-tags --resource <FunctionArn>` per function to filter client-side
   - CLM caches Lambda ARNs per customer account (refreshes every 24 hours or on error)

4. **CLM invokes Lambdas in sequence**
   - **Step 1: Preflight Check**
     - CLM invokes `rosa-preflight-checker` Lambda
     - Input: region, cluster configuration
     - Validates quotas, IAM permissions, enabled services
     - If validation fails, CLM marks cluster provisioning as failed and reports error to customer

   - **Step 2: Network Verification**
     - CLM invokes `rosa-network-verifier` Lambda
     - Input: VPC ID, subnet IDs, network requirements
     - Validates VPC configuration, subnet routing, security groups
     - If validation fails, CLM marks cluster provisioning as failed and reports error to customer

   - **Step 3: OIDC Provisioning**
     - CLM invokes `rosa-oidc-provisioner` Lambda
     - Input: OIDC issuer URL, thumbprint, cluster ID
     - Creates/updates OIDC provider in customer account
     - Returns OIDC provider ARN

5. **CLM stores results and proceeds with cluster provisioning**
   - CLM stores Lambda invocation results (validation checks, OIDC provider ARN) in database
   - CLM proceeds with HyperShift cluster creation (provisions control plane in Management Cluster)

6. **Maestro distributes cluster configuration to Management Cluster** (optional)
   - Maestro publishes cluster configuration to Management Cluster via MQTT
   - Management Cluster HyperShift operator creates hosted control plane

### Design Decisions and Open Questions

#### Q1: How does CLM authenticate to invoke customer Lambdas?

**✅ DECISION MADE**: **Lambda Resource Policy** selected for authentication

Below are the two options that were evaluated, with Lambda Resource Policy chosen as the preferred approach.

---

### Option A: AssumeRole with External ID

**Overview**: Customer creates IAM role that trusts RH Regional Platform account. CLM assumes this role before invoking Lambdas.

**Setup (performed by `rosactl`)**:

1. **Create IAM Role in Customer Account**:

```json
{
  "RoleName": "RosaRegionalPlatformAccess",
  "AssumeRolePolicyDocument": {
    "Version": "2012-10-17",
    "Statement": [
      {
        "Effect": "Allow",
        "Principal": {
          "AWS": "arn:aws:iam::123456789012:role/CLMServiceRole"
        },
        "Action": "sts:AssumeRole",
        "Condition": {
          "StringEquals": {
            "sts:ExternalId": "${CUSTOMER_ORG_ID}"
          }
        }
      }
    ]
  }
}
```

2. **Attach IAM Policy to Role**:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": "lambda:InvokeFunction",
      "Resource": [
        "arn:aws:lambda:*:${CUSTOMER_ACCOUNT_ID}:function:rosa-oidc-provisioner:prod",
        "arn:aws:lambda:*:${CUSTOMER_ACCOUNT_ID}:function:rosa-preflight-checker:prod",
        "arn:aws:lambda:*:${CUSTOMER_ACCOUNT_ID}:function:rosa-network-verifier:prod"
      ]
    }
  ]
}
```

**CLM Invocation Code**:

```go
// Assume role in customer account
stsClient := sts.NewFromConfig(cfg)
assumeRoleOutput, err := stsClient.AssumeRole(ctx, &sts.AssumeRoleInput{
    RoleArn:         aws.String("arn:aws:iam::987654321098:role/RosaRegionalPlatformAccess"),
    RoleSessionName: aws.String(fmt.Sprintf("rosa-clm-%s", clusterID)),
    ExternalId:      aws.String(customerOrgID),
    DurationSeconds: aws.Int32(3600),
})
if err != nil {
    return fmt.Errorf("failed to assume role: %w", err)
}

// Create Lambda client with assumed role credentials
lambdaCfg := aws.Config{
    Region: aws.String(region),
    Credentials: credentials.NewStaticCredentialsProvider(
        *assumeRoleOutput.Credentials.AccessKeyId,
        *assumeRoleOutput.Credentials.SecretAccessKey,
        *assumeRoleOutput.Credentials.SessionToken,
    ),
}
lambdaClient := lambda.NewFromConfig(lambdaCfg)

// Invoke Lambda
payload, _ := json.Marshal(map[string]interface{}{
    "issuer_url": "https://oidc.example.com",
    "thumbprint": "abc123...",
    "cluster_id": clusterID,
})

invokeOutput, err := lambdaClient.Invoke(ctx, &lambda.InvokeInput{
    FunctionName: aws.String("rosa-oidc-provisioner:prod"),
    Payload:      payload,
})
```

**Pros**:
- Familiar IAM pattern (widely used for cross-account access)
- Customer has full control (can revoke access by deleting role)
- External ID prevents confused deputy attacks
- Customer can audit role assumptions via CloudTrail
- Can scope role session duration (15 min - 12 hours)

**Cons**:
- Additional IAM role to manage per customer account
- Role assumption adds latency (extra STS API call ~100-200ms per invocation)
- CLM must manage temporary credentials (expiration, renewal)
- Role ARN must be discovered/stored by CLM

---

### Option B: Lambda Resource Policy

**Overview**: Each Lambda has resource-based policy allowing direct invocation from RH Regional Platform account. No role assumption needed.

**Setup (performed by `rosactl`)**:

1. **Add Resource Policy to Each Lambda**:

```bash
# For OIDC Provisioner Lambda
aws lambda add-permission \
  --function-name rosa-oidc-provisioner \
  --statement-id AllowRosaRegionalPlatformInvoke \
  --action lambda:InvokeFunction \
  --principal arn:aws:iam::123456789012:role/CLMServiceRole
```

**Resulting Lambda Resource Policy** (visible via `aws lambda get-policy`):

```json
{
  "Version": "2012-10-17",
  "Id": "default",
  "Statement": [
    {
      "Sid": "AllowRosaRegionalPlatformInvoke",
      "Effect": "Allow",
      "Principal": {
        "AWS": "arn:aws:iam::123456789012:role/CLMServiceRole"
      },
      "Action": "lambda:InvokeFunction",
      "Resource": "arn:aws:lambda:us-east-1:987654321098:function:rosa-oidc-provisioner"
    }
  ]
}
```

**CLM Invocation Code**:

```go
// Use CLM's own IAM credentials (no role assumption needed)
lambdaClient := lambda.NewFromConfig(cfg) // cfg uses CLM service role

// Invoke Lambda directly
payload, _ := json.Marshal(map[string]interface{}{
    "issuer_url": "https://oidc.example.com",
    "thumbprint": "abc123...",
    "cluster_id": clusterID,
})

invokeOutput, err := lambdaClient.Invoke(ctx, &lambda.InvokeInput{
    FunctionName: aws.String("arn:aws:lambda:us-east-1:987654321098:function:rosa-oidc-provisioner:prod"),
    Payload:      payload,
})
if err != nil {
    return fmt.Errorf("failed to invoke lambda: %w", err)
}
```

**Pros**:
- Simpler architecture (no additional IAM roles)
- No role assumption latency (100-200ms saved per invocation)
- No credential management (CLM uses its own long-lived credentials)
- Fewer IAM entities to manage
- Lambda function ARN is sufficient (no need to discover role ARN)

**Cons**:
- Trust is at AWS account level (trusts entire RH Regional Platform account)
  - Mitigated by scoping principal to specific CLM service role ARN (not entire account)
- Harder to revoke access (customer must update all Lambda resource policies)
  - Requires updating 3-5 Lambda policies vs deleting 1 role
  - Can be automated via `rosactl cleanup-access` command
- Customer has less visibility (no AssumeRole CloudTrail events)
  - Still visible via Lambda invocation CloudWatch Logs
  - CloudTrail shows Lambda invocations with principal information

---

### ✅ Selected Approach: Option B (Lambda Resource Policy)

**Rationale for Selection**:

1. **Simpler for Customers**: No additional IAM role to create/manage
2. **Better Performance**: Eliminates 100-200ms STS call per Lambda invocation (significant for 3-5 sequential Lambda calls = 500ms+ saved)
3. **Easier Operations**: CLM credential management simpler (no temporary credentials to renew)
4. **Sufficient Security**: Resource policy scoped to specific CLM role ARN prevents unauthorized access

**Security Parity**: Both options provide equivalent security when properly configured:
- AssumeRole: Trust policy + external ID + scoped role policy
- Resource Policy: Principal ARN scoping (specific CLM role) + scoped resource policy

**Future Migration Path**: If customer requires stronger isolation later, can add AssumeRole requirement (Lambda resource policy + AssumeRole both enforced)

---

**Implementation Impact**:
- `rosactl setup-account` will add resource policies to each Lambda (via `aws lambda add-permission`)
- CLM will invoke Lambdas directly using its service role credentials (no STS AssumeRole call)
- CloudWatch Logs will show Lambda invocations with CLM service role principal

---

#### Q2: How does `rosactl` CLI work?

**✅ DECISIONS MADE** (Partial - some details still TBD):

### Architecture & State Management

- **Stateless**: `rosactl` maintains no local state (can run from any machine with same credentials)
- **Direct AWS operations**: Lambda deployment goes directly to customer AWS account
- **Platform API passthrough**: Cluster operations go through Platform API → CLM
- **Platform API is stateless**: Acts as passthrough to CLM (CLM holds state)

### Authentication

- **Credentials**: Only AWS credentials required (no separate Red Hat credentials)
- **Platform API authentication**: Uses AWS IAM (customer's AWS credentials authenticate to Platform API)
- **Credential chain**: Standard AWS credential chain (profiles, environment variables, IAM roles)
  - Supports `--profile` flag for AWS profiles
  - Supports standard environment variables (`AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, etc.)
  - Supports IAM instance/task roles

### Command Flow

Modeled after existing `rosa` CLI multi-step workflow, but simplified (no `--interactive`, no `--mode auto/manual`):

```bash
# Step 1: Basic validation
rosactl init
# - Validates AWS credentials are configured and valid
# - Verifies Platform API is reachable (authenticate via AWS IAM)
# - Verifies AWS region is valid/supported
# - Does NOT do comprehensive preflight checks (that happens via Lambda later)

# Step 2: Deploy Lambdas and register account
rosactl setup-account
# - Deploys 3 Lambda functions to customer AWS account
# - Configures Lambda resource policies (allow CLM invocation)
# - Creates CloudWatch Log Groups with 90-day retention
# - Creates Lambda execution roles with minimal IAM permissions
# - Calls Platform API to register account (stores account ID, Lambda ARNs, region)
# - Validates deployment with test invocations

# Step 3: Create cluster
rosactl create cluster --name <name> --vpc-id <vpc> --subnet-ids <subnets>
# Behavior TBD: Pure API passthrough vs local validation first?
# Makes POST /api/v1/clusters call to Platform API
# Platform API → CLM → Lambda invocations → cluster provisioning
```

### Design Rationale

**Why multi-step vs single command?**
- Mirrors existing `rosa` CLI flow (familiar to customers migrating from ROSA HCP)
- Separates validation (`init`) from setup (`setup-account`) from cluster creation
- Allows customers to verify credentials before deploying Lambdas
- Enables future merging of steps if needed (e.g., `rosactl setup-account --skip-init`)

**Why no `--interactive` or `--mode auto/manual`?**
- Simpler UX (fewer flags to understand)
- Lambda deployment is straightforward (no complex IAM policy decisions like ROSA account-roles)
- Customers can review Lambda code/policies before running `setup-account` if desired
- Future: Can add these flags later if customer feedback requests them

### Open Questions (Still TBD)

- **`rosactl create cluster` behavior**: Should it do local validation (check VPC exists, subnets exist) or pure passthrough to Platform API?
- **Other commands needed**: `update-lambdas`, `delete cluster`, `list clusters`, `describe cluster`, `logs`, etc.?
- **Error handling**: If Lambda deployment fails mid-way (2 of 3 Lambdas created), does `setup-account` rollback or support resume?
- **Update/migration commands**: `rosactl update-lambdas`, `rosactl migrate-account` (for existing ROSA HCP customers)?

**Impact**: Affects customer onboarding experience and automation

**Timeline**: Complete remaining decisions before implementation

---

#### Q3: What is the "OIDC controller" in the diagram?

**Questions**:
- Is this a Lambda function or a service in CLM?
- If a service, what is its role in the Lambda flow?
- How does it interact with the OIDC Provisioning Lambda?

**Impact**: Affects component architecture and responsibilities

**Timeline**: Clarify before implementation

---

### Migration Requirements and Processes

* **Context**: The ROSA HCP service is currently active with existing customers using OIDC/STS model. The ROSA Regional HCP service must support migrating existing customers and clusters to the Lambda-based model.

* **Migration Strategy**:
  - **Day 1 Requirement**: Regional Platform must support existing ROSA HCP customers without forced migration
  - **Dual Mode Support**: CLM supports both OIDC/STS (legacy) and Lambda-based (new) access methods
  - **Gradual Migration**: Customers migrate at their own pace; no forced cutover date
  - **Backward Compatibility**: Existing ROSA HCP clusters continue using OIDC/STS until customer opts into Lambda model

* **Migration Process for Existing Customers**:
  1. Customer receives migration notification: "ROSA Regional Platform now supports Lambda-based access for enhanced security"
  2. Customer reviews Lambda model benefits (granular permissions, audit trails, versioning)
  3. Customer runs `rosactl migrate-account` to deploy Lambdas to their account
  4. `rosactl` validates OIDC/STS configuration still works (backward compatibility test)
  5. `rosactl` deploys Lambda functions alongside existing OIDC provider (no disruption)
  6. CLM detects Lambda functions via tags; switches to Lambda-based access for new operations
  7. Existing clusters continue using OIDC/STS; new clusters use Lambda-based access
  8. After validation period (30-90 days), customer can optionally remove OIDC provider (legacy cleanup)

* **Migration Validation**:
  - `rosactl migrate-account --dry-run` simulates migration without making changes
  - `rosactl test-migration` validates Lambda deployment and CLM connectivity
  - Rollback plan: If Lambda-based access fails, CLM falls back to OIDC/STS (automatic)

* **Migration Timeline**:
  - **Month 1-3**: Regional Platform launches with dual mode support (OIDC/STS + Lambda)
  - **Month 4-6**: Customer education and migration campaigns
  - **Month 7-12**: Gradual customer migration; operations team monitors adoption
  - **Month 13+**: Evaluate deprecation of OIDC/STS model (only if >90% customers migrated)

* **Migration Risks**:
  - **Customer Adoption**: Customers may not migrate if perceived as complex (mitigation: automated `rosactl migrate-account`)
  - **Dual Mode Complexity**: CLM must support both access methods (mitigation: well-tested fallback logic)
  - **IAM Policy Conflicts**: Lambda execution roles may conflict with existing IAM policies (mitigation: use unique role names)
  - **Migration Failures**: Lambda deployment may fail in some customer accounts (mitigation: detailed error messages, support runbooks)

---

## Related Documentation

- **ROSA HCP OIDC/STS Flow**: https://gist.github.com/jmelis/1b2de46a2401cc01f1822c629548ca22
- **Regional Account Minting** (planned): How customer accounts are provisioned for Regional Platform
- **Fully Private EKS Bootstrap**: `docs/design-decisions/001-fully-private-eks-bootstrap.md` - Similar pattern of executing operations without direct cluster access
- **Platform API Repository**: https://github.com/openshift-online/rosa-regional-platform-api
- **Maestro Repository**: https://github.com/openshift-online/maestro
- **CLM (HyperFleet) Components**:
  - HyperFleet API: https://github.com/openshift-hyperfleet/hyperfleet-api
  - HyperFleet Sentinel: https://github.com/openshift-hyperfleet/hyperfleet-sentinel
  - HyperFleet Adapter: https://github.com/openshift-hyperfleet/hyperfleet-adapter
- **Current ROSA CLI** (for reference, NOT reused): https://github.com/openshift/rosa