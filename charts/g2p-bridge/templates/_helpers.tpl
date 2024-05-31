{{/*
Expand the name of the chart.
*/}}
{{- define "gctb.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
We truncate at 63 chars because some Kubernetes name fields are limited to this (by the DNS naming spec).
If release name contains chart name it will be used as a full name.
*/}}
{{- define "gctb.fullname" -}}
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
{{- define "gctb.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "gctb.labels" -}}
helm.sh/chart: {{ include "gctb.chart" . }}
{{ include "gctb.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "gctb.selectorLabels" -}}
app.kubernetes.io/name: {{ include "gctb.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Create the name of the service account to use
*/}}
{{- define "gctb.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "gctb.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
Render Env values section
*/}}
{{- define "gctb.envVars" -}}
{{- range $k, $v := .Values.envVars }}
- name: {{ $k }}
  value: {{ tpl $v $ | quote }}
{{- end }}
{{- range $k, $v := .Values.envVarsFrom }}
- name: {{ $k }}
  valueFrom:
    {{- if $v.configMapKeyRef }}
    configMapKeyRef:
      name: {{ tpl $v.configMapKeyRef.name $ | quote }}
      key: {{ tpl $v.configMapKeyRef.key $ | quote }}
    {{- else if $v.secretKeyRef }}
    secretKeyRef:
      name: {{ tpl $v.secretKeyRef.name $ | quote }}
      key: {{ tpl $v.secretKeyRef.key $ | quote }}
    {{- end }}
{{- end }}
{{- end }}
