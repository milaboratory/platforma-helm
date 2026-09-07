{{/*
Expand the name of the chart.
*/}}
{{- define "platforma.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
*/}}
{{- define "platforma.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "platforma.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "platforma.labels" -}}
helm.sh/chart: {{ include "platforma.chart" . }}
{{ include "platforma.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "platforma.selectorLabels" -}}
app.kubernetes.io/name: {{ include "platforma.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Create the name of the service account for the server
*/}}
{{- define "platforma.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "platforma.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
Create the name of the service account for jobs
*/}}
{{- define "platforma.jobServiceAccountName" -}}
{{- if .Values.jobServiceAccount.create }}
{{- default (printf "%s-jobs" (include "platforma.fullname" .)) .Values.jobServiceAccount.name }}
{{- else }}
{{- default "default" .Values.jobServiceAccount.name }}
{{- end }}
{{- end }}

{{/*
Container image
*/}}
{{- define "platforma.image" -}}
{{- $tag := default .Chart.AppVersion .Values.image.tag }}
{{- printf "%s:%s" .Values.image.repository $tag }}
{{- end }}

{{/*
Workspace PVC name
*/}}
{{- define "platforma.workspacePvcName" -}}
{{- if .Values.storage.workspace.existingClaim }}
{{- .Values.storage.workspace.existingClaim }}
{{- else }}
{{- printf "%s-workspace" (include "platforma.fullname" .) }}
{{- end }}
{{- end }}

{{/*
Workspace PV name (includes namespace for multi-tenant safety)
*/}}
{{- define "platforma.workspacePvName" -}}
{{- printf "%s-%s-workspace-pv" .Release.Namespace (include "platforma.fullname" .) }}
{{- end }}

{{/*
Database PVC name
*/}}
{{- define "platforma.databasePvcName" -}}
{{- if .Values.storage.database.existingClaim }}
{{- .Values.storage.database.existingClaim }}
{{- else }}
{{- printf "%s-database" (include "platforma.fullname" .) }}
{{- end }}
{{- end }}

{{/*
Kueue cluster resource name prefix.
Used for cluster-scoped resources (ResourceFlavors, ClusterQueues, WorkloadPriorityClasses).
Defaults to fullname when kueue.dedicated.clusterResourceName is empty.
*/}}
{{- define "platforma.kueue.clusterResourceName" -}}
{{- if .Values.kueue.dedicated.clusterResourceName -}}
{{- .Values.kueue.dedicated.clusterResourceName -}}
{{- else -}}
{{- include "platforma.fullname" . -}}
{{- end -}}
{{- end }}

{{/*
Kueue UI LocalQueue name — always chart-generated (both modes create LocalQueues)
*/}}
{{- define "platforma.kueue.uiQueueName" -}}
{{- printf "%s-ui-tasks" (include "platforma.fullname" .) -}}
{{- end }}

{{/*
Kueue Batch LocalQueue name — always chart-generated (both modes create LocalQueues)
*/}}
{{- define "platforma.kueue.batchQueueName" -}}
{{- printf "%s-batch-tasks" (include "platforma.fullname" .) -}}
{{- end }}

{{/*
Kueue UI ClusterQueue name
*/}}
{{- define "platforma.kueue.uiClusterQueueName" -}}
{{- if eq .Values.kueue.mode "shared" -}}
{{- required "kueue.shared.clusterQueues.ui is required in shared mode" .Values.kueue.shared.clusterQueues.ui -}}
{{- else -}}
{{- printf "%s-ui" (include "platforma.kueue.clusterResourceName" .) -}}
{{- end -}}
{{- end }}

{{/*
Kueue Batch ClusterQueue name
*/}}
{{- define "platforma.kueue.batchClusterQueueName" -}}
{{- if eq .Values.kueue.mode "shared" -}}
{{- required "kueue.shared.clusterQueues.batch is required in shared mode" .Values.kueue.shared.clusterQueues.batch -}}
{{- else -}}
{{- printf "%s-batch" (include "platforma.kueue.clusterResourceName" .) -}}
{{- end -}}
{{- end }}

{{/*
Kueue WorkloadPriorityClass names — mode-aware
*/}}
{{- define "platforma.kueue.priorityClassName.ui" -}}
{{- if eq .Values.kueue.mode "shared" -}}
{{- required "kueue.shared.workloadPriorityClasses.uiTasks is required in shared mode" .Values.kueue.shared.workloadPriorityClasses.uiTasks -}}
{{- else -}}
{{- printf "%s-ui" (include "platforma.kueue.clusterResourceName" .) -}}
{{- end -}}
{{- end }}

{{- define "platforma.kueue.priorityClassName.high" -}}
{{- if eq .Values.kueue.mode "shared" -}}
{{- required "kueue.shared.workloadPriorityClasses.high is required in shared mode" .Values.kueue.shared.workloadPriorityClasses.high -}}
{{- else -}}
{{- printf "%s-high" (include "platforma.kueue.clusterResourceName" .) -}}
{{- end -}}
{{- end }}

{{- define "platforma.kueue.priorityClassName.normal" -}}
{{- if eq .Values.kueue.mode "shared" -}}
{{- required "kueue.shared.workloadPriorityClasses.normal is required in shared mode" .Values.kueue.shared.workloadPriorityClasses.normal -}}
{{- else -}}
{{- printf "%s-normal" (include "platforma.kueue.clusterResourceName" .) -}}
{{- end -}}
{{- end }}

{{- define "platforma.kueue.priorityClassName.low" -}}
{{- if eq .Values.kueue.mode "shared" -}}
{{- required "kueue.shared.workloadPriorityClasses.low is required in shared mode" .Values.kueue.shared.workloadPriorityClasses.low -}}
{{- else -}}
{{- printf "%s-low" (include "platforma.kueue.clusterResourceName" .) -}}
{{- end -}}
{{- end }}

{{/*
Kueue AdmissionCheck name for ProvisioningRequest
*/}}
{{- define "platforma.kueue.admissionCheckName" -}}
{{- printf "%s-provreq" (include "platforma.kueue.clusterResourceName" .) -}}
{{- end }}

{{/*
Main storage type — required, no auto-detection
*/}}
{{- define "platforma.mainStorageType" -}}
{{- .Values.storage.main.type -}}
{{- end }}

{{/*
htpasswd secret name — resolves to existing secret or chart-generated secret.
Returns empty string if htpasswd is not configured.
*/}}
{{- define "platforma.htpasswdSecretName" -}}
{{- if .Values.auth.htpasswd.secretName -}}
  {{- .Values.auth.htpasswd.secretName -}}
{{- else if and .Values.auth.htpasswd.credentials (gt (len .Values.auth.htpasswd.credentials) 0) -}}
  {{- printf "%s-htpasswd" (include "platforma.fullname" .) -}}
{{- end -}}
{{- end }}

{{/*
Generate htpasswd file content from inline credentials
*/}}
{{- define "platforma.htpasswdFileContent" -}}
{{- $result := "" -}}
{{- range .Values.auth.htpasswd.credentials -}}
{{- $result = printf "%s%s\n" $result (htpasswd .username .password) -}}
{{- end -}}
{{- $result -}}
{{- end }}

{{/*
Mount paths — single source of truth for all templates
*/}}
{{- define "platforma.path.database" -}}/data/database{{- end }}
{{- define "platforma.path.workspace" -}}/data/workspace{{- end }}
{{/*
Work storage: storage holding working directories.

Backend gets it via --work-dir and passes it to the job template, so both sides
always name the same location.
*/}}
{{- define "platforma.path.workStorageName" -}}work{{- end }}
{{- define "platforma.path.workStorage" -}}{{ include "platforma.path.workspace" . }}/{{ include "platforma.path.workStorageName" . }}{{- end }}

{{- define "platforma.path.templates" -}}/etc/platforma/templates{{- end }}
{{- define "platforma.path.scripts" -}}/etc/platforma/scripts{{- end }}
{{- define "platforma.path.license" -}}/etc/platforma/license{{- end }}
{{- define "platforma.path.secrets" -}}/etc/platforma/secrets{{- end }}

{{/*
Check if workspace storage is configured
Returns "true" if exactly one workspace option is enabled
*/}}
{{- define "platforma.workspaceConfigured" -}}
{{- $count := 0 }}
{{- if .Values.storage.workspace.existingClaim }}
  {{- $count = add $count 1 }}
{{- end }}
{{- if .Values.storage.workspace.efs.enabled }}
  {{- $count = add $count 1 }}
{{- end }}
{{- if .Values.storage.workspace.fsxLustre.enabled }}
  {{- $count = add $count 1 }}
{{- end }}
{{- if .Values.storage.workspace.filestore.enabled }}
  {{- $count = add $count 1 }}
{{- end }}
{{- if .Values.storage.workspace.nfs.enabled }}
  {{- $count = add $count 1 }}
{{- end }}
{{- if .Values.storage.workspace.pvc.enabled }}
  {{- $count = add $count 1 }}
{{- end }}
{{- eq (int $count) 1 }}
{{- end }}

{{/*
=============================================================================
Multi-provider auth (`auth.providers`) — backend >= 4.3.0
=============================================================================
The backend's per-provider `auth.*` CLI namespace declares any number of auth
providers, each with an id and a type (sso | htpasswd | ldap). It is a
REPLACEMENT for the flat legacy flags (--sso-idp-*, --auth-htpasswd,
--auth-ldap-*): the backend refuses to boot when both are present, so the
helpers below are gated against the legacy values blocks in deployment.yaml.

Secret material is the reason this cannot live in app.extraArgs alone — the
backend reads the htpasswd file, the OAuth client secret and the LDAP TLS
material from PATHS, and only the chart can mount a Secret at a path. Every
provider gets its own directory so two providers of the same type never
collide on a file name.
*/}}

{{/* Root of the per-provider secret mounts. */}}
{{- define "platforma.path.authSecrets" -}}{{ include "platforma.path.secrets" . }}/auth{{- end }}

{{/* Directory holding one provider's mounted secrets. Args: ctx, id. */}}
{{- define "platforma.auth.providerPath" -}}
{{- printf "%s/%s" (include "platforma.path.authSecrets" .ctx) .id -}}
{{- end }}

{{/* "true" when the multi-provider scheme is in use. */}}
{{- define "platforma.auth.providersEnabled" -}}
{{- if gt (len (default (dict) .Values.auth.providers)) 0 -}}true{{- end -}}
{{- end }}

{{/*
Legacy single-provider auth configured through the flat values blocks. Rendered
into an error message, so it returns the offending values paths rather than a
boolean — an empty result means "no legacy auth".
*/}}
{{- define "platforma.auth.legacyPaths" -}}
{{- $paths := list -}}
{{- if include "platforma.htpasswdSecretName" . -}}
  {{- $paths = append $paths "auth.htpasswd" -}}
{{- end -}}
{{- if .Values.auth.ldap.server -}}
  {{- $paths = append $paths "auth.ldap.server" -}}
{{- end -}}
{{- if .Values.auth.sso.issuer -}}
  {{- $paths = append $paths "auth.sso.issuer" -}}
{{- end -}}
{{- if .Values.auth.sso.clientSecret.secretName -}}
  {{- $paths = append $paths "auth.sso.clientSecret.secretName" -}}
{{- end -}}
{{- join ", " $paths -}}
{{- end }}

{{/*
htpasswd secret name for one provider — an existing Secret, or the one this
chart generates from inline credentials. Args: ctx, id, provider.
*/}}
{{- define "platforma.auth.providerHtpasswdSecretName" -}}
{{- $h := default (dict) .provider.htpasswd -}}
{{- if $h.secretName -}}
  {{- $h.secretName -}}
{{- else if gt (len (default (list) $h.credentials)) 0 -}}
  {{- printf "%s-auth-%s-htpasswd" (include "platforma.fullname" .ctx) .id -}}
{{- end -}}
{{- end }}

{{/*
Every `--auth.*` flag for every configured provider, as a YAML list of args.

The args are accumulated into a list and emitted with toYaml rather than
hand-quoted: role rules carry regexps (auth.role.attr-regex,
auth.role.group-regex) whose backslashes are an invalid escape inside a
hand-written double-quoted YAML scalar, and toYaml escapes them correctly.

Providers are emitted in sorted id order so the rendered Deployment is stable
and does not churn the pod template hash between upgrades.
*/}}
{{- define "platforma.auth.providerArgs" -}}
{{- $ctx := . -}}
{{- $args := list -}}
{{- /* Extension fields are declared once for the installation, and every field any provider maps
       is one by definition - so they are collected from mapFields rather than asked for twice.
       auth.extensionFields stays for a field declared ahead of anything mapping it. */ -}}
{{- $extensionFields := default (list) .Values.auth.extensionFields -}}
{{- range $id := keys (default (dict) .Values.auth.providers) | sortAlpha -}}
  {{- $p := index $ctx.Values.auth.providers $id -}}
  {{- range $field, $claim := default (dict) $p.mapFields -}}
    {{- $extensionFields = append $extensionFields $field -}}
  {{- end -}}
{{- end -}}
{{- range $f := $extensionFields | uniq | sortAlpha -}}
  {{- $args = append $args (printf "--auth.extension-field=%s" $f) -}}
{{- end -}}
{{- range $id := keys (default (dict) .Values.auth.providers) | sortAlpha -}}
  {{- $p := index $ctx.Values.auth.providers $id -}}
  {{- $dir := include "platforma.auth.providerPath" (dict "ctx" $ctx "id" $id) -}}
  {{- if not $p.type -}}
    {{- fail (printf "ERROR: auth.providers.%s.type is required. One of: sso, htpasswd, ldap." $id) -}}
  {{- end -}}
  {{- $args = append $args (printf "--auth.provider-id=%s" $id) -}}
  {{- $args = append $args (printf "--auth.provider-type=%s=%s" $id $p.type) -}}

  {{- /* ---- sso connection + login parameters ---- */ -}}
  {{- if eq $p.type "sso" -}}
    {{- $sso := default (dict) $p.sso -}}
    {{- if not $sso.issuer -}}
      {{- fail (printf "ERROR: auth.providers.%s.sso.issuer is required for a provider of type sso." $id) -}}
    {{- end -}}
    {{- if not $sso.clientId -}}
      {{- fail (printf "ERROR: auth.providers.%s.sso.clientId is required for a provider of type sso." $id) -}}
    {{- end -}}
    {{- $args = append $args (printf "--auth.sso.issuer=%s=%s" $id $sso.issuer) -}}
    {{- $args = append $args (printf "--auth.sso.client-id=%s=%s" $id $sso.clientId) -}}
    {{- if $sso.scopes -}}{{- $args = append $args (printf "--auth.sso.scopes=%s=%s" $id $sso.scopes) -}}{{- end -}}
    {{- if $sso.resource -}}{{- $args = append $args (printf "--auth.sso.resource=%s=%s" $id $sso.resource) -}}{{- end -}}
    {{- if $sso.prompt -}}{{- $args = append $args (printf "--auth.sso.prompt=%s=%s" $id $sso.prompt) -}}{{- end -}}
    {{- if $sso.accessType -}}{{- $args = append $args (printf "--auth.sso.access-type=%s=%s" $id $sso.accessType) -}}{{- end -}}
    {{- if $sso.userIdClaim -}}{{- $args = append $args (printf "--auth.sso.user-id-claim=%s=%s" $id $sso.userIdClaim) -}}{{- end -}}
    {{- if $sso.subjectTokenSource -}}{{- $args = append $args (printf "--auth.sso.subject-token-source=%s=%s" $id $sso.subjectTokenSource) -}}{{- end -}}
    {{- range $port := default (list) $sso.redirectPorts -}}
      {{- $args = append $args (printf "--auth.sso.redirect-port=%s=%v" $id $port) -}}
    {{- end -}}
    {{- range $alg := default (list) $sso.jwtAlgorithms -}}
      {{- $args = append $args (printf "--auth.sso.jwt-algorithm=%s=%s" $id $alg) -}}
    {{- end -}}
    {{- $cs := default (dict) $sso.clientSecret -}}
    {{- if $cs.secretName -}}
      {{- $args = append $args (printf "--auth.sso.client-secret-file=%s=%s/%s" $id $dir ($cs.secretKey | default "client-secret")) -}}
    {{- end -}}
  {{- end -}}

  {{- /* ---- htpasswd connection ---- */ -}}
  {{- if eq $p.type "htpasswd" -}}
    {{- if not (include "platforma.auth.providerHtpasswdSecretName" (dict "ctx" $ctx "id" $id "provider" $p)) -}}
      {{- fail (printf "ERROR: auth.providers.%s is type htpasswd but has no password file.\n\nSet either:\n  auth.providers.%s.htpasswd.credentials  # inline, chart creates the Secret\n  auth.providers.%s.htpasswd.secretName   # existing Secret holding an htpasswd file" $id $id $id) -}}
    {{- end -}}
    {{- $args = append $args (printf "--auth.htpasswd.file=%s=%s/htpasswd" $id $dir) -}}
  {{- end -}}

  {{- /* ---- ldap connection ---- */ -}}
  {{- if eq $p.type "ldap" -}}
    {{- $ldap := default (dict) $p.ldap -}}
    {{- if not $ldap.url -}}
      {{- fail (printf "ERROR: auth.providers.%s.ldap.url is required for a provider of type ldap." $id) -}}
    {{- end -}}
    {{- $args = append $args (printf "--auth.ldap.url=%s=%s" $id $ldap.url) -}}
    {{- if $ldap.userDN -}}{{- $args = append $args (printf "--auth.ldap.user-dn=%s=%s" $id $ldap.userDN) -}}{{- end -}}
    {{- if $ldap.bindDN -}}{{- $args = append $args (printf "--auth.ldap.bind-dn=%s=%s" $id $ldap.bindDN) -}}{{- end -}}
    {{- if $ldap.bindPassword -}}{{- $args = append $args (printf "--auth.ldap.bind-password=%s=%s" $id $ldap.bindPassword) -}}{{- end -}}
    {{- if $ldap.baseDN -}}{{- $args = append $args (printf "--auth.ldap.base-dn=%s=%s" $id $ldap.baseDN) -}}{{- end -}}
    {{- if $ldap.userFilter -}}{{- $args = append $args (printf "--auth.ldap.user-filter=%s=%s" $id $ldap.userFilter) -}}{{- end -}}
    {{- range $rule := default (list) $ldap.searchRules -}}
      {{- $args = append $args (printf "--auth.ldap.search-rule=%s=%s" $id $rule) -}}
    {{- end -}}
    {{- if $ldap.groupBaseDN -}}{{- $args = append $args (printf "--auth.ldap.group-base-dn=%s=%s" $id $ldap.groupBaseDN) -}}{{- end -}}
    {{- if $ldap.startTLS -}}{{- $args = append $args (printf "--auth.ldap.start-tls=%s=true" $id) -}}{{- end -}}
    {{- if $ldap.insecureTLS -}}{{- $args = append $args (printf "--auth.ldap.insecure-tls=%s=true" $id) -}}{{- end -}}
    {{- $ca := default (dict) $ldap.trustedCASecretRef -}}
    {{- if $ca.name -}}
      {{- $args = append $args (printf "--auth.ldap.trusted-ca=%s=%s/ldap-ca/%s" $id $dir ($ca.key | default "ca.crt")) -}}
    {{- end -}}
    {{- $cc := default (dict) $ldap.clientCertSecretRef -}}
    {{- if $cc.name -}}
      {{- $args = append $args (printf "--auth.ldap.client-cert=%s=%s/ldap-client/%s,%s/ldap-client/%s" $id $dir ($cc.certKey | default "tls.crt") $dir ($cc.keyKey | default "tls.key")) -}}
    {{- end -}}
  {{- end -}}

  {{- /* ---- identity matching, mapping and provisioning (all types) ---- */ -}}
  {{- if $p.lookUpAttr -}}{{- $args = append $args (printf "--auth.look-up-attr=%s=%s" $id $p.lookUpAttr) -}}{{- end -}}
  {{- if $p.trustUnverifiedEmail -}}{{- $args = append $args (printf "--auth.trust-unverified-email=%s=true" $id) -}}{{- end -}}
  {{- if $p.createUsers -}}{{- $args = append $args (printf "--auth.create-users=%s=true" $id) -}}{{- end -}}
  {{- $map := default (dict) $p.map -}}
  {{- if $map.login -}}{{- $args = append $args (printf "--auth.map.login=%s=%s" $id $map.login) -}}{{- end -}}
  {{- if $map.email -}}{{- $args = append $args (printf "--auth.map.email=%s=%s" $id $map.email) -}}{{- end -}}
  {{- if $map.displayName -}}{{- $args = append $args (printf "--auth.map.display-name=%s=%s" $id $map.displayName) -}}{{- end -}}
  {{- if $map.fullName -}}{{- $args = append $args (printf "--auth.map.full-name=%s=%s" $id $map.fullName) -}}{{- end -}}
  {{- /* map.externalId is removed: the backend no longer owns an "external_id" key. Map onto a
         field of your own with mapFields, so two providers can keep two external ids apart. The
         extension-field declaration is derived from mapFields above, so it is not set twice. */ -}}
  {{- if $map.externalId -}}{{- fail (printf "provider %q sets map.externalId, which is removed: use mapFields: {external_id: %s} instead" $id $map.externalId) -}}{{- end -}}
  {{- if $map.groups -}}{{- $args = append $args (printf "--auth.map.groups=%s=%s" $id $map.groups) -}}{{- end -}}
  {{- range $field, $claim := default (dict) $p.mapFields -}}
    {{- $args = append $args (printf "--auth.map-field=%s.%s=%s" $id $field $claim) -}}
  {{- end -}}

  {{- /* ---- roles ---- */ -}}
  {{- range $login := default (list) $p.adminUsers -}}
    {{- $args = append $args (printf "--auth.admin-user=%s=%s" $id $login) -}}
  {{- end -}}
  {{- $roles := default (dict) $p.roles -}}
  {{- range $rule := default (list) $roles.groups -}}
    {{- $args = append $args (printf "--auth.role.group=%s=%s" $id $rule) -}}
  {{- end -}}
  {{- range $rule := default (list) $roles.groupRegexps -}}
    {{- $args = append $args (printf "--auth.role.group-regex=%s=%s" $id $rule) -}}
  {{- end -}}
  {{- range $rule := default (list) $roles.attrRegexps -}}
    {{- $args = append $args (printf "--auth.role.attr-regex=%s=%s" $id $rule) -}}
  {{- end -}}

  {{- /* ---- Google Cloud Identity group lookup ---- */ -}}
  {{- $google := default (dict) $p.google -}}
  {{- if $google.groupFetch -}}
    {{- $args = append $args (printf "--auth.google-group-fetch=%s=true" $id) -}}
    {{- if $google.apiTimeout -}}{{- $args = append $args (printf "--auth.google-api-timeout=%s=%v" $id $google.apiTimeout) -}}{{- end -}}
    {{- if $google.apiRetries -}}{{- $args = append $args (printf "--auth.google-api-retries=%s=%v" $id $google.apiRetries) -}}{{- end -}}
  {{- end -}}
{{- end -}}
{{- toYaml $args -}}
{{- end }}

{{/*
volumeMounts for every provider's secret material. One mount per Secret, all
under the provider's own directory.
*/}}
{{- define "platforma.auth.providerVolumeMounts" -}}
{{- $ctx := . -}}
{{- range $id := keys (default (dict) .Values.auth.providers) | sortAlpha }}
{{- $p := index $ctx.Values.auth.providers $id }}
{{- $dir := include "platforma.auth.providerPath" (dict "ctx" $ctx "id" $id) }}
{{- if eq $p.type "htpasswd" }}
- name: auth-{{ $id }}-htpasswd
  mountPath: {{ $dir }}
  readOnly: true
{{- end }}
{{- if eq $p.type "sso" }}
{{- $cs := default (dict) (default (dict) $p.sso).clientSecret }}
{{- if $cs.secretName }}
- name: auth-{{ $id }}-client-secret
  mountPath: {{ $dir }}
  readOnly: true
{{- end }}
{{- end }}
{{- if eq $p.type "ldap" }}
{{- $ldap := default (dict) $p.ldap }}
{{- if (default (dict) $ldap.trustedCASecretRef).name }}
- name: auth-{{ $id }}-ldap-ca
  mountPath: {{ $dir }}/ldap-ca
  readOnly: true
{{- end }}
{{- if (default (dict) $ldap.clientCertSecretRef).name }}
- name: auth-{{ $id }}-ldap-client
  mountPath: {{ $dir }}/ldap-client
  readOnly: true
{{- end }}
{{- end }}
{{- end }}
{{- end }}

{{/*
volumes backing platforma.auth.providerVolumeMounts.
*/}}
{{- define "platforma.auth.providerVolumes" -}}
{{- $ctx := . -}}
{{- range $id := keys (default (dict) .Values.auth.providers) | sortAlpha }}
{{- $p := index $ctx.Values.auth.providers $id }}
{{- if eq $p.type "htpasswd" }}
{{- $h := default (dict) $p.htpasswd }}
- name: auth-{{ $id }}-htpasswd
  secret:
    secretName: {{ include "platforma.auth.providerHtpasswdSecretName" (dict "ctx" $ctx "id" $id "provider" $p) }}
    items:
      - key: {{ $h.secretKey | default "htpasswd" }}
        path: htpasswd
{{- end }}
{{- if eq $p.type "sso" }}
{{- $cs := default (dict) (default (dict) $p.sso).clientSecret }}
{{- if $cs.secretName }}
- name: auth-{{ $id }}-client-secret
  secret:
    secretName: {{ $cs.secretName }}
    items:
      - key: {{ $cs.secretKey | default "client-secret" }}
        path: {{ $cs.secretKey | default "client-secret" }}
{{- end }}
{{- end }}
{{- if eq $p.type "ldap" }}
{{- $ldap := default (dict) $p.ldap }}
{{- $ca := default (dict) $ldap.trustedCASecretRef }}
{{- if $ca.name }}
- name: auth-{{ $id }}-ldap-ca
  secret:
    secretName: {{ $ca.name }}
{{- end }}
{{- $cc := default (dict) $ldap.clientCertSecretRef }}
{{- if $cc.name }}
- name: auth-{{ $id }}-ldap-client
  secret:
    secretName: {{ $cc.name }}
{{- end }}
{{- end }}
{{- end }}
{{- end }}

{{/*
htpasswd file content for one provider's inline credentials. Args: provider.
*/}}
{{- define "platforma.auth.providerHtpasswdContent" -}}
{{- $result := "" -}}
{{- range (default (dict) .provider.htpasswd).credentials -}}
{{- $result = printf "%s%s\n" $result (htpasswd .username .password) -}}
{{- end -}}
{{- $result -}}
{{- end }}

{{/*
The source of the volume mounted at /tmp, which is also where TMPDIR points when the
command asked for scratch space.

A command that asked for scratch space gets a volume the cluster attaches, made for
the job and deleted with it. Every other command gets the small shared volume, which
is what every job had before scratch space existed.

Without a StorageClass there is nothing to attach, and the request falls back to that
same shared volume: a volume nothing can provision would leave the job Pending for
ever, and scratch space is an optimisation, never a precondition.

Rendered at the caller's indentation — use it with `nindent`.
*/}}
{{- define "platforma.job.scratchVolumeSource" -}}
{{- $class := (include "platforma.scratchStorage" . | fromYaml).network.storageClass.name -}}
{{- if $class -}}
<<- if and .Resources .Resources.HasScratch >>
ephemeral:
  volumeClaimTemplate:
    spec:
      accessModes: ["ReadWriteOnce"]
      storageClassName: {{ $class }}
      resources:
        requests:
          storage: "<< .Resources.ScratchFreeSpace >>"
<<- else >>
emptyDir: {}
<<- end >>
{{- else -}}
emptyDir: {}
{{- end }}
{{- end }}

{{/*
The scratch-storage settings in effect, as a dict, after the defaults that come from
`environment` are filled in.

Scratch space must work out of the box on AWS, on any cluster, whether or not our own
CloudFormation or Terraform built it. So the network tier is complete by default there:
a gp3 StorageClass the chart creates, and the ceiling gp3 can serve. Elsewhere nothing
is assumed — the chart cannot know what a cluster's storage classes provision — and the
tier stays off until an operator names a class.

Every field an operator sets wins over its default, including `create: false` to point
at a class the cluster already has.
*/}}
{{- define "platforma.scratchStorage" -}}
{{- $s := .Values.jobs.scratchStorage -}}
{{- $aws := eq .Values.environment "aws" -}}
{{- $sc := $s.network.storageClass -}}
{{- $create := $sc.create -}}
{{- if kindIs "invalid" $create -}}{{- $create = $aws -}}{{- end -}}
{{- $encrypted := $sc.encrypted -}}
{{- if kindIs "invalid" $encrypted -}}{{- $encrypted = true -}}{{- end -}}
{{- $type := default "gp3" $sc.type -}}
{{- $iops := default 16000 $sc.iops -}}
{{- /*
  A volume that provisions performance has a smallest legal size: EBS refuses a volume
  whose IOPS are more than the type allows per GiB. Derive the floor from the class this
  chart creates, so a small request is grown to a size that can be provisioned instead of
  failing to provision at all. A class the chart does not create has settings it cannot
  see, so there the operator sets the floor.
*/ -}}
{{- $iopsPerGi := dict "gp3" 500.0 "io1" 50.0 "io2" 1000.0 -}}
{{- $minRequest := $s.network.minRequest -}}
{{- if kindIs "invalid" $minRequest -}}
  {{- $minRequest = "" -}}
  {{- if and $create (hasKey $iopsPerGi $type) -}}
    {{- $minRequest = printf "%dGi" (int (ceil (divf (float64 $iops) (get $iopsPerGi $type)))) -}}
  {{- end -}}
{{- end -}}
{{- $network := dict
      "maxRequest" (default (ternary "16Ti" "" $aws) $s.network.maxRequest)
      "gpuMaxRequest" (default "" $s.network.gpuMaxRequest)
      "minRequest" $minRequest
      "storageClass" (dict
        "name" (default (ternary "platforma-scratch" "" $aws) $sc.name)
        "create" $create
        "type" $type
        "iops" $iops
        "throughput" (default 1000 $sc.throughput)
        "encrypted" $encrypted)
-}}
{{- toYaml (dict "network" $network) -}}
{{- end }}
