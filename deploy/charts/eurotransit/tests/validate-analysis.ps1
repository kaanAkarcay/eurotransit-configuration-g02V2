[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$chart = Split-Path -Parent $PSScriptRoot
$digest = 'sha256:' + ('0' * 64)

function Invoke-HelmTemplate {
    param([string[]]$Arguments)

    $command = "helm template eurotransit `"$chart`" --namespace eurotransit $($Arguments -join ' ')"
    $output = & helm template eurotransit $chart --namespace eurotransit @Arguments 2>&1
    $exitCode = $LASTEXITCODE
    $global:LASTEXITCODE = 0
    if ($exitCode -ne 0) {
        throw "Expected Helm render to succeed.`nCommand: $command`nOutput:`n$($output -join "`n")"
    }
    return ($output -join "`n")
}

function Assert-Rejected {
    param(
        [string]$Name,
        [string[]]$Arguments,
        [ValidateSet('Schema', 'Template')]
        [string]$ExpectedSource,
        [string]$ExpectedPattern
    )

    $command = "helm template eurotransit `"$chart`" --namespace eurotransit $($Arguments -join ' ')"
    $output = & helm template eurotransit $chart --namespace eurotransit @Arguments 2>&1
    $exitCode = $LASTEXITCODE
    # Expected native-command failures must not leak into pwsh's process exit
    # code after every assertion has passed (the original Linux CI failure).
    $global:LASTEXITCODE = 0
    $text = $output -join "`n"

    if ($exitCode -eq 0) {
        throw "Invalid scenario '$Name' unexpectedly rendered successfully.`nCommand: $command`nOutput:`n$text"
    }

    $sourcePattern = if ($ExpectedSource -eq 'Schema') {
        'values don''t meet the specifications of the schema|values\.schema\.json|Must validate'
    } else {
        'execution error at .*templates/(analysis-templates\.yaml|_helpers\.tpl)'
    }
    if ($text -notmatch $sourcePattern) {
        throw "Invalid scenario '$Name' failed outside the expected $ExpectedSource validation layer.`nCommand: $command`nOutput:`n$text"
    }
    if ($text -notmatch $ExpectedPattern) {
        throw "Invalid scenario '$Name' failed for an unexpected semantic reason.`nCommand: $command`nExpected: $ExpectedPattern`nOutput:`n$text"
    }

    Write-Host "Rejected '$Name' in the expected $ExpectedSource layer."
}

$catalogRender = Invoke-HelmTemplate -Arguments @(
    '--set', 'deploymentStrategies.catalog=canary',
    '--set', "catalog.image.digest=$digest",
    '--set', 'progressiveDelivery.automatedAnalysis.services.catalog.enabled=true'
)

if ($catalogRender -match 'vector\s*\(\s*sum\s*\(') {
    throw 'Rendered PromQL still contains the invalid vector(sum(...)) shape.'
}
foreach ($required in @(
    'kind: AnalysisTemplate',
    'name: candidate-request-volume',
    'initialDelay: 5m',
    'name: candidate-p95-latency',
    'name: candidate-http-5xx',
    'initialDelay: 30s',
    'interval: 15s',
    'count: 19',
    'failureLimit: 0',
    'setWeight: 10',
    'setWeight: 25',
    'setWeight: 50',
    'setWeight: 100',
    '\[5m\]',
    '\[1m\]',
    'progressDeadlineSeconds: 2100',
    'progressDeadlineAbort: true',
    'rollbackWindow:\s+revisions: 2'
)) {
    if ($catalogRender -notmatch $required) {
        throw "Catalog analysis render is missing expected contract '$required'."
    }
}
if ($catalogRender -match 'candidate-http-5xx[\s\S]*?initialDelay: 5m' -or
    $catalogRender -match 'candidate-container-restarts[\s\S]*?initialDelay: 5m') {
    throw 'Critical safety metrics still wait for the complete five-minute window.'
}

$inventoryRender = Invoke-HelmTemplate -Arguments @(
    '--set', 'blueGreen.inventory.enabled=true',
    '--set', "inventory.image.digest=$digest",
    '--set', 'progressiveDelivery.automatedAnalysis.services.inventory.enabled=true'
)
if ($inventoryRender -notmatch 'autoPromotionEnabled: true' -or
    $inventoryRender -notmatch 'prePromotionAnalysis:' -or
    $inventoryRender -notmatch 'postPromotionAnalysis:' -or
    $inventoryRender -notmatch 'scaleDownDelaySeconds: 1200' -or
    $inventoryRender -notmatch 'progressDeadlineSeconds: 2100' -or
    $inventoryRender -notmatch 'progressDeadlineAbort: true' -or
    $inventoryRender -notmatch 'rollbackWindow:\s+revisions: 2') {
    throw 'Inventory Blue/Green render does not preserve promotion, analysis, deadline, rollback-window, and retention contracts.'
}

Assert-Rejected 'duration below five minutes' @(
    '--set', 'progressiveDelivery.automatedAnalysis.duration=4m'
) 'Template' 'duration must be at least 5m'

Assert-Rejected 'duration not divisible by readiness interval' @(
    '--set', 'progressiveDelivery.automatedAnalysis.interval=17s'
) 'Template' 'duration must be exactly divisible by interval'

Assert-Rejected 'safety warm-up not aligned to interval' @(
    '--set', 'progressiveDelivery.automatedAnalysis.safetyWarmup=31s'
) 'Template' 'duration minus safetyWarmup must be exactly divisible by interval'

Assert-Rejected 'weights not increasing' @(
    '--set-json', 'progressiveDelivery.automatedAnalysis.canaryWeights=[10,50,25,100]'
) 'Template' 'canaryWeights must be strictly increasing'

Assert-Rejected 'weights do not end at 100' @(
    '--set-json', 'progressiveDelivery.automatedAnalysis.canaryWeights=[10,25,50,90]'
) 'Template' 'canaryWeights must end at 100'

Assert-Rejected 'frontend analysis unsupported' @(
    '--set', 'progressiveDelivery.automatedAnalysis.services.frontend.enabled=true'
) 'Schema' 'progressiveDelivery\.automatedAnalysis\.services\.frontend\.enabled'

Assert-Rejected 'orders analysis unsupported' @(
    '--set', 'progressiveDelivery.automatedAnalysis.services.orders.enabled=true'
) 'Schema' 'progressiveDelivery\.automatedAnalysis\.services\.orders\.enabled'

Assert-Rejected 'catalog analysis without progressive strategy' @(
    '--set', 'deploymentStrategies.catalog=standard',
    '--set', 'progressiveDelivery.automatedAnalysis.services.catalog.enabled=true'
) 'Template' 'catalog automated analysis requires'

Assert-Rejected 'inventory analysis without Blue/Green' @(
    '--set', 'progressiveDelivery.automatedAnalysis.services.inventory.enabled=true'
) 'Template' 'inventory automated analysis requires'

Assert-Rejected 'payments analysis without Blue/Green' @(
    '--set', 'progressiveDelivery.automatedAnalysis.services.payments.enabled=true'
) 'Template' 'payments automated analysis requires'

Assert-Rejected 'progress deadline below automated strategy budget' @(
    '--set', 'progressiveDelivery.progressDeadlineSeconds=1800'
) 'Template' 'must be at least longest automated analysis \(1200\) \+ minReadySeconds \+ progressDeadlineSafetyMarginSeconds = 1820 seconds'

Assert-Rejected 'old ReplicaSet delay too short' @(
    '--set', 'progressiveDelivery.blueGreen.scaleDownDelaySeconds=900'
) 'Template' 'must be greater than analysis duration plus postPromotionSafetyMarginSeconds'

$fixtures = Get-Content (Join-Path $PSScriptRoot 'analysis-result-fixtures.json') -Raw | ConvertFrom-Json
foreach ($fixture in $fixtures) {
    $allHttpSamplesHealthy = $fixture.http5xx.Count -gt 0 -and
        @($fixture.http5xx | Where-Object { $_ -ne 0 }).Count -eq 0
    $allRestartSamplesHealthy = $fixture.containerRestarts.Count -gt 0 -and
        @($fixture.containerRestarts | Where-Object { $_ -ne 0 }).Count -eq 0
    $allReadinessSamplesHealthy = $fixture.ready.Count -gt 0 -and
        @($fixture.ready | Where-Object { $_ -ne 1 }).Count -eq 0
    $success = -not $fixture.providerError -and
        $fixture.requestVolume.Count -eq 1 -and $fixture.requestVolume[0] -ge 15 -and
        $allHttpSamplesHealthy -and
        $fixture.p95Latency.Count -eq 1 -and $fixture.p95Latency[0] -le 0.5 -and
        $allRestartSamplesHealthy -and
        $allReadinessSamplesHealthy

    if ($success -ne $fixture.expectedSuccess) {
        throw "Fixture '$($fixture.name)' produced success=$success, expected=$($fixture.expectedSuccess)."
    }
}

Write-Host "Validated fail-closed analysis rendering, invalid configurations, and $($fixtures.Count) result fixtures."
$global:LASTEXITCODE = 0
exit 0
