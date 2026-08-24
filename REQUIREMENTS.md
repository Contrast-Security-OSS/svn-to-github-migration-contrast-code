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

Windows runners managed by the same corporate MDM as the proxy usually already trust it through the OS certificate store, so this mainly matters for Linux containers and ephemeral build agents that don't have it installed by default. `Invoke-RestMethod` on PowerShell 7+ for Linux uses .NET's certificate handling rather than an env var like `SSL_CERT_FILE` or `CURL_CA_BUNDLE`, confirmed while testing this round's fixes, the fix that worked was installing the proxy's CA into the container's own trust store (`update-ca-certificates` on Debian) rather than pointing an env var at it.

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

- SVN read access to the source repository. If the SVN server requires authentication, set `SVN_USERNAME` and `SVN_PASSWORD` as pipeline secrets, the scripts use them to seed the SVN credential cache before running `git svn`. `git svn` itself has no option to take a password directly, `--username` exists but there's no `--password`, so it has to read one from SVN's own cache. Several things follow from that, and two rounds of Contrast Scan against this repository flagged different parts of it:
  - The password is piped to `svn info` over stdin (`--password-from-stdin`), not passed as a `--password` argument, an argument value is visible to any local user for the life of the process via `/proc/<pid>/cmdline` or `ps`, stdin isn't.
  - Getting the credential cached at all needs `--config-option servers:global:store-plaintext-passwords=yes`, the stock `ask` default silently declines to persist a password under `--non-interactive`, which would otherwise make the whole scheme fail to authenticate on the very next `git svn` call.
  - Because `git svn` depends on the cache being populated, seeding it can't be skipped. Every svn and git-svn call the script makes runs with `HOME` (and, on Windows, `APPDATA`) pointed at a directory created fresh for this run, instead of the real one, so the cached credential lands there instead of the shared, per-user `~/.subversion`, and the whole directory is deleted at the end regardless of how the run finishes. `svn --config-dir` looks like the more direct way to scope this, and an earlier version used it, but it doesn't fully work, verified directly, `git svn clone` still prompted interactively for a password when pointed at a `--config-dir` a plain `svn info` had already cached one into, it doesn't route authentication through a custom config-dir the way it does config file settings. Overriding `HOME` is what svn's own credential lookup actually keys off, confirmed the same way, by seeding a credential and then having `git svn clone` reuse it successfully under an overridden `HOME` with no further prompting.
- A GitHub personal access token or GitHub App installation token, scoped to create and push to repositories in the destination organization. Set it as `GITHUB_TOKEN`, a pipeline secret, never in plain text in the pipeline definition or in source. It authenticates the push through an HTTP header and is never written to disk or to git config. It also never appears in argv, for the same `/proc`/`ps` reason as the SVN password, the git push header is set through `GIT_CONFIG_COUNT`/`GIT_CONFIG_KEY_0`/`GIT_CONFIG_VALUE_0` environment variables rather than a `git -c` flag. A second Contrast Scan found the same token still landing in argv a different way in the shell script, all four of its `curl -H "Authorization: token ..."` calls to the GitHub API. Those now go through a `curl -K -` invocation, config including the header piped over stdin instead of passed as a flag, so it never appears in that curl process's argv either. This doesn't apply to the Python or PowerShell versions, neither shells out to curl, `urllib` and `Invoke-RestMethod` set request headers directly over the socket, never via a subprocess's command line.
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

## Every run clones fresh, there is no incremental mode

Earlier versions of these scripts pointed `--workdir` at a persistent, shared pipeline cache and reused it across runs, doing `git svn rebase` instead of a full clone when a previous checkout was found there, to keep large or old SVN histories fast to sync. Two rounds of Contrast Scan against this repository both landed on the same underlying problem with that design, so it was removed rather than patched a third time.

The core issue, a directory in a shared pipeline cache is also writable by whatever else shares that cache, other jobs, other pipelines on the same runner, or lower-privileged builds that run without secrets. Anything able to write to the cache path ahead of a real run could plant its own `.git` directory there, and the scripts would then operate inside it. The first attempt at defending against this compared the checkout's `svn-remote.svn.url` against `--svn-url` and refused to continue on a mismatch, plus neutralized `core.hooksPath` and `core.fsmonitor` on every git call. That's a non-secret value an attacker can simply set to match, and a follow-up scan showed the hooks/fsmonitor neutralization was a denylist of exactly two dangerous config keys out of many: a planted `filter.<name>.smudge` command paired with a planted `.gitattributes` executes during `git svn rebase`'s checkout step the same way a hook would, `credential.helper` can be planted to exfiltrate a token on a 401, `http.proxy` plus `http.sslVerify=false` can MITM the push even with the token header correctly scoped to the right URL, and a `.git` planted as a gitlink *file* rather than a directory slipped past the reuse check entirely and fell through to the clone path, which didn't apply any of the hardening in the first place. There is no complete list of git config keys that can execute a command or weaken a connection, so a denylist against a directory something else can write to was never going to hold up.

The fix that actually closes this is not reusing a pre-existing directory at all. Every run now:

- Refuses outright if `--workdir` already exists, in any form, file, directory, or symlink, rather than branching into a reuse path. Point it at a path that doesn't exist yet, a build ID or timestamp in the path works well.
- Clones the full SVN history fresh every time. For a large or old repository this is slower than incremental reuse was, that's the real cost of closing this class of finding, there wasn't a version of "trust a directory something else can write to" that held up under a second and third look.
- Still applies `-c core.hooksPath=<empty temp dir> -c core.fsmonitor=` to every git call, including the clone itself now, as cheap defense in depth, but this is no longer the thing standing between an attacker and code execution, a fresh directory this run just created is.

Pushing with `--mirror` keeps the GitHub repo a faithful mirror of SVN, including deleting branches on GitHub that no longer exist in SVN. That's appropriate here since GitHub's only role is to give Contrast something to scan, not to be a second source of truth, and it's also only safe because every ref in the workdir being mirrored now genuinely came from this run's own `git svn clone`, not from whatever refs happened to be sitting in a reused directory.

If a pipeline genuinely needs faster repeated syncs of a very large SVN history, that has to be solved above this script, with infrastructure that gives the workdir path real exclusive-write isolation, a dedicated ephemeral runner per pipeline, or a directory permissioned so only the pipeline's own service account can write to it, not a generic shared cache path. These scripts don't attempt to verify that guarantee, since there's no reliable way to verify OS-level isolation from inside the script itself, so they don't offer a reuse mode at all.

## Repository creation

Each script creates the destination GitHub repository automatically through the GitHub REST API if it doesn't already exist, so the first build for a given SVN project doesn't require a manual step. Per GitHub's guidance, the repo is created without a README, license, or `.gitignore`, since the mirrored history brings its own content and an initial commit on GitHub would conflict with the mirror push.

The scripts check whether the destination account is an organization or a personal account before creating anything, GitHub uses a different API endpoint for each (`POST /orgs/{org}/repos` versus `POST /user/repos`), and calling the wrong one for a personal account fails with a 404 rather than the expected already-exists response. This was caught during live testing against a personal account and fixed, in normal production use the destination is almost always an organization, but the check costs nothing and avoids a confusing failure if that ever isn't the case.

A repository that already exists under the target name isn't necessarily one this pipeline created. In an org that allows members to create their own repositories, which is GitHub's default, anyone who knows (or guesses) the naming convention documented above could pre-create the destination repo, public and under their own control, before the pipeline's first run ever fires. The original create-then-422-means-exists logic had no way to tell a legitimate rerun apart from that. A Contrast Scan flagged this, so whenever the repository is found to already exist, whether through the initial existence check or a 422 on creation, the scripts fetch it and confirm it's actually private and actually owned by the expected org or account before pushing anything, refusing otherwise.

Private and org-owned isn't the full story either, and a follow-up scan pointed at the gap directly, that check defeats a public-repo squat and a personal-account squat, but not the scenario named in its own original comment: a low-privileged org member, in an org that allows members to create private repositories, which is also common, pre-creates a *private* repo under the org with the target name. That repo is private and owned by the org, so both checks pass, but its creator still holds the admin role on it as a direct collaborator, distinct from access via org or team membership. The scripts now additionally list direct collaborators on a pre-existing repo when the destination is an organization (confirmed against the real API, a repo's owner shows up here with `permissions.admin: true`) and refuse to push unless every direct collaborator is in `--allowed-admins`, a comma-separated list of GitHub logins, which defaults to empty. A personal-account destination skips this check, the account itself always shows up as a collaborator there, that's normal, not a squatting signal the way an unexpected collaborator on an org repo is, and the existing owner-login check already fully covers that case.

If your pipeline's own identity legitimately needs to be a direct collaborator on destination repos, rather than getting access through org or team membership, pass its login in `--allowed-admins` explicitly.

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
| Work directory | no | Where the fresh git-svn checkout is created, defaults to `svn-import/<repo>`. Must not already exist, see "Every run clones fresh" above |
| GitHub host | no | Defaults to `github.com`, set to a GitHub Enterprise Server hostname otherwise |
| Allowed admins | no | Comma-separated GitHub logins permitted to be direct collaborators on a pre-existing destination repo under an organization. Defaults to none |

Environment variables, all pipeline secrets, never plain text:

- `GITHUB_TOKEN`, required
- `SVN_USERNAME` and `SVN_PASSWORD`, optional, only needed if the SVN server requires authentication

## Native command failures must stop the script

`$ErrorActionPreference = "Stop"` in the PowerShell script only governs PowerShell cmdlets, it does nothing for native executables like `git` and `svn`, which signal failure solely through `$LASTEXITCODE`. A Contrast Scan found that this was checked in exactly one place (`git svn --version`) and nowhere else, meaning a failed or partial `git svn rebase`, `git svn clone`, or `git push --mirror` fell straight through to the next step instead of stopping the run. The practical failure mode is quiet, a broken SVN connection or a commit from an author missing in `authors.txt` could make the rebase fail, and the script would still print "Done" and exit 0, so the pipeline step reports success while Contrast keeps scanning stale code. Every native call that matters now checks `$LASTEXITCODE` and throws on a nonzero result.

The PowerShell script has since been run end to end for real, against a real authenticated SVN server and a real GitHub push, not just syntax-checked, that gap is closed as of this round. See `TESTING.md`.

## Files in this folder

- `import_svn_to_github.sh`, POSIX shell version
- `import_svn_to_github.py`, Python 3 version, standard library only, no extra packages to install
- `Import-SvnToGitHub.ps1`, PowerShell version
