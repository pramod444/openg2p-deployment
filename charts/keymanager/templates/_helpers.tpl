{{/*
Return the proper  image name
*/}}
{{- define "keymanager.image" -}}
{{ include "common.images.image" (dict "imageRoot" .Values.image "global" .Values.global) }}
{{- end -}}

{{/*
Return the proper image name (for the init container volume-permissions image)
*/}}
{{- define "keymanager.volumePermissions.image" -}}
{{- include "common.images.image" ( dict "imageRoot" .Values.volumePermissions.image "global" .Values.global ) -}}
{{- end -}}

{{/*
Return the proper Docker Image Registry Secret Names
*/}}
{{- define "keymanager.imagePullSecrets" -}}
{{- include "common.images.pullSecrets" (dict "images" (list .Values.image .Values.volumePermissions.image .Values.postgresInit.image .Values.keygen.image) "global" .Values.global) -}}
{{- end -}}

{{/*
Create the name of the service account to use
*/}}
{{- define "keymanager.serviceAccountName" -}}
{{- if .Values.serviceAccount.create -}}
    {{ default (printf "%s" (include "common.names.fullname" .)) .Values.serviceAccount.name }}
{{- else -}}
    {{ default "default" .Values.serviceAccount.name }}
{{- end -}}
{{- end -}}

{{/*
Compile all warnings into a single message.
*/}}
{{- define "keymanager.validateValues" -}}
{{- $messages := list -}}
{{- $messages := append $messages (include "keymanager.validateValues.foo" .) -}}
{{- $messages := append $messages (include "keymanager.validateValues.bar" .) -}}
{{- $messages := without $messages "" -}}
{{- $message := join "\n" $messages -}}

{{- if $message -}}
{{-   printf "\nVALUES VALIDATION:\n%s" $message -}}
{{- end -}}
{{- end -}}

{{/*
Return podAnnotations
*/}}
{{- define "keymanager.podAnnotations" -}}
{{- if .Values.podAnnotations }}
{{ include "common.tplvalues.render" (dict "value" .Values.podAnnotations "context" $) }}
{{- end }}
{{- if and .Values.metrics.enabled .Values.metrics.podAnnotations }}
{{ include "common.tplvalues.render" (dict "value" .Values.metrics.podAnnotations "context" $) }}
{{- end }}
{{- end -}}

{{/*
Render Env values section
*/}}
{{- define "keymanager.baseEnvVars" -}}
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

{{- define "keymanager.envVars" -}}
{{- $envVars := merge (deepCopy .Values.envVars) (deepCopy .Values.envVarsFrom) (.Values.springConfig.gitRepo.enabled | ternary (deepCopy .Values.springConfig.gitRepo.envVars) dict) -}}
{{- include "keymanager.baseEnvVars" (dict "envVars" $envVars "context" $) }}
{{- end -}}

{{- define "keymanager.postgresInit.envVars" -}}
{{- $envVars := merge (deepCopy .Values.postgresInit.envVars) (deepCopy .Values.postgresInit.envVarsFrom) -}}
{{- include "keymanager.baseEnvVars" (dict "envVars" $envVars "context" $) }}
{{- end -}}

{{- define "keymanager.keygen.envVars" -}}
{{- $envVars := merge (deepCopy .Values.keygen.envVars) (deepCopy .Values.envVars) (.Values.springConfig.gitRepo.enabled | ternary (deepCopy .Values.springConfig.gitRepo.envVars) dict) -}}
{{- $envVarsFrom := merge (deepCopy .Values.keygen.envVarsFrom) (deepCopy .Values.envVarsFrom) -}}
{{- $_ := merge $envVars $envVarsFrom -}}
{{- include "keymanager.baseEnvVars" (dict "envVars" $envVars "context" $) }}
{{- end -}}

{{/*
Return command
*/}}
{{- define "keymanager.commandBase" -}}
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

{{- define "keymanager.command" -}}
{{- include "keymanager.commandBase" (dict "command" .Values.command "args" .Values.args "startUpCommand" .Values.startUpCommand "context" $) }}
{{- end -}}

{{- define "keymanager.keygen.command" -}}
{{- include "keymanager.commandBase" (dict "command" .Values.keygen.command "args" .Values.keygen.args "startUpCommand" .Values.keygen.startUpCommand "context" $) }}
{{- end -}}
