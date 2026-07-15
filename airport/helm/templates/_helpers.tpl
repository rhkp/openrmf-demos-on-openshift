{{- define "openrmf-airport.name" -}}
{{- include "openrmf.lib.appName" . }}
{{- end }}

{{- define "openrmf-airport.fullname" -}}
{{- include "openrmf.lib.fullname" . }}
{{- end }}

{{- define "openrmf-airport.labels" -}}
{{- include "openrmf.lib.labels" . }}
{{- end }}

{{- define "openrmf-airport.selectorLabels" -}}
{{- include "openrmf.lib.selectorLabels" . }}
{{- end }}

{{- define "openrmf-airport.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default "rmf-demo" .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}
