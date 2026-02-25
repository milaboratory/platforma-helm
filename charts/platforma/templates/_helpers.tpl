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
Kueue UI LocalQueue name
*/}}
{{- define "platforma.kueue.uiQueueName" -}}
{{- if eq .Values.kueue.mode "shared" }}
{{- .Values.kueue.shared.queues.ui }}
{{- else }}
{{- printf "%s-ui-tasks" (include "platforma.fullname" .) }}
{{- end }}
{{- end }}

{{/*
Kueue Batch LocalQueue name
*/}}
{{- define "platforma.kueue.batchQueueName" -}}
{{- if eq .Values.kueue.mode "shared" }}
{{- .Values.kueue.shared.queues.batch }}
{{- else }}
{{- printf "%s-batch-tasks" (include "platforma.fullname" .) }}
{{- end }}
{{- end }}

{{/*
Kueue UI ClusterQueue name
*/}}
{{- define "platforma.kueue.uiClusterQueueName" -}}
{{- printf "%s-ui" (include "platforma.fullname" .) }}
{{- end }}

{{/*
Kueue Batch ClusterQueue name
*/}}
{{- define "platforma.kueue.batchClusterQueueName" -}}
{{- printf "%s-batch" (include "platforma.fullname" .) }}
{{- end }}

{{/*
Mount paths — single source of truth for all templates
*/}}
{{- define "platforma.path.database" -}}/data/database{{- end }}
{{- define "platforma.path.workspace" -}}/data/workspace{{- end }}
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
