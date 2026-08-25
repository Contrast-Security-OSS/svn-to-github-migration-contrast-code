# Running this against your own SVN repo and GitHub repo

This is the practical, copy-paste version, exact commands to run the migration against a real SVN repository and a real GitHub destination. For why the scripts are built the way they are, see `REQUIREMENTS.md`. For testing the scripts themselves in a throwaway sandbox instead of your real repos, see `TESTING.md`.

You can run any of the three scripts directly on your own machine or CI runner, Docker isn't required for real use, it was only used in `TESTING.md` to build a disposable sandbox.

## Step 1, confirm the tools are installed

Pick whichever script matches what's available, then check its dependencies.

```
git --version
git svn --version
svn --version
```

If `git svn --version` fails, `git-svn` is a separate package on most systems, `apt-get install git-svn` on Debian/Ubuntu, `dnf install git-svn` on Fedora/RHEL, bundled with Git for Mac (Homebrew) and Windows.

Then, depending on which script you're running:

```
# shell version
curl --version
base64 --version

# Python version
python3 --version

# PowerShell version
pwsh --version
```

## Step 2, gather what you need

- The SVN URL you want to import. If it uses the standard `trunk`/`branches`/`tags` layout, point at the repository root, e.g. `https://svn.example.com/myproject`. If it doesn't use that layout, see the note in `REQUIREMENTS.md` under "SVN repository layout" before running anything.
- SVN credentials, only if the server requires them. Anonymous/`file://` access needs nothing here.
- The destination GitHub organization or username, and the repository name you want it to land in. If that repo doesn't exist yet, the script creates it, private, for you.
- A GitHub token with permission to create and push repositories in that destination, a personal access token with the `repo` scope, or a GitHub App installation token. Create one at https://github.com/settings/tokens if you don't already have one.

## Step 3, build the authors file

Every script requires `--authors-file`/`-AuthorsFile`, mapping SVN usernames to a Git name and email. Generate a starting point directly from your SVN repo:

```
svn log -q YOUR_SVN_URL | grep -e '^r' | awk 'BEGIN { FS = "|" } ; { print $2" = "$2 }' | sed -E 's/^ *//' | sort | uniq > authors.txt
```

Then open `authors.txt` and fill in a real name and email for each line, it should look like:

```
jsmith = Jane Smith <jane.smith@example.com>
```

## Step 4, run it

Replace every `YOUR_...` placeholder below with your real values. `GITHUB_TOKEN` is a pipeline secret, export it as an environment variable, never put it directly in a command you'll save to shell history or a script file. Same for `SVN_USERNAME`/`SVN_PASSWORD`, only needed if your SVN server requires authentication.

### Shell (`import_svn_to_github.sh`)

```
export GITHUB_TOKEN="YOUR_GITHUB_TOKEN"
# only if your SVN server requires auth:
export SVN_USERNAME="YOUR_SVN_USERNAME"
export SVN_PASSWORD="YOUR_SVN_PASSWORD"

./import_svn_to_github.sh \
  --svn-url "YOUR_SVN_URL" \
  --github-org "YOUR_GITHUB_ORG_OR_USERNAME" \
  --github-repo "YOUR_DESTINATION_REPO_NAME" \
  --authors-file "./authors.txt"
```

### Python (`import_svn_to_github.py`)

```
export GITHUB_TOKEN="YOUR_GITHUB_TOKEN"
export SVN_USERNAME="YOUR_SVN_USERNAME"
export SVN_PASSWORD="YOUR_SVN_PASSWORD"

python3 import_svn_to_github.py \
  --svn-url "YOUR_SVN_URL" \
  --github-org "YOUR_GITHUB_ORG_OR_USERNAME" \
  --github-repo "YOUR_DESTINATION_REPO_NAME" \
  --authors-file "./authors.txt"
```

### PowerShell (`Import-SvnToGitHub.ps1`)

```powershell
$env:GITHUB_TOKEN = "YOUR_GITHUB_TOKEN"
$env:SVN_USERNAME = "YOUR_SVN_USERNAME"
$env:SVN_PASSWORD = "YOUR_SVN_PASSWORD"

./Import-SvnToGitHub.ps1 `
  -SvnUrl "YOUR_SVN_URL" `
  -GitHubOrg "YOUR_GITHUB_ORG_OR_USERNAME" `
  -GitHubRepo "YOUR_DESTINATION_REPO_NAME" `
  -AuthorsFile "./authors.txt"
```

All three print progress as they go, seeding credentials if needed, checking or creating the destination repo, cloning the full SVN history, then pushing. The last line on success is `Done. GitHub will trigger the Contrast Scan integration from this push.`

## If your SVN repository is too large to push with full history

GitHub enforces a hard limit around 2GB on a single push. A full-history clone of an old or large SVN repository can easily exceed that, even when the current code itself is small, since it converts every past revision, not just the current one. If a normal run fails on push size, or you already know your SVN repository's total history is in that range, add `--snapshot-only` (`-SnapshotOnly` in PowerShell). This imports only the current revision as a single commit, no history, which is usually all Contrast Scan needs anyway. See "Repositories too large to push with full history" in `REQUIREMENTS.md` for the full explanation.

In this mode, drop `--authors-file` entirely, it's not used, and optionally set `--commit-author`/`-CommitAuthor` to something more meaningful than the default:

```
# shell
./import_svn_to_github.sh \
  --svn-url "YOUR_SVN_URL" \
  --github-org "YOUR_GITHUB_ORG_OR_USERNAME" \
  --github-repo "YOUR_DESTINATION_REPO_NAME" \
  --snapshot-only \
  --commit-author "Your Name <you@example.com>"

# Python
python3 import_svn_to_github.py \
  --svn-url "YOUR_SVN_URL" \
  --github-org "YOUR_GITHUB_ORG_OR_USERNAME" \
  --github-repo "YOUR_DESTINATION_REPO_NAME" \
  --snapshot-only \
  --commit-author "Your Name <you@example.com>"
```

```powershell
# PowerShell
./Import-SvnToGitHub.ps1 `
  -SvnUrl "YOUR_SVN_URL" `
  -GitHubOrg "YOUR_GITHUB_ORG_OR_USERNAME" `
  -GitHubRepo "YOUR_DESTINATION_REPO_NAME" `
  -SnapshotOnly `
  -CommitAuthor "Your Name <you@example.com>"
```

`GITHUB_TOKEN`, and `SVN_USERNAME`/`SVN_PASSWORD` if needed, are set the same way as Step 4.

## Step 5, verify the result

Open the destination repository on GitHub. You should see your SVN project's files. With the default full-history mode, the commit history has one commit per SVN revision, each with a `git-svn-id:` trailer naming its source revision. With `--snapshot-only`, there's exactly one commit, named after the SVN revision it was exported from, and no history before it.

## Things to know before running this for real

- **Every run clones the full SVN history, there's no incremental mode.** If you run the same command twice with the same `--workdir`, the second run refuses rather than reusing it, this is intentional, see "Every run clones fresh" in `REQUIREMENTS.md`. If you don't pass `--workdir` at all, it defaults to `svn-import/<repo>` in the current directory, which means running the command a second time from the same directory will hit that same refusal. Either delete that directory between runs, or pass a fresh `--workdir` each time, e.g. one that includes a build number or timestamp in a pipeline.
- **The destination repo, if it already exists, must be private and owned by the account or org you named.** If it's under an organization, the scripts also check that no unexpected person has direct collaborator access to it, guarding against someone else having pre-created it. If your own pipeline identity is a legitimate direct collaborator rather than getting access through org or team membership, pass `--allowed-admins`/`-AllowedAdmins` with that login, comma-separated if there's more than one.
- **Large files.** If a push fails or warns about a file over GitHub's size limits, see "Large files" in `REQUIREMENTS.md`, this isn't handled automatically.
- **A TLS-inspecting corporate proxy or VPN** (Netskope and similar) will break the GitHub API calls with a certificate error unless its CA certificate is trusted on the machine running the script. See "TLS-inspecting corporate proxies" in `REQUIREMENTS.md` for the exact environment variables each script needs.
- **GitHub Enterprise Server** instead of github.com, pass `--github-host`/`-GitHubHost` with your GHES hostname.
- **Repository too large for a single push.** See "If your SVN repository is too large to push with full history" above, `--snapshot-only` trades full history for a push that actually fits.

## If something goes wrong

The full list of error messages and what they mean is in `TESTING.md` under "If something fails", it was written against a sandbox but every message there is the same one you'd see against a real repo.
