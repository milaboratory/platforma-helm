# Multi-provider auth (auth.* provider scheme)

The per-provider `auth.*` scheme declares one or more auth providers, each with an
id and a type. **Supported types: `sso` (OIDC), `ldap` and `htpasswd`**, in any
combination and any number — two OIDC providers plus a directory plus a local
password file is a valid configuration. `saml` and `scim` are reserved but **not
yet implemented**, and there is **no `token` provider type** — single-user token
auth remains legacy and single-provider (`--auth-token`), and the legacy flags
**cannot be combined** with the `auth.*` scheme.

> **Adding or removing a provider invalidates every session.** The JWT signing key
> is derived from the configured auth-method set, so everyone signs in again after
> the change. Plan provider changes like a restart with forced re-login.

These are backend startup flags. In Kubernetes, pass them through the chart's
`app.extraArgs`, and inject secrets from a Secret via `app.env.secretVariables`
(see `values-hz-staging.yaml`); do not put secret literals in values.

`auth.*` replaces the flat `--sso-idp-*` / `--auth-htpasswd` flags, which still
work but log a deprecation warning at startup. To convert an existing OIDC install,
start the backend with its current flags plus `--print-auth-config`: it prints the
equivalent `auth.*` block and exits. The other legacy modes are a handful of flags
each, so that command points at the mapping rather than generating one — htpasswd
and LDAP are converted by hand from the sections below.

## Google OIDC

Configure a Google Workspace SSO provider with the per-provider `auth.*` flags,
optionally deriving roles from Google group membership.

### Prerequisites

- An OAuth 2.0 **Web application** client in Google Cloud (Client ID + secret).
  Register the desktop loopback redirect URIs (the app uses RFC 8252 loopback
  ports).
- For group-based roles: the Cloud Identity API enabled, and each role-mapped
  group readable by the signing-in user.

### Final flags example

```
--auth.provider-id=google
--auth.provider-type=google=sso
--auth.sso.issuer=google=https://accounts.google.com
--auth.sso.client-id=google=<CLIENT_ID>.apps.googleusercontent.com
--auth.sso.client-secret=google=<CLIENT_SECRET>          # inject via a Secret in k8s
--auth.sso.scopes=google=openid email profile
--auth.sso.access-type=google=offline                    # Google issues a refresh token only with 'offline'
--auth.sso.redirect-port=google=8765                     # must match a redirect URI registered at the IdP

# user model
--auth.map.login=google=email                            # login = email: match key + "Signed in as <email>"
--auth.map.email=google=email                            # store the email attribute (required for group roles)
--auth.map.display-name=google=name                      # friendly name in the UI
--auth.create-users=google=true                          # provision on first login

# group-based roles (optional)
--auth.google-group-fetch=google=true                    # Google's token has no groups claim
--auth.role.group=google=admin=platforma-admins@example.com

--master-secret=<base64url-32-bytes>             # required for htpasswd/LDAP/SSO
```

### Notes

- **Identity.** `--auth.map.login=google=email` makes the login (the match
  key, since `look-up-attr` defaults to `login`) the email — human-readable, and
  shown as "Signed in as". It changes if the user is renamed; for rename-proof
  identity drop that line to keep login = the OIDC `sub` (a stable numeric id),
  and accept that "Signed in as" then shows the `sub`.
- **Email is required for group roles.** Cloud Identity keys group membership on
  the user's **email**, not the `sub`, so `--auth.map.email` must be set for
  `auth.google-group-fetch` to resolve groups.
- **Scope is auto-added.** Enabling `--auth.google-group-fetch` automatically
  adds the required `https://www.googleapis.com/auth/cloud-identity.groups.readonly`
  scope; you do not need to list it in `--auth.sso.scopes`.
- **Group matching is exact.** `--auth.role.group` matches a group's full
  email/name exactly (no regexp); repeat the flag for more groups/roles. For
  Google this is the only form available — see the group-regex note below.
- **Roles.** Only `admin` and `user` are assignable; rules only elevate, never
  lower, the role. Tune Google API calls per provider with
  `--auth.google-api-timeout google=<dur>` (default 5s) and
  `--auth.google-api-retries google=<n>` (default 2, must be > 0).
- **Refresh tokens.** Google returns a refresh token only when the auth request
  carries `access_type=offline`, so set `--auth.sso.access-type=google=offline`
  unless you want users re-prompted when the access token expires.
- The `auth.*` scheme cannot be combined with the legacy `--sso-idp-*` /
  `--auth-ldap-*` flags.

### OIDC login parameters

Beyond the connection settings, each `sso` provider takes the OIDC login knobs
below. All are optional and keyed by provider id; every one has a legacy
`--sso-idp-*` twin with identical semantics.

| Flag                              | Default                               | Purpose |
|-----------------------------------|---------------------------------------|---|
| `--auth.sso.scopes`               | `openid profile email offline_access` | space-separated scope list; must contain `openid` |
| `--auth.sso.client-secret-file`   | —                                     | read the client secret from a file instead of the flag; cannot be combined with `--auth.sso.client-secret` |
| `--auth.sso.access-type`          | —                                     | `online` \| `offline`; Google needs `offline` for a refresh token |
| `--auth.sso.prompt`               | `login`                               | `none` \| `login` \| `consent` \| `select_account` |
| `--auth.sso.redirect-port`        | `8765`                                | loopback callback port (RFC 8252); repeatable per provider, and every port must be registered at the IdP as `http://127.0.0.1:<port>/callback` |
| `--auth.sso.user-id-claim`        | `sub`                                 | claim carrying the provider's stable subject, e.g. `oid` for Entra |
| `--auth.sso.resource`             | —                                     | RFC 8707 `resource=` audience, for IdPs issuing JWT access tokens bound to an API |
| `--auth.sso.subject-token-source` | `id_token`                            | `access_token` \| `id_token`, for cloud STS exchanges |
| `--auth.sso.jwt-algorithm`        | `RS256`, `ES256`, `ES384`             | allowed signing algorithm; repeatable per provider |

### Role rules

Three rule forms assign a role at login, all keyed by provider id and all
repeatable:

```
--auth.role.attr-regex=<id>=<role>=<attr>=<regex>   # a user attribute value fully matches a regexp
--auth.role.group=<id>=<role>=<group>               # the login belongs to this exact group
--auth.role.group-regex=<id>=<role>=<regex>         # any of the login's groups fully matches a regexp
--auth.admin-user=<id>=<login>                      # a specific login is admin
```

Every regexp is a **full match** — `admin[0-9]+` matches the group `admin42` but
not `platforma-admin42-eu`.

`--auth.role.group-regex` needs the login's whole group set, which means the
provider's token must carry a groups claim (`--auth.map.groups`, plus whatever
scope the IdP requires to emit it — e.g. `groups` for Okta). It is therefore
**rejected at boot together with `--auth.google-group-fetch`**: the out-of-band
Google lookup can only answer "is this user in *this named* group", so there is
nothing for a regexp to run against. Use `--auth.role.group` for Google.

```
# Okta: groups arrive in the token, so both group forms work
--auth.sso.scopes=okta=openid profile email groups
--auth.map.groups=okta=groups
--auth.role.group-regex=okta=admin=admin[0-9]+
--auth.role.attr-regex=okta=admin=email=.*@example\.com
```

## htpasswd

A local password-file provider — a self-contained login source that needs no
external IdP. It authenticates a username/password against an Apache htpasswd
file and provisions the backend user on that user's first login.

Create the file with the standard `htpasswd` tool (bcrypt recommended):

```bash
htpasswd -B -c /etc/platforma/htpasswd alice     # first user (-c creates the file)
htpasswd -B    /etc/platforma/htpasswd ops-bob    # add more
```

```
--auth.provider-id=local
--auth.provider-type=local=htpasswd
--auth.htpasswd.file=local=/etc/platforma/htpasswd
--auth.admin-user=local=admin                    # grant admin to the 'admin' local user
# or by rule, e.g. every ops-* login is admin:
--auth.role.attr-regex=local=admin=login=ops-.*

--master-secret=<base64url-32-bytes>             # required for htpasswd/LDAP/SSO
```

Notes:

- **A master secret is required** for htpasswd (and LDAP/SSO); only single-user
  token auth derives one automatically. Pass `--master-secret` /
  `--master-secret-file` (in k8s, `masterSecret.secretName`).
- The user's `login` is the htpasswd username; there are no claims to map.
- Admin comes from `--auth.admin-user` (matched as a full-match regexp) or the
  role rules (`--auth.role.*`).

## LDAP

A directory provider: it authenticates a username/password by binding against the
LDAP server, and can read the user's attributes and group memberships from the
same directory. This is the per-provider form of the legacy `--auth-ldap-*` flags,
with the same two authentication modes.

### Search+bind (recommended)

A service account searches for the user's DN, then the backend binds as the user
to check the password. Only this mode can read attributes and groups, because
only it has an account able to query the directory.

```
--auth.provider-id=corp
--auth.provider-type=corp=ldap
--auth.ldap.url=corp=ldaps://ldap.example.com:636
--auth.ldap.bind-dn=corp=cn=svc-platforma,ou=services,dc=example,dc=com
--auth.ldap.bind-password=corp=<SECRET>            # inject via a Secret in k8s
--auth.ldap.base-dn=corp=ou=users,dc=example,dc=com
--auth.ldap.user-filter=corp=(uid=%u)              # '%u' is the login

# user model — read from the directory entry found by the search
--auth.map.email=corp=mail
--auth.map.display-name=corp=displayName
--auth.create-users=corp=true

# group-based roles (optional)
--auth.ldap.group-base-dn=corp=ou=groups,dc=example,dc=com
--auth.role.group=corp=admin=platforma-admins
--auth.role.group-regex=corp=admin=cn=platforma-.*,ou=groups,dc=example,dc=com

--master-secret=<base64url-32-bytes>
```

Add `--auth.ldap.search-rule=corp=<filter>|<baseDN>` (repeatable) for extra
subtrees; it is tried after the `base-dn`/`user-filter` pair, in the order given.

### Direct bind

No service account: the login is substituted into a DN template and bound
directly. Simpler, but the backend can only read the user's own entry, so
`--auth.ldap.group-base-dn` is rejected in this mode.

```
--auth.provider-id=corp
--auth.provider-type=corp=ldap
--auth.ldap.url=corp=ldaps://ldap.example.com:636
--auth.ldap.user-dn=corp=cn=%u,ou=users,dc=example,dc=com
```

### TLS

```
--auth.ldap.start-tls=corp=true                    # secure a plain ldap:// connection
--auth.ldap.trusted-ca=corp=/etc/ssl/corp-ca.pem   # repeatable; replaces the system pool
--auth.ldap.client-cert=corp=/etc/ssl/cert.pem,/etc/ssl/key.pem
--auth.ldap.insecure-tls=corp=true                 # NEVER in production
```

### Notes

- **Attributes are read from the entry the search found.** Only the attributes
  named by `auth.map.*` are requested; a multi-valued attribute contributes its
  first value. `--auth.look-up-attr=corp=email` works once `email` is mapped, so a
  directory user and an OIDC user with the same address resolve to one account.
- **Groups come from two sources, unioned.** The user's own `memberOf` attribute
  (standard in Active Directory, and in OpenLDAP with the memberof overlay), plus —
  when `--auth.ldap.group-base-dn` is set — a reverse `member=<userDN>` search
  under that base, which covers directories that do not maintain `memberOf`.
- **Each group is matchable by DN or by cn.** A group reported as
  `cn=platforma-admins,ou=groups,dc=example,dc=com` also matches the rule value
  `platforma-admins`. Two groups sharing a cn in different subtrees therefore both
  satisfy a cn rule — match on the full DN when that distinction matters.
- **Groups are only fetched when a rule reads them.** With no `auth.role.group*`
  rule and no `auth.map.groups`, no group lookup runs.
- **Active Directory omits the primary group** from `memberOf` (usually
  `Domain Users`). Do not build a rule on it.
- **The `%u` placeholder** is the login, in both `auth.ldap.user-dn` and
  `auth.ldap.user-filter`.
- **`auth.map.login` is rejected for an LDAP provider.** The login must stay the
  value `auth.ldap.user-filter` matches, because every token refresh re-resolves
  it through that filter to confirm the user still exists in the directory — a
  remapped login would find nothing and log the user out. To key users on their
  email, make the filter match it (`--auth.ldap.user-filter=corp=(mail=%u)`) so
  the email *is* the credential, or map it to `email` and set
  `--auth.look-up-attr=corp=email`.

## Multiple providers (SSO + htpasswd)

Declare each provider id once, then key every flag by that id. A common setup is
an OIDC provider that provisions the workforce, plus an htpasswd file of local
accounts as a fallback for when the IdP is unreachable.

```
# provider registry
--auth.provider-id=google
--auth.provider-id=local

# google: OIDC, provisions users on first login (see the Google OIDC section)
--auth.provider-type=google=sso
--auth.sso.issuer=google=https://accounts.google.com
--auth.sso.client-id=google=<CLIENT_ID>.apps.googleusercontent.com
--auth.sso.client-secret=google=<CLIENT_SECRET>
--auth.sso.scopes=google=openid email profile
--auth.map.login=google=email
--auth.map.email=google=email
--auth.create-users=google=true
--auth.role.group=google=admin=platforma-admins@example.com
--auth.google-group-fetch=google=true

# local: htpasswd example (see the htpasswd section)
--auth.provider-type=local=htpasswd
--auth.htpasswd.file=local=/etc/platforma/htpasswd
--auth.role.attr-regex=local=admin=login=ops-.*

--master-secret=<base64url-32-bytes>             # required (htpasswd + SSO)
```

Every provider-scoped flag is a map keyed by the provider id, so per-provider
values may also be written on one line (`--auth.provider-type google=sso local=htpasswd`).
Role rules (`--auth.role.*`, `--auth.admin-user`) apply per provider — a login is
evaluated only against the rules of the provider that authenticated it.

**Token auth is not expressible here.** The scheme has no `token` type, so an
install needing single-user token auth must use `--auth-token` instead — and
cannot also run an `auth.*` provider at the same time.

## Multiple providers of the same type

Nothing is limited to one provider per type. Two OIDC providers are just two
declared ids:

```
--auth.provider-id=google
--auth.provider-id=okta
--auth.provider-type=google=sso
--auth.provider-type=okta=sso
--auth.sso.issuer=google=https://accounts.google.com
--auth.sso.issuer=okta=https://example.okta.com
--auth.sso.client-id=google=<GOOGLE_CLIENT_ID>
--auth.sso.client-id=okta=<OKTA_CLIENT_ID>
```

All OIDC providers share one session store and one session manager, which routes
every session to the provider that issued it. That shared manager is also what
backs federated (WIF) storage access, so a user's storage credentials come from
whichever provider they signed in with.

### Federated storage with several OIDC providers

A federated (per-user) data library exchanges the caller's OIDC token for cloud
credentials. Sessions are indexed by the token's `sub` claim, which is unique only
per issuer — so with more than one OIDC provider a `sub` alone no longer names one
person. Each federated library therefore declares the provider its cloud trust is
built on:

```
--data-library-gcs-federation-auth-provider=onco=logto
--data-library-s3-federation-auth-provider=archive=okta
```

The named provider must be a declared `sso` provider. The backend refuses to start
if a federated library names a provider that does not exist or is not `sso`, or if
it names none while several `sso` providers are configured. With exactly one `sso`
provider the binding is optional — there is nothing to disambiguate.

At runtime the lookup is scoped to that provider, so a user signed in through a
different one simply has no session for the storage rather than being handed the
wrong provider's token. An unbound lookup that turns out to match sessions from
several providers fails closed with an explicit error.

The same holds for `ldap` and `htpasswd`: declare as many ids as you need. Each
login is evaluated only against the rules of the provider that authenticated it.

## Custom user attributes

Declare an installation's extra user fields once, then let each provider fill them
from its own claim:

```
--auth.extension-field=department
--auth.map-field=google.department=dept
--auth.map-field=okta.department=departmentName
```

A declared extension field may also serve as the match key
(`--auth.look-up-attr=google=department`). A provider with
`--auth.create-users=<id>=true` must map whatever attribute it matches on, or the
backend refuses to boot: it could authenticate and resolve existing users but
never provision new ones, and that is better surfaced at startup than per login.
`login` is exempt — the driver always supplies it.

## Reserved namespaces

`auth.saml.*` and `auth.scim.token` are registered so the flag namespace is fixed
now and configuration written against it will not need rewriting when the drivers
land. They parse today but nothing reads them, and a provider declared with either
type is rejected at boot with what it is waiting on: SAML has no driver yet, and
SCIM is inbound provisioning rather than a login method, deferred together with the
backend group store. Both are hidden from `--help`; pass `--show-hidden` to list
them.

## User provisioning (CSV)

`--user-provisioning` seeds user records before the server starts serving, so an
IdP identity can land on an account the operator prepared instead of a fresh one.
It runs at boot under either auth scheme.

```
--user-provisioning=file:///etc/platforma/users.csv    # or s3://, https://, gcs://
--user-provisioning-match-attribute=login              # login (default) | email
```

The CSV needs a header row; only the `login` and `email` columns are read (any
other column is skipped with a warning):

```csv
login,email
jsmith,jsmith@example.com
```

`--user-provisioning-match-attribute` selects which column matches a row to an
**existing** record: `login` also creates a record for a row that matches none,
`email` requires every row to match one already. The run writes only the email —
it never renames a login.

### How a provisioned record is claimed at login

- **Provider looks up by email** (`--auth.look-up-attr=<id>=email`): the first login
  carrying that email adopts the record. The seeded login is kept — the provider's
  own login value is not written over it, so the next provisioning run still matches
  the row — while every other mapped attribute is refreshed as usual. Adoption also
  reaches an account recorded under a provider that is no longer configured (an LDAP
  account after an SSO cutover), which no index lookup can find. It is a one-time
  scan: adoption indexes the record for the provider, so later logins are point
  lookups.
- **Provider looks up by login** (the default): the record is claimed only when the
  provider's mapped login equals the seeded login.

**Emails must be unique across records.** Two records sharing one email is an
ambiguous identity: adoption is refused (an error is logged, and the login proceeds
as an ordinary new/own identity rather than adopting either), and a later boot with
`--user-provisioning-match-attribute=email` fails on `duplicate match value in store`.

**The email must be verified.** Adoption requires the IdP to vouch for the email:
an unverified address is a value the user asserted, and honouring it would let
whoever asserts it take over the account carrying it. A login is never refused for
this — it just proceeds under its own identity, with a warning logged.

| `email_verified` in the token | Adopts? |
|---|---|
| `true` | yes |
| `false` | no — never, regardless of configuration |
| absent | no, unless `--auth.trust-unverified-email=<id>=true` |

Only an `sso` provider is questioned this way. An `ldap` or `saml` provider's email
comes from the directory or a signed assertion rather than a claim the user can set,
so it identifies a record without the switch — which those providers reject.

Absent counts as unverified because a provider that lets users pick an arbitrary
email and sends no claim is exactly the dangerous case. For an IdP whose emails
*are* authoritative but which sends no claim — Entra ID sends none — opt in:

```
--auth.trust-unverified-email=entra=true    # requires auth.look-up-attr=entra=email
```

Turn it on only when the IdP, not the user, controls the address. Google Workspace
sends `email_verified=true` and needs nothing.
