{{- define "surge-links.labels" -}}
app.kubernetes.io/name: {{ .Chart.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{- define "surge-links.selector" -}}
app.kubernetes.io/name: {{ .Chart.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{- define "surge-links.image" -}}
{{ .Values.image.repository }}:{{ .Values.image.tag | default .Chart.AppVersion }}
{{- end }}

{{- define "surge-links.env" -}}
{{- if .Values.database.existingSecret }}
- name: DATABASE_URL
  valueFrom:
    secretKeyRef:
      name: {{ .Values.database.existingSecret }}
      key: {{ .Values.database.secretKey }}
{{- else }}
- name: DATABASE_URL
  value: {{ required "database.url or database.existingSecret is required" .Values.database.url | quote }}
- name: DB_IAM_AUTH
  value: {{ .Values.database.iamAuth | quote }}
{{- end }}
- name: API_KEY
  valueFrom:
    secretKeyRef:
      name: {{ .Values.apiKey.existingSecret }}
      key: {{ .Values.apiKey.secretKey }}
{{- range $k, $v := .Values.config }}
- name: {{ $k }}
  value: {{ $v | quote }}
{{- end }}
{{- end }}
