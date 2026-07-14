{{- define "openrmf.lib.novnc.containers" -}}
{{- $root := index . 0 }}
- name: novnc
  image: {{ $root.Values.novnc.image | quote }}
  imagePullPolicy: {{ $root.Values.novnc.pullPolicy }}
  args:
    - "--web"
    - "/opt/novnc"
    - {{ $root.Values.novnc.webPort | quote }}
    - {{ printf "127.0.0.1:%v" $root.Values.novnc.vncPort | quote }}
  ports:
    - containerPort: {{ $root.Values.novnc.webPort }}
      name: novnc-ws
  securityContext:
    allowPrivilegeEscalation: false
    runAsNonRoot: true
    capabilities:
      drop: ["ALL"]
  resources:
    {{- toYaml $root.Values.novnc.resources | nindent 4 }}
{{- end }}

{{- define "openrmf.lib.novnc.manifests" -}}
{{- $root := index . 0 }}
{{- $urls := include "openrmf.lib.novnc.urls" $root | fromJson }}
apiVersion: v1
kind: Service
metadata:
  name: {{ include "openrmf.lib.fullname" $root }}-novnc
  namespace: {{ $root.Values.namespace.name }}
  labels:
    {{- include "openrmf.lib.labels" $root | nindent 4 }}
spec:
  selector:
    {{- include "openrmf.lib.selectorLabels" $root | nindent 4 }}
  ports:
    - name: http
      port: 80
      targetPort: {{ $root.Values.novnc.webPort }}
{{- if not (eq $root.Values.novnc.routes.enabled false) }}
---
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: {{ include "openrmf.lib.fullname" $root }}-novnc
  namespace: {{ $root.Values.namespace.name }}
  labels:
    {{- include "openrmf.lib.labels" $root | nindent 4 }}
  annotations:
    openrmf.openrobotics.org/novnc-url: {{ $urls.novncUrl | quote }}
spec:
  host: {{ $urls.novncHost }}.{{ $urls.clusterDomain }}
  to:
    kind: Service
    name: {{ include "openrmf.lib.fullname" $root }}-novnc
  port:
    targetPort: http
  tls:
    termination: edge
  wildcardPolicy: None
{{- end }}
{{- end }}
