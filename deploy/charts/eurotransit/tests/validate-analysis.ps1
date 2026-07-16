[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$chart = Split-Path -Parent $PSScriptRoot
$digest = 'sha256:' + ('0' * 64)

function Invoke-HelmTemplate {
    param([string[]]$Arguments)

    $output = & helm template eurotransit $chart --namespace eurotransit @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Expected Helm render to succeed:`n$($output -join "`n")"
    }
    return ($output -join "`n")
}

function Assert-Rejected {
    param(
        [string]$Name,
        [string[]]$Arguments,
        [string]$ExpectedPattern
    )

    $output = & helm template eurotransit $chart --namespace eurotransit @Arguments 2>&1
    if ($LASTEXITCODE -eq 0) {
        throw "Invalid scenario '$Name' unexpectedly rendered successfully."
    }
    $text = $output -join "`n"
    if ($text -notmatch $ExpectedPattern) {
        throw "Invalid scenario '$Name' failed for an unexpected reason:`n$text"
    }
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
    'count: 20',
    'failureLimit: 0',
    'setWeight: 10',
    'setWeight: 25',
    'setWeight: 50',
    'setWeight: 100',
    '\[5m\]'
)) {
    if ($catalogRender -notmatch $required) {
        throw "Catalog analysis render is missing expected contract '$required'."
    }
}

$inventoryRender = Invoke-HelmTemplate -Arguments @(
    '--set', 'blueGreen.inventory.enabled=true',
    '--set', "inventory.image.digest=$digest",
    '--set', 'progressiveDelivery.automatedAnalysis.services.inventory.enabled=true'
)
if ($inventoryRender -notmatch 'autoPromotionEnabled: true' -or
    $inventoryRender -notmatch 'prePromotionAnalysis:' -or
    $inventoryRender -notmatch 'postPromotionAnalysis:' -or
    $inventoryRender -notmatch 'scaleDownDelaySeconds: 1200') {
    throw 'Inventory Blue/Green render does not preserve both analyses and the safety delay.'
}

Assert-Rejected 'duration below five minutes' @(
    '--set', 'progressiveDelivery.automatedAnalysis.duration=4m'
) 'duration must be at least 5m'

Assert-Rejected 'duration not divisible by readiness interval' @(
    '--set', 'progressiveDelivery.automatedAnalysis.interval=17s'
) 'exactly divisible'

Assert-Rejected 'weights not increasing' @(
    '--set-json', 'progressiveDelivery.automatedAnalysis.canaryWeights=[10,50,25,100]'
) 'strictly increasing'

Assert-Rejected 'weights do not end at 100' @(
    '--set-json', 'progressiveDelivery.automatedAnalysis.canaryWeights=[10,25,50,90]'
) 'must end at 100'

Assert-Rejected 'frontend analysis unsupported' @(
    '--set', 'progressiveDelivery.automatedAnalysis.services.frontend.enabled=true'
) 'frontend.enabled'

Assert-Rejected 'orders analysis unsupported' @(
    '--set', 'progressiveDelivery.automatedAnalysis.services.orders.enabled=true'
) 'orders.enabled'

Assert-Rejected 'catalog analysis without progressive strategy' @(
    '--set', 'deploymentStrategies.catalog=standard',
    '--set', 'progressiveDelivery.automatedAnalysis.services.catalog.enabled=true'
) 'catalog automated analysis requires'

Assert-Rejected 'inventory analysis without Blue/Green' @(
    '--set', 'progressiveDelivery.automatedAnalysis.services.inventory.enabled=true'
) 'inventory automated analysis requires'

Assert-Rejected 'payments analysis without Blue/Green' @(
    '--set', 'progressiveDelivery.automatedAnalysis.services.payments.enabled=true'
) 'payments automated analysis requires'

Assert-Rejected 'old ReplicaSet delay too short' @(
    '--set', 'progressiveDelivery.blueGreen.scaleDownDelaySeconds=900'
) 'must be greater than analysis duration'

$fixtures = Get-Content (Join-Path $PSScriptRoot 'analysis-result-fixtures.json') -Raw | ConvertFrom-Json
foreach ($fixture in $fixtures) {
    $success = -not $fixture.providerError -and
        $fixture.requestVolume.Count -eq 1 -and $fixture.requestVolume[0] -ge 15 -and
        $fixture.http5xx.Count -eq 1 -and $fixture.http5xx[0] -eq 0 -and
        $fixture.p95Latency.Count -eq 1 -and $fixture.p95Latency[0] -le 0.5 -and
        $fixture.containerRestarts.Count -eq 1 -and $fixture.containerRestarts[0] -eq 0 -and
        $fixture.ready.Count -eq 1 -and $fixture.ready[0] -eq 1

    if ($success -ne $fixture.expectedSuccess) {
        throw "Fixture '$($fixture.name)' produced success=$success, expected=$($fixture.expectedSuccess)."
    }
}

Write-Host "Validated fail-closed analysis rendering, invalid configurations, and $($fixtures.Count) result fixtures."
