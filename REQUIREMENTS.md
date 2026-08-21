# SVN to GitHub Migration for Contrast Scan, Requirements

## Purpose

Contrast Scan integrates with GitHub, not Subversion. To get Contrast Scan running as part of the build pipeline, source code needs to land in a GitHub repository before Contrast can scan it. This document covers what's needed to convert an SVN repository to Git and push it to GitHub as part of the pipeline, using GitHub's documented command line import process.

Reference, the process these scripts follow:
https://docs.github.com/en/migrations/importing-source-code/using-the-command-line-to-import-source-code/importing-a-subversion-repository

## Assumptions and out of scope

- GitHub is already integrated with Contrast at the organization level, through a GitHub App, webhook, or GitHub Action that triggers Contrast Scan on push. This document only covers getting code from SVN into GitHub, not configuring that integration.
- Contrast Scan results are stored in Contrast automatically once the scan runs, no separate step is needed here.
- The three scripts in this folder do the same thing. Use whichever one the pipeline's runner/agent can actually execute.

## Tooling requirements on the pipeline runner or agent

- `git`, with the `git-svn` component installed. On Debian and Ubuntu this is a separate package, `git-svn`. On RPM-based systems it's also separate, usually `git-svn` or bundled in `perl-Git-SVN`.
- `svn`, the Subversion command line client.
- `git-lfs`, in case any files exceed GitHub's size limits and need migrating to Git LFS. Not invoked automatically by these scripts, see Large Files below.
- `curl` and `base64`, for the shell script only.
- One of Python 3, PowerShell 5.1 or 7+, or a POSIX shell, matching whichever script the pipeline runs.
- Network access from the runner to both the SVN server and github.com, or the GitHub Enterprise Server host if self-hosted.

## Credentials and access

- SVN read access to the source repository. If the SVN server requires authentication, set `SVN_USERNAME` and `SVN_PASSWORD` as pipeline secrets, the scripts use them to seed the SVN credential cache before running `git svn`.
- A GitHub personal access token or GitHub App installation token, scoped to create and push to repositories in the destination organization. Set it as `GITHUB_TOKEN`, a pipeline secret, never in plain text in the pipeline definition or in source. It's used in an HTTP auth header for the git push and is never written to disk or to git config.
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

## Repository creation

Each script creates the destination GitHub repository automatically through the GitHub REST API if it doesn't already exist, so the first build for a given SVN project doesn't require a manual step. Per GitHub's guidance, the repo is created without a README, license, or `.gitignore`, since the mirrored history brings its own content and an initial commit on GitHub would conflict with the mirror push.

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

## Files in this folder

- `import_svn_to_github.sh`, POSIX shell version
- `import_svn_to_github.py`, Python 3 version, standard library only, no extra packages to install
- `Import-SvnToGitHub.ps1`, PowerShell version
