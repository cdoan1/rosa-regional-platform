# rosa-regional-platform

For the full architecture overview, see [docs/README.md](docs/README.md).

## Repository Structure

```
rosa-regional-platform/
├── argocd/
│   └── config/                       # Live Helm chart configurations
│       ├── applicationset/           # ApplicationSet templates
│       ├── management-cluster/       # Management cluster application templates
│       ├── regional-cluster/         # Regional cluster application templates
│       └── shared/                   # Shared configurations (ArgoCD, etc.)
├── ci/                               # CI automation (e2e tests, janitor)
├── deploy/                           # Per-environment deployment configs
├── docs/                             # Design documents and presentations
├── hack/                             # Developer utility scripts
├── scripts/                          # Dev and pipeline scripts
└── terraform/
    ├── config/                       # Terraform root configurations
    └── modules/                      # Reusable Terraform modules
```

## Getting Started

### Pipeline-Based Provisioning (CI/CD)

This is the standard way to provision a region. A central AWS account hosts CodePipelines that automatically provision Regional and Management Clusters when configuration is committed to Git.

See [Provision a New Central Pipeline](docs/central-pipeline-provisioning.md) for the full walkthrough.

### Local Provisioning (Development)

> **Note:** Local provisioning is intended for development and debugging only. Prefer the pipeline-based approach above.

For manual provisioning using `make` targets and local `.tfvars` files, see [Local Region Provisioning](docs/full-region-provisioning.md). For all available `make` targets, run `make help`.

## CI

CI is managed through the [OpenShift CI](https://docs.ci.openshift.org/) system (Prow + ci-operator). The job configuration lives in [openshift/release](https://github.com/openshift/release/tree/master/ci-operator/config/openshift-online/rosa-regional-platform).

For the list of jobs, how to trigger them, AWS credentials setup, and local execution, see [ci/README.md](ci/README.md).
