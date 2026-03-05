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
nginx helpers — used by the optional nginx templates
*/}}

{{- define "alloy.nginx.fullname" -}}
{{- printf "%s-nginx" (include "alloy.fullname" .) | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "alloy.nginx.labels" -}}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
app.kubernetes.io/name: {{ printf "%s-nginx" .Chart.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Values.nginx.image.tag | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{- define "alloy.nginx.selectorLabels" -}}
app.kubernetes.io/name: {{ printf "%s-nginx" .Chart.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}
