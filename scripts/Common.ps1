Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-PocRepositoryRoot {
    return (Split-Path -Parent $PSScriptRoot)
}

function Assert-Command {
    param(
        [Parameter(Mandatory)]
        [string] $Name
    )

    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "Required command '$Name' was not found in PATH."
    }
}

function Invoke-CheckedCommand {
    param(
        [Parameter(Mandatory)]
        [string] $FilePath,

        [Parameter()]
        [string[]] $ArgumentList = @(),

        [Parameter()]
        [switch] $CaptureOutput
    )

    if ($CaptureOutput) {
        $output = & $FilePath @ArgumentList 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw "$FilePath failed with exit code $LASTEXITCODE.`n$($output -join [Environment]::NewLine)"
        }

        return ($output -join [Environment]::NewLine)
    }

    & $FilePath @ArgumentList
    if ($LASTEXITCODE -ne 0) {
        throw "$FilePath failed with exit code $LASTEXITCODE."
    }
}

function Invoke-AgentTaskCommand {
    param(
        [Parameter()]
        [string[]] $ArgumentList = @(),

        [Parameter()]
        [switch] $CaptureOutput
    )

    $hadEnvironmentToken = Test-Path Env:GH_TOKEN
    $environmentToken = $env:GH_TOKEN
    try {
        Remove-Item Env:GH_TOKEN -ErrorAction SilentlyContinue
        return Invoke-CheckedCommand gh (@('agent-task') + $ArgumentList) -CaptureOutput:$CaptureOutput
    }
    finally {
        if ($hadEnvironmentToken) {
            $env:GH_TOKEN = $environmentToken
        }
    }
}

function ConvertTo-Base64Url {
    param(
        [Parameter(Mandatory)]
        [byte[]] $Bytes
    )

    return [Convert]::ToBase64String($Bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_')
}

function New-GitHubAppJwt {
    param(
        [Parameter(Mandatory)]
        [string] $AppId,

        [Parameter(Mandatory)]
        [string] $PrivateKeyPath
    )

    $now = [DateTimeOffset]::UtcNow
    $header = '{"alg":"RS256","typ":"JWT"}'
    $payload = @{
        iat = $now.AddSeconds(-60).ToUnixTimeSeconds()
        exp = $now.AddMinutes(9).ToUnixTimeSeconds()
        iss = $AppId
    } | ConvertTo-Json -Compress
    $unsignedToken = '{0}.{1}' -f @(
        (ConvertTo-Base64Url ([Text.Encoding]::UTF8.GetBytes($header))),
        (ConvertTo-Base64Url ([Text.Encoding]::UTF8.GetBytes($payload)))
    )

    $rsa = [Security.Cryptography.RSA]::Create()
    try {
        $rsa.ImportFromPem([IO.File]::ReadAllText($PrivateKeyPath))
        $signature = $rsa.SignData(
            [Text.Encoding]::UTF8.GetBytes($unsignedToken),
            [Security.Cryptography.HashAlgorithmName]::SHA256,
            [Security.Cryptography.RSASignaturePadding]::Pkcs1
        )
    }
    finally {
        $rsa.Dispose()
    }

    return "$unsignedToken.$(ConvertTo-Base64Url $signature)"
}

function Get-PocDeploymentOutputs {
    param(
        [Parameter(Mandatory)]
        [string] $DeploymentName
    )

    $json = Invoke-CheckedCommand az @(
        'deployment', 'sub', 'show',
        '--name', $DeploymentName,
        '--query', 'properties.outputs',
        '--output', 'json',
        '--only-show-errors'
    ) -CaptureOutput

    return ($json | ConvertFrom-Json -AsHashtable)
}

function Get-PocOutputValue {
    param(
        [Parameter(Mandatory)]
        [hashtable] $Outputs,

        [Parameter(Mandatory)]
        [string] $Name
    )

    if (-not $Outputs.ContainsKey($Name) -or $null -eq $Outputs[$Name].value) {
        throw "Deployment output '$Name' is missing."
    }

    return $Outputs[$Name].value
}

function Connect-PocAks {
    param(
        [Parameter(Mandatory)]
        [string] $ResourceGroupName,

        [Parameter(Mandatory)]
        [string] $AksName
    )

    Invoke-CheckedCommand az @(
        'aks', 'get-credentials',
        '--resource-group', $ResourceGroupName,
        '--name', $AksName,
        '--overwrite-existing',
        '--only-show-errors'
    )
    Invoke-CheckedCommand kubelogin @('convert-kubeconfig', '-l', 'azurecli')
}

function Set-PrivateFilePermissions {
    param(
        [Parameter(Mandatory)]
        [string] $Path
    )

    if ($IsWindows) {
        Invoke-CheckedCommand icacls @(
            $Path,
            '/inheritance:r',
            '/grant:r',
            "$([System.Security.Principal.WindowsIdentity]::GetCurrent().Name):(R,W)"
        )
    }
    else {
        Invoke-CheckedCommand chmod @('600', $Path)
    }
}
