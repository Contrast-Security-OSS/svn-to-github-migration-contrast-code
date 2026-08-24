#!/usr/bin/env python3
"""Import an SVN repository into GitHub so Contrast Scan can pick it up on push.

Follows https://docs.github.com/en/migrations/importing-source-code/using-the-command-line-to-import-source-code/importing-a-subversion-repository
"""
import argparse
import base64
import json
import os
import shutil
import ssl
import subprocess
import sys
import tempfile
import urllib.error
import urllib.request


def which_or_die(tool):
    if shutil.which(tool) is None:
        sys.exit(f"Required tool not found: {tool}")


def run(cmd, cwd=None, input=None, env=None):
    subprocess.run(cmd, cwd=cwd, input=input, env=env, check=True)


def build_ssl_context():
    # Some corporate TLS-inspecting proxies issue a CA certificate that's
    # missing the keyUsage extension. That's tolerated by curl and git, but
    # OpenSSL 3.x's strict X.509 checks, on by default in this ssl module,
    # reject it outright. This turns that one conformance check off without
    # touching anything else the standard context verifies, chain of trust,
    # expiry, and hostname checks all still apply.
    ctx = ssl.create_default_context()
    if hasattr(ssl, "VERIFY_X509_STRICT"):
        ctx.verify_flags &= ~ssl.VERIFY_X509_STRICT
    return ctx


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--svn-url", required=True)
    parser.add_argument("--github-org", required=True)
    parser.add_argument("--github-repo", required=True)
    parser.add_argument("--authors-file", required=True)
    parser.add_argument("--workdir", default=None)
    parser.add_argument("--github-host", default="github.com")
    args = parser.parse_args()

    token = os.environ.get("GITHUB_TOKEN")
    if not token:
        sys.exit("GITHUB_TOKEN environment variable is required")
    svn_username = os.environ.get("SVN_USERNAME")
    svn_password = os.environ.get("SVN_PASSWORD")

    workdir = args.workdir or os.path.join("svn-import", args.github_repo)
    api_base = (
        "https://api.github.com"
        if args.github_host == "github.com"
        else f"https://{args.github_host}/api/v3"
    )

    for tool in ("git", "svn"):
        which_or_die(tool)
    try:
        subprocess.run(
            ["git", "svn", "--version"],
            check=True,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
    except (subprocess.CalledProcessError, FileNotFoundError):
        sys.exit("git-svn is not installed")

    # core.hooksPath is redirected to this empty directory, and core.fsmonitor
    # is cleared, on every git invocation that touches workdir. Without this,
    # a workdir reused from a shared/cached CI path could carry a planted
    # .git/hooks/* script or a core.fsmonitor command that executes arbitrary
    # code the moment git refreshes its index, e.g. during 'git svn rebase'.
    hooks_neutralize_dir = tempfile.mkdtemp()
    safe_git_args = ["-c", f"core.hooksPath={hooks_neutralize_dir}", "-c", "core.fsmonitor="]

    def safe_git(args_, cwd=None, env=None):
        run(["git", *safe_git_args, *args_], cwd=cwd, env=env)

    svn_auth_seeded = False

    def cleanup():
        # The SVN credential only needs to live on disk long enough for the
        # git-svn calls below to read it, git-svn has no way to accept a
        # password directly. Remove it again once this run is done, success
        # or failure, rather than leaving it in the shared auth cache
        # indefinitely.
        if svn_auth_seeded:
            import re

            hostpart = re.sub(r"^([a-zA-Z]+://[^/]+).*", r"\1", args.svn_url)
            subprocess.run(
                ["svn", "auth", "--remove", svn_username, hostpart],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
        shutil.rmtree(hooks_neutralize_dir, ignore_errors=True)

    try:
        if svn_username and svn_password:
            print("Seeding SVN credential cache")
            # --password-from-stdin keeps the password out of argv, where it
            # would otherwise be readable by any local user via
            # /proc/<pid>/cmdline or ps for the duration of this call.
            # store-plaintext-passwords=yes is required for svn to actually
            # cache it, the stock 'ask' default silently declines to persist
            # the password under --non-interactive, which would otherwise
            # make the later git-svn calls fail to authenticate with no
            # cached credential.
            run(
                [
                    "svn",
                    "info",
                    "--non-interactive",
                    "--config-option",
                    "servers:global:store-plaintext-passwords=yes",
                    "--username",
                    svn_username,
                    "--password-from-stdin",
                    args.svn_url,
                ],
                input=svn_password.encode(),
            )
            svn_auth_seeded = True

        print(f"Ensuring GitHub repository {args.github_org}/{args.github_repo} exists on {args.github_host}")

        ssl_context = build_ssl_context()

        def gh_request(url, data=None, method="GET"):
            req = urllib.request.Request(
                url,
                data=json.dumps(data).encode() if data is not None else None,
                headers={
                    "Authorization": f"token {token}",
                    "Accept": "application/vnd.github+json",
                    "Content-Type": "application/json",
                },
                method=method,
            )
            return urllib.request.urlopen(req, context=ssl_context)

        def verify_repo_ownership():
            # A repo that already exists under the target name could have
            # been pre-created by someone else, e.g. a low-privileged org
            # member name-squatting the destination before the pipeline's
            # first run. Confirm it's actually private and owned by the
            # expected account before mirroring proprietary source into it.
            with gh_request(f"{api_base}/repos/{args.github_org}/{args.github_repo}") as resp:
                repo = json.loads(resp.read())
            if not repo.get("private"):
                sys.exit(
                    f"Refusing to push: {args.github_org}/{args.github_repo} is not private."
                )
            owner_login = (repo.get("owner") or {}).get("login", "")
            if owner_login.lower() != args.github_org.lower():
                sys.exit(
                    f"Refusing to push: {args.github_org}/{args.github_repo} is owned by "
                    f"'{owner_login}', not '{args.github_org}'."
                )

        repo_exists = False
        try:
            gh_request(f"{api_base}/repos/{args.github_org}/{args.github_repo}")
            repo_exists = True
        except urllib.error.HTTPError as e:
            if e.code != 404:
                sys.exit(f"Failed to check for existing repository, HTTP {e.code}: {e.read().decode(errors='replace')}")

        if repo_exists:
            print("Repository already exists, verifying it before pushing.")
            verify_repo_ownership()
            print("Ownership and visibility confirmed, continuing.")
        else:
            # POST /orgs/{org}/repos only works when github_org is an
            # organization, personal accounts use POST /user/repos instead,
            # ask the API which kind of account this is before picking one.
            account_type = "User"
            try:
                with gh_request(f"{api_base}/users/{args.github_org}") as resp:
                    account_type = json.loads(resp.read()).get("type", "User")
            except urllib.error.HTTPError:
                pass

            create_url = (
                f"{api_base}/orgs/{args.github_org}/repos"
                if account_type == "Organization"
                else f"{api_base}/user/repos"
            )

            try:
                gh_request(
                    create_url,
                    data={"name": args.github_repo, "auto_init": False, "private": True},
                    method="POST",
                )
                print("Repository created.")
            except urllib.error.HTTPError as e:
                if e.code == 422:
                    print("Repository already exists, verifying it before pushing.")
                    verify_repo_ownership()
                    print("Ownership and visibility confirmed, continuing.")
                else:
                    sys.exit(f"Failed to create repository, HTTP {e.code}: {e.read().decode(errors='replace')}")

        git_dir = os.path.join(workdir, ".git")
        if os.path.isdir(git_dir):
            # A pre-existing workdir is only trustworthy if it's actually a
            # checkout of the SVN URL this run was asked to import, not a
            # directory an attacker planted at the same shared/cached path
            # with a different svn-remote, malicious hooks, or a hijacked
            # push destination.
            existing_svn_url = subprocess.run(
                ["git", *safe_git_args, "config", "--get", "svn-remote.svn.url"],
                cwd=workdir,
                capture_output=True,
                text=True,
            ).stdout.strip()
            if existing_svn_url != args.svn_url:
                sys.exit(
                    f"Refusing to reuse {workdir}: it's configured for SVN URL "
                    f"'{existing_svn_url}', not '{args.svn_url}'. If this is a stale or "
                    "untrusted cache, clear it manually and retry."
                )
            print(f"Existing checkout found at {workdir}, fetching incremental updates")
            safe_git(["svn", "rebase"], cwd=workdir)
        else:
            print(f"No existing checkout, cloning full SVN history to {workdir}")
            parent = os.path.dirname(os.path.abspath(workdir))
            os.makedirs(parent, exist_ok=True)
            clone_cmd = [
                "svn",
                "clone",
                "-s",
                args.svn_url,
                workdir,
                "--authors-file",
                args.authors_file,
            ]
            if svn_username:
                clone_cmd += ["--username", svn_username]
            run(["git", *clone_cmd])

        head_check = subprocess.run(
            ["git", *safe_git_args, "rev-parse", "HEAD"], cwd=workdir, capture_output=True
        )
        if head_check.returncode != 0:
            sys.exit(
                f"No history was imported from {args.svn_url}. This usually means the "
                "repository doesn't use the standard trunk/branches/tags layout that "
                "'git svn clone -s' expects, check the SVN URL and layout before retrying."
            )

        remote_url = f"https://{args.github_host}/{args.github_org}/{args.github_repo}.git"
        existing_remotes = subprocess.run(
            ["git", *safe_git_args, "remote"], cwd=workdir, check=True, capture_output=True, text=True
        ).stdout.split()
        if "origin" in existing_remotes:
            safe_git(["remote", "set-url", "origin", remote_url], cwd=workdir)
        else:
            safe_git(["remote", "add", "origin", remote_url], cwd=workdir)
        # set-url without --push only touches remote.origin.url, a planted
        # remote.origin.pushurl in a reused workdir would otherwise survive
        # and take precedence over it on push.
        safe_git(["remote", "set-url", "--push", "origin", remote_url], cwd=workdir)

        print(f"Pushing mirror to {args.github_org}/{args.github_repo}")
        auth_header = base64.b64encode(f"x-access-token:{token}".encode()).decode()
        # The header is scoped to this exact literal URL (http.<url>.extraheader)
        # rather than applied globally (http.extraheader), and supplied
        # through GIT_CONFIG_* environment variables rather than -c, so it
        # never appears in process argv. Scoping it to the literal URL also
        # means that if a planted pushurl or a url.*.insteadOf rewrite in a
        # reused workdir redirects the connection elsewhere, the header
        # simply won't be attached to that request, since it won't match the
        # URL git actually connects to.
        push_env = {
            **os.environ,
            "GIT_CONFIG_COUNT": "1",
            "GIT_CONFIG_KEY_0": f"http.{remote_url}.extraheader",
            "GIT_CONFIG_VALUE_0": f"AUTHORIZATION: basic {auth_header}",
        }
        safe_git(["push", "--mirror", remote_url], cwd=workdir, env=push_env)

        print("Done. GitHub will trigger the Contrast Scan integration from this push.")
    finally:
        cleanup()


if __name__ == "__main__":
    main()
