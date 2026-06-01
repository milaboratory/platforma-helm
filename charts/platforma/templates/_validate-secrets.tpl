{{- /*
platforma.checkSecret — fails render if the referenced Secret does not exist,
or (when `keys` provided) if any of the expected data keys is missing.

Args (dict):
  ctx            — root context (".")
  name           — secret name
  keys           — list of expected data keys (optional)
  hint           — human description of what this secret is for
  example        — optional kubectl example for creating the secret
  valuesPath     — values.yaml path that controls the secret name
                   (e.g., "license.secretName") — shown as the
                   "use an existing secret" alternative
  keyValuesPaths — list of values.yaml paths controlling the expected key
                   names, aligned 1:1 with `keys`
*/ -}}
{{- define "platforma.checkSecret" -}}
{{- $ctx := .ctx -}}
{{- $ns := $ctx.Release.Namespace -}}
{{- $sec := (lookup "v1" "Secret" $ns .name) -}}
{{- if not $sec -}}
{{- fail (printf "ERROR: %s — Secret %q not found in namespace %q.\n\n  Option A: create it\n    %s\n\n  Option B: point the chart at an existing Secret\n    Set %s in values.yaml to the name of a Secret that already exists in namespace %q.\n\n  Option C: disable chart-level Secret existence checks\n    Set validation.checkSecrets: false in values.yaml.\n    Make sure workload's ServiceAccount can access all required secrets."
    .hint .name $ns (default "(no kubectl example provided)" .example) .valuesPath $ns) -}}
{{- end -}}
{{- $data := default (dict) $sec.data -}}
{{- $keys := default (list) .keys -}}
{{- $keyPaths := default (list) .keyValuesPaths -}}
{{- range $i, $k := $keys -}}
  {{- if not (hasKey $data $k) -}}
    {{- $present := keys $data | sortAlpha | join ", " -}}
    {{- $kp := index $keyPaths $i -}}
    {{- fail (printf "ERROR: %s — Secret %q in namespace %q is missing required key %q.\n  present keys: [%s]\n\n  Option A: re-create the Secret with key %q\n    %s\n\n  Option B: point the chart at an existing key in this Secret\n    Set %s in values.yaml to one of the present keys listed above.\n\n  Option C: disable chart-level Secret existence checks\n    Set validation.checkSecrets: false in values.yaml. \n    Make sure workload's ServiceAccount can access all required secrets."
        $.hint $.name $ns $k $present $k (default "(no kubectl example provided)" $.example) $kp) -}}
  {{- end -}}
{{- end -}}
{{- end -}}

{{- /*
platforma.validateSecrets — entry point. Skipped when the cluster is
unreachable (helm template / client-side dry-run). Detected by probing the
release namespace: `lookup` returns empty when there is no API server to
query, so the entire validation block becomes a no-op offline.
*/ -}}
{{- define "platforma.validateSecrets" -}}
{{- if not .Values.validation.checkSecrets -}}
  {{- /* Operator opted out of chart-level Secret pre-flight checks */ -}}
{{- else if (lookup "v1" "Namespace" "" .Release.Namespace) -}}

  {{- /* license — always required */ -}}
  {{- include "platforma.checkSecret" (dict
        "ctx" .
        "name" .Values.license.secretName
        "keys" (list .Values.license.secretKey)
        "keyValuesPaths" (list "license.secretKey")
        "valuesPath" "license.secretName"
        "hint" "Platforma license"
        "example" (printf "kubectl -n %s create secret generic %s --from-literal=%s=\"<your-license>\""
                  .Release.Namespace .Values.license.secretName .Values.license.secretKey)) -}}

  {{- /* master secret — always required */ -}}
  {{- include "platforma.checkSecret" (dict
        "ctx" .
        "name" .Values.masterSecret.secretName
        "keys" (list .Values.masterSecret.secretKey)
        "keyValuesPaths" (list "masterSecret.secretKey")
        "valuesPath" "masterSecret.secretName"
        "hint" "Platforma master secret"
        "example" (printf "kubectl -n %s create secret generic %s --from-literal=%s=\"$(openssl rand -base64 32)\""
                  .Release.Namespace .Values.masterSecret.secretName .Values.masterSecret.secretKey)) -}}

  {{- /* jobs secret — mounted into every job pod; existence only */ -}}
  {{- if ne .Values.jobs.secretName .Values.license.secretName -}}
    {{- include "platforma.checkSecret" (dict
          "ctx" .
          "name" .Values.jobs.secretName
          "valuesPath" "jobs.secretName"
          "hint" "Per-job credentials secret (mounted into every job pod)"
          "example" (printf "kubectl -n %s create secret generic %s --from-literal=<key>=<value>"
                    .Release.Namespace .Values.jobs.secretName)) -}}
  {{- end -}}

  {{- /* htpasswd — only when pointing at an existing Secret (inline credentials path creates the Secret itself) */ -}}
  {{- if .Values.auth.htpasswd.secretName -}}
    {{- include "platforma.checkSecret" (dict
          "ctx" .
          "name" .Values.auth.htpasswd.secretName
          "keys" (list .Values.auth.htpasswd.secretKey)
          "keyValuesPaths" (list "auth.htpasswd.secretKey")
          "valuesPath" "auth.htpasswd.secretName"
          "hint" "htpasswd auth secret"
          "example" (printf "htpasswd -nB <username> > htpasswd && kubectl -n %s create secret generic %s --from-file=%s=./htpasswd"
                    .Release.Namespace .Values.auth.htpasswd.secretName .Values.auth.htpasswd.secretKey)) -}}
  {{- end -}}

  {{- /* LDAP — only when LDAP auth is enabled */ -}}
  {{- if .Values.auth.ldap.server -}}
    {{- $ns := .Release.Namespace -}}
    {{- with .Values.auth.ldap.searchPasswordSecretRef }}
      {{- if .name -}}
        {{- include "platforma.checkSecret" (dict
              "ctx" $
              "name" .name
              "keys" (list .key)
              "keyValuesPaths" (list "auth.ldap.searchPasswordSecretRef.key")
              "valuesPath" "auth.ldap.searchPasswordSecretRef.name"
              "hint" "LDAP search-user password secret"
              "example" (printf "kubectl -n %s create secret generic %s --from-literal=%s=\"<ldap-search-user-password>\"" $ns .name .key)) -}}
      {{- end -}}
    {{- end }}
    {{- with .Values.auth.ldap.tls.caSecretRef }}
      {{- if .name -}}
        {{- include "platforma.checkSecret" (dict
              "ctx" $
              "name" .name
              "keys" (list .key)
              "keyValuesPaths" (list "auth.ldap.tls.caSecretRef.key")
              "valuesPath" "auth.ldap.tls.caSecretRef.name"
              "hint" "LDAP CA certificate secret"
              "example" (printf "kubectl -n %s create secret generic %s --from-file=%s=./ldap-ca.crt" $ns .name .key)) -}}
      {{- end -}}
    {{- end }}
    {{- with .Values.auth.ldap.tls.clientCertSecretRef }}
      {{- if .name -}}
        {{- include "platforma.checkSecret" (dict
              "ctx" $
              "name" .name
              "keys" (list .certKey .keyKey)
              "keyValuesPaths" (list "auth.ldap.tls.clientCertSecretRef.certKey" "auth.ldap.tls.clientCertSecretRef.keyKey")
              "valuesPath" "auth.ldap.tls.clientCertSecretRef.name"
              "hint" "LDAP client certificate secret"
              "example" (printf "kubectl -n %s create secret generic %s --from-file=%s=./client.crt --from-file=%s=./client.key" $ns .name .certKey .keyKey)) -}}
      {{- end -}}
    {{- end }}
  {{- end -}}

  {{- /* main storage S3 — only when type=s3 and an explicit secretRef is given (skip on IRSA) */ -}}
  {{- if and (eq (include "platforma.mainStorageType" .) "s3") .Values.storage.main.s3.secretRef.name -}}
    {{- $r := .Values.storage.main.s3.secretRef -}}
    {{- $ak := (default "access-key" $r.accessKeyField) -}}
    {{- $sk := (default "secret-key" $r.secretKeyField) -}}
    {{- include "platforma.checkSecret" (dict
          "ctx" .
          "name" $r.name
          "keys" (list $ak $sk)
          "keyValuesPaths" (list "storage.main.s3.secretRef.accessKeyField" "storage.main.s3.secretRef.secretKeyField")
          "valuesPath" "storage.main.s3.secretRef.name"
          "hint" "Main storage S3 credentials secret"
          "example" (printf "kubectl -n %s create secret generic %s --from-literal=%s=<aws-access-key-id> --from-literal=%s=<aws-secret-access-key>"
                    .Release.Namespace $r.name $ak $sk)) -}}
  {{- end -}}

  {{- /* data sources (read-only data library) — per-source S3 secretRef when set */ -}}
  {{- $ns := .Release.Namespace -}}
  {{- range $i, $src := .Values.dataSources -}}
    {{- if and (eq $src.type "s3") $src.s3 $src.s3.secretRef $src.s3.secretRef.name -}}
      {{- $r := $src.s3.secretRef -}}
      {{- $ak := (default "access-key" $r.accessKeyField) -}}
      {{- $sk := (default "secret-key" $r.secretKeyField) -}}
      {{- include "platforma.checkSecret" (dict
            "ctx" $
            "name" $r.name
            "keys" (list $ak $sk)
            "keyValuesPaths" (list (printf "dataSources[%d].s3.secretRef.accessKeyField" $i) (printf "dataSources[%d].s3.secretRef.secretKeyField" $i))
            "valuesPath" (printf "dataSources[%d].s3.secretRef.name" $i)
            "hint" (printf "Data source %q S3 credentials" $src.name)
            "example" (printf "kubectl -n %s create secret generic %s --from-literal=%s=<aws-access-key-id> --from-literal=%s=<aws-secret-access-key>"
                      $ns $r.name $ak $sk)) -}}
    {{- end -}}
  {{- end -}}

  {{- /* extra env vars sourced from secrets */ -}}
  {{- range $i, $v := .Values.app.env.secretVariables -}}
    {{- include "platforma.checkSecret" (dict
          "ctx" $
          "name" $v.secretName
          "keys" (list $v.secretKey)
          "keyValuesPaths" (list (printf "app.env.secretVariables[%d].secretKey" $i))
          "valuesPath" (printf "app.env.secretVariables[%d].secretName" $i)
          "hint" (printf "Environment variable %q source secret" $v.name)
          "example" (printf "kubectl -n %s create secret generic %s --from-literal=%s=<value>"
                    $ns $v.secretName $v.secretKey)) -}}
  {{- end -}}

  {{- /* image pull secrets — existence only (contract is K8s dockerconfigjson) */ -}}
  {{- range $i, $ips := .Values.imagePullSecrets -}}
    {{- if $ips.name -}}
      {{- include "platforma.checkSecret" (dict
            "ctx" $
            "name" $ips.name
            "valuesPath" (printf "imagePullSecrets[%d].name" $i)
            "hint" "Image pull secret"
            "example" (printf "kubectl -n %s create secret docker-registry %s --docker-server=<registry> --docker-username=<user> --docker-password=<pass>"
                      $ns $ips.name)) -}}
    {{- end -}}
  {{- end -}}

  {{- /* ingress TLS — only when ingress is enabled and a Secret is explicitly named */ -}}
  {{- if and .Values.ingress.enabled .Values.ingress.tls.secretName -}}
    {{- include "platforma.checkSecret" (dict
          "ctx" .
          "name" .Values.ingress.tls.secretName
          "valuesPath" "ingress.tls.secretName"
          "hint" "Primary ingress TLS secret"
          "example" (printf "kubectl -n %s create secret tls %s --cert=./tls.crt --key=./tls.key"
                    .Release.Namespace .Values.ingress.tls.secretName)) -}}
  {{- end -}}
  {{- if and .Values.additionalIngress.enabled .Values.additionalIngress.tls.secretName -}}
    {{- include "platforma.checkSecret" (dict
          "ctx" .
          "name" .Values.additionalIngress.tls.secretName
          "valuesPath" "additionalIngress.tls.secretName"
          "hint" "Additional ingress TLS secret"
          "example" (printf "kubectl -n %s create secret tls %s --cert=./tls.crt --key=./tls.key"
                    .Release.Namespace .Values.additionalIngress.tls.secretName)) -}}
  {{- end -}}

{{- end -}}
{{- end -}}
