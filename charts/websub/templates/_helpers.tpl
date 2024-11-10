{{/*
Return the proper  image name
*/}}
{{- define "websub.image" -}}
{{ include "common.images.image" (dict "imageRoot" .Values.image "global" .Values.global) }}
{{- end -}}

{{- define "websub.consolidator.image" -}}
{{ include "common.images.image" (dict "imageRoot" .Values.consolidator.image "global" .Values.global) }}
{{- end -}}

{{/*
Return the proper Docker Image Registry Secret Names
*/}}
{{- define "websub.imagePullSecrets" -}}
{{- include "common.images.pullSecrets" (dict "images" (list .Values.image .Values.consolidator.image) "global" .Values.global) -}}
{{- end -}}

{{/*
Create the name of the service account to use
*/}}
{{- define "websub.serviceAccountName" -}}
{{- if .Values.serviceAccount.create -}}
    {{ default (printf "%s" (include "common.names.fullname" .)) .Values.serviceAccount.name }}
{{- else -}}
    {{ default "default" .Values.serviceAccount.name }}
{{- end -}}
{{- end -}}

{{/*
Return podAnnotations
*/}}
{{- define "websub.podAnnotations" -}}
{{- if .Values.podAnnotations }}
{{ include "common.tplvalues.render" (dict "value" .Values.podAnnotations "context" $) }}
{{- end }}
{{- if and .Values.metrics.enabled .Values.metrics.podAnnotations }}
{{ include "common.tplvalues.render" (dict "value" .Values.metrics.podAnnotations "context" $) }}
{{- end }}
{{- end -}}

{{- define "websub.consolidator.podAnnotations" -}}
{{- if .Values.consolidator.podAnnotations }}
{{ include "common.tplvalues.render" (dict "value" .Values.consolidator.podAnnotations "context" $) }}
{{- end }}
{{- if and .Values.metrics.enabled .Values.metrics.podAnnotations }}
{{ include "common.tplvalues.render" (dict "value" .Values.metrics.podAnnotations "context" $) }}
{{- end }}
{{- end -}}

{{/*
Render Env values section
*/}}
{{- define "websub.baseEnvVars" -}}
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

{{- define "websub.envVars" -}}
{{- $envVars := merge (deepCopy .Values.envVars) (deepCopy .Values.envVarsFrom) -}}
{{- include "websub.baseEnvVars" (dict "envVars" $envVars "context" $) }}
{{- end -}}

{{- define "websub.consolidator.envVars" -}}
{{- $envVars := merge (deepCopy .Values.consolidator.envVars) (deepCopy .Values.consolidator.envVarsFrom) -}}
{{- include "websub.baseEnvVars" (dict "envVars" $envVars "context" $) }}
{{- end -}}

{{/*
Return command
*/}}
{{- define "websub.commandBase" -}}
{{- if or .command .args }}
{{- if .command }}
command: {{- include "common.tplvalues.render" (dict "value" .command "context" .context) }}
{{- end }}
{{- if .args }}
args: {{- include "common.tplvalues.render" (dict "value" .args "context" .context) }}
{{- end }}
{{- else if .startUpCommand }}
command: ["/startup.sh"]
args: []
{{- end }}
{{- end -}}

{{- define "websub.command" -}}
{{- include "websub.commandBase" (dict "command" .Values.command "args" .Values.args "startUpCommand" .Values.startUpCommand "context" $) }}
{{- end -}}

{{- define "websub.consolidator.command" -}}
{{- include "websub.commandBase" (dict "command" .Values.consolidator.command "args" .Values.consolidator.args "startUpCommand" .Values.consolidator.startUpCommand "context" $) }}
{{- end -}}
