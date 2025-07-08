{{/*
Return the proper  image name
*/}}
{{- define "keymanager.image" -}}
{{ include "common.images.image" (dict "imageRoot" .Values.image "global" .Values.global) }}
{{- end -}}

{{/*
Return the proper Docker Image Registry Secret Names
*/}}
{{- define "keymanager.imagePullSecrets" -}}
{{- include "common.images.pullSecrets" (dict "images" (list .Values.image .Values.postgresInit.image .Values.keygen.image) "global" .Values.global) -}}
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

{{- define "keymanager.postgresInit.command" -}}
{{- include "keymanager.commandBase" (dict "command" .Values.postgresInit.command "args" .Values.postgresInit.args "startUpCommand" .Values.postgresInit.startUpCommand "context" $) }}
{{- end -}}
