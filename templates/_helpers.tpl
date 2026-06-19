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
Usage: pass the PVC claim name as the first argument via dict.
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
Expects .port and .path to be passed via dict.
  {{ include "akpn.httpProbes" (dict "port" 8989 "path" "/ping") }}
*/}}
{{- define "akpn.httpProbes" -}}
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

