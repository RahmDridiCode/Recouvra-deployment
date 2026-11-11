{{- define "recouvra.labels" -}}
app.kubernetes.io/part-of: recouvra
{{- end }}

{{- define "recouvra.image" -}}
{{ .repository }}:{{ .tag }}
{{- end }}
