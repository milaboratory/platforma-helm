# How to set up a domain for Platforma on GCP

Platforma's HTTPS ingress (Certificate Manager + Cloud DNS A record + GKE
Gateway) needs:

- **A domain** — `platforma.mycompany.bio`, `platforma.example.com`, etc.
- **A Cloud DNS managed zone** — Google Cloud's DNS service, controlling the
  domain or a subdomain of it. The installer creates A and CNAME records inside
  this zone for the load balancer IP and TLS cert validation.

You give the installer two things:

| Installer prompt | Example | What it is |
|---|---|---|
| `Domain` | `platforma.mycompany.bio` | The fully-qualified hostname users type in the Desktop App |
| `DNS zone name` | `mycompany-bio` | Cloud DNS managed-zone resource name (Console: **Network Services → Cloud DNS → Zones**) |

If your DNS is already in Cloud DNS for the parent domain, you're done — the
installer's zone picker will list it and ask you for a subdomain prefix.

If your DNS is somewhere else (Route53, Cloudflare, GoDaddy, Namecheap, etc.),
you need to **create a Cloud DNS zone for a subdomain** and **delegate
authority** to it from your current DNS host. That's a one-time setup,
~10 minutes including propagation.

---

## Scenario A — your domain's DNS is already in Cloud DNS

Skip ahead. Run the installer; the zone picker auto-detects existing zones.

If you don't see your zone in the picker, make sure the active gcloud project
matches the project that hosts the zone. Cross-project zones are supported via
the `dns_zone_project` Terraform variable (set as an env var before running
`install.sh`).

---

## Scenario B — your domain is hosted elsewhere; delegate a subdomain to Cloud DNS

**Recommended subdomain pattern**: `platforma.<your-root-domain>` (e.g.
`platforma.mycompany.bio`). Keeps Platforma isolated from your other DNS
records and means you only delegate one subdomain — the rest of your
DNS stays where it is.

The full picture of what you set up:

```
Your registrar / DNS host (Route53, Cloudflare, etc.)
  └── mycompany.bio                            (root, stays where it is)
       └── platforma            NS records  →  Cloud DNS in your GCP project
                                                  └── platforma.mycompany.bio
                                                        ├── A     → load-balancer IP
                                                        └── CNAME → cert validation
```

### Step 1 — create the Cloud DNS zone in GCP

Pick a zone name (Cloud DNS resource ID, lowercase letters/digits/dashes — has
to be unique within the project). Common pattern: replace dots with dashes:
`mycompany.bio` → `mycompany-bio`, `platforma.mycompany.bio` → `platforma-mycompany-bio`.

```bash
PROJECT_ID=your-gcp-project
ZONE_NAME=platforma-mycompany-bio
DNS_NAME=platforma.mycompany.bio.   # trailing dot is REQUIRED

gcloud dns managed-zones create "$ZONE_NAME" \
  --project="$PROJECT_ID" \
  --dns-name="$DNS_NAME" \
  --description="Platforma deployment subdomain" \
  --visibility=public
```

Or via Console: **Network Services → Cloud DNS → Create zone**, **Public**,
DNS name = `platforma.mycompany.bio.` (trailing dot — Console accepts it
either way).

### Step 2 — read the 4 nameservers Cloud DNS assigned

```bash
gcloud dns managed-zones describe "$ZONE_NAME" \
  --project="$PROJECT_ID" \
  --format="value(nameServers)"
```

Output looks like:

```
ns-cloud-c1.googledomains.com.
ns-cloud-c2.googledomains.com.
ns-cloud-c3.googledomains.com.
ns-cloud-c4.googledomains.com.
```

Copy these 4 hostnames. The trailing dots are part of the value — most
external DNS hosts append the dot themselves, so paste **without trailing
dots** (or follow your host's format guidance).

### Step 3 — delegate at your existing DNS host

The exact UI differs per host. The thing you're doing is the same everywhere:
**add an `NS` record on the parent zone for the subdomain `platforma`,
pointing at the 4 nameservers from Step 2.**

#### Route53 (AWS)

1. **Route53 → Hosted zones → `mycompany.bio`** → **Create record**.
2. Record name: `platforma` (just the subdomain part — Route53 fills in the rest).
3. Record type: **NS**.
4. Value: the 4 `ns-cloud-*.googledomains.com.` hostnames, one per line.
5. TTL: 300 (default 172800 also fine).
6. Save.

#### Cloudflare

1. **Cloudflare dashboard → mycompany.bio → DNS → Records → Add record**.
2. Type: **NS**.
3. Name: `platforma`.
4. Server: the 4 `ns-cloud-*.googledomains.com.` values, **one record per
   nameserver** (Cloudflare doesn't accept multi-value NS records — repeat 4
   times with same name, different values).
5. TTL: Auto.
6. Important: Cloudflare's proxy (orange cloud) doesn't apply to NS records —
   they always proxy as DNS-only.

#### GoDaddy

1. **GoDaddy account → My Products → DNS → mycompany.bio → DNS Management**.
2. **Add → NS**.
3. Host: `platforma`.
4. Points to: the 4 `ns-cloud-*.googledomains.com.` values, **one record per
   nameserver**.
5. TTL: 1 hour.

#### Namecheap

1. **Namecheap → Domain List → mycompany.bio → Manage → Advanced DNS**.
2. **Add new record → NS Record**.
3. Host: `platforma`.
4. Nameserver: one of the `ns-cloud-*.googledomains.com.` hostnames. Repeat
   for the other 3.

#### Other DNS hosts

The shape is always: **NS record on the parent zone, name = subdomain prefix,
value = 4 nameservers from Cloud DNS.**

### Step 4 — verify the delegation

```bash
dig +short NS platforma.mycompany.bio
```

Should return the 4 `ns-cloud-*.googledomains.com.` hostnames within ~1-5
minutes (sometimes longer depending on parent zone TTL — up to 48 h in the
worst case but usually quick).

If `dig` returns nothing or returns your old DNS host's nameservers, the
delegation hasn't propagated yet. Wait and re-check.

You can also confirm the zone is reachable end-to-end:

```bash
dig +short SOA platforma.mycompany.bio
# should return: ns-cloud-c1.googledomains.com. cloud-dns-hostmaster.google.com. <serial> ...
```

Once that resolves, you're ready to run `install.sh`. The installer will
create A + CNAME records inside the zone you just delegated to.

---

## Common pitfalls

- **Trailing dot in DNS name**: Cloud DNS requires the trailing dot
  (`platforma.mycompany.bio.`). External DNS hosts vary — most accept either
  form and normalize internally.
- **Caching delays**: After creating the zone in Cloud DNS, the nameservers
  are immediately authoritative — but external resolvers may still cache the
  parent's NS response. If `dig +trace` shows the right path but `dig +short`
  doesn't, it's resolver caching; flush or wait.
- **Don't delegate the root**: You almost never want to delegate
  `mycompany.bio` itself to Cloud DNS unless you're moving all your DNS to
  Google. Delegate only the subdomain you want Platforma on.
- **Wildcard DNS**: not needed. Platforma uses a single host (the deployment
  domain), not a wildcard.

---

## Multiple deployments

Each Platforma deployment needs its own subdomain. Common patterns:

- **Per environment**: `platforma.mycompany.bio` (prod),
  `platforma-staging.mycompany.bio` (staging) — each gets its own Cloud DNS
  zone (recommended, isolates blast radius) or shares a parent zone with
  records in different leaf names.
- **Per team**: `team-a.platforma.mycompany.bio`, `team-b.platforma.mycompany.bio`
  — same idea, just deeper.

You can run multiple deployments in the same Cloud DNS zone if you give them
different `domain` values (e.g. `prod.platforma.mycompany.bio` and
`staging.platforma.mycompany.bio` both inside the
`platforma-mycompany-bio` zone). The installer creates non-conflicting
records.
