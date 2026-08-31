[CmdletBinding()]
param(
    [Parameter()]
    [string] $DeploymentName = 'copilot-aks-poc-weu',

    [Parameter()]
    [ValidatePattern('^[^/]+/[^/]+$')]
    [string] $Repository = 'rmoreirao/SelfHostedGHCopilotAgent',

    [Parameter()]
    [string] $ArcChartVersion = '0.14.2',

    [Parameter()]
    [string] $RunnerImage = 'ghcr.io/actions/actions-runner:2.337.0'
)

. (Join-Path $PSScriptRoot 'Common.ps1')

foreach ($command in @('az', 'helm', 'kubectl', 'kubelogin')) {
    Assert-Command $command
}

$root = Get-PocRepositoryRoot
$outputs = Get-PocDeploymentOutputs -DeploymentName $DeploymentName
$resourceGroupName = Get-PocOutputValue $outputs 'resourceGroupName'
$aksName = Get-PocOutputValue $outputs 'aksName'
$arcKeyVaultName = Get-PocOutputValue $outputs 'arcKeyVaultName'
$validationKeyVaultName = Get-PocOutputValue $outputs 'validationKeyVaultName'
$runnerClientId = Get-PocOutputValue $outputs 'runnerIdentityClientId'
$secretSyncClientId = Get-PocOutputValue $outputs 'secretSyncIdentityClientId'
$tenantId = Get-PocOutputValue $outputs 'tenantId'
$runnerScaleSetName = Get-PocOutputValue $outputs 'runnerScaleSetName'
$maxRunners = Get-PocOutputValue $outputs 'maxRunners'

Connect-PocAks -ResourceGroupName $resourceGroupName -AksName $aksName

function Get-PrivateEndpointIp {
    param(
        [Parameter(Mandatory)]
        [string] $PrivateEndpointName
    )

    $nicId = Invoke-CheckedCommand az @(
        'network', 'private-endpoint', 'show',
        '--resource-group', $resourceGroupName,
        '--name', $PrivateEndpointName,
        '--query', 'networkInterfaces[0].id',
        '--output', 'tsv',
        '--only-show-errors'
    ) -CaptureOutput

    if ([string]::IsNullOrWhiteSpace($nicId)) {
        throw "Private endpoint '$PrivateEndpointName' does not expose a network interface."
    }

    return (Invoke-CheckedCommand az @(
        'network', 'nic', 'show',
        '--ids', $nicId.Trim(),
        '--query', 'ipConfigurations[0].privateIPAddress',
        '--output', 'tsv',
        '--only-show-errors'
    ) -CaptureOutput).Trim()
}

function Render-Template {
    param(
        [Parameter(Mandatory)]
        [string] $InputPath,

        [Parameter(Mandatory)]
        [string] $OutputPath,

        [Parameter(Mandatory)]
        [hashtable] $Replacements
    )

    $content = [IO.File]::ReadAllText($InputPath)
    foreach ($entry in $Replacements.GetEnumerator()) {
        $content = $content.Replace($entry.Key, [string]$entry.Value)
    }

    $unresolved = @(
        [regex]::Matches($content, '__[A-Z0-9_]+__') |
            ForEach-Object Value |
            Select-Object -Unique
    )
    if ($unresolved) {
        throw "Template '$InputPath' contains unresolved values: $($unresolved -join ', ')."
    }

    [IO.File]::WriteAllText($OutputPath, $content, [Text.UTF8Encoding]::new($false))
}

$arcVaultPrivateIp = Get-PrivateEndpointIp -PrivateEndpointName "pe-$arcKeyVaultName"
$validationVaultPrivateIp = Get-PrivateEndpointIp -PrivateEndpointName "pe-$validationKeyVaultName"

$renderedDirectory = Join-Path $root '.local\rendered'
New-Item -ItemType Directory -Path $renderedDirectory -Force | Out-Null

$serviceAccountsPath = Join-Path $renderedDirectory 'service-accounts.yaml'
$secretProviderClassPath = Join-Path $renderedDirectory 'secret-provider-class.yaml'
$networkPoliciesPath = Join-Path $renderedDirectory 'network-policies.yaml'
$runnerValuesPath = Join-Path $renderedDirectory 'runner-values.yaml'

$identityReplacements = @{
    '__RUNNER_CLIENT_ID__' = $runnerClientId
    '__SECRET_SYNC_CLIENT_ID__' = $secretSyncClientId
    '__TENANT_ID__' = $tenantId
}
Render-Template `
    -InputPath (Join-Path $root 'deploy\kubernetes\service-accounts.yaml') `
    -OutputPath $serviceAccountsPath `
    -Replacements $identityReplacements

$secretProviderReplacements = $identityReplacements.Clone()
$secretProviderReplacements['__ARC_KEY_VAULT_NAME__'] = $arcKeyVaultName
Render-Template `
    -InputPath (Join-Path $root 'deploy\kubernetes\secret-provider-class.yaml') `
    -OutputPath $secretProviderClassPath `
    -Replacements $secretProviderReplacements

Render-Template `
    -InputPath (Join-Path $root 'deploy\kubernetes\network-policies.yaml') `
    -OutputPath $networkPoliciesPath `
    -Replacements @{
        '__ARC_KEY_VAULT_PRIVATE_IP__' = $arcVaultPrivateIp
        '__VALIDATION_KEY_VAULT_PRIVATE_IP__' = $validationVaultPrivateIp
    }

Render-Template `
    -InputPath (Join-Path $root 'deploy\arc\runner-values.template.yaml') `
    -OutputPath $runnerValuesPath `
    -Replacements @{
        '__GITHUB_CONFIG_URL__' = "https://github.com/$Repository"
        '__RUNNER_SCALE_SET_NAME__' = $runnerScaleSetName
        '__MAX_RUNNERS__' = $maxRunners
        '__RUNNER_IMAGE__' = $RunnerImage
    }

Invoke-CheckedCommand kubectl @('apply', '-f', (Join-Path $root 'deploy\kubernetes\namespaces.yaml'))
Invoke-CheckedCommand kubectl @('apply', '-f', $serviceAccountsPath)
Invoke-CheckedCommand kubectl @('apply', '-f', $networkPoliciesPath)
Invoke-CheckedCommand kubectl @('apply', '-f', $secretProviderClassPath)

Invoke-CheckedCommand kubectl @(
    'rollout', 'status',
    'deployment/arc-secret-sync',
    '--namespace', 'arc-runners',
    '--timeout', '10m'
)

$secretJson = Invoke-CheckedCommand kubectl @(
    'get', 'secret', 'arc-github-app',
    '--namespace', 'arc-runners',
    '--output', 'json'
) -CaptureOutput
$secret = $secretJson | ConvertFrom-Json
$expectedSecretKeys = @('github_app_id', 'github_app_installation_id', 'github_app_private_key')
$actualSecretKeys = @($secret.data.PSObject.Properties.Name)
foreach ($key in $expectedSecretKeys) {
    if ($key -notin $actualSecretKeys -or [string]::IsNullOrWhiteSpace($secret.data.$key)) {
        throw "Synchronized Kubernetes Secret is missing non-empty key '$key'."
    }
}

$controllerChart = 'oci://ghcr.io/actions/actions-runner-controller-charts/gha-runner-scale-set-controller'
$runnerChart = 'oci://ghcr.io/actions/actions-runner-controller-charts/gha-runner-scale-set'

Invoke-CheckedCommand helm @(
    'upgrade', '--install', 'arc',
    $controllerChart,
    '--namespace', 'arc-systems',
    '--version', $ArcChartVersion,
    '--values', (Join-Path $root 'deploy\arc\controller-values.yaml'),
    '--atomic',
    '--wait',
    '--timeout', '10m'
)

Invoke-CheckedCommand helm @(
    'upgrade', '--install', $runnerScaleSetName,
    $runnerChart,
    '--namespace', 'arc-runners',
    '--version', $ArcChartVersion,
    '--values', $runnerValuesPath,
    '--atomic',
    '--wait',
    '--timeout', '10m'
)

Invoke-CheckedCommand kubectl @(
    'get', 'autoscalingrunnersets.actions.github.com',
    '--namespace', 'arc-runners',
    $runnerScaleSetName
)
Invoke-CheckedCommand kubectl @(
    'wait',
    '--for=condition=Ready',
    'pod',
    '--all-namespaces',
    '--selector', "actions.github.com/scale-set-name=$runnerScaleSetName",
    '--timeout', '5m'
)
Invoke-CheckedCommand kubectl @(
    'get', 'pods',
    '--all-namespaces',
    '--selector', "actions.github.com/scale-set-name=$runnerScaleSetName"
)

Write-Host "ARC runner scale set '$runnerScaleSetName' is registered for $Repository."
