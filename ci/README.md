# CI

CI is managed through the [OpenShift CI](https://docs.ci.openshift.org/) system (Prow + ci-operator). The job configuration lives in [openshift/release](https://github.com/openshift/release/tree/master/ci-operator/config/openshift-online/rosa-regional-platform).

## Jobs

| Job                                                                                                                                                                                       | Schedule                  | Description                                                                                                    |
| ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------- | -------------------------------------------------------------------------------------------------------------- |
| [`terraform-validate`](https://prow.ci.openshift.org/job-history/gs/test-platform-results/pr-logs/directory/pull-ci-openshift-online-rosa-regional-platform-main-terraform-validate)      | Pre-submit                | Runs `terraform validate` on all root modules                                                                  |
| [`helm-lint`](https://prow.ci.openshift.org/job-history/gs/test-platform-results/pr-logs/directory/pull-ci-openshift-online-rosa-regional-platform-main-helm-lint)                        | Pre-submit                | Lints Helm charts                                                                                              |
| [`check-rendered-files`](https://prow.ci.openshift.org/job-history/gs/test-platform-results/pr-logs/directory/pull-ci-openshift-online-rosa-regional-platform-main-check-rendered-files)  | Pre-submit                | Verifies rendered deploy files are up to date                                                                  |
| [`on-demand-e2e`](https://prow.ci.openshift.org/job-history/gs/test-platform-results/pr-logs/directory/pull-ci-openshift-online-rosa-regional-platform-main-on-demand-e2e)                | Pre-submit (manual)       | Full e2e: provisions ephemeral environment, runs tests, tears down. Trigger with `/test on-demand-e2e` on a PR |
| [`nightly`](https://prow.ci.openshift.org/job-history/gs/test-platform-results/logs/periodic-ci-openshift-online-rosa-regional-platform-main-nightly)                                     | Daily at 07:00 UTC        | End-to-end provisioning and test suite against `main`                                                          |
| [`nightly-resources-janitor`](https://prow.ci.openshift.org/job-history/gs/test-platform-results/logs/periodic-ci-openshift-online-rosa-regional-platform-main-nightly-resources-janitor) | Weekly (Sunday 12:00 UTC) | Purges leaked AWS resources using [aws-nuke](https://github.com/ekristen/aws-nuke)                             |

## Build Image

The CI image is built from [ci/Containerfile](ci/Containerfile) and includes all required tools (Terraform, Helm, AWS CLI, Python/uv, etc.).

## Pre-merge / Ephemeral Environment

The [ci/pre-merge.py](ci/pre-merge.py) script manages ephemeral environments for CI testing. It supports two modes — provision and teardown — designed to run as separate CI steps with tests in between.

1. Creates a CI-owned git branch from the source repo/branch
2. Bootstraps the pipeline-provisioner pointing at the CI branch
3. Pushes rendered deploy files to trigger pipelines via GitOps
4. Waits for RC/MC pipelines to provision infrastructure
5. (Separate CI step) Runs the testing suite against the provisioned environment
6. Tears down infrastructure via GitOps (`delete: true` in config.yaml)
7. Destroys the pipeline-provisioner
8. CI branch is retained for post-run troubleshooting (delete manually via `git push ci --delete <branch>`)

### Running locally

```bash
# Requires uv (https://docs.astral.sh/uv/)

# Provision
BUILD_ID=abc123 ./ci/pre-merge.py --repo owner/repo --branch my-feature --creds-dir /path/to/credentials

# Run tests (separate step, same BUILD_ID)

# Teardown
BUILD_ID=abc123 ./ci/pre-merge.py --teardown --repo owner/repo --branch my-feature --creds-dir /path/to/credentials
```

### Triggering the E2E Job Manually

1. Obtain an API token by visiting <https://oauth-openshift.apps.ci.l2s4.p1.openshiftapps.com/oauth/token/request>
2. Log in with `oc login`
3. Start the job:

```bash
curl -X POST \
    -H "Authorization: Bearer $(oc whoami -t)" \
    'https://gangway-ci.apps.ci.l2s4.p1.openshiftapps.com/v1/executions/' \
    -d '{"job_name": "periodic-ci-openshift-online-rosa-regional-platform-main-nightly", "job_execution_type": "1"}'
```

4. Copy the `id` from the response and check the execution to get the Prow URL:

```bash
curl -X GET \
    -H "Authorization: Bearer $(oc whoami -t)" \
    'https://gangway-ci.apps.ci.l2s4.p1.openshiftapps.com/v1/executions/<id>'
```

Open the `job_url` from the response to watch the job in Prow.

## Download CodeBuild Logs

`ci/download-codebuild-logs.py` downloads CloudWatch logs for all CodeBuild projects matching a CI prefix. It fetches every log stream (build run) per project and names files with timestamps (e.g. `ci-202982-regional-apply.20260306-075604.log`) for chronological ordering. ANSI color codes are stripped from the output.

```bash
# Download all logs for a CI run (requires uv)
./ci/download-codebuild-logs.py ci-202982

# Specify a region (default: us-east-1)
./ci/download-codebuild-logs.py ci-202982 --region eu-west-1
```

Logs are saved to `codebuild-logs-<ci-prefix>/`. The same download logic is used by `ephemerallib` to collect logs into Prow artifacts (with additional secret redaction).

## AWS Credentials

The e2e job uses three sets of AWS credentials (central, regional, and management accounts).

Credentials are stored in Vault at `kv/selfservice/cluster-secrets-rosa-regional-platform-int/nightly-static-aws-credentials` and mounted at `/var/run/rosa-credentials/` with keys:

- `ci_access_key`, `ci_secret_key`, `ci_assume_role_arn` — Central account (base credentials + AssumeRole)
- `regional_access_key`, `regional_secret_key` — Regional sub-account
- `management_access_key`, `management_secret_key` — Management sub-account
- `github_token` — GitHub token with push access for creating CI branches

## Nightly Resources Janitor

The e2e tests create AWS resources across multiple accounts. Teardown relies on `terraform destroy`, which can fail and leak resources. The **nightly-resources-janitor** job is a weekly fallback that purges everything except resources we need to keep between tests using [aws-nuke](https://github.com/ekristen/aws-nuke).

### What is preserved

See `./ci/aws-nuke-config.yaml`.

### Running locally

```bash
# Dry-run (list only, no deletions)
./ci/janitor/purge-aws-account.sh

# Live run (actually delete resources)
./ci/janitor/purge-aws-account.sh --no-dry-run
```

The script uses whatever AWS credentials are active in your environment. The account must be in the allowlist in `purge-aws-account.sh`.
