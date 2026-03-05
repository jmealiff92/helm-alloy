{{/*
=============================================================================
alloy — library chart named templates
=============================================================================
All templates below operate on the CALLING chart's context (`.`), so
`.Chart.Name` and `.Release.Name` refer to the child chart (alloy-otlp,
alloy-prom, alloy-discovery), not to this library. This gives each child
chart correctly-namespaced resource names and labels automatically.
=============================================================================
*/}}

{{- define "alloy.fullname" -}}
{{- printf "%s-%s" .Release.Name .Chart.Name | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "alloy.labels" -}}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
app.kubernetes.io/name: {{ .Chart.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{- define "alloy.selectorLabels" -}}
app.kubernetes.io/name: {{ .Chart.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
=============================================================================
alloy.deployment — shared Deployment manifest
=============================================================================
Child charts call this from their templates/deployment.yaml:

  {{- include "alloy.deployment" . }}

Values contract (must be provided by the child chart's values.yaml):
  .Values.replicaCount
  .Values.image.{repository,tag,pullPolicy}
  .Values.config.content              (used only for checksum annotation)
  .Values.serviceAccountName          (optional)
  .Values.storagePath
  .Values.service.ports[]             (name, targetPort, protocol)
  .Values.securityContext
  .Values.resources
  .Values.extraArgs[]
  .Values.extraEnv[]
  .Values.extraVolumes[]
  .Values.extraVolumeMounts[]
  .Values.podAnnotations{}
  .Values.nodeSelector{}
  .Values.affinity{}
  .Values.tolerations[]
=============================================================================
*/}}
{{- define "alloy.deployment" -}}
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ include "alloy.fullname" . }}
  namespace: {{ .Release.Namespace }}
  labels:
    {{- include "alloy.labels" . | nindent 4 }}
spec:
  replicas: {{ .Values.replicaCount }}
  selector:
    matchLabels:
      {{- include "alloy.selectorLabels" . | nindent 6 }}
  template:
    metadata:
      annotations:
        checksum/config: {{ .Values.config.content | sha256sum }}
        {{- with .Values.podAnnotations }}
        {{- toYaml . | nindent 8 }}
        {{- end }}
      labels:
        {{- include "alloy.selectorLabels" . | nindent 8 }}
    spec:
      {{- if .Values.serviceAccountName }}
      serviceAccountName: {{ .Values.serviceAccountName }}
      {{- end }}

      volumes:
        - name: config
          configMap:
            name: {{ include "alloy.fullname" . }}-config
        - name: storage
          emptyDir: {}
        {{- with .Values.extraVolumes }}
        {{- toYaml . | nindent 8 }}
        {{- end }}

      containers:
        # ── Grafana Alloy ────────────────────────────────────────────────
        - name: alloy
          image: "{{ .Values.image.repository }}:{{ .Values.image.tag }}"
          imagePullPolicy: {{ .Values.image.pullPolicy }}
          args:
            - run
            - /etc/alloy/config.alloy
            - --storage.path={{ .Values.storagePath }}
            - --server.http.listen-addr=0.0.0.0:12345
            {{- range .Values.extraArgs }}
            - {{ . | quote }}
            {{- end }}
          ports:
            {{- range .Values.service.ports }}
            - name: {{ .name }}
              containerPort: {{ .targetPort }}
              protocol: {{ .protocol }}
            {{- end }}
          securityContext:
            {{- toYaml .Values.securityContext | nindent 12 }}
          volumeMounts:
            - name: config
              mountPath: /etc/alloy
              readOnly: true
            - name: storage
              mountPath: {{ .Values.storagePath }}
            {{- with .Values.extraVolumeMounts }}
            {{- toYaml . | nindent 12 }}
            {{- end }}
          {{- with .Values.extraEnv }}
          env:
            {{- toYaml . | nindent 12 }}
          {{- end }}
          resources:
            {{- toYaml .Values.resources | nindent 12 }}
          readinessProbe:
            httpGet:
              path: /-/ready
              port: 12345
            initialDelaySeconds: 10
            periodSeconds: 10
          livenessProbe:
            httpGet:
              path: /-/healthy
              port: 12345
            initialDelaySeconds: 20
            periodSeconds: 20

      {{- with .Values.nodeSelector }}
      nodeSelector:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      {{- with .Values.affinity }}
      affinity:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      {{- with .Values.tolerations }}
      tolerations:
        {{- toYaml . | nindent 8 }}
      {{- end }}
{{- end }}

{{/*
=============================================================================
alloy.service — shared Service manifest
=============================================================================
Values contract:
  .Values.service.type
  .Values.service.ports[]  (name, port, targetPort, protocol)
=============================================================================
*/}}
{{- define "alloy.service" -}}
apiVersion: v1
kind: Service
metadata:
  name: {{ include "alloy.fullname" . }}
  namespace: {{ .Release.Namespace }}
  labels:
    {{- include "alloy.labels" . | nindent 4 }}
spec:
  type: {{ .Values.service.type }}
  selector:
    {{- include "alloy.selectorLabels" . | nindent 4 }}
  ports:
    {{- range .Values.service.ports }}
    - name: {{ .name }}
      port: {{ .port }}
      targetPort: {{ .targetPort }}
      protocol: {{ .protocol }}
    {{- end }}
{{- end }}

{{/*
=============================================================================
alloy.configmap — shared ConfigMap manifest
=============================================================================
Values contract:
  .Values.config.content  (multi-line Alloy River config string)
=============================================================================
*/}}
{{- define "alloy.configmap" -}}
apiVersion: v1
kind: ConfigMap
metadata:
  name: {{ include "alloy.fullname" . }}-config
  namespace: {{ .Release.Namespace }}
  labels:
    {{- include "alloy.labels" . | nindent 4 }}
data:
  config.alloy: |-
    {{- .Values.config.content | nindent 4 }}
{{- end }}
