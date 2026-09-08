#!/usr/bin/env python3
"""Fill auth.providers from YAML templates next to this file.

CodeBuild fetches this script from DeployerAssetBaseUrl. Missing templates are
pulled from the same prefix (auth-templates/<kind>.yaml). Placeholders are YAML
scalars ($name, $clientId, …) replaced after parse so types stay real. Empty
values are dropped so optional LDAP fields stay absent.
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

GUID = re.compile(r"^[0-9a-fA-F-]{36}$")
ENTRA_ISSUER = "https://login.microsoftonline.com/{guid}/v2.0"

# AUTH_METHOD is the deprecated single-method selector: when set it IS the
# whole configuration. Names are the RFC 1123 provider ids the backend mounts.
LEGACY_SLOTS = {
    "htpasswd": {"sso": "", "ldap": "", "local": "local"},
    "ldap": {"sso": "", "ldap": "corp", "local": ""},
    "google": {"sso": "google", "ldap": "", "local": ""},
    "entra": {"sso": "entra", "ldap": "", "local": ""},
}

KINDS = ("google", "entra", "ldap", "local", "admin")

# Env (and issuer) bindings for each SSO template. The YAML file is the shape.
SSO_FIELDS = {
    "google": {"clientId": "GOOGLE_CLIENT_ID", "secret": "GOOGLE_CLIENT_SECRET"},
    "entra": {"clientId": "ENTRA_CLIENT_ID", "issuer": "entra"},
}


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


def roles(slot):
    # attrRegexps, not adminUsers: auth.admin-user compares exactly, these are
    # regexps. ADMIN_USERS is merged into every slot (legacy global flag).
    patterns = split_list(";".join(p for p in (slot, env("ADMIN_USERS")) if p))
    if not patterns:
        return {}
    return {"roles": {"attrRegexps": ["admin=login=" + p for p in patterns]}}


def drop_empty(obj):
    if isinstance(obj, dict):
        out = {}
        for key, value in obj.items():
            value = drop_empty(value)
            if value in ("", [], None):
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
    method = env("AUTH_METHOD")
    if method:
        print("WARNING: AuthMethod is deprecated. Use SsoProvider / LdapServer /")
        print("  EnableLocalUsers, which can be combined.")
        chosen = LEGACY_SLOTS[method]
        return chosen["sso"], chosen["ldap"], chosen["local"]
    sso = env("SSO_PROVIDER")
    if sso in ("", "none"):
        sso = ""
    ldap = "corp" if env("LDAP_SERVER") else ""
    local = "local" if env("ENABLE_LOCAL_USERS") == "true" else ""
    if not (sso or ldap or local):
        print("No auth source selected - the admin credential is the only login.")
    return sso, ldap, local


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
    fields = {"name": name, "clientId": env(spec["clientId"])}
    if spec.get("issuer") == "entra":
        fields["issuer"] = entra_issuer()
    return fields, env(spec.get("secret") or "")


def main():
    sso_id, ldap_id, local_id = slots()
    providers = []
    secret = ""
    if sso_id:
        fields, secret = sso_fields(sso_id, sso_id)
        providers.append(render(sso_id, **fields))
        providers[-1].update(roles(env("SSO_ADMIN_USERS")))
    if ldap_id:
        providers.append(render("ldap", **ldap_fields(ldap_id)))
        providers[-1].update(roles(env("LDAP_ADMIN_USERS")))
    if local_id:
        providers.append(render("local", name=local_id))
        providers[-1].update(roles(env("LOCAL_ADMIN_USERS")))
    providers.append(render("admin"))

    with open(VALUES_PATH, "w") as values_file:
        json.dump({"auth": {"providers": providers}}, values_file)
    with open(ENV_PATH, "w") as env_file:
        env_file.write("LOCAL_ID=" + shlex.quote(local_id) + "\n")
        env_file.write("SSO_CLIENT_SECRET=" + shlex.quote(secret) + "\n")

    print("Auth sources: sso='%s' ldap='%s' local='%s'" % (sso_id, ldap_id, local_id))
    print("NOTE: changing the set of auth sources re-derives the JWT signing key,")
    print("  so every signed-in user has to sign in again once after this deploy.")


if __name__ == "__main__":
    main()
