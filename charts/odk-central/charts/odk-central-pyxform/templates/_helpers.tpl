{{/*
Render Env values section
*/}}
{{- define "odkPyxform.baseEnvVars" -}}
{{- $context := .context -}}
{{- range $k, $v := .envVars }}
- name: {{ $k }}
{{- if or (kindIs "int" $v) (kindIs "bool" $v) }}
  value: {{ $v | quote }}
{{- else if kindIs "string" $v }}
  value: {{ include "common.tplvalues.render" ( dict "value" $v "context" $context ) | squote }}
{{- else }}
  valueFrom: {{- include "common.tplvalues.render" ( dict "value" $v "context" $context ) | nindent 4}}
{{- end }}
{{- end }}
{{- end -}}

{{- define "odkPyxform.envVars" -}}
{{- $envVars := merge (deepCopy .Values.envVars) (deepCopy .Values.envVarsFrom) -}}
{{- include "mail.baseEnvVars" (dict "envVars" $envVars "context" $) }}
{{- end }}
