# Testing the SVN to GitHub migration scripts

This walks through testing the migration scripts end to end in a throwaway Debian container, using a real local SVN repository and a real GitHub push.

Everything runs inside Docker so nothing touches your actual machine's package set, and the SVN repository created here is temporary, it lives only inside the container.

All three scripts, `import_svn_to_github.sh`, `import_svn_to_github.py`, and `Import-SvnToGitHub.ps1`, have now been run this way against a real throwaway GitHub repository, and all three worked, a file committed inside the container's SVN repo landed on GitHub with the correct commit history. Several real bugs turned up along the way, across two separate rounds of Contrast Scan against this repository, and are already fixed in all three scripts, see the notes inline below and in `REQUIREMENTS.md`. `Import-SvnToGitHub.ps1` needed PowerShell installed in the test container to exercise the same way, that's a separate step below since it isn't in Debian's default repos.

## What you need before starting

- Docker installed and running locally
- A GitHub personal access token with permission to create and push repositories in the target org, scoped narrowly to a throwaway test org or your own account, not a production token
- A folder of a few real files on your machine you don't mind committing into a test SVN repo, used to prove the tool moves real content, not just empty commits
- If you're behind a TLS-inspecting corporate proxy or VPN, Netskope is a common one, a copy of that proxy's CA certificate bundle. Without it, the container can't make HTTPS calls to GitHub at all, see Step 2

## Step 1, pull a Debian image

```
docker pull debian:latest
```

## Step 2, start the container with the right mounts

Two things need to be visible inside the container, the migration scripts folder, and a folder of files to pick from when the test script asks what to commit.

```
docker run -it --rm \
  --name svn-migration-test \
  -v "/Users/jasoneasterday/Development/git/svn-to-github-migration:/scripts:ro" \
  -v "$HOME/Documents:/host-files:ro" \
  debian:latest bash
```

Swap `$HOME/Documents` for whatever folder has files you're comfortable test-committing. On Docker Desktop for Mac, the path you mount has to be under a shared location, `/Users` and `/private/tmp` work by default, `/Library` doesn't unless you add it under Docker's file sharing settings.

If you're behind a TLS-inspecting proxy or VPN, add the proxy's CA bundle as a third mount and point `curl` and `git` at it, otherwise every HTTPS call to GitHub inside the container fails with a certificate error before you even get to the SVN part. For Netskope on a Mac, the bundle usually lives at `/Library/Application Support/Netskope/STAgent/data/netskope-cert-bundle.pem`, copy it somewhere under `/Users` or `/private/tmp` first since `/Library` won't mount directly, then:

```
docker run -it --rm \
  --name svn-migration-test \
  -e CURL_CA_BUNDLE=/etc/ssl/certs/proxy-ca-bundle.pem \
  -e GIT_SSL_CAINFO=/etc/ssl/certs/proxy-ca-bundle.pem \
  -e SSL_CERT_FILE=/etc/ssl/certs/proxy-ca-bundle.pem \
  -v "/Users/jasoneasterday/Development/git/svn-to-github-migration:/scripts:ro" \
  -v "$HOME/Documents:/host-files:ro" \
  -v "/path/to/your/copied-cert-bundle.pem:/etc/ssl/certs/proxy-ca-bundle.pem:ro" \
  debian:latest bash
```

`SSL_CERT_FILE` is only needed if you're testing `import_svn_to_github.py`, `curl` and `git` only look at the first two.

Everything from here runs inside the container's shell.

## Step 3, install Subversion and the tools the migration script needs

Per the official package list at https://subversion.apache.org/packages.html, Debian installs the SVN client and the Apache module as separate packages:

```
apt-get update
apt-get install -y subversion libapache2-mod-svn git git-svn curl ca-certificates
```

`libapache2-mod-svn` isn't actually required for this test, it's only needed if you want SVN served over HTTP through Apache rather than accessed as a local `file://` path. This test uses `file://`, since `git svn` behaves the same way against it as it does against a real `http://` or `https://` SVN server, and it avoids setting up Apache virtual hosts and auth just to prove the migration logic works. It's included in the install command since you asked for it, and it's there if you want to extend this test to serve the repo over HTTP later.

`git-svn` is the actual dependency the migration script needs, along with `curl` for the GitHub API call it makes to create the destination repository.

## Step 4, run the test script

The scripts are already executable on the host, and `/scripts` is mounted read-only, so don't try to `chmod` them inside the container, that fails against a read-only mount and isn't needed anyway.

```
/scripts/run_svn_test.sh
```

## Step 5, what the script does, step by step

1. Creates a fresh SVN repository at `/svn-repos/testrepo` with `svnadmin create`, if one doesn't already exist in this container, and sets up a standard `trunk`, `branches`, `tags` layout inside it
2. Checks out a working copy of `trunk` to `/work/testrepo-wc`
3. Lists files under `/host-files` and asks you to type the path to one or more files to commit, repeating until you leave the prompt blank
4. Copies each selected file into the working copy, `svn add`s it, and asks for a commit message
5. Runs `svn status`, `svn log`, and `svn list` so you can see the repository actually has your files and history in it, this is the point where you'd catch a problem with the SVN side before ever touching GitHub
6. Writes a minimal `authors.txt` for this test run, mapping the container's current user to a placeholder name and email, since the test only has one committer
7. Asks whether to migrate to GitHub now
8. If yes, asks for the GitHub repository URL, a username, and a personal access token
   The username is captured for the record only, `import_svn_to_github.sh` authenticates with the token alone, not a username and password, so nothing in the migration script actually reads what you type there. Enter something to move past the prompt, it isn't validated against GitHub.
9. Parses the org and repo name out of the URL you gave it and calls `import_svn_to_github.sh` with `--svn-url file:///svn-repos/testrepo`, pointing at the repository created in step 1

## Step 6, verify the result

Once the script finishes, check the destination GitHub repository in a browser. You should see the file or files you picked, and a commit history entry matching the message you gave and the committer name from the generated `authors.txt`.

The migration script always clones fresh and refuses to reuse a pre-existing `--workdir`, on purpose, see "Every run clones fresh, there is no incremental mode" in `REQUIREMENTS.md` for why. `run_svn_test.sh` accounts for this itself, generating a new `--workdir` path each time it runs, so running it a second time to commit and migrate another file works, and you'll see the second run's fresh clone pick up the full history, both commits, not just the new one. If you invoke `import_svn_to_github.sh`/`.py`/`.ps1` directly with a fixed `--workdir` and run it twice, the second run refuses with "it already exists," that's expected, point it at a different path.

## Step 7, testing the PowerShell version

`Import-SvnToGitHub.ps1` needs PowerShell in the container, which isn't in Debian's default apt repos. Find the right release for the container's architecture (this is an arm64 example, matching Apple Silicon Docker Desktop, swap for `linux-x64` on an Intel host) rather than guessing a version, then install it in the same container from Step 2:

```
apt-get install -y libicu-dev
curl -sL "$(gh api repos/PowerShell/PowerShell/releases/latest --jq '.assets[] | select(.name | test("linux-arm64.tar.gz$")) | .browser_download_url')" -o /tmp/pwsh.tar.gz
mkdir -p /opt/microsoft/powershell/7
tar zxf /tmp/pwsh.tar.gz -C /opt/microsoft/powershell/7
chmod +x /opt/microsoft/powershell/7/pwsh
ln -s /opt/microsoft/powershell/7/pwsh /usr/bin/pwsh
```

If you're behind a TLS-inspecting proxy, `Invoke-RestMethod` doesn't honor `SSL_CERT_FILE`/`CURL_CA_BUNDLE` the way curl, git, and Python do, it uses .NET's own certificate handling. Install the proxy's CA into the container's trust store instead of pointing an env var at it:

```
cp /etc/ssl/certs/proxy-ca-bundle.pem /usr/local/share/ca-certificates/proxy.crt
update-ca-certificates
```

Then run the same shape of command as Step 4, using named parameters instead of the script's interactive prompts (there's no PowerShell equivalent of `run_svn_test.sh` yet):

```
pwsh -NoProfile -File /scripts/Import-SvnToGitHub.ps1 \
  -SvnUrl file:///svn-repos/testrepo \
  -GitHubOrg your-org-or-account \
  -GitHubRepo your-test-repo \
  -AuthorsFile /work/authors.txt \
  -WorkDir /work/pwsh-git-svn-clone
```

## Cleaning up

The container is started with `--rm`, so exiting the shell (`exit`) tears down everything inside it, the SVN repository, the working copy, and the local git-svn clone. Nothing persists between runs unless you add a volume for `/svn-repos` and `/work` yourself.

On the GitHub side, delete the test repository when you're done, this test creates a real repository through the API, it doesn't simulate that step.

## If something fails

- `git-svn is not installed`, the container is missing the `git-svn` package, re-run the `apt-get install` from Step 3
- `SSL certificate problem: self-signed certificate in certificate chain` on any `curl` or `git push` call, you're behind a TLS-inspecting proxy and haven't mounted its CA bundle, see the proxy note in Step 2
- `CA cert does not include key usage extension` from the Python script specifically, even with `SSL_CERT_FILE` set correctly, this is already handled in `import_svn_to_github.py`, see the TLS-inspecting corporate proxies note in `REQUIREMENTS.md` for why
- The GitHub API call in `import_svn_to_github.sh` returns anything other than repository created or already exists, double check the token's scopes and that it has access to the org you gave it
- `svn: E200009` or similar on commit, usually means nothing was staged, check that the file path you typed at the prompt actually resolved under `/host-files`
- `No history was imported from ...`, the SVN URL doesn't have a `trunk` directory at its root, `git svn clone -s` needs the standard layout, this test script sets one up automatically, but a real source repository that doesn't use it will hit this too, see the SVN repository layout note in `REQUIREMENTS.md`
- `Refusing to use ... it already exists`, you pointed `--workdir`/`-WorkDir` at a path from a previous run. This is intentional, see "Every run clones fresh, there is no incremental mode" in `REQUIREMENTS.md`, point it at a path that doesn't exist yet
- `Refusing to push: ... has a direct collaborator ... that isn't in --allowed-admins`, the destination repo already exists under an organization and has a collaborator this run wasn't told to trust. If that's actually expected, e.g. the pipeline's own bot account, pass `--allowed-admins`/`-AllowedAdmins` with that login
- On the PowerShell version specifically, authentication or API errors that don't reproduce on the shell or Python versions in the same container are usually the TLS trust store, see Step 7, `Invoke-RestMethod` needs the proxy CA installed system-wide, an env var pointed at the bundle does nothing for it
