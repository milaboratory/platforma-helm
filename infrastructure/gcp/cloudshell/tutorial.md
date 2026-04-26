# Deploy Platforma on Google Cloud

<walkthrough-disable-features toc/>

This walkthrough deploys [Platforma](https://platforma.bio) on Google Cloud using
**Infrastructure Manager** (Google's managed Terraform service). The installer
provisions everything needed to run Platforma in production:

- A GKE Standard cluster with auto-scaling node pools (system + UI + batch)
- Filestore (SSD) for shared workspace storage
- Google Cloud Storage bucket for primary results
- Workload Identity for keyless GCP API access
- Kueue + AppWrapper for batch job scheduling
- HTTPS ingress (Cloud DNS + Certificate Manager + Gateway API)
- The Platforma Helm release itself

End to end takes **~20-25 minutes**. You only need to fill in a handful of
values; this tutorial guides you through them.

## Prerequisites

Before starting, make sure you have:

* **A GCP project** with billing enabled. <walkthrough-project-setup billing="true"/>
* **A Cloud DNS managed zone** for the domain you want to use
  (e.g. `platforma.example.com`). If you don't have one yet, see
  [domain-guide.md](https://github.com/milaboratory/platforma-helm/blob/main/infrastructure/gcp/domain-guide.md).
* **A Platforma license key** (`E-…` string) from MiLaboratories.
* **Owner role** on the project (the installer creates a service account
  and grants it permissions on your behalf).

## Step 1 — Pick your project

Confirm Cloud Shell is pointing at the right project. Run:

```bash
gcloud config set project <walkthrough-project-id/>
```

You can verify with:

```bash
gcloud config get-value project
gcloud beta billing projects describe $(gcloud config get-value project) --format='value(billingEnabled)'
```

The second command should print `True`. If it prints `False`, link a billing
account in the Console before continuing.

## Step 2 — Confirm your domain + Cloud DNS zone

The installer needs the FQDN where Platforma will live and the name of the
Cloud DNS zone that controls it. List your zones:

```bash
gcloud dns managed-zones list --format="table(name, dnsName)"
```

You should see your zone listed. Note both the **zone name** (left column)
and the **DNS name** (right column, with a trailing dot).

For example, if you see:

```
NAME              DNS_NAME
mycompany-bio     mycompany.bio.
```

…then you can run Platforma at any subdomain ending in `mycompany.bio`,
for example `platforma.mycompany.bio`. You'll provide both pieces in the
next step.

## Step 3 — Run the installer

The installer script collects the remaining inputs (deployment name, region,
size, domain, license key, contact email) and submits the deployment to
Infrastructure Manager.

<walkthrough-info-message>
The installer prompts interactively. You can also pre-fill any prompt by
exporting the corresponding environment variable before running the
script — useful when re-running.
</walkthrough-info-message>

```bash
bash infrastructure/gcp/cloudshell/install.sh
```

The script will:

1. Run pre-flight checks (billing, ADC, required APIs).
2. Prompt for: deployment name, region, deployment size, domain, DNS zone,
   contact email, demo library toggle, and license key.
3. Create a service account `platforma-im-deployer@…` in your project and
   grant it Owner.
4. Submit the IM deployment pointing at the latest published bundle in
   `gs://platforma-infrastructure-manager/`.
5. Poll the deployment until it reaches **ACTIVE** (~15-25 min).
6. Print the connection details when done.

While it runs you can watch progress in the
[Infrastructure Manager Console](https://console.cloud.google.com/infra-manager/deployments)
or tail the Cloud Build logs from there.

## Step 4 — Connect the Platforma Desktop App

When the installer finishes it prints two things:

1. The command to retrieve your auto-generated admin password from Secret Manager.
2. Your Platforma URL (e.g. `https://platforma.mycompany.bio`).

The TLS certificate provisions a few minutes after the load balancer is up.
You can confirm it's ready with:

```bash
gcloud certificate-manager certificates describe <walkthrough-spotlight-pointer cssSelector="dummy">YOUR-CLUSTER-cert</walkthrough-spotlight-pointer> --location=global
```

When the certificate state is `ACTIVE`:

1. Open the Platforma Desktop App on your machine.
2. Click **Add Connection** → **Remote Server**.
3. Enter your Platforma URL.
4. Log in with username `platforma` and the password from step 1 above.

You should see your projects, run a workflow, and confirm the demo data
library appears in the data sources list (if you enabled it).

## Updating an existing deployment

To update a deployment with newer chart values, a different size, or to bump
the IM bundle version, simply re-run the same script. It detects the existing
deployment and updates in place via a new IM revision. Roll back via the
**Revisions** tab in the IM Console if anything goes wrong.

## Tearing down

To destroy the deployment and all infrastructure (note: the primary GCS
bucket is **retained** for data safety; delete it manually if needed):

```bash
DEPLOYMENT_NAME=platforma  # whatever you used
gcloud infra-manager deployments delete "$DEPLOYMENT_NAME" --location=europe-west1 --quiet
```

## <walkthrough-conclusion-trophy/> All done

You have a production-ready Platforma deployment on GCP.

Next steps:

* [GCP runbook](https://github.com/milaboratory/platforma-helm/blob/main/infrastructure/gcp/README.md) for full reference
* [Power-user / advanced installation](https://github.com/milaboratory/platforma-helm/blob/main/infrastructure/gcp/advanced-installation.md) — same deployment via local `gcloud` + `tofu`
* [Permissions reference](https://github.com/milaboratory/platforma-helm/blob/main/infrastructure/gcp/permissions.md) for tightening the deployer service account
