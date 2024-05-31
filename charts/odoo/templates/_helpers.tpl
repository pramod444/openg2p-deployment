{{/*
Return the proper Odoo image name
*/}}
{{- define "odoo.image" -}}
{{ include "common.images.image" (dict "imageRoot" .Values.image "global" .Values.global) }}
{{- end -}}

{{/*
Return the proper Docker Image Registry Secret Names
*/}}
{{- define "odoo.imagePullSecrets" -}}
{{ include "common.images.pullSecrets" (dict "images" (list .Values.image) "global" .Values.global) }}
{{- end -}}

{{/*
Odoo credential secret name
*/}}
{{- define "odoo.secretName" -}}
{{- coalesce .Values.existingSecret (include "common.names.fullname" .) -}}
{{- end -}}

{{/*
 Create the name of the service account to use
 */}}
{{- define "odoo.serviceAccountName" -}}
{{- if .Values.serviceAccount.create -}}
    {{ default (include "common.names.fullname" .) .Values.serviceAccount.name }}
{{- else -}}
    {{ default "default" .Values.serviceAccount.name }}
{{- end -}}
{{- end -}}

{{/*
Render Hostname section
*/}}
{{- define "odoo.hostname" -}}
{{ default $.Values.global.hostname (default .hostname .host) }}
{{- end -}}

{{/*
Render Env values section
*/}}
{{- define "odoo.envVars" -}}
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
