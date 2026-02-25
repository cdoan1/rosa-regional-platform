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

## AWS Accounts and Boskos Leases

The nightly job (`periodic-ci-openshift-online-rosa-regional-platform-main-nightly`) provisions infrastructure across two AWS accounts. It runs on a daily cron (`0 7 * * *`) and uses [Boskos](https://docs.ci.openshift.org/docs/architecture/quota-and-leases/) to lease quota-slices for concurrency control, ensuring parallel runs don't collide.

Each account has its own Boskos pool, both pinned to us-east-1 so both accounts are always in the same region:

| Account | Boskos Pool | Env Var |
|---------|-------------|---------|
| Account 0 (regional) | `rosa-regional-platform-int-account-0-quota-slice` | `ACCOUNT_0_LEASE` (region) |
| Account 1 (management) | `rosa-regional-platform-int-account-1-quota-slice` | `ACCOUNT_1_LEASE` (region) |

Both leases are explicit (no `cluster_profile`). AWS credentials are mounted from a separate secret at `/var/run/rosa-credentials/` with keys `regional_access_key`, `regional_secret_key`, `management_access_key`, `management_secret_key`.

### Where things are defined

- **Boskos pool definitions**: [`openshift/release` — `core-services/prow/02_config/generate-boskos.py`](https://github.com/openshift/release/blob/master/core-services/prow/02_config/generate-boskos.py) (search for `rosa-regional-platform-int`)
- **CI job configuration**: [`openshift/release` — `ci-operator/config/openshift-online/rosa-regional-platform/`](https://github.com/openshift/release/tree/master/ci-operator/config/openshift-online/rosa-regional-platform)
- **Credentials (Vault)**: `kv/selfservice/cluster-secrets-rosa-regional-platform-int/nightly-static-aws-credentials`, synced to build clusters as `rosa-regional-platform-nightly-static-creds` in `test-credentials` namespace

### Boskos janitor

A [Boskos janitor](https://docs.ci.openshift.org/docs/architecture/quota-and-leases/) runs in the CI cluster and automatically releases leases that were not properly returned (e.g., if a job is killed or times out). This prevents leaked leases from permanently blocking the pool.

## Test Results

Results are available on the [OpenShift CI Prow dashboard](https://prow.ci.openshift.org/?job=periodic-ci-openshift-online-rosa-regional-platform-main-nightly).
