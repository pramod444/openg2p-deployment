{{/*
Render Env values section
*/}}
{{- define "odkEnketo.envVars" -}}
{{- range $k, $v := .Values.envVars }}
- name: {{ $k }}
  value: {{ include "common.tplvalues.render" ( dict "value" $v "context" $ ) | squote }}
{{- end }}
{{- range $k, $v := .Values.envVarsFrom }}
- name: {{ $k }}
  valueFrom:
    {{- if $v.configMapKeyRef }}
    configMapKeyRef:
      name: {{ include "common.tplvalues.render" ( dict "value" $v.configMapKeyRef.name "context" $ ) | squote }}
      key: {{ include "common.tplvalues.render" ( dict "value" $v.configMapKeyRef.key "context" $ ) | squote }}
    {{- else if $v.secretKeyRef }}
    secretKeyRef:
      name: {{ include "common.tplvalues.render" ( dict "value" $v.secretKeyRef.name "context" $ ) | squote }}
      key: {{ include "common.tplvalues.render" ( dict "value" $v.secretKeyRef.key "context" $ ) | squote }}
    {{- end }}
{{- end }}
{{- end }}
