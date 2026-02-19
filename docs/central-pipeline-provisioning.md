# Complete Guide: Provision a New Central Pipeline

This comprehensive guide walks through all steps to provision a new central pipeline in the ROSA Regional Platform. Follow these steps in order to set up a central pipeline that will provision both Regional and Management Clusters with full ArgoCD configuration and Maestro connectivity.

---

## 1. Pre-Flight Checklist

Before starting, ensure your environment is properly configured.

### Required Tools
Verify all tools are installed and accessible:

```bash
# Check tool versions
aws --version
terraform --version
python --version  # or python3 --version
```

### Required AWS accounts

To provision a regional and management cluster, you require three AWS accounts. One account for Central, one account for the Regional Cluster, and one account for the Management Cluster.  Ensure you have access to the designated Central account via environment variables or ideally AWS profiles. 

The 2 accounts designated for the Regional Cluster and Management Cluster require additional configuration.  Add the Central AWS account number to the trust policy of `OrganizationAccountAccessRole` in the 2 regional and management accounts.

## 2. Configure a new Sector/Region Deployment

<details>
<summary>🔧 Configure New Region Deployment</summary>

### Add Sector to Configuration

Edit `config.yaml` and add your new sector following this pattern:

```yaml
sectors:
  # ... existing entries ...
  - name: "brian-testing"
    environment: "brian"
    terraform_vars:
      app_code: "infra"
      service_phase: "dev"
      cost_center: "000"
      environment: "{{ environment }}"
    values:
      management-cluster:
        hypershift:
          oidcStorageS3Bucket:
            name: "hypershift-mc-{{ aws_region }}"
            region: "{{ aws_region }}"
          externalDns:
            domain: "dev.{{ aws_region }}.rosa.example.com"
```

### Add Region to Configuration

Edit `config.yaml` and add your new region following this pattern:

```yaml
region_deployments:
  # ... existing entries ...
  - name: "us-east-1"
    aws_region: "us-east-1"
    sector: "brian"
    account_id: "<Regional account>"
    terraform_vars:
      account_id: "{{ account_id }}"
      region: "{{ aws_region }}"
      alias: "regional-{{region_alias}}"
      region_alias: "{{ region_alias }}"
    management_clusters:
      - cluster_id: "mc01-{{ region_alias }}"
        account_id: "<Management Account>"
```

### Generate Rendered Configurations

Run the rendering script to generate the required files:

```bash
./scripts/render.py
```

**Verify rendered files were created:**

```bash
ls -la deploy/<sector>/<region>/  # Replace with your environment/name
```

You should see `argocd/` and `terraform/` subdirectories with generated configs.

### Commit and Push Changes

```bash
git add config.yaml deploy/
git commit -m "$(cat <<'EOF'
Add <region> region configuration

- Add <region>/<sector> to config.yaml
- Generate deploy configs (argocd + terraform)
- Prepare for regional cluster provisioning
EOF
)"
git push origin <your-branch>
```

</details>

---

## 3. Central Pipeline Provisioning

Switch to your **central account** AWS profile and provision the pipeline.

### Execute central pipeline bootstrap

```bash
# Authenticate with central account (choose your preferred method)
export AWS_PROFILE=<central-profile>
# OR: aws configure set profile <regional-profile>
# OR: use your SSO/assume role method

# Bootstrap the pipeline
GITHUB_REPO_OWNER=<ORG> GITHUB_REPO_NAME=rosa-regional-platform GITHUB_BRANCH=<BRANCH> TARGET_ENVIRONMENT=<SECTOR> ./scripts/bootstrap-central-account.sh
```

### Accept the Codestar connection

As a single manual process, you must accept the CodeStar connection.  

Log into the Central AWS Account console.  

`Developer Tools` > `Settings` > `Connections` > `Accept the pending connection`

Since the pipeline was deployed before the connection was accepted, you must retrigger the `CodePipeline`.

The `pipeline-provisioner` will begin creating new pipelines for any configured regions in the specified sector.  You should expect to see 2 new pipelines.  One for the regional cluster deployment and 1 for the management cluster deployment.  

### Verify Regional Cluster Deployment (optional)

<details>
<summary>🔍 Verify Regional Cluster Deployment (optional)</summary>

```bash
# Check ArgoCD applications are synced
./scripts/dev/bastion-connect.sh regional
kubectl get applications -n argocd
```

Expected: ArgoCD applications "Synced" and "Healthy".

</details>

---

## 4. Verify Maestro Connectivity

Maestro uses AWS IoT Core for secure MQTT communication between Regional and Management Clusters. This requires a two-account certificate exchange process.

<details>
<summary>🔍 Verify IoT Resources (optional)</summary>

```bash
# Choose your preferred authentication method
export AWS_PROFILE=<regional-profile>
# OR: use --profile flag, SSO, assume role, etc.
```

```bash
# In regional account - verify IoT endpoint
aws iot describe-endpoint --endpoint-type iot:Data-ATS

# Check certificate is active
aws iot list-certificates
```

Expected: IoT endpoint URL should be returned and certificate should show "ACTIVE" status.

</details>

---

## 5. Verify Management Cluster Provisioning

<details>
<summary>🔍 Verify Management Cluster Deployment (optional)</summary>

```bash
# Authenticate with management account (choose your preferred method)
export AWS_PROFILE=<management-profile>
# OR: aws configure set profile <management-profile>
# OR: use your SSO/assume role method
```

```bash
# Check cluster is provisioned
./scripts/dev/bastion-connect.sh management

# Verify ArgoCD applications
kubectl get applications -n argocd
```

Expected: ArgoCD applications "Synced" and "Healthy".

</details>

---
The pipeline process current ends here.  For the remaining manual directions, follow [Consumer Registration & Verification](https://github.com/openshift-online/rosa-regional-platform/blob/main/docs/full-region-provisioning.md#6-consumer-registration--verification)
