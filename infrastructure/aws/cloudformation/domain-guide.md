# How to register a domain in AWS

Platforma requires a domain name and a Route53 hosted zone. This guide walks through registering a domain directly in AWS and setting up the hosted zone.

You need two things:
- A **registered domain** (e.g. `example.com`) — a name you've purchased and own
- A **Route53 hosted zone** — AWS's DNS management for that domain; the CloudFormation stack writes records here for certificate validation and load balancer routing

If you already have a domain registered elsewhere (GoDaddy, Namecheap, etc.), skip to [Using an existing domain](#using-an-existing-domain).

---

## Registering a new domain in Route53

### Step 1: Open Route53 domain registration

In the AWS Console, navigate to **Route53 → Registered domains → Register domain**.

### Step 2: Search for a domain

Enter a domain name and click **Search**. AWS will show availability and pricing for various TLDs (`.com`, `.io`, `.bio`, etc.).

`.com` costs ~$13/year. `.io` costs ~$40/year. Pricing varies by TLD.

### Step 3: Add to cart and check out

Select your domain, add it to the cart, and complete the contact information form. AWS requires a valid email, name, and address for ICANN compliance.

Enable **privacy protection** (included free) to hide your personal details from the public WHOIS database.

### Step 4: Complete registration

Confirm the order. Domain registration takes a few minutes to a few hours. You'll receive a confirmation email.

> **Hosted zone created automatically:** When you register a domain through Route53, AWS automatically creates a hosted zone for it. You do not need to create one manually.

---

## Finding your hosted zone ID

Once the domain is registered, go to **Route53 → Hosted zones**. Click your domain to open it.

The hosted zone ID is displayed at the top — it looks like `Z0123456789ABCDEF`. Copy this value; you'll need it for the CloudFormation parameter **Route53 hosted zone ID**.

---

## Using an existing domain

If your domain is registered with another registrar, you can either:

**Option A — Transfer the domain to Route53** (recommended for simplicity): Route53 becomes your registrar and DNS provider. Follow the [AWS domain transfer guide](https://docs.aws.amazon.com/Route53/latest/DeveloperGuide/domain-transfer-to-route-53.html).

**Option B — Keep registrar, delegate DNS to Route53:** Create a hosted zone in Route53 (**Route53 → Hosted zones → Create hosted zone**). Route53 assigns 4 nameservers. Copy those nameservers to your domain registrar's DNS settings (replaces existing nameservers). DNS propagation takes up to 48 hours.

With Option B, your domain registration stays at your current registrar, but Route53 manages DNS — which is all CloudFormation needs.

---

## Choosing a subdomain for Platforma

You don't need to use the root domain. A subdomain like `platforma.example.com` works fine and keeps Platforma isolated from other services on your domain.

When filling in the CloudFormation parameter **Domain name**, enter the full endpoint: `platforma.example.com` (not just `example.com`).

The **hosted zone ID** should be the zone for the root domain (`example.com`), not a subdomain — Route53 hosted zones are always for root domains.
