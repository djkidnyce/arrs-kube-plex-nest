{{/*
Common labels applied to every resource.
*/}}
{{- define "akpn.labels" -}}
app.kubernetes.io/part-of: arrs-kube-plex-nest
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
{{- end }}

{{/*
Standard LSIO environment variables pulled from the global ConfigMap.
*/}}
{{- define "akpn.globalEnv" -}}
- name: PUID
  valueFrom:
    configMapKeyRef:
      name: media-env
      key: PUID
- name: PGID
  valueFrom:
    configMapKeyRef:
      name: media-env
      key: PGID
- name: TZ
  valueFrom:
    configMapKeyRef:
      name: media-env
      key: TZ
{{- end }}

{{/*
Pod-level security defaults. LSIO images start as root (s6 init) then drop
to PUID/PGID, so runAsNonRoot cannot be set pod-wide for those pods.
*/}}
{{- define "akpn.podSecurityContext" -}}
securityContext:
  seccompProfile:
    type: RuntimeDefault
  fsGroup: 1000
{{- end }}

{{/*
Container security for LSIO images: drop everything except the capabilities
the s6 init needs to chown /config and setuid to PUID/PGID.
*/}}
{{- define "akpn.lsioContainerSecurity" -}}
securityContext:
  allowPrivilegeEscalation: false
  capabilities:
    drop: ["ALL"]
    add: ["CHOWN", "DAC_OVERRIDE", "FOWNER", "FSETID", "KILL", "SETGID", "SETUID", "SETPCAP", "NET_BIND_SERVICE"]
{{- end }}

{{/*
Container security for fully unprivileged sidecars/init containers.
*/}}
{{- define "akpn.restrictedContainerSecurity" -}}
securityContext:
  allowPrivilegeEscalation: false
  runAsNonRoot: true
  runAsUser: 1000
  runAsGroup: 1000
  readOnlyRootFilesystem: true
  capabilities:
    drop: ["ALL"]
{{- end }}

{{/*
Standard media + config volumeMounts used by *arr services.
*/}}
{{- define "akpn.mediaVolumeMounts" -}}
- name: config
  mountPath: /config
- name: media
  mountPath: /mnt/media
{{- end }}

{{/*
Standard volumes block for a service that uses a config PVC + shared media PVC.
  {{ include "akpn.mediaVolumes" (dict "configClaim" "sonarr-config") }}
*/}}
{{- define "akpn.mediaVolumes" -}}
- name: config
  persistentVolumeClaim:
    claimName: {{ .configClaim }}
- name: media
  persistentVolumeClaim:
    claimName: media-pvc
{{- end }}

{{/*
Standard liveness / readiness probes for *arr HTTP services.
  {{ include "akpn.httpProbes" (dict "port" 8989 "path" "/ping") }}
*/}}
{{- define "akpn.httpProbes" -}}
startupProbe:
  httpGet:
    path: {{ .path }}
    port: {{ .port }}
  failureThreshold: 30
  periodSeconds: 10
livenessProbe:
  httpGet:
    path: {{ .path }}
    port: {{ .port }}
  initialDelaySeconds: 30
  periodSeconds: 30
  timeoutSeconds: 5
  failureThreshold: 3
readinessProbe:
  httpGet:
    path: {{ .path }}
    port: {{ .port }}
  initialDelaySeconds: 15
  periodSeconds: 10
{{- end }}

{{/*
Resolve a Service type from the expose settings.
  {{ include "akpn.serviceType" (dict "svc" "sonarr" "root" $) }}
*/}}
{{- define "akpn.serviceType" -}}
{{- $e := .root.Values.expose -}}
{{- $types := dict "nodePort" "NodePort" "loadBalancer" "LoadBalancer" "clusterIP" "ClusterIP" -}}
{{- if index $e .svc -}}
{{- default "ClusterIP" (index $types $e.mode) -}}
{{- else -}}
ClusterIP
{{- end -}}
{{- end }}


