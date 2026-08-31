[CmdletBinding()]
param(
    [Parameter()]
    [string] $DeploymentName = 'copilot-aks-poc-weu',

    [Parameter()]
    [ValidatePattern('^[^/]+/[^/]+$')]
    [string] $Repository = 'rmoreirao/SelfHostedGHCopilotAgent',

    [Parameter()]
    [switch] $RequireCopilotFirewallDisabled,

    [Parameter()]
    [switch] $SkipArc
)

. (Join-Path $PSScriptRoot 'Common.ps1')

foreach ($command in @('az', 'gh', 'helm', 'kubectl', 'kubelogin')) {
    Assert-Command $command
}

function Assert-Condition {
    param(
        [Parameter(Mandatory)]
        [bool] $Condition,

        [Parameter(Mandatory)]
        [string] $Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

$outputs = Get-PocDeploymentOutputs -DeploymentName $DeploymentName
$resourceGroupName = Get-PocOutputValue $outputs 'resourceGroupName'
$aksName = Get-PocOutputValue $outputs 'aksName'
$arcKeyVaultName = Get-PocOutputValue $outputs 'arcKeyVaultName'
$validationKeyVaultName = Get-PocOutputValue $outputs 'validationKeyVaultName'
$runnerScaleSetName = Get-PocOutputValue $outputs 'runnerScaleSetName'
$maxRunners = [int](Get-PocOutputValue $outputs 'maxRunners')
$firewallPublicIp = Get-PocOutputValue $outputs 'firewallPublicIp'

$aks = (
    Invoke-CheckedCommand az @(
        'aks', 'show',
        '--resource-group', $resourceGroupName,
        '--name', $aksName,
        '--output', 'json',
        '--only-show-errors'
    ) -CaptureOutput
) | ConvertFrom-Json

Assert-Condition ($aks.disableLocalAccounts -eq $true) 'AKS local accounts are not disabled.'
Assert-Condition ($aks.aadProfile.managed -eq $true) 'AKS Microsoft Entra integration is not enabled.'
Assert-Condition ($aks.aadProfile.enableAzureRbac -eq $true) 'AKS Azure RBAC is not enabled.'
Assert-Condition ($aks.oidcIssuerProfile.enabled -eq $true) 'AKS OIDC issuer is not enabled.'
Assert-Condition ($aks.securityProfile.workloadIdentity.enabled -eq $true) 'AKS Workload Identity is not enabled.'
Assert-Condition ($aks.networkProfile.networkDataplane -eq 'cilium') 'AKS is not using the Cilium data plane.'
Assert-Condition ($aks.networkProfile.networkPolicy -eq 'cilium') 'AKS is not using Cilium network policy.'
Assert-Condition ($aks.networkProfile.outboundType -eq 'userDefinedRouting') 'AKS is not using UDR egress.'

$nodePools = @(
    (
        Invoke-CheckedCommand az @(
            'aks', 'nodepool', 'list',
            '--resource-group', $resourceGroupName,
            '--cluster-name', $aksName,
            '--output', 'json',
            '--only-show-errors'
        ) -CaptureOutput
    ) | ConvertFrom-Json
)
$systemPool = $nodePools | Where-Object name -eq 'system'
$runnerPool = $nodePools | Where-Object name -eq 'runners'
Assert-Condition ($null -ne $systemPool) "AKS system node pool is missing."
Assert-Condition ($null -ne $runnerPool) "AKS runner node pool is missing."
Assert-Condition ($runnerPool.minCount -eq 0) 'Runner node pool does not scale to zero.'
Assert-Condition ($runnerPool.maxCount -eq $maxRunners) 'Runner node pool maximum differs from maxRunners.'
Assert-Condition ('workload=arc-runner:NoSchedule' -in @($runnerPool.nodeTaints)) 'Runner node pool taint is missing.'

foreach ($vaultName in @($arcKeyVaultName, $validationKeyVaultName)) {
    $vault = (
        Invoke-CheckedCommand az @(
            'keyvault', 'show',
            '--resource-group', $resourceGroupName,
            '--name', $vaultName,
            '--output', 'json',
            '--only-show-errors'
        ) -CaptureOutput
    ) | ConvertFrom-Json
    Assert-Condition ($vault.properties.publicNetworkAccess -eq 'Disabled') "Key Vault '$vaultName' has public access."
    Assert-Condition ($vault.properties.enableRbacAuthorization -eq $true) "Key Vault '$vaultName' is not using Azure RBAC."

    $privateEndpoint = (
        Invoke-CheckedCommand az @(
            'network', 'private-endpoint', 'show',
            '--resource-group', $resourceGroupName,
            '--name', "pe-$vaultName",
            '--output', 'json',
            '--only-show-errors'
        ) -CaptureOutput
    ) | ConvertFrom-Json
    $connectionStates = @(
        $privateEndpoint.privateLinkServiceConnections |
            ForEach-Object { $_.privateLinkServiceConnectionState.status }
    )
    Assert-Condition ('Approved' -in $connectionStates) "Private endpoint for '$vaultName' is not approved."
}

$firewall = (
    Invoke-CheckedCommand az @(
        'network', 'firewall', 'show',
        '--resource-group', $resourceGroupName,
        '--name', $aksName.Replace('aks-', 'afw-'),
        '--output', 'json',
        '--only-show-errors'
    ) -CaptureOutput
) | ConvertFrom-Json
Assert-Condition ($firewall.provisioningState -eq 'Succeeded') 'Azure Firewall is not provisioned.'
Assert-Condition (
    -not [string]::IsNullOrWhiteSpace(
        [string]$firewall.ipConfigurations[0].publicIpAddress.id
    )
) 'Azure Firewall lacks its public IP reference.'

$resolvedFirewallPublicIp = Invoke-CheckedCommand az @(
    'network', 'public-ip', 'show',
    '--ids', $firewall.ipConfigurations[0].publicIpAddress.id,
    '--query', 'ipAddress',
    '--output', 'tsv',
    '--only-show-errors'
) -CaptureOutput
Assert-Condition ($resolvedFirewallPublicIp.Trim() -eq $firewallPublicIp) 'Firewall public IP differs from deployment output.'

$route = (
    Invoke-CheckedCommand az @(
        'network', 'route-table', 'route', 'show',
        '--resource-group', $resourceGroupName,
        '--route-table-name', $aksName.Replace('aks-', 'rt-'),
        '--name', 'default-via-firewall',
        '--output', 'json',
        '--only-show-errors'
    ) -CaptureOutput
) | ConvertFrom-Json
Assert-Condition ($route.addressPrefix -eq '0.0.0.0/0') 'AKS default route is missing.'
Assert-Condition ($route.nextHopType -eq 'VirtualAppliance') 'AKS default route does not use Azure Firewall.'
Assert-Condition ($route.nextHopIpAddress -eq $firewall.ipConfigurations[0].privateIpAddress) 'AKS route next hop is not the firewall.'

if ($SkipArc) {
    Write-Host 'Azure infrastructure validation passed; ARC checks were skipped.'
    return
}

Connect-PocAks -ResourceGroupName $resourceGroupName -AksName $aksName

foreach ($serviceAccountName in @('arc-secret-sync', 'arc-runner')) {
    $serviceAccount = (
        Invoke-CheckedCommand kubectl @(
            'get', 'serviceaccount', $serviceAccountName,
            '--namespace', 'arc-runners',
            '--output', 'json'
        ) -CaptureOutput
    ) | ConvertFrom-Json
    Assert-Condition ($serviceAccount.automountServiceAccountToken -eq $false) "Service account '$serviceAccountName' mounts API tokens."
    Assert-Condition (
        -not [string]::IsNullOrWhiteSpace(
            [string]$serviceAccount.metadata.annotations.'azure.workload.identity/client-id'
        )
    ) "Service account '$serviceAccountName' lacks Workload Identity."
}

$secret = (
    Invoke-CheckedCommand kubectl @(
        'get', 'secret', 'arc-github-app',
        '--namespace', 'arc-runners',
        '--output', 'json'
    ) -CaptureOutput
) | ConvertFrom-Json
$secretKeys = @($secret.data.PSObject.Properties.Name)
foreach ($key in @('github_app_id', 'github_app_installation_id', 'github_app_private_key')) {
    Assert-Condition ($key -in $secretKeys) "ARC credential Secret lacks '$key'."
}

$controllerStatus = Invoke-CheckedCommand helm @(
    'status', 'arc',
    '--namespace', 'arc-systems',
    '--output', 'json'
) -CaptureOutput | ConvertFrom-Json
Assert-Condition ($controllerStatus.info.status -eq 'deployed') 'ARC controller Helm release is not deployed.'

$runnerStatus = Invoke-CheckedCommand helm @(
    'status', $runnerScaleSetName,
    '--namespace', 'arc-runners',
    '--output', 'json'
) -CaptureOutput | ConvertFrom-Json
Assert-Condition ($runnerStatus.info.status -eq 'deployed') 'ARC runner scale-set Helm release is not deployed.'

$runnerSet = (
    Invoke-CheckedCommand kubectl @(
        'get', 'autoscalingrunnerset.actions.github.com', $runnerScaleSetName,
        '--namespace', 'arc-runners',
        '--output', 'json'
    ) -CaptureOutput
) | ConvertFrom-Json
Assert-Condition ($runnerSet.metadata.name -eq $runnerScaleSetName) 'ARC AutoscalingRunnerSet is missing.'

$listenerPods = (
    Invoke-CheckedCommand kubectl @(
        'get', 'pods',
        '--all-namespaces',
        '--selector', "actions.github.com/scale-set-name=$runnerScaleSetName",
        '--output', 'json'
    ) -CaptureOutput
) | ConvertFrom-Json
$readyListener = @($listenerPods.items) | Where-Object {
    $_.metadata.name -match 'listener' -and
    $_.status.phase -eq 'Running' -and
    'True' -in @($_.status.conditions | Where-Object type -eq 'Ready' | ForEach-Object status)
}
Assert-Condition ($null -ne $readyListener) 'ARC listener pod is not Ready.'

$copilotConfiguration = (
    Invoke-CheckedCommand gh @(
        'api',
        '-H', 'X-GitHub-Api-Version: 2026-03-10',
        "repos/$Repository/copilot/cloud-agent/configuration"
    ) -CaptureOutput
) | ConvertFrom-Json
if ($RequireCopilotFirewallDisabled) {
    Assert-Condition ($copilotConfiguration.is_firewall_enabled -eq $false) 'GitHub Copilot integrated firewall is still enabled.'
}

Write-Host 'Infrastructure validation passed.'
