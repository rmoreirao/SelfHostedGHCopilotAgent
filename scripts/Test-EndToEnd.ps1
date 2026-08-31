[CmdletBinding()]
param(
    [Parameter()]
    [string] $DeploymentName = 'copilot-aks-poc-weu',

    [Parameter()]
    [ValidatePattern('^[^/]+/[^/]+$')]
    [string] $Repository = 'rmoreirao/SelfHostedGHCopilotAgent',

    [Parameter()]
    [ValidateRange(10, 60)]
    [int] $TimeoutMinutes = 35
)

. (Join-Path $PSScriptRoot 'Common.ps1')

foreach ($command in @('gh', 'kubectl')) {
    Assert-Command $command
}

function Wait-Until {
    param(
        [Parameter(Mandatory)]
        [scriptblock] $Condition,

        [Parameter(Mandatory)]
        [DateTimeOffset] $Deadline,

        [Parameter(Mandatory)]
        [string] $FailureMessage,

        [Parameter()]
        [int] $IntervalSeconds = 10
    )

    while ([DateTimeOffset]::UtcNow -lt $Deadline) {
        $value = & $Condition
        if ($value) {
            return $value
        }
        Start-Sleep -Seconds $IntervalSeconds
    }

    throw $FailureMessage
}

function Get-RunnerPods {
    param(
        [Parameter(Mandatory)]
        [string] $ScaleSetName
    )

    $json = Invoke-CheckedCommand kubectl @(
        'get', 'pods',
        '--namespace', 'arc-runners',
        '--selector', 'app.kubernetes.io/name=copilot-aks-runner',
        '--output', 'json'
    ) -CaptureOutput
    return @(($json | ConvertFrom-Json).items)
}

$root = Get-PocRepositoryRoot
$outputs = Get-PocDeploymentOutputs -DeploymentName $DeploymentName
$runnerScaleSetName = Get-PocOutputValue $outputs 'runnerScaleSetName'
$deadline = [DateTimeOffset]::UtcNow.AddMinutes($TimeoutMinutes)

$copilotConfiguration = (
    Invoke-CheckedCommand gh @(
        'api',
        '-H', 'X-GitHub-Api-Version: 2026-03-10',
        "repos/$Repository/copilot/cloud-agent/configuration"
    ) -CaptureOutput
) | ConvertFrom-Json
if ($copilotConfiguration.is_firewall_enabled -ne $false) {
    throw 'GitHub Copilot integrated firewall must be disabled before self-hosted runner validation.'
}

$existingRuns = @(
    (
        Invoke-CheckedCommand gh @(
            'run', 'list',
            '--repo', $Repository,
            '--workflow', 'arc-smoke-test.yml',
            '--limit', '20',
            '--json', 'databaseId'
        ) -CaptureOutput
    ) | ConvertFrom-Json | ForEach-Object databaseId
)

Invoke-CheckedCommand gh @(
    'workflow', 'run', 'arc-smoke-test.yml',
    '--repo', $Repository,
    '--ref', 'main'
)

$smokeRun = Wait-Until -Deadline $deadline -FailureMessage 'The smoke workflow run did not appear.' -Condition {
    $runs = @(
        (
            Invoke-CheckedCommand gh @(
                'run', 'list',
                '--repo', $Repository,
                '--workflow', 'arc-smoke-test.yml',
                '--limit', '20',
                '--json', 'databaseId,status,conclusion,url,createdAt'
            ) -CaptureOutput
        ) | ConvertFrom-Json
    )
    return $runs |
        Where-Object { $_.databaseId -notin $existingRuns } |
        Sort-Object createdAt -Descending |
        Select-Object -First 1
}

$smokeRunnerObserved = $false
do {
    if ((Get-RunnerPods -ScaleSetName $runnerScaleSetName).Count -gt 0) {
        $smokeRunnerObserved = $true
    }

    $smokeRun = (
        Invoke-CheckedCommand gh @(
            'run', 'view', [string]$smokeRun.databaseId,
            '--repo', $Repository,
            '--json', 'databaseId,status,conclusion,url,createdAt'
        ) -CaptureOutput
    ) | ConvertFrom-Json
    if ($smokeRun.status -eq 'completed') {
        break
    }
    if ([DateTimeOffset]::UtcNow -ge $deadline) {
        throw 'The smoke workflow did not complete before the timeout.'
    }
    Start-Sleep -Seconds 10
} while ($true)

if ($smokeRun.conclusion -ne 'success') {
    Invoke-CheckedCommand gh @(
        'run', 'view', [string]$smokeRun.databaseId,
        '--repo', $Repository,
        '--log-failed'
    )
    throw "Smoke workflow concluded '$($smokeRun.conclusion)'."
}
if (-not $smokeRunnerObserved) {
    throw 'No ephemeral ARC runner pod was observed for the smoke workflow.'
}

$smokeLogs = Invoke-CheckedCommand gh @(
    'run', 'view', [string]$smokeRun.databaseId,
    '--repo', $Repository,
    '--log'
) -CaptureOutput
foreach ($marker in @('EPHEMERAL_RUNNER_VALIDATED=', 'PRIVATE_ACCESS_VALIDATED=', 'EGRESS_BLOCKED=example.com')) {
    if (-not $smokeLogs.Contains($marker)) {
        throw "Smoke workflow logs lack '$marker'."
    }
}

$null = Wait-Until -Deadline ([DateTimeOffset]::UtcNow.AddMinutes(5)) `
    -FailureMessage 'The smoke runner pod was not deleted.' `
    -Condition { (Get-RunnerPods -ScaleSetName $runnerScaleSetName).Count -eq 0 }

$existingTaskIds = @(
    (
        Invoke-AgentTaskCommand @(
            'list',
            '--limit', '50',
            '--json', 'id'
        ) -CaptureOutput
    ) | ConvertFrom-Json | ForEach-Object id
)

$taskDescription = @'
Create a file named validation/copilot-aks-proof.txt containing exactly these two lines:
copilot-runner=aks
private-access=validated
Do not modify any other file. Open a pull request and leave it open.
'@
Invoke-AgentTaskCommand @(
    'create',
    $taskDescription,
    '--repo', $Repository,
    '--base', 'main'
)

$agentTask = Wait-Until -Deadline $deadline -FailureMessage 'The Copilot agent task did not appear.' -Condition {
    $tasks = @(
        (
            Invoke-AgentTaskCommand @(
                'list',
                '--limit', '50',
                '--json', 'id,state,repository,createdAt,pullRequestNumber,pullRequestUrl'
            ) -CaptureOutput
        ) | ConvertFrom-Json
    )
    return $tasks |
        Where-Object {
            $_.id -notin $existingTaskIds -and
            ([string]$_.repository).Contains($Repository)
        } |
        Sort-Object createdAt -Descending |
        Select-Object -First 1
}

$agentRunnerObserved = $false
do {
    if ((Get-RunnerPods -ScaleSetName $runnerScaleSetName).Count -gt 0) {
        $agentRunnerObserved = $true
    }

    $agentTask = (
        Invoke-AgentTaskCommand @(
            'view', [string]$agentTask.id,
            '--repo', $Repository,
            '--json', 'id,state,pullRequestNumber,pullRequestState,pullRequestUrl,completedAt'
        ) -CaptureOutput
    ) | ConvertFrom-Json
    if ($agentTask.state -in @('completed', 'failed', 'cancelled')) {
        break
    }
    if ([DateTimeOffset]::UtcNow -ge $deadline) {
        throw 'The Copilot agent task did not complete before the timeout.'
    }
    Start-Sleep -Seconds 15
} while ($true)

if ($agentTask.state -ne 'completed') {
    throw "Copilot agent task concluded '$($agentTask.state)'."
}
if (-not $agentRunnerObserved) {
    throw 'No ephemeral ARC runner pod was observed for the Copilot task.'
}
if (-not $agentTask.pullRequestNumber -or $agentTask.pullRequestState -ne 'OPEN') {
    throw 'Copilot did not leave an open validation pull request.'
}

$agentLogs = Invoke-AgentTaskCommand @(
    'view', [string]$agentTask.id,
    '--repo', $Repository,
    '--log'
) -CaptureOutput
foreach ($marker in @('COPILOT_SETUP_RUNNER=', 'PRIVATE_ACCESS_VALIDATED=')) {
    if (-not $agentLogs.Contains($marker)) {
        throw "Copilot task logs lack '$marker'."
    }
}

$changedFiles = @(
    Invoke-CheckedCommand gh @(
        'pr', 'diff', [string]$agentTask.pullRequestNumber,
        '--repo', $Repository,
        '--name-only'
    ) -CaptureOutput -split '\r?\n' |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
)
if ($changedFiles.Count -ne 1 -or $changedFiles[0] -ne 'validation/copilot-aks-proof.txt') {
    throw "Validation pull request changed unexpected files: $($changedFiles -join ', ')."
}

$null = Wait-Until -Deadline ([DateTimeOffset]::UtcNow.AddMinutes(5)) `
    -FailureMessage 'The Copilot task runner pod was not deleted.' `
    -Condition { (Get-RunnerPods -ScaleSetName $runnerScaleSetName).Count -eq 0 }

$evidence = [ordered]@{
    validatedAt = [DateTimeOffset]::UtcNow.ToString('O')
    repository = $Repository
    runnerScaleSet = $runnerScaleSetName
    smokeRunId = $smokeRun.databaseId
    smokeRunUrl = $smokeRun.url
    copilotSessionId = $agentTask.id
    copilotPullRequestNumber = $agentTask.pullRequestNumber
    copilotPullRequestUrl = $agentTask.pullRequestUrl
    ephemeralSmokeRunnerObserved = $smokeRunnerObserved
    ephemeralCopilotRunnerObserved = $agentRunnerObserved
}
$evidencePath = Join-Path $root '.local\evidence.json'
[IO.File]::WriteAllText(
    $evidencePath,
    ($evidence | ConvertTo-Json),
    [Text.UTF8Encoding]::new($false)
)

Write-Host "End-to-end validation passed. Evidence: $evidencePath"
Write-Host "Copilot proof pull request: $($agentTask.pullRequestUrl)"
