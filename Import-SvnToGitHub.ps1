<#
.SYNOPSIS
Imports an SVN repository into GitHub so Contrast Scan can pick it up on push.

.DESCRIPTION
Follows https://docs.github.com/en/migrations/importing-source-code/using-the-command-line-to-import-source-code/importing-a-subversion-repository
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$SvnUrl,
    [Parameter(Mandatory = $true)][string]$GitHubOrg,
    [Parameter(Mandatory = $true)][string]$GitHubRepo,
    [Parameter(Mandatory = $true)][string]$AuthorsFile,
    [string]$WorkDir,
    [string]$GitHubHost = "github.com"
)

$ErrorActionPreference = "Stop"

if (-not $env:GITHUB_TOKEN) {
    throw "GITHUB_TOKEN environment variable is required"
}
$Token = $env:GITHUB_TOKEN
$SvnUsername = $env:SVN_USERNAME
$SvnPassword = $env:SVN_PASSWORD

if (-not $WorkDir) {
    $WorkDir = Join-Path "svn-import" $GitHubRepo
}

$ApiBase = if ($GitHubHost -eq "github.com") { "https://api.github.com" } else { "https://$GitHubHost/api/v3" }

foreach ($tool in @("git", "svn")) {
    if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) {
        throw "Required tool not found: $tool"
    }
}
git svn --version | Out-Null
if ($LASTEXITCODE -ne 0) {
    throw "git-svn is not installed"
}

if ($SvnUsername -and $SvnPassword) {
    Write-Host "Seeding SVN credential cache"
    svn info --non-interactive --username "$SvnUsername" --password "$SvnPassword" "$SvnUrl" | Out-Null
}

Write-Host "Ensuring GitHub repository $GitHubOrg/$GitHubRepo exists on $GitHubHost"
$Headers = @{
    Authorization = "token $Token"
    Accept        = "application/vnd.github+json"
}
$Body = @{ name = $GitHubRepo; auto_init = $false; private = $true } | ConvertTo-Json

try {
    Invoke-RestMethod -Uri "$ApiBase/orgs/$GitHubOrg/repos" -Method Post -Headers $Headers -Body $Body -ContentType "application/json" | Out-Null
    Write-Host "Repository created."
} catch {
    $StatusCode = $_.Exception.Response.StatusCode.value__
    if ($StatusCode -eq 422) {
        Write-Host "Repository already exists, continuing."
    } else {
        throw "Failed to create repository, HTTP ${StatusCode}: $($_.Exception.Message)"
    }
}

if (Test-Path (Join-Path $WorkDir ".git")) {
    Write-Host "Existing checkout found at $WorkDir, fetching incremental updates"
    Push-Location $WorkDir
    try { git svn rebase } finally { Pop-Location }
} else {
    Write-Host "No existing checkout, cloning full SVN history to $WorkDir"
    New-Item -ItemType Directory -Force -Path (Split-Path $WorkDir -Parent) | Out-Null
    if ($SvnUsername) {
        git svn clone -s "$SvnUrl" "$WorkDir" --authors-file "$AuthorsFile" --username "$SvnUsername"
    } else {
        git svn clone -s "$SvnUrl" "$WorkDir" --authors-file "$AuthorsFile"
    }
}

Push-Location $WorkDir
try {
    $RemoteUrl = "https://$GitHubHost/$GitHubOrg/$GitHubRepo.git"
    $Remotes = git remote
    if ($Remotes -contains "origin") {
        git remote set-url origin $RemoteUrl
    } else {
        git remote add origin $RemoteUrl
    }

    Write-Host "Pushing mirror to $GitHubOrg/$GitHubRepo"
    $AuthBytes = [System.Text.Encoding]::ASCII.GetBytes("x-access-token:$Token")
    $AuthHeader = [Convert]::ToBase64String($AuthBytes)
    git -c "http.extraheader=AUTHORIZATION: basic $AuthHeader" push --mirror origin
} finally {
    Pop-Location
}

Write-Host "Done. GitHub will trigger the Contrast Scan integration from this push."
