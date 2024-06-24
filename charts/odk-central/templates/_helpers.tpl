{{/*
Render Env values section
*/}}
{{- define "odk-central.baseEnvVars" -}}
{{- $context := .context -}}
{{- range $k, $v := .envVars }}
- name: {{ $k }}
{{- if or (kindIs "int64" $v) (kindIs "float64" $v) (kindIs "bool" $v) }}
  value: {{ $v | quote }}
{{- else if kindIs "string" $v }}
  value: {{ include "common.tplvalues.render" ( dict "value" $v "context" $context ) | squote }}
{{- else }}
  valueFrom: {{- include "common.tplvalues.render" ( dict "value" $v "context" $context ) | nindent 4}}
{{- end }}
{{- end }}
{{- end -}}

{{- define "odk-central-backend.envVars" -}}
{{- $envVars := merge (deepCopy .Values.backend.envVars) (deepCopy .Values.backend.envVarsFrom) -}}
{{- include "odk-central.baseEnvVars" (dict "envVars" $envVars "context" $) }}
{{- end -}}

{{- define "odk-central-frontend.envVars" -}}
{{- $envVars := merge (deepCopy .Values.frontend.envVars) (deepCopy .Values.frontend.envVarsFrom) -}}
{{- include "odk-central.baseEnvVars" (dict "envVars" $envVars "context" $) }}
{{- end -}}
