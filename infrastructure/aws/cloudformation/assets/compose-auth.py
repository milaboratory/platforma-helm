#!/usr/bin/env python3
"""Fill auth.providers from YAML templates next to this file.

CodeBuild fetches this script from DeployerAssetBaseUrl. Missing templates are
pulled from the same prefix (auth-templates/<kind>.yaml). Placeholders are YAML
scalars ($name, $clientId, …) replaced after parse so types stay real. Empty
values are dropped so optional LDAP fields stay absent.

An SSO source turns on by having its own fields filled in — there is no
selector parameter. Google and Entra are independent, so both may run at once.
"""

import json
import os
import re
import shlex
import subprocess
import sys
import urllib.request
from pathlib import Path

try:
    import yaml
except ImportError:
    subprocess.check_call([sys.executable, "-m", "pip", "install", "-q", "pyyaml"])
    import yaml

VALUES_PATH = os.environ.get("COMPOSE_AUTH_VALUES", "/tmp/auth-values.json")
ENV_PATH = os.environ.get("COMPOSE_AUTH_ENV", "/tmp/auth-env.sh")
SECRETS_PATH = os.environ.get("COMPOSE_AUTH_SECRETS", "/tmp/auth-secrets.json")
# Admin grants a deploy made before the per-source parameters were removed.
# PREVIOUS_PATH is the live release's values, read only to seed GRANTS_PATH the
# first time; GRANTS_PATH is the frozen snapshot every later deploy reads, so a
# change to AdminUsers is not held down by what the last deploy rendered.
PREVIOUS_PATH = os.environ.get("COMPOSE_AUTH_PREVIOUS", "/tmp/auth-previous.json")
GRANTS_PATH = os.environ.get("COMPOSE_AUTH_GRANTS", "/tmp/auth-legacy-grants.json")

ADMIN_PREFIX = "admin=login="
GRANTS_CONFIGMAP = "platforma-legacy-admin-grants"
GRANTS_KEY = "grants.json"
HELM_RELEASE = "platforma"

GUID = re.compile(r"^[0-9a-fA-F-]{36}$")
ENTRA_ISSUER = "https://login.microsoftonline.com/{guid}/v2.0"

# AUTH_METHOD is the leftover single-method selector from stacks created
# before the slot parameters. It is appended after the slot sources (and
# before admin), not a takeover. Names are the RFC 1123 provider ids the
# backend mounts.
LEGACY_SLOTS = {
    "htpasswd": {"sso": "", "ldap": "", "local": "local"},
    "ldap": {"sso": "", "ldap": "corp", "local": ""},
    "google": {"sso": "google", "ldap": "", "local": ""},
    "entra": {"sso": "entra", "ldap": "", "local": ""},
}

KINDS = ("google", "entra", "ldap", "local", "admin")

# Env (and issuer) bindings for each SSO template. The YAML file is the shape.
# 'enabledBy' is the set of env vars that turn the source on: any one of them
# carrying a value is the operator asking for that IdP.
SSO_FIELDS = {
    "google": {
        "clientId": "GOOGLE_CLIENT_ID",
        "secret": "GOOGLE_CLIENT_SECRET",
        "enabledBy": ("GOOGLE_CLIENT_ID",),
    },
    "entra": {
        "clientId": "ENTRA_CLIENT_ID",
        "issuer": "entra",
        "enabledBy": ("ENTRA_CLIENT_ID", "ENTRA_TENANT_ID", "ENTRA_ISSUER"),
    },
}

# Google's Secret keeps the unsuffixed name every existing cluster already
# mounts; a second IdP that needs a client secret gets its own suffixed one.
SSO_SECRET_NAME = "platforma-sso-client-secret"
SSO_SECRET_UNSUFFIXED = "google"


def env(name):
    return os.environ.get(name, "").strip()


def split_list(value):
    return [p.strip() for p in value.split(";") if p.strip()]


def entra_issuer():
    """Full issuer URL, or a bare tenant GUID in EntraIssuer or EntraTenantId."""
    issuer = env("ENTRA_ISSUER") or env("ENTRA_TENANT_ID")
    if GUID.match(issuer):
        return ENTRA_ISSUER.format(guid=issuer)
    return issuer


def sso_secret_name(kind):
    if kind == SSO_SECRET_UNSUFFIXED:
        return SSO_SECRET_NAME
    return "%s-%s" % (SSO_SECRET_NAME, kind)


def namespace():
    """The deploy target, set by CodeBuild. Empty when run offline, as in tests."""
    return env("NAMESPACE")


def run(command):
    """stdout of a successful command, or None. Absent state is not an error."""
    try:
        result = subprocess.run(
            command,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            check=False,
        )
    except OSError:
        return None
    if result.returncode != 0:
        return None
    return result.stdout.decode("utf-8")


def load_cluster_state():
    """Seed the grant pin and the previous release values from the cluster.

    Both are absent on a first install, and both are absent when this runs
    outside a cluster, so a miss leaves the file alone and the file-backed
    paths take over.
    """
    target = namespace()
    if not target:
        return
    if not os.path.exists(GRANTS_PATH):
        pinned = run(["kubectl", "get", "configmap", GRANTS_CONFIGMAP,
                      "-n", target, "-o",
                      "jsonpath={.data.%s}" % GRANTS_KEY.replace(".", "\\.")])
        if pinned and pinned.strip():
            with open(GRANTS_PATH, "w") as handle:
                handle.write(pinned)
    if not os.path.exists(PREVIOUS_PATH):
        values = run(["helm", "get", "values", HELM_RELEASE, "-n", target, "-o", "json"])
        if values and values.strip():
            with open(PREVIOUS_PATH, "w") as handle:
                handle.write(values)


def apply_cluster_state():
    """Pin the grants and create one Secret per SSO source that sends one."""
    target = namespace()
    if not target:
        return
    manifest = run(["kubectl", "create", "configmap", GRANTS_CONFIGMAP,
                    "-n", target,
                    "--from-file=%s=%s" % (GRANTS_KEY, GRANTS_PATH),
                    "--dry-run=client", "-o", "yaml"])
    if manifest:
        subprocess.run(["kubectl", "apply", "-n", target, "-f", "-"],
                       input=manifest.encode("utf-8"), check=True)
    subprocess.check_call(["kubectl", "apply", "-n", target, "-f", SECRETS_PATH])


def read_json(path, default):
    try:
        with open(path) as handle:
            return json.load(handle) or default
    except (IOError, OSError, ValueError):
        return default


def legacy_grants():
    """Frozen per-provider admin patterns, seeded once from the live release.

    The per-source AdminUsers parameters are gone, so the grants they produced
    are read back off the deployed values the first time and pinned to a file
    the deployer stores. Later deploys read the pin, never the release.
    """
    pinned = read_json(GRANTS_PATH, None)
    if pinned is not None:
        return pinned
    previous = read_json(PREVIOUS_PATH, {})
    grants = {}
    for provider in (previous.get("auth") or {}).get("providers") or []:
        name = provider.get("name")
        patterns = ((provider.get("roles") or {}).get("attrRegexps")) or []
        kept = [p[len(ADMIN_PREFIX):] for p in patterns if p.startswith(ADMIN_PREFIX)]
        if name and kept:
            grants[name] = ";".join(kept)
    return grants


def roles(name, grants):
    # attrRegexps, not adminUsers: auth.admin-user compares exactly, these are
    # regexps. ADMIN_USERS grants on every provider; a provider that carried
    # per-source grants before they became a pin keeps them too.
    patterns = []
    for source in (env("ADMIN_USERS"), grants.get(name, "")):
        for pattern in split_list(source):
            if pattern not in patterns:
                patterns.append(pattern)
    if not patterns:
        return {}
    return {"roles": {"attrRegexps": [ADMIN_PREFIX + p for p in patterns]}}


def drop_empty(obj):
    if isinstance(obj, dict):
        out = {}
        for key, value in obj.items():
            value = drop_empty(value)
            if value in ("", [], None, {}):
                continue
            out[key] = value
        return out
    return obj


def fill(node, fields):
    if isinstance(node, str) and node.startswith("$") and node[1:] in fields:
        return fields[node[1:]]
    if isinstance(node, dict):
        return {key: fill(value, fields) for key, value in node.items()}
    if isinstance(node, list):
        return [fill(item, fields) for item in node]
    return node


def fetch(url, dest):
    if url.startswith("s3://"):
        subprocess.check_call(["aws", "s3", "cp", url, str(dest), "--quiet"])
        return
    dest.write_bytes(urllib.request.urlopen(url).read())


def template_dir():
    here = Path(__file__).resolve().parent / "auth-templates"
    if (here / "admin.yaml").exists():
        return here
    base = env("DEPLOYER_ASSET_BASE").rstrip("/")
    dest = Path("/tmp/auth-templates")
    dest.mkdir(parents=True, exist_ok=True)
    for kind in KINDS:
        fetch("%s/auth-templates/%s.yaml" % (base, kind), dest / ("%s.yaml" % kind))
    return dest


def render(kind, **fields):
    loaded = yaml.safe_load((template_dir() / ("%s.yaml" % kind)).read_text())
    return drop_empty(fill(loaded, fields))


def slots():
    """SSO ids in template order, plus the LDAP and local ids."""
    sso = [kind for kind, spec in SSO_FIELDS.items()
           if any(env(name) for name in spec["enabledBy"])]
    ldap = "corp" if env("LDAP_SERVER") else ""
    local = "local" if env("ENABLE_LOCAL_USERS") == "true" else ""
    return sso, ldap, local


def legacy():
    method = env("AUTH_METHOD")
    if not method:
        return "", "", ""
    print("WARNING: AuthMethod is deprecated. Its source is appended after")
    print("  the IdP / LdapServer / EnableLocalUsers sources; leave it unchanged.")
    chosen = LEGACY_SLOTS[method]
    return chosen["sso"], chosen["ldap"], chosen["local"]


def ldap_fields(name):
    server = env("LDAP_SERVER")
    search_user = env("LDAP_SEARCH_USER")
    # ldaps:// is already TLS, so StartTLS on top of it is wrong.
    start_tls = (not server.lower().startswith("ldaps://")
                 and env("LDAP_START_TLS") == "true")
    return {
        "name": name,
        "url": server,
        "startTLS": start_tls,
        "userDN": env("LDAP_BIND_DN"),
        "bindDN": search_user,
        "bindPassword": os.environ.get("LDAP_SEARCH_PASSWORD", "") if search_user else "",
        "searchRules": split_list(env("LDAP_SEARCH_RULES")),
        "map": {"email": "mail", "displayName": "displayName"} if search_user else None,
    }


def sso_fields(kind, name):
    spec = SSO_FIELDS[kind]
    secret = env(spec.get("secret") or "")
    fields = {
        "name": name,
        "clientId": env(spec["clientId"]),
        # No secret means no clientSecret block at all: drop_empty removes the
        # empty name, then the empty parent.
        "secretName": sso_secret_name(kind) if secret else "",
    }
    if spec.get("issuer") == "entra":
        fields["issuer"] = entra_issuer()
    return fields, secret


def add_sso(providers, secrets, grants, kind):
    fields, secret = sso_fields(kind, kind)
    providers.append(render(kind, **fields))
    providers[-1].update(roles(kind, grants))
    if secret:
        secrets[fields["secretName"]] = secret


def add_ldap(providers, grants, name):
    providers.append(render("ldap", **ldap_fields(name)))
    providers[-1].update(roles(name, grants))


def add_local(providers, grants, name):
    providers.append(render("local", name=name))
    providers[-1].update(roles(name, grants))


def secret_manifests(secrets):
    """One Secret per SSO source that sends a client secret, for kubectl apply."""
    return {
        "apiVersion": "v1",
        "kind": "List",
        "items": [
            {
                "apiVersion": "v1",
                "kind": "Secret",
                "metadata": {"name": name},
                "stringData": {"client-secret": value},
            }
            for name, value in sorted(secrets.items())
        ],
    }


def main():
    load_cluster_state()
    sso_ids, ldap_id, local_id = slots()
    legacy_sso, legacy_ldap, legacy_local = legacy()
    grants = legacy_grants()
    providers = []
    secrets = {}
    for sso_id in sso_ids:
        add_sso(providers, secrets, grants, sso_id)
    if ldap_id:
        add_ldap(providers, grants, ldap_id)
    if local_id:
        add_local(providers, grants, local_id)
    if legacy_sso and legacy_sso not in sso_ids:
        add_sso(providers, secrets, grants, legacy_sso)
        sso_ids = sso_ids + [legacy_sso]
    if legacy_ldap and not ldap_id:
        add_ldap(providers, grants, legacy_ldap)
        ldap_id = legacy_ldap
    if legacy_local and not local_id:
        add_local(providers, grants, legacy_local)
        local_id = legacy_local
    if not (sso_ids or ldap_id or local_id):
        print("No auth source selected - the admin credential is the only login.")
    providers.append(render("admin"))

    with open(VALUES_PATH, "w") as values_file:
        json.dump({"auth": {"providers": providers}}, values_file)
    with open(SECRETS_PATH, "w") as secrets_file:
        json.dump(secret_manifests(secrets), secrets_file)
    with open(GRANTS_PATH, "w") as grants_file:
        json.dump(grants, grants_file)
    with open(ENV_PATH, "w") as env_file:
        env_file.write("LOCAL_ID=" + shlex.quote(local_id) + "\n")
    apply_cluster_state()

    print("Auth sources: sso='%s' ldap='%s' local='%s'" % (
        ",".join(sso_ids), ldap_id, local_id))
    if grants:
        print("Pinned per-source admin grants carried forward: %s" %
              ", ".join(sorted(grants)))
    print("NOTE: changing the set of auth sources re-derives the JWT signing key,")
    print("  so every signed-in user has to sign in again once after this deploy.")


if __name__ == "__main__":
    main()
