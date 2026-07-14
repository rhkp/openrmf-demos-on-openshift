{{- define "openrmf-office.name" -}}
{{- include "openrmf.lib.appName" . }}
{{- end }}

{{- define "openrmf-office.fullname" -}}
{{- include "openrmf.lib.fullname" . }}
{{- end }}

{{- define "openrmf-office.labels" -}}
{{- include "openrmf.lib.labels" . }}
{{- end }}

{{- define "openrmf-office.selectorLabels" -}}
{{- include "openrmf.lib.selectorLabels" . }}
{{- end }}

{{- define "openrmf-office.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default "rmf-demo" .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}
