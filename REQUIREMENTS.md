# SVN to GitHub Migration for Contrast Scan, Requirements

## Purpose

Contrast Scan integrates with GitHub, not Subversion. To get Contrast Scan running as part of the build pipeline, source code needs to land in a GitHub repository before Contrast can scan it. This document covers what's needed to convert an SVN repository to Git and push it to GitHub as part of the pipeline, using GitHub's documented command line import process.

Reference, the process these scripts follow:
https://docs.github.com/en/migrations/importing-source-code/using-the-command-line-to-import-source-code/importing-a-subversion-repository

## Assumptions and out of scope

- GitHub is already integrated with Contrast at the organization level, through a GitHub App, webhook, or GitHub Action that triggers Contrast Scan on push. This document only covers getting code from SVN into GitHub, not configuring that integration.
- Contrast Scan results are stored in Contrast automatically once the scan runs, no separate step is needed here.
- The three scripts in this folder do the same thing. Use whichever one the pipeline's runner/agent can actually execute.

## TLS-inspecting corporate proxies

If the pipeline runner sits behind a proxy or VPN that does TLS inspection, Netskope is a common one, `curl`, `git`, and Python's HTTPS calls will fail with a certificate error unless that proxy's CA certificate is trusted on the runner. This surfaced directly while testing these scripts in a plain Debian container, `curl` failed with `SSL certificate problem: self-signed certificate in certificate chain` until the proxy's CA bundle was added.

- `curl`, set `CURL_CA_BUNDLE=/path/to/proxy-ca-bundle.pem`
- `git`, set `GIT_SSL_CAINFO=/path/to/proxy-ca-bundle.pem`
- Python, set `SSL_CERT_FILE=/path/to/proxy-ca-bundle.pem`, Python's `ssl` module picks this up the same way OpenSSL's command line tools do

Getting the bundle trusted isn't always enough for Python specifically. In testing, `import_svn_to_github.py` still failed even with `SSL_CERT_FILE` set correctly, with `CA cert does not include key usage extension`. OpenSSL 3.x enables a strict X.509 conformance check by default that some corporate CA certificates, including the one hit during testing, don't satisfy, even though the same certificate is accepted fine by curl and git. The script now builds its own SSL context and turns that one specific check off, chain of trust, expiry, and hostname validation are all still enforced, this doesn't weaken verification against a real MITM, it just stops rejecting an otherwise-valid corporate CA cert over a formatting nitpick. If you're not behind a TLS-inspecting proxy this never comes up.

Windows runners managed by the same corporate MDM as the proxy usually already trust it through the OS certificate store, so this mainly matters for Linux containers and ephemeral build agents that don't have it installed by default. The PowerShell script wasn't tested behind a TLS-inspecting proxy on a Linux runner, only reviewed for logic parity with the other two, if it needs the same treatment there, the fix looks different, `Invoke-RestMethod` on PowerShell 7+ for Linux uses .NET's certificate handling rather than an env var like `SSL_CERT_FILE`.

## SVN repository layout

`git svn clone -s` expects the standard SVN layout, a `trunk`, `branches`, and `tags` directory at the repository root. If the source repository doesn't use that layout, the clone silently finds nothing to import and the later push sends no refs, with no error, this was reproduced directly while testing. The scripts now fail loudly instead, if nothing was imported, they exit with an error naming the SVN URL rather than pushing an empty result. If a source repository genuinely uses a non-standard layout, drop the `-s` flag from the `git svn clone` line in the script and point `--svn-url` directly at the branch to import instead.

## Tooling requirements on the pipeline runner or agent

- `git`, with the `git-svn` component installed. On Debian and Ubuntu this is a separate package, `git-svn`. On RPM-based systems it's also separate, usually `git-svn` or bundled in `perl-Git-SVN`.
- `svn`, the Subversion command line client.
- `git-lfs`, in case any files exceed GitHub's size limits and need migrating to Git LFS. Not invoked automatically by these scripts, see Large Files below.
- `curl` and `base64`, for the shell script only.
- One of Python 3, PowerShell 5.1 or 7+, or a POSIX shell, matching whichever script the pipeline runs.
- Network access from the runner to both the SVN server and github.com, or the GitHub Enterprise Server host if self-hosted.

## Credentials and access

- SVN read access to the source repository. If the SVN server requires authentication, set `SVN_USERNAME` and `SVN_PASSWORD` as pipeline secrets, the scripts use them to seed the SVN credential cache before running `git svn`. `git svn` itself has no option to take a password directly, `--username` exists but there's no `--password`, so it has to read one from SVN's own cache. Two things follow from that, and a Contrast Scan of this repository flagged both:
  - The password is piped to `svn info` over stdin (`--password-from-stdin`), not passed as a `--password` argument, an argument value is visible to any local user for the life of the process via `/proc/<pid>/cmdline` or `ps`, stdin isn't.
  - Because `git svn` depends on the cache being populated, seeding it can't be skipped, but the scripts now remove that cached credential again as soon as the run finishes, success or failure, rather than leaving it in `~/.subversion/auth` indefinitely on a shared, persistent runner where any later job running as the same OS user could read it. Getting the credential cached at all also needs `--config-option servers:global:store-plaintext-passwords=yes`, the stock `ask` default silently declines to persist a password under `--non-interactive`, which would otherwise make the whole scheme fail to authenticate on the very next `git svn` call.
- A GitHub personal access token or GitHub App installation token, scoped to create and push to repositories in the destination organization. Set it as `GITHUB_TOKEN`, a pipeline secret, never in plain text in the pipeline definition or in source. It authenticates the push through an HTTP header and is never written to disk or to git config. It also never appears in argv, for the same `/proc`/`ps` reason as the SVN password, the header is set through `GIT_CONFIG_COUNT`/`GIT_CONFIG_KEY_0`/`GIT_CONFIG_VALUE_0` environment variables rather than a `git -c` flag, which a Contrast Scan flagged as a second, distinct exposure of the same kind.
- The destination GitHub organization name, and a naming convention for the destination repository so repeated builds map back to the same repo.

## Author mapping

SVN commits are attributed by SVN username. Git wants a name and email. Build an `authors.txt` file mapping SVN usernames to a name and email, in the form:

```
svnuser = Real Name <email@example.com>
```

Generate a starting point with:

```
svn log -q | grep -e '^r' | awk 'BEGIN { FS = "|" } ; { print $2" = "$2 }' | sed -E 's/^ *//' | sort | uniq
```

Then fill in real names and emails, and maintain it as a static file the pipeline can reach, since it's referenced on every run.

## Handling repeated builds

A full history checkout of the SVN repository can be slow for older or larger repositories. Since this runs on every build, each script checks whether a previous checkout exists in the pipeline's persistent workspace or cache.

- If one exists, the script runs `git svn rebase` to pull incremental changes instead of a full clone.
- If the pipeline doesn't persist a workspace between runs, every build does a full clone, which is correct but slower. Point `--workdir` (or the equivalent parameter) at a cached path if the pipeline supports one.

Pushing with `--mirror` keeps the GitHub repo a faithful mirror of SVN, including deleting branches on GitHub that no longer exist in SVN. That's appropriate here since GitHub's only role is to give Contrast something to scan, not to be a second source of truth.

### A shared, cached workdir is not automatically a trustworthy one

Pointing `--workdir` at a persistent, shared pipeline cache, which the guidance above recommends for speed, means the directory is also writable by whatever else shares that cache: other jobs, other pipelines on the same runner, or lower-privileged builds that run without secrets. A Contrast Scan of this repository flagged that the scripts didn't account for that. Anything able to write to the cache path could plant a `.git` directory there ahead of a real run, and the scripts trusted its config and hooks wholesale, giving that writer code execution as the pipeline user (`git svn rebase` refreshes the index, which runs a planted `core.fsmonitor` command and fires hook scripts like `pre-rebase` and `post-checkout`) and a path to steal `GITHUB_TOKEN` (a planted `remote.origin.pushurl` or `url.*.insteadOf` survives a plain `git remote set-url` and can redirect the push, header and all, to an attacker's host).

The scripts now treat a pre-existing workdir as untrusted until proven otherwise:

- Before reusing it, they compare the checkout's own `svn-remote.svn.url` against the `--svn-url` this run was given, and refuse to continue on a mismatch rather than silently trusting or overwriting it.
- Every git command run against the workdir passes `-c core.hooksPath=<empty temp dir> -c core.fsmonitor=`, so a planted hook or fsmonitor command never executes, verified directly against a real planted hook through an actual `git svn rebase`, not just inferred.
- Both `remote.origin.url` and `remote.origin.pushurl` are reset to the exact expected URL on every run, undoing a hijacked pushurl.
- The GitHub token is attached via a header scoped to that literal destination URL (`http.<url>.extraheader`, set through `GIT_CONFIG_*` environment variables, never through `-c` or argv), not applied globally. Verified with a real redirect, a `url.*.insteadOf` rewrite pointed the push at a different host and the token simply wasn't sent there, it only goes out on requests that match the exact URL it's scoped to.

## Repository creation

Each script creates the destination GitHub repository automatically through the GitHub REST API if it doesn't already exist, so the first build for a given SVN project doesn't require a manual step. Per GitHub's guidance, the repo is created without a README, license, or `.gitignore`, since the mirrored history brings its own content and an initial commit on GitHub would conflict with the mirror push.

The scripts check whether the destination account is an organization or a personal account before creating anything, GitHub uses a different API endpoint for each (`POST /orgs/{org}/repos` versus `POST /user/repos`), and calling the wrong one for a personal account fails with a 404 rather than the expected already-exists response. This was caught during live testing against a personal account and fixed, in normal production use the destination is almost always an organization, but the check costs nothing and avoids a confusing failure if that ever isn't the case.

A repository that already exists under the target name isn't necessarily one this pipeline created. In an org that allows members to create their own repositories, which is GitHub's default, anyone who knows (or guesses) the naming convention documented above could pre-create the destination repo, public and under their own control, before the pipeline's first run ever fires. The original create-then-422-means-exists logic had no way to tell a legitimate rerun apart from that. A Contrast Scan flagged this, so now, whenever the repository is found to already exist, whether through the initial existence check or a 422 on creation, the scripts fetch it and confirm it's actually private and actually owned by the expected org or account before pushing anything, and refuse to continue otherwise.

## Large files

If a push fails because a file exceeds GitHub's size limits, run `git lfs migrate import --everything --above=100MB` in the local clone before retrying the push. This isn't automated in the scripts since it rewrites history and should be a deliberate, reviewed step, not an automatic one in a pipeline.

## Script parameters

All three scripts take the same inputs.

| Parameter | Required | Description |
| --- | --- | --- |
| SVN URL | yes | The SVN repository or branch URL to import |
| GitHub org | yes | Destination GitHub organization |
| GitHub repo | yes | Destination repository name |
| Authors file | yes | Path to the authors mapping file above |
| Work directory | no | Where the local git-svn checkout lives, defaults to `svn-import/<repo>`. Point this at a cached path for incremental updates |
| GitHub host | no | Defaults to `github.com`, set to a GitHub Enterprise Server hostname otherwise |

Environment variables, all pipeline secrets, never plain text:

- `GITHUB_TOKEN`, required
- `SVN_USERNAME` and `SVN_PASSWORD`, optional, only needed if the SVN server requires authentication

## Native command failures must stop the script

`$ErrorActionPreference = "Stop"` in the PowerShell script only governs PowerShell cmdlets, it does nothing for native executables like `git` and `svn`, which signal failure solely through `$LASTEXITCODE`. A Contrast Scan found that this was checked in exactly one place (`git svn --version`) and nowhere else, meaning a failed or partial `git svn rebase`, `git svn clone`, or `git push --mirror` fell straight through to the next step instead of stopping the run. The practical failure mode is quiet, a broken SVN connection or a commit from an author missing in `authors.txt` could make the rebase fail, and the script would still print "Done" and exit 0, so the pipeline step reports success while Contrast keeps scanning stale code. Every native call that matters now checks `$LASTEXITCODE` and throws on a nonzero result. The check itself was verified directly, a failed `git push` sets `$LASTEXITCODE` and the same pattern used elsewhere in the script correctly throws on it, though the full PowerShell script wasn't run end to end against a real SVN server the way the shell and Python versions were, see the note in `TESTING.md`.

## Files in this folder

- `import_svn_to_github.sh`, POSIX shell version
- `import_svn_to_github.py`, Python 3 version, standard library only, no extra packages to install
- `Import-SvnToGitHub.ps1`, PowerShell version
