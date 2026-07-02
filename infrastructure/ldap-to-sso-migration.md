# Migration: LDAP → SSO

Manual procedure to move an existing Platforma instance from LDAP to SSO (OIDC).

**The installers do not switch auth in place.** The AWS CloudFormation and GCP
Cloud Shell installers provision SSO on a fresh or reconfigured instance; they
do not migrate an LDAP instance to SSO for you. Re-homing user data onto the new
SSO identities is the manual, tool-assisted procedure below.

## Why this is manual

Platforma's auth method is **single-valued**. The backend ranks configured
methods SSO > LDAP > htpasswd > token and serves exactly one — there is no
dual-mode where LDAP and SSO logins coexist during a cutover. Switching the
method changes how every user is identified, so user-owned data (projects,
results) must be re-pointed from the old LDAP login to the new SSO username by
hand.

## Risks — read before starting

- **Identity remap.** A user's identity under SSO is the value of the configured
  `--sso-idp-user-id-claim` (default `sub`). Unless that value equals the
  identity you intend each user to keep, their projects and data orphan. Decide
  the old-login → new-SSO-username mapping **before** you start, and pick a
  `user-id-claim` whose value matches it.
- **Lockout.** SSO discovery is fetched lazily at first login. Verify the issuer
  is reachable from the cluster before cutting over.
- **Session loss.** Changing the auth method invalidates every existing session.
  All users must re-login.

## Tools

| Tool | Ships in | Used for |
|---|---|---|
| `platforma --migrate-blobs-to-primary` | this repo (backend binary) | copy library/static-storage blobs into primary storage before an access change |
| `pl-cli admin:copy-project` | `@platforma-sdk/pl-cli` (run via `npx @platforma-sdk/pl-cli@latest`) | copy a project from the LDAP login to the SSO username |
| `pl-cli project:delete` | `@platforma-sdk/pl-cli` | delete the old LDAP-owned copy after verification |

There is **no atomic move**. Re-homing a project is the two-step
`admin:copy-project` then `project:delete` pattern: copy, verify the target user
sees it, then delete the original.

## Procedure

### Step 0 — Decide the identity mapping

List every active LDAP login and the SSO username it becomes. Choose the
`--sso-idp-user-id-claim` whose JWT value will equal that SSO username for each
user. Without this, the rest of the procedure re-homes data to the wrong owner.

### Step 1 — (Conditional) Migrate blobs to primary storage

Only if a data library currently uses **static-access** library storage that
will become **SSO-federated** after the cutover. Federated access derives
per-user credentials from the SSO token; blobs written under the old static
access stay readable only if they live in primary storage first. Run this
**while the source bucket is still static:**

```bash
platforma --migrate-blobs-to-primary <SOURCE_STORAGE_ID>
```

Exit 0 means every blob used in projects was copied to primary store.
A non-zero exit means some blobs failed — inspect the logs and **do not cut over**
until it exits clean.

Platforma does not copy entire data library into primary store, but copies all raw
data files that are in use by existing projects. This is required to keep projects
working after switch to SSO-federated access mode.

### Step 2 — Configure SSO and admin access

Stand up the SSO-configured instance (fresh provisioning, or reconfigure the
existing one). Set at least `--sso-idp-issuer` and `--sso-idp-client-id`, plus
the `--sso-idp-user-id-claim` chosen in Step 0.

To perform project re-homing in the next step, you need admin access. Grant it
by adding `--admin-user <ID>` at backend startup, where `<ID>` matches the value
of the claim chosen for user identity (`--sso-idp-user-id-claim`). This is
required for `admin:copy-project` operations.

### Step 3 — Re-home each project

Per user, per project — copy from the LDAP login to the SSO username, verify,
then delete the old copy. `admin:copy-project` copies; the original stays with
the LDAP user until you delete it.

```bash
npx @platforma-sdk/pl-cli@latest admin:copy-project \
  --address <SERVER> \
  --admin-user <CTRL_USER> --admin-password <CTRL_PASS> \
  --source-user <LDAP_LOGIN> \
  --source-project <PROJECT_ID_OR_LABEL> \
  --target-user <SSO_USERNAME>
```

Confirm the target SSO user sees the project, then remove the original:

```bash
npx @platforma-sdk/pl-cli@latest project:delete <PROJECT_ID> \
  --address <SERVER> \
  --admin-user <CTRL_USER> --admin-password <CTRL_PASS> \
  --target-user <LDAP_LOGIN> \
  --force
```

`project:delete` permanently destroys the copy it targets — `--target-user`
selects the LDAP owner's copy, never the SSO user's.

Old project removal is important as otherwise Platforma will keep this project forever,
even after active user authenticated via SSO deletes it from the account.

### Step 4 — Confirm and lock down

Confirm a real user can log in via SSO and reach their re-homed projects.
