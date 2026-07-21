{{/*
Zenoh Router — container spec
*/}}
{{- define "openrmf.lib.zenohRouter.containers" -}}
{{- $root := index . 0 }}
- name: zenoh-router
  image: {{ $root.Values.zenoh.image | quote }}
  imagePullPolicy: {{ $root.Values.zenoh.pullPolicy }}
  ports:
    - containerPort: {{ $root.Values.zenoh.port }}
      name: zenoh-tcp
  securityContext:
    allowPrivilegeEscalation: false
    runAsNonRoot: true
    capabilities:
      drop: ["ALL"]
  volumeMounts:
    - name: zenoh-router-config
      mountPath: /etc/zenoh
      readOnly: true
  resources:
    {{- toYaml $root.Values.zenoh.resources | nindent 4 }}
{{- end }}

{{/*
Zenoh Router — volumes needed by the container
*/}}
{{- define "openrmf.lib.zenohRouter.volumes" -}}
{{- $root := index . 0 }}
- name: zenoh-router-config
  configMap:
    name: {{ include "openrmf.lib.fullname" $root }}-zenoh-config
{{- end }}

{{/*
Zenoh Router — ConfigMap with router config (IPv4, no multicast scouting)
*/}}
{{- define "openrmf.lib.zenohRouter.configmap" -}}
{{- $root := index . 0 }}
apiVersion: v1
kind: ConfigMap
metadata:
  name: {{ include "openrmf.lib.fullname" $root }}-zenoh-config
  namespace: {{ $root.Values.namespace.name }}
  labels:
    {{- include "openrmf.lib.labels" $root | nindent 4 }}
data:
  router-config.json5: |
    {
      mode: "router",
      listen: {
        endpoints: [{{ printf "\"tcp/0.0.0.0:%v\"" $root.Values.zenoh.port }}]
      },
      scouting: {
        multicast: {
          enabled: false
        }
      }
    }
{{- end }}

{{/*
Zenoh Router — standalone Deployment (for multi-pod architecture)
*/}}
{{- define "openrmf.lib.zenohRouter.deployment" -}}
{{- $root := index . 0 }}
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ include "openrmf.lib.fullname" $root }}-zenoh-router
  namespace: {{ $root.Values.namespace.name }}
  labels:
    {{- include "openrmf.lib.labels" $root | nindent 4 }}
    app.kubernetes.io/component: zenoh-router
spec:
  replicas: 1
  selector:
    matchLabels:
      {{- include "openrmf.lib.selectorLabels" $root | nindent 6 }}
      app.kubernetes.io/component: zenoh-router
  template:
    metadata:
      labels:
        {{- include "openrmf.lib.selectorLabels" $root | nindent 8 }}
        app.kubernetes.io/component: zenoh-router
    spec:
      serviceAccountName: {{ default "rmf-demo" $root.Values.serviceAccount.name }}
      restartPolicy: Always
      securityContext:
        seccompProfile:
          type: RuntimeDefault
      volumes:
        {{- include "openrmf.lib.zenohRouter.volumes" (list $root) | nindent 8 }}
      containers:
        {{- include "openrmf.lib.zenohRouter.containers" (list $root) | nindent 8 }}
{{- end }}

{{/*
Zenoh Router — ClusterIP Service (for multi-pod architecture)
*/}}
{{- define "openrmf.lib.zenohRouter.service" -}}
{{- $root := index . 0 }}
apiVersion: v1
kind: Service
metadata:
  name: {{ include "openrmf.lib.fullname" $root }}-zenoh-router
  namespace: {{ $root.Values.namespace.name }}
  labels:
    {{- include "openrmf.lib.labels" $root | nindent 4 }}
spec:
  selector:
    {{- include "openrmf.lib.selectorLabels" $root | nindent 4 }}
    app.kubernetes.io/component: zenoh-router
  ports:
    - name: zenoh-tcp
      port: {{ $root.Values.zenoh.port }}
      targetPort: {{ $root.Values.zenoh.port }}
{{- end }}
