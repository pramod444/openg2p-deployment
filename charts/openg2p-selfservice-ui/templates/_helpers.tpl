{{/*
Expand the name of the chart.
*/}}
{{- define "portal.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
We truncate at 63 chars because some Kubernetes name fields are limited to this (by the DNS naming spec).
If release name contains chart name it will be used as a full name.
*/}}
{{- define "portal.fullname" -}}
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
{{- define "portal.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "portal.labels" -}}
helm.sh/chart: {{ include "portal.chart" . }}
{{ include "portal.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "portal.selectorLabels" -}}
app.kubernetes.io/name: {{ include "portal.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Create the name of the service account to use
*/}}
{{- define "portal.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "portal.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
Render Env values section
*/}}
{{- define "portal.envVars" -}}
{{- range $k, $v := .Values.envVars }}
- name: {{ $k }}
  value: {{ tpl $v $ | squote }}
{{- end }}
{{- range $k, $v := .Values.envVarsFrom }}
- name: {{ $k }}
  valueFrom:
    {{- if $v.configMapKeyRef }}
    configMapKeyRef:
      name: {{ tpl $v.configMapKeyRef.name $ | squote }}
      key: {{ tpl $v.configMapKeyRef.key $ | squote }}
    {{- else if $v.secretKeyRef }}
    secretKeyRef:
      name: {{ tpl $v.secretKeyRef.name $ | squote }}
      key: {{ tpl $v.secretKeyRef.key $ | squote }}
    {{- end }}
{{- end }}
{{- end }}
