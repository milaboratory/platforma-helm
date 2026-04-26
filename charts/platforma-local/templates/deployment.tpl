apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ include "platforma-local.fullname" . }}
  labels:
    {{- include "platforma-local.labels" . | nindent 4 }}
spec:
  replicas: 1
  strategy:
    type: Recreate
  selector:
    matchLabels:
      {{- include "platforma-local.selectorLabels" . | nindent 6 }}
  template:
    metadata:
      labels:
        {{- include "platforma-local.selectorLabels" . | nindent 8 }}
    spec:
      containers:
        - name: platforma
          image: "{{ .Values.image.repository }}:{{ .Values.image.tag }}"
          imagePullPolicy: {{ .Values.image.pullPolicy }}
          args:
            # Network
            - "--listen-address=0.0.0.0"
            - "--monitoring-ip=0.0.0.0"
            # Storage paths
            - "--main-root=/data/main"
            - "--db-dir=/data/database"
            - "--work-dir=/data/workspace/work"
            - "--packages-dir=/data/workspace/packages"
            # Local FS primary storage
            - "--primary-storage-fs=/data/storage"
            {{- if .Values.storage.fsExternalUrl }}
            - "--primary-storage-fs-url={{ .Values.storage.fsExternalUrl }}"
            {{- end }}
            # Queue runners — all queues use local runner (RAM/CPU auto-detected from pod cgroup)
            - "--queue-runner=ui-tasks:local"
            - "--queue-runner=light:local"
            - "--queue-runner=medium:local"
            - "--queue-runner=heavy:local"
            # Authentication — htpasswd
            {{- if .Values.auth.htpasswd.secretName }}
            - "--auth-htpasswd=/etc/platforma/secrets/htpasswd"
            {{- end }}
            # Authentication — LDAP
            {{- if .Values.auth.ldap.server }}
            - "--auth-ldap-server={{ .Values.auth.ldap.server }}"
            {{- if .Values.auth.ldap.startTLS }}
            - "--auth-ldap-start-tls"
            {{- end }}
            {{- if .Values.auth.ldap.bindDN }}
            - "--auth-ldap-dn={{ .Values.auth.ldap.bindDN }}"
            {{- end }}
            {{- range .Values.auth.ldap.searchRules }}
            - "--auth-ldap-search-rule={{ . }}"
            {{- end }}
            {{- if .Values.auth.ldap.searchUser }}
            - "--auth-ldap-search-user={{ .Values.auth.ldap.searchUser }}"
            {{- end }}
            {{- if .Values.auth.ldap.tls.insecureSkipVerify }}
            - "--auth-ldap-insecure-tls"
            {{- end }}
            {{- end }}
            # License
            {{- if .Values.license.secretName }}
            - "--license-file=/etc/platforma/license/{{ .Values.license.secretKey }}"
            {{- end }}
            # No host data library
            - "--no-host-data-library"
            # Debug
            - "--debug-enabled"
            - "--debug-port=9091"
            {{- if .Values.app.debug.enabled }}
            - "--debug-ip=0.0.0.0"
            - "--log-level=debug"
            {{- else }}
            - "--debug-ip=127.0.0.1"
            {{- end }}
            # Extra arguments (e.g. --no-auth for testing)
            {{- range .Values.app.extraArgs }}
            - {{ . | quote }}
            {{- end }}
          ports:
            - name: grpc
              containerPort: 6345
              protocol: TCP
            - name: http
              containerPort: 6347
              protocol: TCP
          env:
            {{- if .Values.license.secretName }}
            - name: PL_LICENSE
              valueFrom:
                secretKeyRef:
                  name: {{ .Values.license.secretName }}
                  key: {{ .Values.license.secretKey }}
            {{- end }}
            {{- if and .Values.auth.ldap.server .Values.auth.ldap.searchPasswordSecretRef.name }}
            - name: PL_AUTH_LDAP_SEARCH_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: {{ .Values.auth.ldap.searchPasswordSecretRef.name }}
                  key: {{ .Values.auth.ldap.searchPasswordSecretRef.key }}
            {{- else if and .Values.auth.ldap.server .Values.auth.ldap.searchPassword }}
            - name: PL_AUTH_LDAP_SEARCH_PASSWORD
              value: {{ .Values.auth.ldap.searchPassword | quote }}
            {{- end }}
            {{- range .Values.app.extraEnv }}
            - name: {{ .name }}
              {{- if .valueFrom }}
              valueFrom:
                {{- toYaml .valueFrom | nindent 16 }}
              {{- else }}
              value: {{ .value | quote }}
              {{- end }}
            {{- end }}
          startupProbe:
            grpc:
              port: 6345
              service: ""
            initialDelaySeconds: 5
            periodSeconds: 3
            timeoutSeconds: 5
            failureThreshold: 600
          readinessProbe:
            grpc:
              port: 6345
              service: ""
            periodSeconds: 5
            timeoutSeconds: 5
            failureThreshold: 6
          livenessProbe:
            grpc:
              port: 6345
              service: "GRPC"
            periodSeconds: 10
            timeoutSeconds: 5
            failureThreshold: 6
          resources:
            {{- toYaml .Values.resources | nindent 12 }}
          volumeMounts:
            - name: storage
              mountPath: /data/storage
            - name: workspace
              mountPath: /data/workspace
            - name: database
              mountPath: /data/database
            - name: main
              mountPath: /data/main
            {{- if .Values.license.secretName }}
            - name: license
              mountPath: /etc/platforma/license
              readOnly: true
            {{- end }}
            {{- if .Values.auth.htpasswd.secretName }}
            - name: htpasswd
              mountPath: /etc/platforma/secrets
              readOnly: true
            {{- end }}
      volumes:
        - name: storage
          emptyDir:
            sizeLimit: {{ .Values.volumes.storage.sizeLimit }}
        - name: workspace
          emptyDir:
            sizeLimit: {{ .Values.volumes.workspace.sizeLimit }}
        - name: database
          emptyDir:
            sizeLimit: {{ .Values.volumes.database.sizeLimit }}
        - name: main
          emptyDir:
            sizeLimit: {{ .Values.volumes.main.sizeLimit }}
        {{- if .Values.license.secretName }}
        - name: license
          secret:
            secretName: {{ .Values.license.secretName }}
            items:
              - key: {{ .Values.license.secretKey }}
                path: {{ .Values.license.secretKey }}
        {{- end }}
        {{- if .Values.auth.htpasswd.secretName }}
        - name: htpasswd
          secret:
            secretName: {{ .Values.auth.htpasswd.secretName }}
            items:
              - key: {{ .Values.auth.htpasswd.secretKey }}
                path: htpasswd
        {{- end }}
