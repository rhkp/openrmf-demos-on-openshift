{{- define "openrmf.lib.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{- define "openrmf.lib.appName" -}}
{{- .Values.app.name | default .Chart.Name | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "openrmf.lib.labels" -}}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version | replace "+" "_" }}
app.kubernetes.io/name: {{ include "openrmf.lib.appName" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/part-of: openrmf-demos-on-openshift
app.kubernetes.io/managed-by: {{ .Release.Service }}
rmf.openrobotics.org/demo: {{ .Values.demo.name }}
{{- end }}

{{- define "openrmf.lib.selectorLabels" -}}
app.kubernetes.io/name: {{ include "openrmf.lib.appName" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{- define "openrmf.lib.rmfWeb.urls" -}}
{{- $clusterDomain := required "rmfWeb.routes.clusterDomain is required when rmfWeb.enabled" .Values.rmfWeb.routes.clusterDomain }}
{{- $apiHost := default (printf "%s-api-%s" (include "openrmf.lib.fullname" .) .Values.namespace.name) .Values.rmfWeb.routes.apiHost }}
{{- $trajHost := default (printf "%s-traj-%s" (include "openrmf.lib.fullname" .) .Values.namespace.name) .Values.rmfWeb.routes.trajectoryHost }}
{{- $dashHost := default (printf "%s-dashboard-%s" (include "openrmf.lib.fullname" .) .Values.namespace.name) .Values.rmfWeb.routes.dashboardHost }}
{{- $apiUrl := printf "https://%s.%s" $apiHost $clusterDomain }}
{{- $trajUrl := printf "wss://%s.%s" $trajHost $clusterDomain }}
{{- $dashUrl := printf "https://%s.%s" $dashHost $clusterDomain }}
{{- dict "clusterDomain" $clusterDomain "apiHost" $apiHost "trajHost" $trajHost "dashHost" $dashHost "apiUrl" $apiUrl "trajUrl" $trajUrl "dashUrl" $dashUrl | toJson }}
{{- end }}

{{- define "openrmf.lib.novnc.urls" -}}
{{- $clusterDomain := required "novnc.routes.clusterDomain is required when novnc.enabled" .Values.novnc.routes.clusterDomain }}
{{- $novncHost := default (printf "%s-novnc-%s" (include "openrmf.lib.fullname" .) .Values.namespace.name) .Values.novnc.routes.novncHost }}
{{- $novncUrl := printf "https://%s.%s" $novncHost $clusterDomain }}
{{- dict "clusterDomain" $clusterDomain "novncHost" $novncHost "novncUrl" $novncUrl | toJson }}
{{- end }}

{{- define "openrmf.lib.dashboardRouteAnnotations" -}}
openrmf.openrobotics.org/dashboard-url: {{ .dashUrl | quote }}
openrmf.openrobotics.org/api-url: {{ .apiUrl | quote }}
openrmf.openrobotics.org/trajectory-url: {{ .trajUrl | quote }}
{{- end }}
