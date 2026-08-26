# SVN to GitHub Migration for Contrast Scan

Migrate source code from a Subversion (SVN) repository into a private GitHub repository so [Contrast Scan](https://www.contrastsecurity.com/contrast-scan) can pick it up on push.

GitHub [deprecated its built-in SVN importer](https://github.blog/changelog/2024-04-17-updates-to-github-importer-and-the-deprecation-of-the-source-import-rest-api-endpoint/) in April 2024 and [sunset SVN protocol support](https://github.blog/changelog/2024-01-08-subversion-has-been-sunset/) the same year. The only remaining path is `git svn` from the command line. These scripts automate that process end to end, including creating the destination repository, verifying its ownership, and pushing the converted history.

## What's in this repo

| File | Description |
| --- | --- |
| `import_svn_to_github.sh` | POSIX shell version of the SVN migration script |
| `import_svn_to_github.py` | Python 3 version (standard library only, no extra packages) |
| `Import-SvnToGitHub.ps1` | PowerShell version |
| `import_files_to_github.sh` | Convenience script to push a plain local folder (not SVN) to GitHub |
| `GETTING_STARTED.md` | Step-by-step instructions with copy-paste commands |
| `REQUIREMENTS.md` | Design rationale, security model, and edge cases |
| `TESTING.md` | How to test in a throwaway Docker container |
| `Dockerfile` | Test container setup |
| `run_svn_test.sh` | Interactive test harness for the Docker container |

All three SVN scripts do the same thing. Use whichever one your pipeline runner can execute.

## Quick start

### Prerequisites

- `git` with the `git-svn` component installed (`apt-get install git-svn` on Debian/Ubuntu)
- `svn` (the Subversion command line client)
- One of: Python 3, PowerShell 5.1+, or a POSIX shell with `curl` and `base64`
- A GitHub personal access token with the `repo` scope, or a GitHub App installation token

### 1. Build an authors file

Map SVN usernames to Git authors. Generate a starting point from your SVN repo:

```sh
svn log -q YOUR_SVN_URL | grep -e '^r' | awk 'BEGIN { FS = "|" } ; { print $2" = "$2 }' | sed -E 's/^ *//' | sort | uniq > authors.txt
```

Then edit `authors.txt` so each line reads:

```
svnuser = Real Name <email@example.com>
```

### 2. Set credentials as environment variables

```sh
export GITHUB_TOKEN="your-token"       # required
export SVN_USERNAME="your-svn-user"    # only if SVN requires auth
export SVN_PASSWORD="your-svn-pass"    # only if SVN requires auth
```

Never put these in a script file or shell history. Use your CI platform's secret management.

### 3. Run the migration

```sh
./import_svn_to_github.sh \
  --svn-url "https://svn.example.com/myproject" \
  --github-org "your-org" \
  --github-repo "your-repo" \
  --authors-file "./authors.txt"
```

The script creates the destination repository if it doesn't exist, clones the full SVN history, and pushes it. On success, the last line is:

```
Done. GitHub will trigger the Contrast Scan integration from this push.
```

See [GETTING_STARTED.md](GETTING_STARTED.md) for the Python and PowerShell equivalents, optional flags, and the local-folder workflow using `import_files_to_github.sh`.

## If your SVN repository is too large

GitHub enforces a hard limit around 2 GB per push. If the full history exceeds that, add `--snapshot-only` to import just the current revision as a single commit with no history:

```sh
./import_svn_to_github.sh \
  --svn-url "https://svn.example.com/myproject" \
  --github-org "your-org" \
  --github-repo "your-repo" \
  --snapshot-only
```

No authors file is needed in this mode. See "Repositories too large to push with full history" in [REQUIREMENTS.md](REQUIREMENTS.md) for details.

## Security model

These scripts handle credentials (GitHub tokens, SVN passwords) and push proprietary source code. The security design is documented in [REQUIREMENTS.md](REQUIREMENTS.md). The highlights:

- **Credentials stay out of process argv.** The GitHub token and SVN password are passed via environment variables and stdin, never as command-line arguments (which are visible to other users via `ps` on shared machines).
- **Fresh workdir every run.** The scripts refuse to operate on a pre-existing directory, preventing a class of attack where a planted `.git/config` in a shared CI cache could execute code or exfiltrate credentials.
- **Destination repo verification.** Before pushing, the scripts confirm the target repository is private, owned by the expected account, and (for organizations) has no unexpected direct collaborators. This guards against name-squatting.
- **Isolated SVN credential cache.** SVN credentials are cached in a per-run temp directory (not `~/.subversion`) and cleaned up on exit.
- **Token scoping.** The GitHub auth header is scoped to the exact destination URL via `GIT_CONFIG_*` environment variables, so a redirect or `insteadOf` rewrite in git config cannot send the token to a different host.

## Running on a corporate network with TLS inspection

If your CI runner sits behind a TLS-inspecting proxy (Netskope, Zscaler, etc.), you need to trust the proxy's CA certificate. See "TLS-inspecting corporate proxies" in [REQUIREMENTS.md](REQUIREMENTS.md) for the exact environment variables each script needs.

## Things to know before running in production

- **Every run clones fresh.** There is no incremental mode. If you run the same command twice with the same `--workdir`, the second run refuses. Pass a fresh `--workdir` each time (a build number or timestamp works well) or delete the old one between runs. See [REQUIREMENTS.md](REQUIREMENTS.md) for why this is intentional.
- **`--mirror` push is destructive.** The push replaces all content in the destination repo. Do not point this at a repository that contains unrelated work.
- **Large files.** If a push fails because a file exceeds GitHub's size limits, see "Large files" in [REQUIREMENTS.md](REQUIREMENTS.md) for the `git lfs migrate` workaround.
- **GitHub Enterprise Server.** Pass `--github-host your-ghes-hostname` to target a GHES instance instead of github.com.

## Testing

See [TESTING.md](TESTING.md) for how to test the scripts in a disposable Docker container without touching real SVN or GitHub repos.

## License

This project is provided as-is for use with Contrast Security products.
