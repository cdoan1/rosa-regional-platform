{{/*
Expand the name of the chart.
*/}}
{{- define "hyperfleet-system.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
*/}}
{{- define "hyperfleet-system.fullname" -}}
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

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "hyperfleet-system.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "hyperfleet-system.labels" -}}
helm.sh/chart: {{ include "hyperfleet-system.chart" . }}
{{ include "hyperfleet-system.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "hyperfleet-system.selectorLabels" -}}
app.kubernetes.io/name: {{ include "hyperfleet-system.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Create the name of the service account to use
*/}}
{{- define "hyperfleet-system.serviceAccountName" -}}
{{- if .Values.hyperfleetSystem.serviceAccount.create }}
{{- default "hyperfleet-sa" .Values.hyperfleetSystem.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.hyperfleetSystem.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
Generate a random password
*/}}
{{- define "hyperfleet-system.randomPassword" -}}
{{- randAlphaNum 32 }}
{{- end }}

{{/*
PostgreSQL connection string
*/}}
{{- define "hyperfleet-system.postgresql.connectionString" -}}
postgresql://{{ .Values.hyperfleetSystem.postgresql.database.username }}:$(DB_PASSWORD)@{{ .Values.hyperfleetSystem.api.database.host }}:{{ .Values.hyperfleetSystem.api.database.port }}/{{ .Values.hyperfleetSystem.postgresql.database.name }}?sslmode={{ .Values.hyperfleetSystem.api.database.sslMode }}
{{- end }}

{{/*
RabbitMQ AMQP URL
*/}}
{{- define "hyperfleet-system.rabbitmq.amqpUrl" -}}
amqp://$(RABBITMQ_USER):$(RABBITMQ_PASSWORD)@{{ .Values.hyperfleetSystem.sentinel.broker.rabbitmq.host }}:{{ .Values.hyperfleetSystem.sentinel.broker.rabbitmq.port }}/hyperfleet
{{- end }}
