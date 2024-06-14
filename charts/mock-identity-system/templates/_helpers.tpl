{{/*
Return the proper  image name
*/}}
{{- define "mock-identity-system.image" -}}
{{ include "common.images.image" (dict "imageRoot" .Values.image "global" .Values.global) }}
{{- end -}}

{{/*
Return the proper image name (for the init container volume-permissions image)
*/}}
{{- define "mock-identity-system.volumePermissions.image" -}}
{{- include "common.images.image" ( dict "imageRoot" .Values.volumePermissions.image "global" .Values.global ) -}}
{{- end -}}

{{/*
Return the proper Docker Image Registry Secret Names
*/}}
{{- define "mock-identity-system.imagePullSecrets" -}}
{{- include "common.images.pullSecrets" (dict "images" (list .Values.image .Values.volumePermissions.image) "global" .Values.global) -}}
{{- end -}}

{{/*
Create the name of the service account to use
*/}}
{{- define "mock-identity-system.serviceAccountName" -}}
{{- if .Values.serviceAccount.create -}}
    {{ default (printf "%s" (include "common.names.fullname" .)) .Values.serviceAccount.name }}
{{- else -}}
    {{ default "default" .Values.serviceAccount.name }}
{{- end -}}
{{- end -}}

{{/*
Compile all warnings into a single message.
*/}}
{{- define "mock-identity-system.validateValues" -}}
{{- $messages := list -}}
{{- $messages := append $messages (include "mock-identity-system.validateValues.foo" .) -}}
{{- $messages := append $messages (include "mock-identity-system.validateValues.bar" .) -}}
{{- $messages := without $messages "" -}}
{{- $message := join "\n" $messages -}}

{{- if $message -}}
{{-   printf "\nVALUES VALIDATION:\n%s" $message -}}
{{- end -}}
{{- end -}}

{{/*
Return podAnnotations
*/}}
{{- define "mock-identity-system.podAnnotations" -}}
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
{{- define "mock-identity-system.baseEnvVars" -}}
{{- $context := .context }}
{{- range $k, $v := .envVars }}
- name: {{ $k }}
  value: {{ include "common.tplvalues.render" ( dict "value" $v "context" $context ) | squote }}
{{- end }}
{{- range $k, $v := .envVarsFrom }}
- name: {{ $k }}
  valueFrom:
    {{- if $v.configMapKeyRef }}
    configMapKeyRef:
      name: {{ include "common.tplvalues.render" ( dict "value" $v.configMapKeyRef.name "context" $context ) | squote }}
      key: {{ include "common.tplvalues.render" ( dict "value" $v.configMapKeyRef.key "context" $context ) | squote }}
    {{- else if $v.secretKeyRef }}
    secretKeyRef:
      name: {{ include "common.tplvalues.render" ( dict "value" $v.secretKeyRef.name "context" $context ) | squote }}
      key: {{ include "common.tplvalues.render" ( dict "value" $v.secretKeyRef.key "context" $context ) | squote }}
    {{- end }}
{{- end }}
{{- end -}}

{{- define "mock-identity-system.envVars" -}}
{{- include "mock-identity-system.baseEnvVars" (dict "envVars" .Values.envVars "envVarsFrom" .Values.envVarsFrom "context" $) }}
{{- end -}}

{{- define "mock-identity-system.postgresInit.envVars" -}}
{{- include "mock-identity-system.baseEnvVars" (dict "envVars" .Values.postgresInit.envVars "envVarsFrom" .Values.postgresInit.envVarsFrom "context" $) }}
{{- end -}}

{{- define "mock-identity-system.keygen.envVars" -}}
{{- $_ := merge .Values.keygen.envVars (deepCopy .Values.envVars) }}
{{- $_ := merge .Values.keygen.envVarsFrom (deepCopy .Values.envVarsFrom) }}
{{- include "mock-identity-system.baseEnvVars" (dict "envVars" .Values.keygen.envVars "envVarsFrom" .Values.keygen.envVarsFrom "context" $) }}
{{- end -}}

{{/*
Return command
*/}}
{{- define "mock-identity-system.commandBase" -}}
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

{{- define "mock-identity-system.command" -}}
{{- include "mock-identity-system.commandBase" (dict "command" .Values.command "args" .Values.args "startUpCommand" .Values.startUpCommand "context" $) }}
{{- end -}}

{{- define "mock-identity-system.keygen.command" -}}
{{- include "mock-identity-system.commandBase" (dict "command" .Values.keygen.command "args" .Values.keygen.args "startUpCommand" .Values.keygen.startUpCommand "context" $) }}
{{- end -}}
