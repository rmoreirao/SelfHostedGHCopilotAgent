[CmdletBinding()]
param(
    [Parameter()]
    [ValidatePattern('^[^/]+/[^/]+$')]
    [string] $Repository = 'rmoreirao/SelfHostedGHCopilotAgent',

    [Parameter()]
    [string] $AppName = 'ARC Copilot AKS PoC',

    [Parameter()]
    [ValidateRange(1024, 65535)]
    [int] $CallbackPort = 53682,

    [Parameter()]
    [ValidateRange(60, 1800)]
    [int] $TimeoutSeconds = 600,

    [Parameter()]
    [string] $ExistingAppSlug,

    [Parameter()]
    [long] $InstallationId,

    [Parameter()]
    [switch] $Force
)

. (Join-Path $PSScriptRoot 'Common.ps1')

Assert-Command gh

$root = Get-PocRepositoryRoot
$localStateDirectory = Join-Path $root '.local'
$privateKeyPath = Join-Path $localStateDirectory 'github-app.pem'
$credentialPath = Join-Path $localStateDirectory 'github-app.json'

if ((Test-Path $credentialPath) -and -not $Force) {
    throw "GitHub App state already exists at '$credentialPath'. Use -Force only when replacing that App."
}

$null = Invoke-CheckedCommand gh @(
    'repo', 'view', $Repository,
    '--json', 'nameWithOwner',
    '--jq', '.nameWithOwner'
) -CaptureOutput

$owner = $Repository.Split('/', 2)[0]
$repositoryUrl = "https://github.com/$Repository"
$headers = @{
    Accept = 'application/vnd.github+json'
    'X-GitHub-Api-Version' = '2022-11-28'
    'User-Agent' = 'SelfHostedGHCopilotAgent-PoC'
}

if ($ExistingAppSlug) {
    if (-not (Test-Path $privateKeyPath)) {
        throw "Recovery requires the existing private key at '$privateKeyPath'."
    }

    $appMetadata = (
        Invoke-CheckedCommand gh @(
            'api', "apps/$ExistingAppSlug"
        ) -CaptureOutput
    ) | ConvertFrom-Json
    if ($appMetadata.owner.login -ne $owner) {
        throw "GitHub App '$ExistingAppSlug' is owned by '$($appMetadata.owner.login)', not '$owner'."
    }

    $conversion = [pscustomobject]@{
        id = $appMetadata.id
        slug = $appMetadata.slug
        client_id = $appMetadata.client_id
    }
}
else {
    $state = [Guid]::NewGuid().ToString('N')
    $callbackUrl = "http://localhost:$CallbackPort/callback"
    $startUrl = "http://localhost:$CallbackPort/start"

    $manifest = @{
        name = $AppName
        url = $repositoryUrl
        redirect_url = $callbackUrl
        public = $false
        default_permissions = @{
            administration = 'write'
            metadata = 'read'
        }
        default_events = @()
    } | ConvertTo-Json -Depth 5 -Compress

    $listener = [System.Net.HttpListener]::new()
    $listener.Prefixes.Add("http://localhost:$CallbackPort/")
    $listener.Start()

    try {
        Write-Host "Opening GitHub's App manifest flow. Approve creation of the private App in the browser."
        Start-Process $startUrl

        $deadline = [DateTimeOffset]::UtcNow.AddSeconds($TimeoutSeconds)
        $manifestCode = $null

        while ([DateTimeOffset]::UtcNow -lt $deadline -and -not $manifestCode) {
            $remainingMilliseconds = [Math]::Max(
                1,
                [int]($deadline - [DateTimeOffset]::UtcNow).TotalMilliseconds
            )
            $contextTask = $listener.GetContextAsync()
            if (-not $contextTask.Wait($remainingMilliseconds)) {
                break
            }

            $context = $contextTask.Result
            $response = $context.Response

            if ($context.Request.Url.AbsolutePath -eq '/start') {
                $encodedManifest = [System.Net.WebUtility]::HtmlEncode($manifest)
                $encodedState = [System.Uri]::EscapeDataString($state)
                $html = @"
<!doctype html>
<html lang="en">
<head><meta charset="utf-8"><title>Create ARC GitHub App</title></head>
<body>
  <p>Redirecting to GitHub to create the repository-scoped ARC App...</p>
  <form id="manifest" action="https://github.com/settings/apps/new?state=$encodedState" method="post">
    <input type="hidden" name="manifest" value="$encodedManifest">
    <noscript><button type="submit">Continue to GitHub</button></noscript>
  </form>
  <script>document.getElementById("manifest").submit();</script>
</body>
</html>
"@
                $bytes = [Text.Encoding]::UTF8.GetBytes($html)
                $response.ContentType = 'text/html; charset=utf-8'
                $response.ContentLength64 = $bytes.Length
                $response.OutputStream.Write($bytes, 0, $bytes.Length)
                $response.Close()
                continue
            }

            if ($context.Request.Url.AbsolutePath -eq '/callback') {
                $query = [System.Web.HttpUtility]::ParseQueryString($context.Request.Url.Query)
                if ($query['state'] -ne $state -or [string]::IsNullOrWhiteSpace($query['code'])) {
                    $response.StatusCode = 400
                    $message = [Text.Encoding]::UTF8.GetBytes('Invalid GitHub manifest callback.')
                    $response.OutputStream.Write($message, 0, $message.Length)
                    $response.Close()
                    throw 'GitHub returned an invalid manifest callback.'
                }

                $manifestCode = $query['code']
                $message = [Text.Encoding]::UTF8.GetBytes(
                    'GitHub App created. Return to the terminal to finish repository installation.'
                )
                $response.ContentType = 'text/plain; charset=utf-8'
                $response.ContentLength64 = $message.Length
                $response.OutputStream.Write($message, 0, $message.Length)
                $response.Close()
                continue
            }

            $response.StatusCode = 404
            $response.Close()
        }

        if (-not $manifestCode) {
            throw "Timed out after $TimeoutSeconds seconds waiting for GitHub App creation."
        }
    }
    finally {
        $listener.Stop()
        $listener.Close()
    }

    $conversion = Invoke-RestMethod `
        -Method Post `
        -Uri "https://api.github.com/app-manifests/$manifestCode/conversions" `
        -Headers $headers

    if (-not $conversion.id -or -not $conversion.slug -or -not $conversion.pem) {
        throw 'GitHub App manifest conversion omitted the App ID, slug, or private key.'
    }

    New-Item -ItemType Directory -Path $localStateDirectory -Force | Out-Null
    [IO.File]::WriteAllText($privateKeyPath, [string]$conversion.pem, [Text.UTF8Encoding]::new($false))
    Set-PrivateFilePermissions -Path $privateKeyPath
}

$installationUrl = if ($InstallationId) {
    "https://github.com/settings/installations/$InstallationId"
}
else {
    "https://github.com/apps/$($conversion.slug)/installations/new"
}

if (-not $ExistingAppSlug) {
    $ownerId = Invoke-CheckedCommand gh @(
        'api', "users/$owner",
        '--jq', '.id'
    ) -CaptureOutput
    $installationUrl = "https://github.com/apps/$($conversion.slug)/installations/new?suggested_target_id=$ownerId"

    Write-Host "Opening the installation page. Choose 'Only select repositories' and select $Repository."
    Start-Process $installationUrl
}

$installationDeadline = [DateTimeOffset]::UtcNow.AddSeconds($TimeoutSeconds)
$verifiedInstallationId = $null
while ([DateTimeOffset]::UtcNow -lt $installationDeadline -and -not $verifiedInstallationId) {
    try {
        $appJwt = New-GitHubAppJwt -AppId ([string]$conversion.id) -PrivateKeyPath $privateKeyPath
        $appHeaders = $headers.Clone()
        $appHeaders.Authorization = "Bearer $appJwt"
        $installationResponse = Invoke-RestMethod `
            -Method Get `
            -Uri 'https://api.github.com/app/installations?per_page=100' `
            -Headers $appHeaders
        $candidates = @(
            $installationResponse |
                Where-Object { $_.account.login -eq $owner }
        )
        if ($InstallationId) {
            $candidates = @($candidates | Where-Object id -eq $InstallationId)
        }

        foreach ($candidate in $candidates) {
            if ($candidate.repository_selection -ne 'selected') {
                throw "The App installation must use 'Only select repositories', not '$($candidate.repository_selection)'."
            }

            $tokenResponse = Invoke-RestMethod `
                -Method Post `
                -Uri "https://api.github.com/app/installations/$($candidate.id)/access_tokens" `
                -Headers $appHeaders
            $installationHeaders = $headers.Clone()
            $installationHeaders.Authorization = "Bearer $($tokenResponse.token)"
            $repositories = Invoke-RestMethod `
                -Method Get `
                -Uri 'https://api.github.com/installation/repositories?per_page=100' `
                -Headers $installationHeaders
            $tokenResponse = $null
            $installationHeaders = $null
            $selectedRepositories = @($repositories.repositories)
            if (
                $repositories.total_count -eq 1 -and
                $selectedRepositories[0].full_name -eq $Repository
            ) {
                $verifiedInstallationId = [string]$candidate.id
                break
            }

            if ($Repository -in @($selectedRepositories.full_name)) {
                throw "The App installation must select only '$Repository'."
            }
        }
    }
    catch {
        if ($_.Exception.Message -like 'The App installation must*') {
            throw
        }
        Write-Verbose $_
    }
    finally {
        $appJwt = $null
        $appHeaders = $null
    }

    if (-not $verifiedInstallationId) {
        Start-Sleep -Seconds 5
    }
}

if (-not $verifiedInstallationId) {
    throw "The App installation on $Repository was not detected. Complete installation at $installationUrl, then rerun with -ExistingAppSlug '$($conversion.slug)' -InstallationId <id> -Force."
}

$credentialState = [ordered]@{
    appId = [string]$conversion.id
    appSlug = [string]$conversion.slug
    clientId = [string]$conversion.client_id
    installationId = [string]$verifiedInstallationId
    repository = $Repository
    privateKeyPath = $privateKeyPath
    createdAt = [DateTimeOffset]::UtcNow.ToString('O')
}
[IO.File]::WriteAllText(
    $credentialPath,
    ($credentialState | ConvertTo-Json),
    [Text.UTF8Encoding]::new($false)
)
Set-PrivateFilePermissions -Path $credentialPath

Write-Host "GitHub App '$($conversion.slug)' is installed only for $Repository."
Write-Host "Credential state: $credentialPath"
