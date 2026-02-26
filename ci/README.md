# CI

## Triggering the Nightly Job Manually

1. Obtain an API token by visiting <https://oauth-openshift.apps.ci.l2s4.p1.openshiftapps.com/oauth/token/request>
2. Log in with `oc login`
3. Start the job:

```bash
curl -X POST \
    -H "Authorization: Bearer $(oc whoami -t)" \
    'https://gangway-ci.apps.ci.l2s4.p1.openshiftapps.com/v1/executions/' \
    -d '{"job_name": "periodic-ci-openshift-online-rosa-regional-platform-main-nightly", "job_execution_type": "1"}'
```

## AWS Credentials

The nightly job (`periodic-ci-openshift-online-rosa-regional-platform-main-nightly`) uses two AWS accounts (regional and management). It runs on a daily cron (`0 7 * * *`).

Credentials are stored in Vault at `kv/selfservice/cluster-secrets-rosa-regional-platform-int/nightly-static-aws-credentials` and mounted at `/var/run/rosa-credentials/` with keys `regional_access_key`, `regional_secret_key`, `management_access_key`, `management_secret_key`.

### Where things are defined

- **CI job config**: [`openshift/release` — `ci-operator/config/openshift-online/rosa-regional-platform/`](https://github.com/openshift/release/tree/master/ci-operator/config/openshift-online/rosa-regional-platform)

## Nightly Resources Janitor

The nightly e2e tests create ~72 types of AWS resources across two accounts. Teardown relies on `terraform destroy`, which can fail and leak resources. The **nightly-resources-janitor** job is a weekly fallback that purges everything except the CI identity (`nightly-e2e` IAM user) using [aws-nuke](https://github.com/ekristen/aws-nuke).

- **Schedule**: Sundays at 12:00 UTC (`0 12 * * 0`)
- **Prow job**: `periodic-ci-openshift-online-rosa-regional-platform-main-nightly-resources-janitor`
- **Script**: `ci/nightly-resources-janitor.sh` — runs `ci/janitor/purge-aws-account.sh` against both CI accounts
- **Dry-run toggle**: Set `DRY_RUN=true` at the top of `ci/nightly-resources-janitor.sh` to list resources without deleting

### What is preserved

- IAM User `nightly-e2e` (access keys, policies, group memberships)
- IAM Role `OrganizationAccountAccessRole` (and its policies)
- AWS service-linked roles (`/aws-service-role/*`)

### Running locally

```bash
# Dry-run (list only, no deletions)
./ci/janitor/purge-aws-account.sh

# Live run (actually delete resources)
./ci/janitor/purge-aws-account.sh --no-dry-run
```

The script uses whatever AWS credentials are active in your environment. The account must be in the allowlist in `purge-aws-account.sh`.

## Test Results

Results are available on the [OpenShift CI Prow dashboard](https://prow.ci.openshift.org/?job=periodic-ci-openshift-online-rosa-regional-platform-main-nightly).
