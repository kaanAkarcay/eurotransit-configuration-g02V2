{{/*
Expand the name of the chart.
*/}}
{{- define "eurotransit.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Return and validate the deployment strategy for a service that supports both
Canary and Blue/Green. Invalid values fail rendering instead of silently
falling back to a different traffic path.
*/}}
{{- define "eurotransit.deploymentStrategy" -}}
{{- $strategy := index .root.Values.deploymentStrategies .service -}}
{{- if not (has $strategy (list "standard" "canary" "blueGreen")) -}}
{{- fail (printf "deploymentStrategies.%s must be one of: standard, canary, blueGreen (got %q)" .service $strategy) -}}
{{- end -}}
{{- $strategy -}}
{{- end -}}

{{/* Build an immutable digest reference when supplied, otherwise preserve the existing tag behavior. */}}
{{- define "eurotransit.imageReference" -}}
{{- if .digest -}}
{{- printf "%s@%s" .repository .digest -}}
{{- else -}}
{{- printf "%s:%s" .repository .tag -}}
{{- end -}}
{{- end -}}

{{/* Progressive delivery is blocked unless CI has supplied an immutable image digest. */}}
{{- define "eurotransit.requireProgressiveDigest" -}}
{{- $digest := default "" .image.digest -}}
{{- if not (regexMatch "^sha256:[a-f0-9]{64}$" $digest) -}}
{{- fail (printf "%s.image.digest must be an immutable sha256 digest before progressive delivery is enabled" .service) -}}
{{- end -}}
{{- end -}}

{{/*
Create a default fully qualified app name.
We truncate at 63 chars because some Kubernetes name fields are limited to this (by the DNS naming spec).
If release name contains chart name it will be used as a full name.
*/}}
{{- define "eurotransit.fullname" -}}
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
