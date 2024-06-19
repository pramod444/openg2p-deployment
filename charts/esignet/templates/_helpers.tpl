{{/*
Return the proper  image name
*/}}
{{- define "esignet.image" -}}
{{ include "common.images.image" (dict "imageRoot" .Values.image "global" .Values.global) }}
{{- end -}}

{{- define "esignet.oidc-ui.image" -}}
{{ include "common.images.image" (dict "imageRoot" .Values.oidcUi.image "global" .Values.global) }}
{{- end -}}

{{/*
Return the proper image name (for the init container volume-permissions image)
*/}}
{{- define "esignet.volumePermissions.image" -}}
{{- include "common.images.image" ( dict "imageRoot" .Values.volumePermissions.image "global" .Values.global ) -}}
{{- end -}}

{{/*
Return the proper Docker Image Registry Secret Names
*/}}
{{- define "esignet.imagePullSecrets" -}}
{{- include "common.images.pullSecrets" (dict "images" (list .Values.image .Values.volumePermissions.image .Values.postgresInit.image .Values.keygen.image .Values.oidcUi.image) "global" .Values.global) -}}
{{- end -}}

{{/*
Create the name of the service account to use
*/}}
{{- define "esignet.serviceAccountName" -}}
{{- if .Values.serviceAccount.create -}}
    {{ default (printf "%s" (include "common.names.fullname" .)) .Values.serviceAccount.name }}
{{- else -}}
    {{ default "default" .Values.serviceAccount.name }}
{{- end -}}
{{- end -}}

{{/*
Compile all warnings into a single message.
*/}}
{{- define "esignet.validateValues" -}}
{{- $messages := list -}}
{{- $messages := append $messages (include "esignet.validateValues.foo" .) -}}
{{- $messages := append $messages (include "esignet.validateValues.bar" .) -}}
{{- $messages := without $messages "" -}}
{{- $message := join "\n" $messages -}}

{{- if $message -}}
{{-   printf "\nVALUES VALIDATION:\n%s" $message -}}
{{- end -}}
{{- end -}}

{{/*
Return podAnnotations
*/}}
{{- define "esignet.podAnnotations" -}}
{{- if .Values.podAnnotations }}
{{ include "common.tplvalues.render" (dict "value" .Values.podAnnotations "context" $) }}
{{- end }}
{{- if and .Values.metrics.enabled .Values.metrics.podAnnotations }}
{{ include "common.tplvalues.render" (dict "value" .Values.metrics.podAnnotations "context" $) }}
{{- end }}
{{- end -}}

{{- define "esignet.oidc-ui.podAnnotations" -}}
{{- if .Values.oidcUi.podAnnotations }}
{{ include "common.tplvalues.render" (dict "value" .Values.oidcUi.podAnnotations "context" $) }}
{{- end }}
{{- if and .Values.metrics.enabled .Values.metrics.podAnnotations }}
{{ include "common.tplvalues.render" (dict "value" .Values.metrics.podAnnotations "context" $) }}
{{- end }}
{{- end -}}

{{/*
Render Env values section
*/}}
{{- define "esignet.baseEnvVars" -}}
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

{{- define "esignet.envVars" -}}
{{- $envVars := merge (deepCopy .Values.envVars) (deepCopy .Values.envVarsFrom) -}}
{{- include "esignet.baseEnvVars" (dict "envVars" $envVars "context" $) }}
{{- end -}}

{{- define "esignet.postgresInit.envVars" -}}
{{- $envVars := merge (deepCopy .Values.postgresInit.envVars) (deepCopy .Values.postgresInit.envVarsFrom) -}}
{{- include "esignet.baseEnvVars" (dict "envVars" $envVars "context" $) }}
{{- end -}}

{{- define "esignet.keygen.envVars" -}}
{{- $envVars := merge (deepCopy .Values.keygen.envVars) (deepCopy .Values.envVars) -}}
{{- $envVarsFrom := merge (deepCopy .Values.keygen.envVarsFrom) (deepCopy .Values.envVarsFrom) -}}
{{- $_ := merge $envVars $envVarsFrom -}}
{{- include "esignet.baseEnvVars" (dict "envVars" $envVars "context" $) }}
{{- end -}}

{{- define "esignet.oidc-ui.envVars" -}}
{{- $envVars := merge (deepCopy .Values.oidcUi.envVars) (deepCopy .Values.oidcUi.envVarsFrom) -}}
{{- include "esignet.baseEnvVars" (dict "envVars" $envVars "context" $) }}
{{- end -}}

{{/*
Return command
*/}}
{{- define "esignet.commandBase" -}}
{{- if or .command .args }}
{{- if .command }}
command: {{- include "common.tplvalues.render" (dict "value" .command "context" .context) }}
{{- end }}
{{- if .Values.args }}
args: {{- include "common.tplvalues.render" (dict "value" .args "context" .context) }}
{{- end }}
{{- else if .startUpCommand }}
command: ["/startup.sh"]
args: []
{{- end }}
{{- end -}}

{{- define "esignet.command" -}}
{{- include "esignet.commandBase" (dict "command" .Values.command "args" .Values.args "startUpCommand" .Values.startUpCommand "context" $) }}
{{- end -}}

{{- define "esignet.keygen.command" -}}
{{- include "esignet.commandBase" (dict "command" .Values.keygen.command "args" .Values.keygen.args "startUpCommand" .Values.keygen.startUpCommand "context" $) }}
{{- end -}}

{{- define "esignet.oidc-ui.command" -}}
{{- if or .Values.oidcUi.command .Values.oidcUi.args }}
{{- if .command }}
command: {{- include "common.tplvalues.render" (dict "value" .Values.oidcUi.command "context" $) }}
{{- end }}
{{- if .Values.oidcUi.args }}
args: {{- include "common.tplvalues.render" (dict "value" .Values.oidcUi.args "context" $) }}
{{- end }}
{{- else }}
command: ["./configure_start.sh"]
args:
  - bash
  - -c
  - echo "Waiting for artifactory..." && if ! curl -I -s -o /dev/null -m 10 --retry 100 --retry-delay 10 --retry-all-errors "$artifactory_url_env/"; then echo "Connecting with artifactory failed after max retries..."; exit 1; fi && exec nginx -g 'daemon off;'
{{- end }}
{{- end -}}
