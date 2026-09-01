[CmdletBinding()]
param(
    [Parameter()]
    [string] $DeploymentName = 'copilot-aks-poc-weu',

    [Parameter()]
    [string] $ResourceGroupName = 'rg-copilot-aks-poc-weu',

    [Parameter()]
    [ValidatePattern('^[^/]+/[^/]+$')]
    [string] $Repository = 'rmoreirao/SelfHostedGHCopilotAgent',

    [Parameter()]
    [switch] $DeleteGitHubApp,

    [Parameter()]
    [switch] $NoWait
)

. (Join-Path $PSScriptRoot 'Common.ps1')

foreach ($command in @('az', 'gh')) {
    Assert-Command $command
}

$root = Get-PocRepositoryRoot
$credentialPath = Join-Path $root '.local\github-app.json'
$outputs = $null
$vaultNames = @()

try {
    $outputs = Get-PocDeploymentOutputs -DeploymentName $DeploymentName
}
catch {
    Write-Verbose "Subscription deployment '$DeploymentName' was not found: $_"
}

if ($outputs) {
    $ResourceGroupName = Get-PocOutputValue $outputs 'resourceGroupName'
    $aksName = Get-PocOutputValue $outputs 'aksName'
    $runnerScaleSetName = Get-PocOutputValue $outputs 'runnerScaleSetName'
    $vaultNames = @(
        Get-PocOutputValue $outputs 'arcKeyVaultName'
        Get-PocOutputValue $outputs 'validationKeyVaultName'
    )

    $aksExists = & az aks show `
        --resource-group $ResourceGroupName `
        --name $aksName `
        --output none `
        --only-show-errors 2>$null
    if ($LASTEXITCODE -eq 0) {
        foreach ($command in @('helm', 'kubectl', 'kubelogin')) {
            Assert-Command $command
        }

        Connect-PocAks -ResourceGroupName $ResourceGroupName -AksName $aksName

        $runnerRelease = & helm status $runnerScaleSetName --namespace arc-runners --output json 2>$null
        if ($LASTEXITCODE -eq 0) {
            Invoke-CheckedCommand helm @(
                'uninstall', $runnerScaleSetName,
                '--namespace', 'arc-runners',
                '--wait',
                '--timeout', '10m'
            )
        }

        $controllerRelease = & helm status arc --namespace arc-systems --output json 2>$null
        if ($LASTEXITCODE -eq 0) {
            Invoke-CheckedCommand helm @(
                'uninstall', 'arc',
                '--namespace', 'arc-systems',
                '--wait',
                '--timeout', '10m'
            )
        }

        & kubectl delete namespace arc-runners arc-systems --ignore-not-found --wait=true 2>$null
        if ($LASTEXITCODE -ne 0) {
            Write-Warning 'Kubernetes namespace cleanup did not complete; resource-group deletion will remove the cluster.'
        }
    }
}

if ($DeleteGitHubApp) {
    if (-not (Test-Path $credentialPath)) {
        throw "Cannot delete the GitHub App because '$credentialPath' is missing."
    }

    $credentials = Get-Content -Raw $credentialPath | ConvertFrom-Json
    if (-not (Test-Path $credentials.privateKeyPath)) {
        throw "Cannot delete the GitHub App because '$($credentials.privateKeyPath)' is missing."
    }

    $jwt = New-GitHubAppJwt `
        -AppId ([string]$credentials.appId) `
        -PrivateKeyPath $credentials.privateKeyPath

    $headers = @{
        Accept = 'application/vnd.github+json'
        Authorization = "Bearer $jwt"
        'X-GitHub-Api-Version' = '2022-11-28'
        'User-Agent' = 'SelfHostedGHCopilotAgent-PoC'
    }
    Invoke-RestMethod `
        -Method Delete `
        -Uri "https://api.github.com/app/installations/$($credentials.installationId)" `
        -Headers $headers
    Invoke-RestMethod `
        -Method Delete `
        -Uri 'https://api.github.com/app' `
        -Headers $headers
    $jwt = $null

    Remove-Item -LiteralPath $credentials.privateKeyPath -Force
    Remove-Item -LiteralPath $credentialPath -Force
}

$groupExists = & az group exists --name $ResourceGroupName
if ($LASTEXITCODE -ne 0) {
    throw 'Unable to determine whether the proof-of-concept resource group exists.'
}

if ($groupExists.Trim() -eq 'true') {
    $deleteArguments = @(
        'group', 'delete',
        '--name', $ResourceGroupName,
        '--yes',
        '--only-show-errors'
    )
    if ($NoWait) {
        $deleteArguments += '--no-wait'
    }
    Invoke-CheckedCommand az $deleteArguments
}

if ($NoWait -and $vaultNames.Count -gt 0) {
    Write-Warning 'Key Vault purge is deferred because -NoWait was used. Rerun cleanup without -NoWait after resource-group deletion completes.'
}
elseif ($vaultNames.Count -gt 0) {
    foreach ($vaultName in $vaultNames) {
        $deletedVault = $null
        for ($attempt = 0; $attempt -lt 24 -and -not $deletedVault; $attempt++) {
            $deletedVaultJson = & az keyvault show-deleted `
                --name $vaultName `
                --output json `
                --only-show-errors 2>$null
            if ($LASTEXITCODE -eq 0) {
                $deletedVault = $deletedVaultJson | ConvertFrom-Json
                break
            }
            Start-Sleep -Seconds 5
        }

        if (-not $deletedVault) {
            throw "Deleted Key Vault '$vaultName' did not become available for purge."
        }

        Invoke-CheckedCommand az @(
            'keyvault', 'purge',
            '--name', $vaultName,
            '--location', $deletedVault.properties.location,
            '--no-wait',
            '--only-show-errors'
        )
    }
}

Write-Host "PoC resources for $Repository were removed."
Write-Host "Re-enable the Copilot integrated firewall in https://github.com/$Repository/settings/copilot/coding_agent before using GitHub-hosted runners."
