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
    [string]$AuthorsFile,
    [string]$WorkDir,
    [string]$GitHubHost = "github.com",
    # Comma-separated GitHub logins permitted to be direct collaborators on a
    # pre-existing destination repo under an organization. Defaults to none,
    # meaning any direct collaborator on an existing org repo causes the run
    # to refuse rather than push into it.
    [string]$AllowedAdmins = "",
    # Skips SVN history entirely and imports just the current revision as a
    # single commit with no history. Use this when the full SVN history is
    # too large for a single GitHub push, GitHub enforces a hard limit around
    # 2GB per push. -AuthorsFile is not required or used in this mode, and
    # -SvnUrl doesn't need to point at a trunk/branches/tags layout, any URL
    # within the repository works.
    [switch]$SnapshotOnly,
    # Git author and committer, "Name <email>", for the single snapshot
    # commit. Only used with -SnapshotOnly.
    [string]$CommitAuthor = "SVN Snapshot Import <svn-snapshot-import@localhost>"
)

$ErrorActionPreference = "Stop"
$AllowedAdminsSet = @($AllowedAdmins -split "," | Where-Object { $_.Trim() } | ForEach-Object { $_.Trim().ToLower() })

if (-not $SnapshotOnly -and -not $AuthorsFile) {
    throw "-AuthorsFile is required unless -SnapshotOnly is set"
}

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
if (-not $SnapshotOnly) {
    git svn --version | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "git-svn is not installed"
    }
}

# This script always clones fresh, it never reuses a pre-existing directory.
# An earlier version tried to validate and reuse a pre-existing workdir for
# faster incremental syncs, comparing its svn-remote.svn.url against
# $SvnUrl before trusting it. That check compares a non-secret value, an
# attacker able to write to a shared or predictable workdir path can set it
# to match and pass the gate, then have the planted checkout's own config,
# hooks, filters, or refs trusted from there. There's no complete fix for
# that short of not trusting a pre-existing directory at all, so that's what
# this does, see REQUIREMENTS.md.
if (Test-Path $WorkDir) {
    throw "Refusing to use $WorkDir`: it already exists. This script always creates a fresh checkout rather than reusing a directory it can't fully vouch for. Point -WorkDir at a path that doesn't exist yet."
}

# $ErrorActionPreference only governs PowerShell cmdlets, native executables
# like git and svn signal failure solely through $LASTEXITCODE, so every call
# that matters here is wrapped to check it explicitly and throw, rather than
# silently falling through to the next step on a failed clone or push.
function Invoke-Checked {
    param([string]$Exe, [string[]]$ExeArgs, [hashtable]$ExtraEnv)
    if ($ExtraEnv) {
        foreach ($key in $ExtraEnv.Keys) { Set-Item "Env:$key" $ExtraEnv[$key] }
    }
    try {
        & $Exe @ExeArgs
        if ($LASTEXITCODE -ne 0) {
            throw "$Exe $($ExeArgs -join ' ') failed with exit code $LASTEXITCODE"
        }
    } finally {
        if ($ExtraEnv) {
            foreach ($key in $ExtraEnv.Keys) { Remove-Item "Env:$key" -ErrorAction SilentlyContinue }
        }
    }
}

# core.hooksPath is redirected to this empty directory, and core.fsmonitor is
# cleared, on every git invocation this script makes, including the initial
# clone. A denylist of dangerous config keys was tried here before and found
# incomplete (filter/merge drivers, credential.helper, http.proxy, and
# insteadOf rewrites are all separate code-execution or credential-exfiltration
# vectors it didn't cover), see REQUIREMENTS.md. The actual fix is that this
# script never operates against a pre-existing directory at all, these two
# overrides remain as cheap defense in depth, not as the primary control.
$HooksNeutralizeDir = Join-Path ([System.IO.Path]::GetTempPath()) ([System.IO.Path]::GetRandomFileName())
New-Item -ItemType Directory -Path $HooksNeutralizeDir | Out-Null

function Invoke-SafeGit {
    param(
        [Parameter(Mandatory = $true)][string[]]$GitArgs,
        [string]$WorkingDirectory,
        [hashtable]$ExtraEnv
    )
    $prefix = @()
    if ($WorkingDirectory) { $prefix += @("-C", $WorkingDirectory) }
    $prefix += @("-c", "core.hooksPath=$HooksNeutralizeDir", "-c", "core.fsmonitor=")
    Invoke-Checked "git" (@($prefix) + @($GitArgs)) $ExtraEnv
}

# Every svn and git-svn call below runs with HOME (and, on Windows, APPDATA)
# pointed at this directory instead of the real one, so their config and
# credential cache land here instead of the shared, per-user profile.
# 'svn --config-dir' looks like the more direct way to do this, but it
# doesn't fully work, verified directly on the shell and Python versions of
# this script, git svn clone still prompts interactively for a password when
# pointed at a --config-dir a plain 'svn info' had already cached one in,
# apparently not routing authentication through it consistently the way it
# does for config file settings. Overriding HOME/APPDATA is what svn's own
# credential lookup actually keys off, and it's what makes the plaintext SVN
# password never land in a location any other job or workload running as the
# same runner user would ever read from, whether or not this run's cleanup
# below actually gets to execute.
$SvnHomeDir = Join-Path ([System.IO.Path]::GetTempPath()) ([System.IO.Path]::GetRandomFileName())
New-Item -ItemType Directory -Path $SvnHomeDir | Out-Null
$SvnIsolationEnv = @{ HOME = $SvnHomeDir; APPDATA = $SvnHomeDir }

try {
    if (-not $SnapshotOnly -and $SvnUsername -and $SvnPassword) {
        Write-Host "Seeding SVN credential cache"
        # --password-from-stdin keeps the password out of argv, where it
        # would otherwise be readable by any local user via /proc/<pid>/cmdline
        # or ps for the duration of this call. store-plaintext-passwords=yes
        # is required for svn to actually cache it, the stock 'ask' default
        # silently declines to persist the password under --non-interactive,
        # which would otherwise make the later git-svn calls fail to
        # authenticate with no cached credential. -SnapshotOnly doesn't need
        # any of this, 'svn export' takes credentials directly on every
        # call, unlike git-svn it has no need to read them back out of a
        # cache, so there's no plaintext password to cache or clean up in
        # that mode at all.
        foreach ($key in $SvnIsolationEnv.Keys) { Set-Item "Env:$key" $SvnIsolationEnv[$key] }
        try {
            $SvnPassword | svn info --non-interactive `
                --config-option servers:global:store-plaintext-passwords=yes `
                --username "$SvnUsername" --password-from-stdin "$SvnUrl" | Out-Null
            if ($LASTEXITCODE -ne 0) {
                throw "Failed to authenticate to SVN as $SvnUsername"
            }
        } finally {
            foreach ($key in $SvnIsolationEnv.Keys) { Remove-Item "Env:$key" -ErrorAction SilentlyContinue }
        }
    }

    Write-Host "Ensuring GitHub repository $GitHubOrg/$GitHubRepo exists on $GitHubHost"
    $Headers = @{
        Authorization = "token $Token"
        Accept        = "application/vnd.github+json"
    }

    # POST /orgs/{org}/repos only works when GitHubOrg is an organization,
    # personal accounts use POST /user/repos instead. This also decides
    # whether the collaborator check below applies, personal accounts always
    # list their own owner as a collaborator, that's not a squatting signal
    # there the way it is for an org repo.
    $AccountType = "User"
    try {
        $Account = Invoke-RestMethod -Uri "$ApiBase/users/$GitHubOrg" -Headers $Headers
        $AccountType = $Account.type
    } catch {
        # Fall through with the User default if this lookup itself fails.
    }

    function Test-RepoOwnership {
        # A repo that already exists under the target name could have been
        # pre-created by someone else, e.g. a low-privileged org member
        # name-squatting the destination before the pipeline's first run.
        # Confirm it's actually private, owned by the expected account, and,
        # for an org destination, has no unexpected direct collaborators,
        # before mirroring proprietary source into it. Private-and-org-owned
        # alone isn't enough: a member of an org that allows members to
        # create their own repositories can pre-create a private repo under
        # the org and still retain admin on it as its creator, which passes
        # a private/owner-only check while leaving them fully in control of
        # the repo.
        $Repo = Invoke-RestMethod -Uri "$ApiBase/repos/$GitHubOrg/$GitHubRepo" -Headers $Headers
        if (-not $Repo.private) {
            throw "Refusing to push: $GitHubOrg/$GitHubRepo is not private."
        }
        if ($Repo.owner.login.ToLower() -ne $GitHubOrg.ToLower()) {
            throw "Refusing to push: $GitHubOrg/$GitHubRepo is owned by '$($Repo.owner.login)', not '$GitHubOrg'."
        }

        if ($AccountType -eq "Organization") {
            try {
                $Collaborators = Invoke-RestMethod -Uri "$ApiBase/repos/$GitHubOrg/$GitHubRepo/collaborators?affiliation=direct" -Headers $Headers
            } catch {
                $StatusCode = $_.Exception.Response.StatusCode.value__
                throw "Refusing to push: couldn't confirm who has direct access to $GitHubOrg/$GitHubRepo, HTTP ${StatusCode}."
            }
            foreach ($collaborator in $Collaborators) {
                if ($AllowedAdminsSet -notcontains $collaborator.login.ToLower()) {
                    throw "Refusing to push: $GitHubOrg/$GitHubRepo has a direct collaborator, '$($collaborator.login)', that isn't in -AllowedAdmins. A repo created by an org member who added themselves this way can retain admin access to it, even though it's private and org-owned."
                }
            }
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

    New-Item -ItemType Directory -Force -Path (Split-Path $WorkDir -Parent) | Out-Null

    if ($SnapshotOnly) {
        Write-Host "Exporting current revision (no history) from $SvnUrl to $WorkDir"
        foreach ($key in $SvnIsolationEnv.Keys) { Set-Item "Env:$key" $SvnIsolationEnv[$key] }
        try {
            if ($SvnUsername -and $SvnPassword) {
                $Rev = ($SvnPassword | svn info --non-interactive --show-item revision --username "$SvnUsername" --password-from-stdin "$SvnUrl").Trim()
                if ($LASTEXITCODE -ne 0) { throw "Failed to read the current SVN revision from $SvnUrl" }
                $SvnPassword | svn export --force --non-interactive --username "$SvnUsername" --password-from-stdin "$SvnUrl" "$WorkDir" | Out-Null
            } else {
                $Rev = (svn info --non-interactive --show-item revision "$SvnUrl").Trim()
                if ($LASTEXITCODE -ne 0) { throw "Failed to read the current SVN revision from $SvnUrl" }
                svn export --force --non-interactive "$SvnUrl" "$WorkDir" | Out-Null
            }
            if ($LASTEXITCODE -ne 0) {
                throw "svn export failed with exit code $LASTEXITCODE"
            }
        } finally {
            foreach ($key in $SvnIsolationEnv.Keys) { Remove-Item "Env:$key" -ErrorAction SilentlyContinue }
        }

        if (-not (Get-ChildItem -Path $WorkDir -Force | Select-Object -First 1)) {
            throw "Nothing was exported from $SvnUrl, the export produced an empty directory. Check the URL is correct and that it actually has content at its current revision."
        }

        $CommitAuthorName, $CommitAuthorEmail = $CommitAuthor -split "<", 2
        $CommitAuthorName = $CommitAuthorName.Trim()
        $CommitAuthorEmail = $CommitAuthorEmail.TrimEnd(">").Trim()

        Invoke-SafeGit -GitArgs @("init", "-q", "$WorkDir")
        Invoke-SafeGit -WorkingDirectory $WorkDir -GitArgs @("add", "-A")
        Invoke-SafeGit -WorkingDirectory $WorkDir -GitArgs @(
            "-c", "user.name=$CommitAuthorName",
            "-c", "user.email=$CommitAuthorEmail",
            "commit", "-q", "-m", "Snapshot of SVN revision $Rev from $SvnUrl, no history preserved"
        )
    } else {
        Write-Host "Cloning full SVN history to $WorkDir"
        if ($SvnUsername) {
            Invoke-SafeGit -GitArgs @("svn", "clone", "-s", "$SvnUrl", "$WorkDir", "--authors-file", "$AuthorsFile", "--username", "$SvnUsername") -ExtraEnv $SvnIsolationEnv
        } else {
            Invoke-SafeGit -GitArgs @("svn", "clone", "-s", "$SvnUrl", "$WorkDir", "--authors-file", "$AuthorsFile") -ExtraEnv $SvnIsolationEnv
        }
    }

    git -C $WorkDir -c "core.hooksPath=$HooksNeutralizeDir" -c "core.fsmonitor=" rev-parse HEAD 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) {
        if ($SnapshotOnly) {
            throw "No commit was created for $SvnUrl."
        }
        throw "No history was imported from $SvnUrl. This usually means the repository doesn't use the standard trunk/branches/tags layout that 'git svn clone -s' expects, check the SVN URL and layout before retrying."
    }

    $RemoteUrl = "https://$GitHubHost/$GitHubOrg/$GitHubRepo.git"
    Invoke-SafeGit -WorkingDirectory $WorkDir -GitArgs @("remote", "add", "origin", $RemoteUrl)
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
    # in process argv. Scoping it to the literal URL also means that if
    # something in this run's own config redirected the connection
    # elsewhere, the header simply wouldn't be attached to that request,
    # since it wouldn't match the URL git actually connects to.
    $PushEnv = @{
        GIT_CONFIG_COUNT   = "1"
        GIT_CONFIG_KEY_0   = "http.$RemoteUrl.extraheader"
        GIT_CONFIG_VALUE_0 = "AUTHORIZATION: basic $AuthHeader"
    }
    Invoke-SafeGit -WorkingDirectory $WorkDir -GitArgs @("push", "--mirror", $RemoteUrl) -ExtraEnv $PushEnv

    Write-Host "Done. GitHub will trigger the Contrast Scan integration from this push."
} finally {
    Remove-Item -Recurse -Force $SvnHomeDir -ErrorAction SilentlyContinue
    if (Test-Path $SvnHomeDir) {
        Write-Warning "Failed to remove the isolated SVN config directory $SvnHomeDir, it may still contain a cached SVN credential."
    }
    Remove-Item -Recurse -Force $HooksNeutralizeDir -ErrorAction SilentlyContinue
}
