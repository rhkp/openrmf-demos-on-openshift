{{- define "openrmf-hotel.name" -}}
{{- include "openrmf.lib.appName" . }}
{{- end }}

{{- define "openrmf-hotel.fullname" -}}
{{- include "openrmf.lib.fullname" . }}
{{- end }}

{{- define "openrmf-hotel.labels" -}}
{{- include "openrmf.lib.labels" . }}
{{- end }}

{{- define "openrmf-hotel.selectorLabels" -}}
{{- include "openrmf.lib.selectorLabels" . }}
{{- end }}

{{- define "openrmf-hotel.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default "rmf-demo" .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}
