# Architecture decisions

Lightweight ADR log for the GCP deployment module. Captures the non-obvious
choices made during the build so future maintainers can see *why* something
is the way it is, not just *what*.

Format per entry: short title, decision, reasoning, trade-offs, and when to
revisit. Numbered for stable cross-references; do not renumber existing
entries — append new ones at the bottom.

---

## 1. Three-tier install model

**Decision.** Three install paths share the same Terraform module:
1. Cloud Shell + Infrastructure Manager (Tier-1, non-IT user)
2. Local CLI + Infrastructure Manager (Tier-2, DevOps)
3. Local Terraform with own GCS state (Tier-3, power user / CI)

Tiers 1 and 2 use the same `install.sh` driver script; Tier-3 uses `tofu apply`
directly.

**Why.** A single deployment surface (TF module) avoids divergent code paths
between "easy install" and "real install". Tier-1 is the Cloud Shell button
flow; Tier-2 is the same driver from a local terminal for IT admins who
prefer their own machine; Tier-3 is for users who want full control over
state, customisation, and CI integration.

**Trade-offs.** Cloud Shell sessions are ephemeral — Tier-1 users coming back
months later may need to redo `gcloud auth` and re-clone. Tier-1/2 hand state
to Infrastructure Manager (managed); Tier-3 owns its own GCS bucket. Mixing
between tiers requires state migration (not currently automated).

**Revisit.** If Tier-2 turns out to be unused (everyone falls into Tier-1 or
Tier-3), drop it and reduce surface area.

---

## 2. Deployment-size presets match AWS parallelism

**Decision.** `deployment_size` accepts `small`, `medium`, `large`, `xlarge`.
Each preset's per-batch-pool max-node values match AWS CloudFormation's
`MaxBatch16c64g` / `MaxBatch32c128g` / etc. exactly, plus matching values for
UI pool, Filestore capacity, and quota auto-requests.

**Why.** Same label means same workload capacity on both clouds. A customer
running `medium` on AWS gets the same parallelism on GCP without re-tuning.
Single source of truth (`presets.tf`) keeps this consistent.

**Trade-offs.** Limits flexibility — users with unusual workload mixes
(e.g. only memory-heavy jobs) see overprovisioned smaller pools sitting idle.
Power users override individual values via `*_overrides` variables.

**Revisit.** If real customer usage clusters around shapes that don't match
AWS's pool ratios (e.g. mostly small jobs), introduce additional preset
variants.

---

## 3. Per-job cap = 62 vCPU / 500 GiB RAM

**Decision.** Kueue `maxJobResources` defaults to 62 vCPU / 500 GiB across all
presets. Single jobs cannot exceed this, regardless of `deployment_size`.

**Why.** Sized to fit within an `n2d-highmem-64` (64 vCPU / 512 GiB) after
GKE daemonset overhead (~2 vCPU, ~12 GiB allocatable loss). Same cap as AWS
runbook so workflow code doesn't need cloud-specific resource tuning.

**Trade-offs.** Genuinely huge single jobs (>62 vCPU) are not supported;
those workflows must shard or run on a different cluster. We have not had a
customer hit this in practice yet.

**Revisit.** If multiple customers report 62-vCPU cap as blocking, add a
`huge` preset with `c3-highmem-176` (176 vCPU) batch nodes plus higher Kueue
caps.

---

## 4. Multi-pool batch design (5 size-differentiated pools)

**Decision.** Five batch node pools: `batch-16c-64g`, `batch-32c-128g`,
`batch-64c-256g`, `batch-32c-256g`, `batch-64c-512g`. All share the same K8s
label (`role=batch`) and taint (`dedicated=batch:NoSchedule`). The GKE
autoscaler picks the smallest-fitting pool per pending pod. Cluster has
`autoscaling_profile = OPTIMIZE_UTILIZATION` to prefer bin-packing.

**Why.** Mirrors AWS's 5-batch-pool layout exactly. A 16-vCPU MiXCR job lands
on `n2d-standard-16` (~$0.90/h) instead of always taking a `n2d-highmem-64`
(~$3.60/h). Quota footprint shrinks accordingly. Same Kueue ResourceFlavor
covers all 5 pools because they share the label/taint — no chart change.

**Trade-offs.** More node pools (5 vs 1) means more autoscaling state and
more quota dimensions. Without `OPTIMIZE_UTILIZATION`, the GKE autoscaler
picks pools at random when multiple match — defeating the multi-pool win.

**Revisit.** If GCP gains node-pool autoprovisioning maturity matching what
AWS Karpenter does, consider replacing the 5-pool layout with NAP for fully
dynamic shape-fitting.

**See:** ADR 4 commit `706cd0d`.

---

## 5. Filestore Zonal SSD as default tier

**Decision.** `filestore_tier = "ZONAL"` (Zonal SSD, 1 TiB minimum). Other
options exposed: `BASIC_HDD`, `BASIC_SSD`, `REGIONAL`, `ENTERPRISE`. Default
capacity 1 TiB (small) up to 8 TiB (xlarge).

**Why.** CTO validated that BASIC_HDD does not deliver enough sustained I/O
for real bioinformatics workflows (small-block random reads on FASTQ files).
Zonal SSD is the cheapest tier that handles production load. Regional/Enterprise
add multi-zone durability — overkill for most deployments and significantly
more expensive.

**Trade-offs.** Zonal SSD is ~$0.30/GiB/mo, so 1 TiB = ~$300/mo idle floor.
This is the largest fixed cost in the deployment. Customers running with no
real data load can drop to BASIC_HDD for testing but should NOT do this in
production.

**Revisit.** Hyperdisk Throughput / Hyperdisk Balanced are GCP's newer tiers
that could potentially replace Zonal SSD with better price/performance — not
yet supported by Filestore as of this writing.

---

## 6. Workload Identity for runtime SAs (no JSON keys)

**Decision.** Two GCP service accounts (`platforma-server`, `platforma-jobs`)
bound to K8s SAs via Workload Identity Federation. No JSON keys exported. A
third bind grants self-impersonation `roles/iam.serviceAccountTokenCreator`
for GCS URL signBlob.

**Why.** JSON keys are an attack surface and don't rotate. Workload Identity
is the GCP-recommended pattern, equivalent to AWS IRSA. Self-impersonation
is needed because Workload Identity tokens cannot directly sign GCS URLs;
the runtime SA needs token-creator permission on itself.

**Trade-offs.** Cross-project GCS access (data libraries hosted outside the
deployment project) requires explicit pre-grant from the foreign project,
because the deployer SA can't manage IAM there. Same-project libraries are
auto-granted (see ADR 13). Cluster's WI pool (`<project>.svc.id.goog`) is
created lazily by GKE — the IAM bindings need explicit `depends_on` the
cluster to avoid `Identity Pool does not exist` race on fresh installs.

**Revisit.** If GCP introduces inter-project Workload Identity Federation
that doesn't require pre-grant, simplify the cross-project data-library docs.

---

## 7. htpasswd auto-gen for testing, user-supplied for production

**Decision.** `auth_method = "htpasswd"` with empty `htpasswd_content`
auto-generates a random admin password, stores it in Secret Manager. With
non-empty `htpasswd_content`, uses the user's pre-bcrypted file content
(generate with `htpasswd -nB <user>`). LDAP is the third option.

**Why.** Auto-gen is the simplest path for testing — no setup. User-supplied
is the production path because (a) it supports multiple users and (b) it
doesn't put a password in Terraform state. LDAP is the corporate-directory
option.

**Trade-offs.** Auto-gen mode puts the random password in TF state and IM
revision storage — surfaced clearly in docs as "TESTING ONLY". The
post-deploy step is auth-method-aware so users see the right credential
retrieval instructions.

**Revisit.** If customers consistently run htpasswd in production with
auto-gen, add a `htpasswd_rotate_password = true` toggle that generates a
fresh secret on each apply.

---

## 8. Cloud Quotas auto-request is best-effort

**Decision.** TF submits 5 quota preference requests on apply
(`CPUS_ALL_REGIONS`, `N2D_CPUS_REGION`, `SSD_TOTAL_GB_REGION`,
`INSTANCES_REGION`, `EnterpriseStorageGibPerRegion`) sized per preset.
Apply does NOT block waiting for approval.

**Why.** Fresh GCP projects ship with default quotas that block any non-
trivial Platforma install. Surfacing the quota requests via TF gives users a
single command for the whole flow. Blocking on approval would make `tofu apply`
unusable on first install.

**Trade-offs.** GCP's auto-decisioning often denies large requests on fresh
projects (no compute history, project < 30 days, large multipliers). Users
must manually escalate via the Console — sometimes by stepping the value up
gradually (32 → 128 → 256 → 512). The runbook documents this. Some quota IDs
have moved between API versions; we use the current `Cloud Quotas v1` IDs
which differ from the older `Service Usage` API.

**Revisit.** If GCP ships an "approve up to N if billing is verified" auto-path,
or if our use case grows enough to warrant a partner-account fast-track,
revisit to skip the manual stepping.

---

## 9. install.sh uses `--local-source` with embedded `inputs.auto.tfvars.json`

**Decision.** The driver script assembles a TF bundle in a tmpdir, embeds
the user's collected inputs as `inputs.auto.tfvars.json`, then submits to
Infrastructure Manager via `gcloud infra-manager deployments apply
--local-source=...`.

**Why.** `--gcs-source` would require uploading the bundle to a GCS bucket
the user must create + grant access to first — extra setup friction.
`--local-source` lets gcloud handle the upload to IM's managed bucket
transparently. `inputs.auto.tfvars.json` (TF auto-loads any `*.auto.tfvars.json`)
avoids needing the unsupported `--input-values-file` flag.

**Trade-offs.** Each apply re-uploads the entire bundle (~few MB). For
slow networks this adds 10-30s per apply. Custom Terraform modules in the
bundle must NOT include `backend.tf` (IM manages state).

**Revisit.** If the bundle grows beyond 100 MB (chart bloat, vendored
providers), switch to `--gcs-source` with a managed bucket.

---

## 10. Bundled chart in repo (temporary — switching to OCI registry)

**Decision.** The Helm release in `app.tf` references the chart via local
path: `chart = "${path.module}/../../../charts/platforma"`. The chart copy
lives at `charts/platforma/` in this repo, kept in sync with `core/pl/helm/`
via the upstream sync workflow.

**Why.** Two upstream chart fixes are still in flight (pl#1789 chown
initContainer, pl#1790 Service appProtocols). Until they merge and a 3.4.0
release is cut, we ship our own copy with the workarounds applied.

**Trade-offs.** Customers must `git pull` to get chart updates instead of
just bumping a version variable. Chart drift between local copy and upstream
is a real risk — mitigated by the sync workflow.

**Revisit.** Phase 8b — once chart 3.4.0 ships with both fixes, switch
`chart = "oci://ghcr.io/milaboratory/helm-charts/platforma"` and use
`var.platforma_chart_version` for the pin. Drop the bundled chart copy.
Tracked as a pending todo in this PR.

---

## 11. Parallel `platforma-grpc` Service workaround (pending pl#1790)

**Decision.** `dns_tls.tf` provisions a second Service called `platforma-grpc`
alongside the chart's main `platforma` Service, with `appProtocols: kubernetes.io/h2c`
explicitly set. The HTTPRoute backend points at this Service.

**Why.** The current chart's Service doesn't expose `appProtocols`. Without
the H2C declaration, the GKE Gateway sends HTTP/1.1 to the gRPC backend,
producing "no healthy upstream" errors at the Desktop App.

**Trade-offs.** Ugly — a parallel Service that selects the same pods. Means
extra plumbing (two Services to track) and potentially confusing for users
who expect one Service per app.

**Revisit.** Phase 8a — once pl#1790 merges and 3.4.0 ships with chart-side
`app.service.appProtocols` knob, drop the parallel Service and configure via
chart values. Tracked as a pending todo.

---

## 12. chown initContainer runs as root (Filestore constraint)

**Decision.** The chart's `chown-workspace` initContainer runs with
`runAsUser: 0`, `runAsNonRoot: false`. Drops ALL Linux capabilities, adds
only `CHOWN` and `FOWNER`.

**Why.** GCP Filestore mounts a share root owned by `root:root`. Unlike AWS
EFS, there's no Access Point equivalent that can present the share with a
different owner. The Platforma server runs as UID 1010 and needs to write
to its workspace path; without a chown step the pod gets `EACCES`.

**Trade-offs.** Some clusters enforce Pod Security Admission `restricted`
profile which rejects `runAsNonRoot: false`. Documented in the runbook.
Privileged escalation is disabled (`allowPrivilegeEscalation: false`) and
the container exits as soon as chown completes — short-lived, narrow blast
radius.

**Revisit.** If GCP introduces a Filestore feature for share-level ownership
override (or volume `fsGroupChangePolicy` solves it cleanly via CSI), drop
the initContainer.

**See:** pl#1789. Long version of why-not-anonymous discussion in CTO Slack
thread (pre-2026-04-26).

---

## 13. Auto-grant runtime SAs on same-project GCS data library buckets

**Decision.** TF creates `google_storage_bucket_iam_member` resources granting
`roles/storage.objectViewer` to both `platforma-server` and `platforma-jobs`
on every same-project GCS bucket listed in `var.data_libraries`. Cross-project
buckets are skipped.

**Why.** Without this, fresh installs of same-project data libraries silently
failed at pod-init time with `AccessDenied` — discovered only after the user
saw the pod's data-source initialisation crash. Auto-grant is the principle-of-
least-surprise behaviour: if the user told us about a bucket, we know the
runtime needs read access.

**Trade-offs.** TF must have `roles/storage.admin` on the bucket's project to
grant the binding (the deployer SA does, in same-project case). Cross-project
case requires the user to grant manually from the foreign project — surfaced
in the docs.

**Revisit.** If we add the per-data-library `iam_admin = false` opt-out
(for buckets where IAM is centrally managed elsewhere), this becomes a
toggle.

---

## 14. Infrastructure Manager is the source of truth for Tier-1/2 state

**Decision.** Inputs and Terraform state for Tier-1 and Tier-2 deployments
live in IM. We do NOT maintain a parallel state store (Secret Manager,
config files, etc.). Updates re-submit a new IM revision; rollback is via
the IM Console "Revisions" tab.

**Why.** Two sources of truth always drift. IM already stores the bundle
(including `inputs.auto.tfvars.json`) per revision; reading inputs back from
IM for prompt pre-population would be reading from the actual state, not a
copy.

**Trade-offs.** Today, re-running install.sh re-prompts every input —
friction for repeated updates. The right fix (read from IM revision) is
non-trivial and is tracked as a follow-up todo. The interim workaround is
env-var pre-fill, documented in the README's "Updates" section.

**Revisit.** Implement IM-revision-input read-back; remove the env-var
workaround documentation.

---

## 15. Custom HCL over standard GCP Terraform modules

**Decision.** All resources are written as direct `resource ...` blocks. We do
NOT use the official `terraform-google-modules/*` modules.

**Why.** For v1.0:

- Module surface (~500 lines of HCL) is small enough that a senior eng can
  audit in an afternoon. No magic, no hidden defaults, error messages
  trace directly to a resource block.
- Two parts of our design are non-standard and would fight upstream module
  abstractions: the multi-pool batch design with `OPTIMIZE_UTILIZATION` and
  the IAM split for server/jobs/signBlob.
- Adopting modules under release pressure carries migration risk; better to
  ship a simple shape first and refactor later.

For v1.1+:

- Plan to migrate `network.tf` to `terraform-google-modules/network/google`
  first. Network resources are stable; `moved {}` blocks make the TF state
  migration safe; serves as the template for future migrations.
- Hold off on `terraform-google-modules/kubernetes-engine/google` for GKE.
  Our multi-pool design + custom labels/taints + autoscaling profile would
  require 50+ override variables — abstraction stops paying for itself.
- Storage / IAM modules: low-priority — minimal value-add over direct resources.

**Trade-offs.** We carry the maintenance burden of tracking GCP API
deprecations and provider releases ourselves (vs upstream maintainers
absorbing it). Mitigation: pin provider versions, add Renovate later, keep
a CHANGELOG with explicit "recreation-required" callouts.

**Revisit.** v1.1 cycle — migrate network.tf, add Renovate, write a
CHANGELOG. If this goes well, evaluate IAM module next. Don't migrate GKE
until our multi-pool design has stabilised AND the upstream module gains
better support for it.

**See:** Slack thread with CTO discussing maintenance vs auditability
trade-off.

---

## 16. Deployer SA: roles/owner default, fine-grained option documented

**Decision.** `install.sh` grants the Infrastructure Manager deployer SA
`roles/owner` on the project by default. `permissions.md` documents an
alternative 12-role fine-grained set for regulated GCP projects where Owner
is forbidden outside break-glass.

**Why.** Owner is the simplest thing that works end to end. Many MiLab
customers (research groups, biotech startups) run in their own dev/test
projects where Owner is not a concern. Regulated customers need the
fine-grained set; they tend to have IT teams who can apply it manually.

**Trade-offs.** Granting Owner to a service account is broadly considered
poor practice. The doc surfaces the trade-off and gives the explicit
alternative; doesn't enforce it.

**Revisit.** If the env-var override `SKIP_DEPLOYER_SA_OWNER_GRANT=true`
gets implemented (currently TODO), make it the default and require explicit
opt-in for Owner grant.

---

## 17. Release tag prefix `gcp-im-v` (not just `v`)

**Decision.** GCP installer releases are tagged `gcp-im-v1.0.0`, `gcp-im-v1.1.0`,
etc. — not bare `v1.0.0`.

**Why.** The platforma-helm repo also tags chart releases as `v3.x.y`.
Without a prefix, GCP installer tags would collide / get confused with chart
version tags.

**Trade-offs.** Slightly verbose. `gh release` listings need filtering by
prefix. `cloudshell_git_branch` URL parameter takes the full tag.

**Revisit.** If the chart repo splits out of platforma-helm into its own
home, drop the prefix.

---

## 18. License validation against live API at install time

**Decision.** `install.sh` validates the user's license key by hitting
`https://licensing-api.milaboratories.com/refresh-token?code=<key>` before
proceeding. A 200 response means valid; non-200 surfaces the API's error
message.

**Why.** Same endpoint the Platforma server hits at runtime. A key that
passes validation at install time will (almost certainly) work in the
cluster — catches typos, wrong-environment keys, expired keys at the moment
the user is at the keyboard, before 20 minutes of provisioning runs.

**Trade-offs.** Adds a network dependency to install.sh. If the licensing
API is briefly unreachable, install fails — but the same outage would
prevent the Platforma server from starting later, so failing fast is correct.

**Revisit.** If licensing API gets a status page, document the URL alongside
the failure message.

---

## 19. DNS delegation precheck in install.sh

**Decision.** Before submit, install.sh runs `dig +short NS <zone-dnsname>`
and compares to the 4 `ns-cloud-*.googledomains.com.` nameservers from the
chosen Cloud DNS zone. Mismatch / empty → fail with remediation message
covering both root-domain (registrar) and subdomain (parent-zone NS record)
cases.

**Why.** The most common first-time user failure is a Cloud DNS zone that
exists but isn't delegated — install runs to completion, but Cert Manager
sits in `PROVISIONING / AUTHORIZATION_ISSUE` indefinitely. Costing 20+ min
to discover. The precheck catches it before submit.

**Trade-offs.** Requires `dig` (graceful skip if absent). False negatives
possible if the user's DNS resolver caches the parent's "no such zone"
response — typically clears in 1-5 min. Failure is opt-out via "Proceed
anyway?" prompt for users debugging unrelated issues.

**Revisit.** If we see consistent false-negatives from Cloud Shell's DNS
resolver, switch to `dig @1.1.1.1` (force public resolver) instead of system
default.

---

## 20. LDAP config 3-tier precheck in install.sh

**Decision.** When `auth_method = "ldap"`:

- **Tier 1 (syntax, hard fail):** URL parses, port numeric, exactly one
  bind mode set (direct-bind XOR search-bind), search rules well-formed.
- **Tier 2 (network, warn only):** TCP probe (python3 → nc → bash builtin
  fallthrough) and TLS handshake for ldaps://.
- **Tier 3 (bind, warn only):** ldapsearch attempts a real bind in
  search-bind mode if creds supplied.

Network and bind tiers are warn-only because Cloud Shell's reachability !=
the cluster's reachability.

**Why.** LDAP misconfigurations (typo'd DN, wrong port, missing %u, certs
not trusted) are common and only surface at first user login attempt — by
which point the deploy is "done" and the user has lost context. Catching
syntax + best-effort network from the install machine gives high-signal
errors at the point the user is at the keyboard.

**Trade-offs.** False-positive warnings on Cloud Shell when LDAP isn't
publicly reachable but the cluster is (via VPC peering / VPN). Documented
in the warning text. Direct-bind mode skips the bind tier (no real user
password to test with).

**Revisit.** If Cloud Shell ever supports executing checks from inside the
target cluster (e.g. via a privileged kubectl exec bridge), move the bind
test there for accuracy.

---

## 21. Demo data library mounts MiLab's public S3 bucket cross-cloud

**Decision.** `enable_demo_data_library = true` (default) provisions a data
library entry pointing at MiLab's public S3 bucket — same dataset the AWS
deployment uses.

**Why.** Customers without their own data should still see something work
on first deploy. Sharing the S3 bucket cross-cloud (versus copying to a
GCS mirror) means there's one source of truth for the demo dataset, and
adding new demos to one bucket benefits both clouds.

**Trade-offs.** Egress costs from S3 → GCP customers when downloading.
MiLab pays the S3 read costs on the demo bucket; volume is small. If this
grows, can mirror to a GCS bucket in MiLab's project.

**Revisit.** If S3 egress costs become material, mirror to GCS and switch
the demo library to `type=gcs`.

---

## 22. Private nodes + Cloud NAT for egress

**Decision.** GKE worker nodes are **private** (no external IPs). Egress to
the public internet (container registries, cross-cloud demo data, external
LDAP, licensing API) routes through a regional **Cloud NAT** attached to a
**Cloud Router**. Google APIs (Storage, IAM, Logging, Monitoring) bypass NAT
via **Private Google Access** on the nodes subnet. The control plane endpoint
stays public, so kubectl from any machine still works without a bastion or
IAP tunnel.

**Why.** With multi-pool batch (5 batch shapes + UI + system, up to ~30
nodes at xlarge), the previous public-nodes design consumed 1
`IN_USE_ADDRESSES` quota slot per node — far above the default 8. Fresh-
project installs hit the limit before scale-up could complete, with
confusing error messages from Cloud Autoscaler. Private nodes drop that
quota use to 2-3 slots total (1 NAT IP + 1 GKE Gateway static IP, plus
maybe a NAT IP under heavy egress). Better security too: nodes not
directly reachable from the internet.

**Trade-offs.**

- Cloud NAT adds ~$0.045/h base + $0.045/GB processed. For typical
  bioinformatics workloads (mostly egress to GCS via Private Google Access,
  which bypasses NAT) the per-GB cost is negligible. Container-image pulls
  on cluster scale-up are the main NAT-billed traffic — bounded.
- One more resource type to maintain (Router + NAT). Stable APIs, low churn.
- `master_ipv4_cidr_block` (default `10.10.0.0/28`) must not overlap with
  any peered networks. Configurable via variable for unusual setups.

**Revisit.** If GCP introduces "shared NAT" or per-cluster NAT primitives
that simplify the topology, migrate. If we ever need static egress IPs
(e.g. customer firewalls whitelisting outbound traffic), switch
`nat_ip_allocate_option` from `AUTO_ONLY` to a reserved IP pool.

**See:** ADR 4 (multi-pool batch — drove the IN_USE_ADDRESSES pressure).

---

## How to add a new ADR

1. Append a new section at the bottom — do not renumber existing ones.
2. Use the format: `## NN. Short title` followed by **Decision.**, **Why.**,
   **Trade-offs.**, **Revisit.**, optionally **See.**
3. Keep each ADR under ~30 lines. If it's longer, the decision is probably
   really two decisions; split it.
4. Cross-reference in code comments where helpful: `# See architecture-decisions.md
   ADR 4`.
5. Don't delete ADRs that have been superseded — mark them and add the
   superseding ADR.
