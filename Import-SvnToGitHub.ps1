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

# $ErrorActionPreference only governs PowerShell cmdlets, native executables
# like git and svn signal failure solely through $LASTEXITCODE, so every call
# that matters here is wrapped to check it explicitly and throw, rather than
# silently falling through to the next step on a failed clone, rebase, or
# push.
function Invoke-Checked {
    param([string]$Exe, [string[]]$ExeArgs)
    & $Exe @ExeArgs
    if ($LASTEXITCODE -ne 0) {
        throw "$Exe $($ExeArgs -join ' ') failed with exit code $LASTEXITCODE"
    }
}

# core.hooksPath is redirected to this empty directory, and core.fsmonitor is
# cleared, on every git invocation that touches $WorkDir. Without this, a
# workdir reused from a shared/cached CI path could carry a planted
# .git/hooks/* script or a core.fsmonitor command that executes arbitrary
# code the moment git refreshes its index, e.g. during 'git svn rebase'.
$HooksNeutralizeDir = Join-Path ([System.IO.Path]::GetTempPath()) ([System.IO.Path]::GetRandomFileName())
New-Item -ItemType Directory -Path $HooksNeutralizeDir | Out-Null

function Invoke-SafeGit {
    param(
        [Parameter(Mandatory = $true)][string[]]$GitArgs,
        [string]$WorkingDirectory
    )
    $prefix = @()
    if ($WorkingDirectory) { $prefix += @("-C", $WorkingDirectory) }
    $prefix += @("-c", "core.hooksPath=$HooksNeutralizeDir", "-c", "core.fsmonitor=")
    & git @prefix @GitArgs
    if ($LASTEXITCODE -ne 0) {
        throw "git $($GitArgs -join ' ') failed with exit code $LASTEXITCODE"
    }
}

$SvnAuthSeeded = $false

try {
    if ($SvnUsername -and $SvnPassword) {
        Write-Host "Seeding SVN credential cache"
        # --password-from-stdin keeps the password out of argv, where it
        # would otherwise be readable by any local user via /proc/<pid>/cmdline
        # or ps for the duration of this call. store-plaintext-passwords=yes
        # is required for svn to actually cache it, the stock 'ask' default
        # silently declines to persist the password under --non-interactive,
        # which would otherwise make the later git-svn calls fail to
        # authenticate with no cached credential.
        $SvnPassword | svn info --non-interactive `
            --config-option servers:global:store-plaintext-passwords=yes `
            --username "$SvnUsername" --password-from-stdin "$SvnUrl" | Out-Null
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to authenticate to SVN as $SvnUsername"
        }
        $SvnAuthSeeded = $true
    }

    Write-Host "Ensuring GitHub repository $GitHubOrg/$GitHubRepo exists on $GitHubHost"
    $Headers = @{
        Authorization = "token $Token"
        Accept        = "application/vnd.github+json"
    }

    function Test-RepoOwnership {
        # A repo that already exists under the target name could have been
        # pre-created by someone else, e.g. a low-privileged org member
        # name-squatting the destination before the pipeline's first run.
        # Confirm it's actually private and owned by the expected account
        # before mirroring proprietary source into it.
        $Repo = Invoke-RestMethod -Uri "$ApiBase/repos/$GitHubOrg/$GitHubRepo" -Headers $Headers
        if (-not $Repo.private) {
            throw "Refusing to push: $GitHubOrg/$GitHubRepo is not private."
        }
        if ($Repo.owner.login.ToLower() -ne $GitHubOrg.ToLower()) {
            throw "Refusing to push: $GitHubOrg/$GitHubRepo is owned by '$($Repo.owner.login)', not '$GitHubOrg'."
        }
    }

    $RepoExists = $true
    try {
        Invoke-RestMethod -Uri "$ApiBase/repos/$GitHubOrg/$GitHubRepo" -Headers $Headers | Out-Null
    } catch {
        $StatusCode = $_.Exception.Response.StatusCode.value__
        if ($StatusCode -eq 404) {
            $RepoExists = $false
        } else {
            throw "Failed to check for existing repository, HTTP ${StatusCode}: $($_.Exception.Message)"
        }
    }

    if ($RepoExists) {
        Write-Host "Repository already exists, verifying it before pushing."
        Test-RepoOwnership
        Write-Host "Ownership and visibility confirmed, continuing."
    } else {
        # POST /orgs/{org}/repos only works when GitHubOrg is an organization,
        # personal accounts use POST /user/repos instead, ask the API which kind
        # of account this is before picking one.
        $AccountType = "User"
        try {
            $Account = Invoke-RestMethod -Uri "$ApiBase/users/$GitHubOrg" -Headers $Headers
            $AccountType = $Account.type
        } catch {
            # Fall through with the User default if this lookup itself fails.
        }
        $CreateUrl = if ($AccountType -eq "Organization") { "$ApiBase/orgs/$GitHubOrg/repos" } else { "$ApiBase/user/repos" }
        $Body = @{ name = $GitHubRepo; auto_init = $false; private = $true } | ConvertTo-Json

        try {
            Invoke-RestMethod -Uri $CreateUrl -Method Post -Headers $Headers -Body $Body -ContentType "application/json" | Out-Null
            Write-Host "Repository created."
        } catch {
            $StatusCode = $_.Exception.Response.StatusCode.value__
            if ($StatusCode -eq 422) {
                Write-Host "Repository already exists, verifying it before pushing."
                Test-RepoOwnership
                Write-Host "Ownership and visibility confirmed, continuing."
            } else {
                throw "Failed to create repository, HTTP ${StatusCode}: $($_.Exception.Message)"
            }
        }
    }

    if (Test-Path (Join-Path $WorkDir ".git")) {
        # A pre-existing workdir is only trustworthy if it's actually a
        # checkout of the SVN URL this run was asked to import, not a
        # directory an attacker planted at the same shared/cached path with a
        # different svn-remote, malicious hooks, or a hijacked push
        # destination.
        $ExistingSvnUrl = (git -C $WorkDir -c "core.hooksPath=$HooksNeutralizeDir" -c "core.fsmonitor=" config --get svn-remote.svn.url 2>$null)
        if ($ExistingSvnUrl -ne $SvnUrl) {
            throw "Refusing to reuse $WorkDir`: it's configured for SVN URL '$ExistingSvnUrl', not '$SvnUrl'. If this is a stale or untrusted cache, clear it manually and retry."
        }
        Write-Host "Existing checkout found at $WorkDir, fetching incremental updates"
        Invoke-SafeGit -WorkingDirectory $WorkDir -GitArgs @("svn", "rebase")
    } else {
        Write-Host "No existing checkout, cloning full SVN history to $WorkDir"
        New-Item -ItemType Directory -Force -Path (Split-Path $WorkDir -Parent) | Out-Null
        if ($SvnUsername) {
            Invoke-Checked "git" @("svn", "clone", "-s", "$SvnUrl", "$WorkDir", "--authors-file", "$AuthorsFile", "--username", "$SvnUsername")
        } else {
            Invoke-Checked "git" @("svn", "clone", "-s", "$SvnUrl", "$WorkDir", "--authors-file", "$AuthorsFile")
        }
    }

    git -C $WorkDir -c "core.hooksPath=$HooksNeutralizeDir" -c "core.fsmonitor=" rev-parse HEAD 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "No history was imported from $SvnUrl. This usually means the repository doesn't use the standard trunk/branches/tags layout that 'git svn clone -s' expects, check the SVN URL and layout before retrying."
    }

    $RemoteUrl = "https://$GitHubHost/$GitHubOrg/$GitHubRepo.git"
    $Remotes = git -C $WorkDir -c "core.hooksPath=$HooksNeutralizeDir" -c "core.fsmonitor=" remote
    if ($Remotes -contains "origin") {
        Invoke-SafeGit -WorkingDirectory $WorkDir -GitArgs @("remote", "set-url", "origin", $RemoteUrl)
    } else {
        Invoke-SafeGit -WorkingDirectory $WorkDir -GitArgs @("remote", "add", "origin", $RemoteUrl)
    }
    # set-url without --push only touches remote.origin.url, a planted
    # remote.origin.pushurl in a reused workdir would otherwise survive and
    # take precedence over it on push.
    Invoke-SafeGit -WorkingDirectory $WorkDir -GitArgs @("remote", "set-url", "--push", "origin", $RemoteUrl)

    Write-Host "Pushing mirror to $GitHubOrg/$GitHubRepo"
    $AuthBytes = [System.Text.Encoding]::ASCII.GetBytes("x-access-token:$Token")
    $AuthHeader = [Convert]::ToBase64String($AuthBytes)
    # The header is scoped to this exact literal URL (http.<url>.extraheader)
    # rather than applied globally (http.extraheader), and supplied through
    # GIT_CONFIG_* environment variables rather than -c, so it never appears
    # in process argv. Scoping it to the literal URL also means that if a
    # planted pushurl or a url.*.insteadOf rewrite in a reused workdir
    # redirects the connection elsewhere, the header simply won't be attached
    # to that request, since it won't match the URL git actually connects to.
    $env:GIT_CONFIG_COUNT = "1"
    $env:GIT_CONFIG_KEY_0 = "http.$RemoteUrl.extraheader"
    $env:GIT_CONFIG_VALUE_0 = "AUTHORIZATION: basic $AuthHeader"
    try {
        Invoke-SafeGit -WorkingDirectory $WorkDir -GitArgs @("push", "--mirror", $RemoteUrl)
    } finally {
        Remove-Item Env:\GIT_CONFIG_COUNT, Env:\GIT_CONFIG_KEY_0, Env:\GIT_CONFIG_VALUE_0 -ErrorAction SilentlyContinue
    }

    Write-Host "Done. GitHub will trigger the Contrast Scan integration from this push."
} finally {
    # The SVN credential only needs to live on disk long enough for the
    # git-svn calls above to read it, git-svn has no way to accept a password
    # directly. Remove it again once this run is done, success or failure,
    # rather than leaving it in the shared auth cache indefinitely.
    if ($SvnAuthSeeded) {
        if ($SvnUrl -match '^([a-zA-Z]+://[^/]+)') {
            $HostPart = $Matches[1]
            svn auth --remove "$SvnUsername" "$HostPart" *> $null
        }
    }
    Remove-Item -Recurse -Force $HooksNeutralizeDir -ErrorAction SilentlyContinue
}
