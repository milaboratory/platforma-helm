# Cloud Shell tutorial — Platforma on GCP

Tier-1 quickstart: opens in Google Cloud Shell, walks the user through a
handful of inputs, submits an Infrastructure Manager deployment, polls it
to completion. ~25 minutes end to end.

## Open in Cloud Shell

[![Open in Cloud Shell](https://gstatic.com/cloudssh/images/open-btn.svg)](https://shell.cloud.google.com/cloudshell/editor?cloudshell_git_repo=https://github.com/milaboratory/platforma-helm&cloudshell_workspace=infrastructure/gcp/cloudshell&cloudshell_tutorial=tutorial.md)

Or copy this URL anywhere you want users to start (docs, email, slide deck):

```
https://shell.cloud.google.com/cloudshell/editor?cloudshell_git_repo=https://github.com/milaboratory/platforma-helm&cloudshell_workspace=infrastructure/gcp/cloudshell&cloudshell_tutorial=tutorial.md
```

## Files

| File | Purpose |
|---|---|
| [`tutorial.md`](tutorial.md) | Cloud Shell walkthrough rendered in the side panel |
| [`install.sh`](install.sh) | Driver script — collects inputs, sets up SA, submits IM deployment, polls to completion |

## Running outside Cloud Shell

`install.sh` works anywhere with `gcloud` configured against the target
project. Pre-fill any prompt by exporting the matching env var:

```bash
export PROJECT_ID=my-project
export DEPLOYMENT_NAME=platforma
export REGION=europe-west1
export ZONE_SUFFIX=b
export DEPLOYMENT_SIZE=small
export DOMAIN_NAME=platforma.mycompany.bio
export DNS_ZONE_NAME=mycompany-bio
export CONTACT_EMAIL=ops@mycompany.bio
export ENABLE_DEMO=true
export LICENSE_KEY=E-XXXXX...
./install.sh
```

## Deployment size presets

`var.deployment_size` (set via the `DEPLOYMENT_SIZE` prompt) controls node-pool
maxes, Kueue batch queue quotas, Filestore default capacity, and the values
the installer requests via `google_cloud_quotas_quota_preference`.

All presets share the same per-job cap of **62 vCPU / 500 GiB RAM** — the
preset only controls how many such jobs can run in parallel.

| Preset | Parallel jobs | UI nodes max | Filestore (GiB) | CPUs (global) | N2D CPUs (region) | PD SSD GB (region) | Filestore Zonal GiB (region) | Instances (region) |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| `small`  |  4 |  4 | 1024 |  512 |  512 |  2048 | 1024 |  32 |
| `medium` |  8 |  8 | 2048 | 1024 | 1024 |  4096 | 2048 |  48 |
| `large`  | 16 | 16 | 4096 | 2048 | 2048 |  8192 | 4096 |  64 |
| `xlarge` | 32 | 16 | 8192 | 4096 | 4096 | 16384 | 8192 | 128 |

Source of truth: [`presets.tf`](../terraform/presets.tf). When changing
preset values there, also update:

- The lookup tables in [`install.sh`](install.sh) (`PRESET_CPUS_GLOBAL`,
  `PRESET_N2D_CPUS`, `PRESET_PD_SSD_GB`, `PRESET_INSTANCES`,
  `PRESET_FILESTORE_GB`) — used for the auto-detect / warn-if-too-low logic.
- The user-facing copy of this table in `infrastructure/gcp/README.md`
  (Phase 7 runbook).

### Quota collision handling

If the user's project already has user-managed `QuotaPreference` records
for any of the keys we'd request (created previously via Console, gcloud,
or another stack), Cloud Quotas API rejects duplicate creates and exposes
no DELETE method. `install.sh` handles this automatically:

1. Queries `gcloud beta quotas preferences list` at startup.
2. For each match, adds the corresponding key to `skip_quota_requests`
   (TF variable that opts out of specific quota_preference resources).
3. Compares the existing `preferredValue` against the preset's required
   value — emits a warning + asks for confirmation when below.

## Bumping the bundle version

`install.sh` references a published Infrastructure Manager bundle:

```bash
IM_BUNDLE_VERSION="${IM_BUNDLE_VERSION:-dev-787bc64}"
```

On each tagged release of the chart repo:
1. CI workflow `publish-gcp-im.yaml` publishes
   `gs://platforma-infrastructure-manager/platforma-gcp-<version>.tar.gz`
2. Update `IM_BUNDLE_VERSION` in `install.sh` to the new version.
3. Merge to `main`. Next user click of the Cloud Shell button picks up
   the new version automatically (Cloud Shell always clones HEAD).

The bundle URL is intentionally **versioned, not `latest.tar.gz`** —
deployments are reproducible and updates are explicit (parity with the
AWS CloudFormation runbook approach, where the YAML filename includes
the version).
