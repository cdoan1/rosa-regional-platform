{{/*
=======================
HyperFleet API Helpers
=======================
*/}}
{{- define "hyperfleet-api.name" -}}
hyperfleet-api
{{- end }}

{{- define "hyperfleet-api.fullname" -}}
hyperfleet-api
{{- end }}

{{- define "hyperfleet-api.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "hyperfleet-api.labels" -}}
helm.sh/chart: {{ include "hyperfleet-api.chart" . }}
{{ include "hyperfleet-api.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{- define "hyperfleet-api.selectorLabels" -}}
app.kubernetes.io/name: {{ include "hyperfleet-api.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/component: api
{{- end }}

{{- define "hyperfleet-api.serviceAccountName" -}}
{{- if .Values.hyperfleetApi.serviceAccount.create }}
{{- default (include "hyperfleet-api.fullname" .) .Values.hyperfleetApi.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.hyperfleetApi.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
=======================
Sentinel Helpers
=======================
*/}}
{{- define "sentinel.name" -}}
hyperfleet-sentinel
{{- end }}

{{- define "sentinel.fullname" -}}
hyperfleet-sentinel
{{- end }}

{{- define "sentinel.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "sentinel.labels" -}}
helm.sh/chart: {{ include "sentinel.chart" . }}
{{ include "sentinel.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{- define "sentinel.selectorLabels" -}}
app.kubernetes.io/name: {{ include "sentinel.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/component: sentinel
{{- end }}

{{- define "sentinel.serviceAccountName" -}}
{{- if .Values.hyperfleetSentinel.serviceAccount.create }}
{{- default (include "sentinel.fullname" .) .Values.hyperfleetSentinel.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.hyperfleetSentinel.serviceAccount.name }}
{{- end }}
{{- end }}

{{- define "sentinel.secretName" -}}
{{ include "sentinel.fullname" . }}-broker-credentials
{{- end }}

{{/*
=======================
Adapter Helpers
=======================
*/}}
{{- define "hyperfleet-adapter.name" -}}
hyperfleet-adapter
{{- end }}

{{- define "hyperfleet-adapter.fullname" -}}
hyperfleet-adapter
{{- end }}

{{- define "hyperfleet-adapter.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "hyperfleet-adapter.labels" -}}
helm.sh/chart: {{ include "hyperfleet-adapter.chart" . }}
{{ include "hyperfleet-adapter.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{- define "hyperfleet-adapter.selectorLabels" -}}
app.kubernetes.io/name: {{ include "hyperfleet-adapter.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/component: adapter
{{- end }}

{{- define "hyperfleet-adapter.serviceAccountName" -}}
{{- if .Values.hyperfleetAdapter.serviceAccount.create }}
{{- default (include "hyperfleet-adapter.fullname" .) .Values.hyperfleetAdapter.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.hyperfleetAdapter.serviceAccount.name }}
{{- end }}
{{- end }}

{{- define "hyperfleet-adapter.adapterConfigMapName" -}}
{{ include "hyperfleet-adapter.fullname" . }}-config
{{- end }}

{{- define "hyperfleet-adapter.adapterTaskConfigMapName" -}}
{{ include "hyperfleet-adapter.fullname" . }}-task-config
{{- end }}

{{- define "hyperfleet-adapter.brokerConfigMapName" -}}
{{ include "hyperfleet-adapter.fullname" . }}-broker-config
{{- end }}

{{- define "hyperfleet-adapter.brokerType" -}}
{{- if .Values.hyperfleetAdapter.broker.type }}
{{- .Values.hyperfleetAdapter.broker.type }}
{{- end }}
{{- end }}
