{{/*
Render Env values section
*/}}
{{- define "odk-central.baseEnvVars" -}}
{{- $context := .context -}}
{{- range $k, $v := .envVars }}
{{- if or (kindIs "int64" $v) (kindIs "float64" $v) (kindIs "bool" $v) }}
- name: {{ $k }}
  value: {{ $v | quote }}
{{- else if kindIs "string" $v }}
- name: {{ $k }}
  value: {{ include "common.tplvalues.render" ( dict "value" $v "context" $context ) | squote }}
{{- else }}
{{- $vEnabled := "true" }}
{{- if hasKey $v "enabled" }}
{{- $vEnabled = kindIs "bool" $v.enabled | ternary ($v.enabled | squote) (include "common.tplvalues.render" (dict "value" $v.enabled "context" $context)) }}
{{- $v = omit $v "enabled" }}
{{- end }}
{{- if eq $vEnabled "true" }}
- name: {{ $k }}
  valueFrom: {{- include "common.tplvalues.render" ( dict "value" $v "context" $context ) | nindent 4}}
{{- end }}
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
