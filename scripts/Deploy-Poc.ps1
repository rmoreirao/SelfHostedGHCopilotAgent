[CmdletBinding()]
param(
    [Parameter()]
    [ValidatePattern('^[^/]+/[^/]+$')]
    [string] $Repository = 'rmoreirao/SelfHostedGHCopilotAgent',

    [Parameter()]
    [string] $Location = 'westeurope',

    [Parameter()]
    [string] $ResourceGroupName = 'rg-copilot-aks-poc-weu',

    [Parameter()]
    [string] $DeploymentName = 'copilot-aks-poc-weu',

    [Parameter()]
    [string] $ArcChartVersion = '0.14.2',

    [Parameter()]
    [string] $RunnerImage = 'ghcr.io/actions/actions-runner:2.337.0',

    [Parameter()]
    [switch] $SkipGitHubAppCreation,

    [Parameter()]
    [switch] $SkipArcInstallation
)

. (Join-Path $PSScriptRoot 'Common.ps1')

foreach ($command in @('az', 'gh', 'helm', 'kubectl', 'kubelogin')) {
    Assert-Command $command
}

$root = Get-PocRepositoryRoot
$localStateDirectory = Join-Path $root '.local'
$credentialPath = Join-Path $localStateDirectory 'github-app.json'
$deploymentOutputPath = Join-Path $localStateDirectory 'deployment-outputs.json'

$null = Invoke-CheckedCommand az @('account', 'show', '--output', 'none', '--only-show-errors')
$authenticatedRepository = Invoke-CheckedCommand gh @(
    'repo', 'view', $Repository,
    '--json', 'nameWithOwner',
    '--jq', '.nameWithOwner'
) -CaptureOutput
if ($authenticatedRepository.Trim() -ne $Repository) {
    throw "GitHub CLI resolved '$Repository' as '$($authenticatedRepository.Trim())'."
}

if (-not (Test-Path $credentialPath)) {
    if ($SkipGitHubAppCreation) {
        throw "GitHub App state was not found at '$credentialPath'."
    }

    & (Join-Path $PSScriptRoot 'New-ArcGitHubApp.ps1') -Repository $Repository
    if ($LASTEXITCODE -ne 0) {
        throw 'GitHub App creation failed.'
    }
}

foreach ($provider in @(
    'Microsoft.Authorization',
    'Microsoft.ContainerService',
    'Microsoft.Insights',
    'Microsoft.KeyVault',
    'Microsoft.ManagedIdentity',
    'Microsoft.Network',
    'Microsoft.OperationsManagement',
    'Microsoft.OperationalInsights'
)) {
    $state = Invoke-CheckedCommand az @(
        'provider', 'show',
        '--namespace', $provider,
        '--query', 'registrationState',
        '--output', 'tsv',
        '--only-show-errors'
    ) -CaptureOutput
    if ($state.Trim() -ne 'Registered') {
        Invoke-CheckedCommand az @(
            'provider', 'register',
            '--namespace', $provider,
            '--wait',
            '--only-show-errors'
        )
    }
}

Invoke-CheckedCommand az @(
    'bicep', 'build',
    '--file', (Join-Path $root 'infra\main.bicep'),
    '--stdout'
) | Out-Null

Invoke-CheckedCommand az @(
    'deployment', 'sub', 'validate',
    '--name', "$DeploymentName-validate",
    '--location', $Location,
    '--template-file', (Join-Path $root 'infra\main.bicep'),
    '--parameters', (Join-Path $root 'infra\main.bicepparam'),
    '--parameters',
    "resourceGroupName=$ResourceGroupName",
    "githubRepository=$Repository",
    '--output', 'none',
    '--only-show-errors'
)

Invoke-CheckedCommand az @(
    'deployment', 'sub', 'create',
    '--name', $DeploymentName,
    '--location', $Location,
    '--template-file', (Join-Path $root 'infra\main.bicep'),
    '--parameters', (Join-Path $root 'infra\main.bicepparam'),
    '--parameters',
    "resourceGroupName=$ResourceGroupName",
    "githubRepository=$Repository",
    '--output', 'none',
    '--only-show-errors'
)

$outputs = Get-PocDeploymentOutputs -DeploymentName $DeploymentName
New-Item -ItemType Directory -Path $localStateDirectory -Force | Out-Null
[IO.File]::WriteAllText(
    $deploymentOutputPath,
    ($outputs | ConvertTo-Json -Depth 10),
    [Text.UTF8Encoding]::new($false)
)

$credentials = Get-Content -Raw $credentialPath | ConvertFrom-Json
foreach ($propertyName in @('appId', 'installationId', 'privateKeyPath', 'repository')) {
    if ([string]::IsNullOrWhiteSpace([string]$credentials.$propertyName)) {
        throw "GitHub App state is missing '$propertyName'."
    }
}
if ($credentials.repository -ne $Repository) {
    throw "GitHub App state belongs to '$($credentials.repository)', not '$Repository'."
}
if (-not (Test-Path $credentials.privateKeyPath)) {
    throw "GitHub App private key '$($credentials.privateKeyPath)' does not exist."
}

$arcKeyVaultName = Get-PocOutputValue $outputs 'arcKeyVaultName'
$arcSecretParametersPath = Join-Path $localStateDirectory 'arc-secrets.parameters.json'
$arcSecretParameters = [ordered]@{
    '$schema' = 'https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#'
    contentVersion = '1.0.0.0'
    parameters = [ordered]@{
        arcKeyVaultName = @{ value = $arcKeyVaultName }
        githubAppId = @{ value = [string]$credentials.appId }
        githubAppInstallationId = @{ value = [string]$credentials.installationId }
        githubAppPrivateKey = @{ value = [IO.File]::ReadAllText($credentials.privateKeyPath) }
    }
}

try {
    [IO.File]::WriteAllText(
        $arcSecretParametersPath,
        ($arcSecretParameters | ConvertTo-Json -Depth 10),
        [Text.UTF8Encoding]::new($false)
    )
    Set-PrivateFilePermissions -Path $arcSecretParametersPath

    Invoke-CheckedCommand az @(
        'deployment', 'group', 'create',
        '--resource-group', $ResourceGroupName,
        '--name', 'arc-github-app-secrets',
        '--template-file', (Join-Path $root 'infra\modules\arc-secrets.bicep'),
        '--parameters', "@$arcSecretParametersPath",
        '--output', 'none',
        '--only-show-errors'
    )
}
finally {
    if (Test-Path $arcSecretParametersPath) {
        Remove-Item -LiteralPath $arcSecretParametersPath -Force
    }
    $arcSecretParameters = $null
}

if (-not $SkipArcInstallation) {
    & (Join-Path $PSScriptRoot 'Install-Arc.ps1') `
        -DeploymentName $DeploymentName `
        -Repository $Repository `
        -ArcChartVersion $ArcChartVersion `
        -RunnerImage $RunnerImage
    if ($LASTEXITCODE -ne 0) {
        throw 'ARC installation failed.'
    }
}

Write-Host "Azure infrastructure and ARC deployment completed for $Repository."
Write-Host "Non-secret deployment outputs: $deploymentOutputPath"
