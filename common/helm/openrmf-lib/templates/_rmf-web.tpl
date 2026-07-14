{{- define "openrmf.lib.rmfWeb.volumes" -}}
{{- $root := index . 0 }}
- name: dashboard-www
  emptyDir: {}
- name: api-server-run
  emptyDir: {}
- name: dashboard-nginx-config
  configMap:
    name: {{ include "openrmf.lib.fullname" $root }}-dashboard-nginx
- name: api-server-config
  configMap:
    name: {{ include "openrmf.lib.fullname" $root }}-api-config
{{- end }}

{{- define "openrmf.lib.rmfWeb.initContainers" -}}
{{- $root := index . 0 }}
{{- $urls := include "openrmf.lib.rmfWeb.urls" $root | fromJson }}
- name: dashboard-init
  image: {{ $root.Values.rmfWeb.dashboard.image | quote }}
  imagePullPolicy: {{ $root.Values.rmfWeb.dashboard.pullPolicy }}
  command: ["/bin/sh", "/scripts/dashboard-init.sh"]
  env:
    - name: RMF_SERVER_URL
      value: {{ $urls.apiUrl | quote }}
    - name: TRAJECTORY_SERVER_URL
      value: {{ $urls.trajUrl | quote }}
  volumeMounts:
    - name: dashboard-www
      mountPath: /dashboard
    - name: dashboard-init-scripts
      mountPath: /scripts
      readOnly: true
{{- end }}

{{- define "openrmf.lib.rmfWeb.initVolumes" -}}
{{- $root := index . 0 }}
- name: dashboard-init-scripts
  configMap:
    name: {{ include "openrmf.lib.fullname" $root }}-dashboard-init
    defaultMode: 0755
{{- end }}

{{- define "openrmf.lib.rmfWeb.containers" -}}
{{- $root := index . 0 }}
{{- $urls := include "openrmf.lib.rmfWeb.urls" $root | fromJson }}
- name: rmf-api-server
  image: {{ $root.Values.rmfWeb.apiServer.image | quote }}
  imagePullPolicy: {{ $root.Values.rmfWeb.apiServer.pullPolicy }}
  command: ["/bin/bash", "-c"]
  args:
    - |
      set -eo pipefail
      source /opt/ros/jazzy/setup.bash
      exec rmf_api_server
  workingDir: /ws
  env:
    - name: ROS_LOCALHOST_ONLY
      value: "1"
    - name: RMW_IMPLEMENTATION
      value: {{ $root.Values.rmfWeb.apiServer.rmwImplementation | quote }}
    - name: HOME
      value: /tmp
    - name: ROS_LOG_DIR
      value: /tmp/.ros/log
    - name: RMF_API_SERVER_CONFIG
      value: /ws/openshift_config.py
  ports:
    - containerPort: 8000
      name: api-http
    - containerPort: 8006
      name: trajectory
  securityContext:
    allowPrivilegeEscalation: false
    runAsNonRoot: true
    capabilities:
      drop: ["ALL"]
  volumeMounts:
    - name: api-server-run
      mountPath: /ws/run
    - name: api-server-config
      mountPath: /ws/openshift_config.py
      subPath: openshift_config.py
  resources:
    {{- toYaml $root.Values.rmfWeb.apiServer.resources | nindent 4 }}
- name: rmf-dashboard
  image: {{ $root.Values.rmfWeb.dashboard.nginxImage | quote }}
  imagePullPolicy: {{ $root.Values.rmfWeb.dashboard.pullPolicy }}
  ports:
    - containerPort: 8080
      name: dash-http
  securityContext:
    allowPrivilegeEscalation: false
    runAsNonRoot: true
    capabilities:
      drop: ["ALL"]
  volumeMounts:
    - name: dashboard-www
      mountPath: /usr/share/nginx/html
      readOnly: true
    - name: dashboard-nginx-config
      mountPath: /etc/nginx/conf.d/default.conf
      subPath: default.conf
  resources:
    {{- toYaml $root.Values.rmfWeb.dashboard.resources | nindent 4 }}
{{- end }}

{{- define "openrmf.lib.rmfWeb.configmaps" -}}
{{- $root := index . 0 }}
{{- $urls := include "openrmf.lib.rmfWeb.urls" $root | fromJson }}
apiVersion: v1
kind: ConfigMap
metadata:
  name: {{ include "openrmf.lib.fullname" $root }}-api-config
  namespace: {{ $root.Values.namespace.name }}
  labels:
    {{- include "openrmf.lib.labels" $root | nindent 4 }}
data:
  openshift_config.py: |
    config = {
        "host": "0.0.0.0",
        "port": 8000,
        "db_url": "sqlite:///ws/run/db.sqlite3",
        "public_url": {{ $urls.apiUrl | quote }},
        "cache_directory": "/ws/run/cache",
        "log_level": "INFO",
        "builtin_admin": "admin",
        "jwt_public_key": None,
        "jwt_secret": "rmfisawesome",
        "oidc_url": None,
        "aud": "rmf_api_server",
        "iss": "stub",
        "ros_args": ["-p", "use_sim_time:=true"],
        "timezone": "UTC",
    }
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: {{ include "openrmf.lib.fullname" $root }}-dashboard-nginx
  namespace: {{ $root.Values.namespace.name }}
  labels:
    {{- include "openrmf.lib.labels" $root | nindent 4 }}
data:
  default.conf: |
{{ $root.Files.Get "charts/openrmf-lib/files/dashboard-nginx.conf" | indent 4 }}
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: {{ include "openrmf.lib.fullname" $root }}-dashboard-init
  namespace: {{ $root.Values.namespace.name }}
  labels:
    {{- include "openrmf.lib.labels" $root | nindent 4 }}
data:
  dashboard-init.sh: |
{{ $root.Files.Get "charts/openrmf-lib/files/dashboard-init.sh" | indent 4 }}
{{- end }}

{{- define "openrmf.lib.rmfWeb.manifests" -}}
{{- $root := index . 0 }}
{{- $urls := include "openrmf.lib.rmfWeb.urls" $root | fromJson }}
apiVersion: v1
kind: Service
metadata:
  name: {{ include "openrmf.lib.fullname" $root }}-api
  namespace: {{ $root.Values.namespace.name }}
  labels:
    {{- include "openrmf.lib.labels" $root | nindent 4 }}
spec:
  selector:
    {{- include "openrmf.lib.selectorLabels" $root | nindent 4 }}
  ports:
    - name: http
      port: 80
      targetPort: 8000
---
apiVersion: v1
kind: Service
metadata:
  name: {{ include "openrmf.lib.fullname" $root }}-trajectory
  namespace: {{ $root.Values.namespace.name }}
  labels:
    {{- include "openrmf.lib.labels" $root | nindent 4 }}
spec:
  selector:
    {{- include "openrmf.lib.selectorLabels" $root | nindent 4 }}
  ports:
    - name: ws
      port: 80
      targetPort: 8006
---
apiVersion: v1
kind: Service
metadata:
  name: {{ include "openrmf.lib.fullname" $root }}-dashboard
  namespace: {{ $root.Values.namespace.name }}
  labels:
    {{- include "openrmf.lib.labels" $root | nindent 4 }}
spec:
  selector:
    {{- include "openrmf.lib.selectorLabels" $root | nindent 4 }}
  ports:
    - name: http
      port: 80
      targetPort: 8080
---
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: {{ include "openrmf.lib.fullname" $root }}-api
  namespace: {{ $root.Values.namespace.name }}
  labels:
    {{- include "openrmf.lib.labels" $root | nindent 4 }}
spec:
  host: {{ $urls.apiHost }}.{{ $urls.clusterDomain }}
  to:
    kind: Service
    name: {{ include "openrmf.lib.fullname" $root }}-api
  port:
    targetPort: http
  tls:
    termination: edge
  wildcardPolicy: None
---
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: {{ include "openrmf.lib.fullname" $root }}-trajectory
  namespace: {{ $root.Values.namespace.name }}
  labels:
    {{- include "openrmf.lib.labels" $root | nindent 4 }}
spec:
  host: {{ $urls.trajHost }}.{{ $urls.clusterDomain }}
  to:
    kind: Service
    name: {{ include "openrmf.lib.fullname" $root }}-trajectory
  port:
    targetPort: ws
  tls:
    termination: edge
  wildcardPolicy: None
---
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: {{ include "openrmf.lib.fullname" $root }}-dashboard
  namespace: {{ $root.Values.namespace.name }}
  labels:
    {{- include "openrmf.lib.labels" $root | nindent 4 }}
  annotations:
    {{- include "openrmf.lib.dashboardRouteAnnotations" (dict "apiUrl" $urls.apiUrl "trajUrl" $urls.trajUrl "dashUrl" $urls.dashUrl) | nindent 4 }}
spec:
  host: {{ $urls.dashHost }}.{{ $urls.clusterDomain }}
  to:
    kind: Service
    name: {{ include "openrmf.lib.fullname" $root }}-dashboard
  port:
    targetPort: http
  tls:
    termination: edge
  wildcardPolicy: None
{{- end }}
