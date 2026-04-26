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
