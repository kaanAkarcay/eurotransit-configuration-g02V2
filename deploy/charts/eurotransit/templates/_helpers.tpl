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

{{/* Convert a simple Argo duration (s/m/h) into seconds for metric count. */}}
{{- define "eurotransit.durationSeconds" -}}
{{- $value := toString . -}}
{{- if hasSuffix "s" $value -}}
{{- trimSuffix "s" $value | atoi -}}
{{- else if hasSuffix "m" $value -}}
{{- mul (trimSuffix "m" $value | atoi) 60 -}}
{{- else if hasSuffix "h" $value -}}
{{- mul (trimSuffix "h" $value | atoi) 3600 -}}
{{- else -}}
{{- fail (printf "analysis duration %q must end in s, m, or h" $value) -}}
{{- end -}}
{{- end -}}

{{/* Number of measurements needed to cover the configured duration. */}}
{{- define "eurotransit.analysisCount" -}}
{{- $duration := include "eurotransit.durationSeconds" .duration | atoi -}}
{{- $interval := include "eurotransit.durationSeconds" .interval | atoi -}}
{{- if le $interval 0 -}}
{{- fail "progressiveDelivery.automatedAnalysis.interval must be greater than zero" -}}
{{- end -}}
{{- max 1 (div (add $duration (sub $interval 1)) $interval) -}}
{{- end -}}

{{/* Frontend automation remains blocked until per-track HTTP telemetry exists. */}}
{{- define "eurotransit.analysisSupported" -}}
{{- if eq .service "frontend" -}}
false
{{- else -}}
true
{{- end -}}
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
