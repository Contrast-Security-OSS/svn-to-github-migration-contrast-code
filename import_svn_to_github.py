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
    parser.add_argument("--authors-file", default=None)
    parser.add_argument("--workdir", default=None)
    parser.add_argument("--github-host", default="github.com")
    parser.add_argument(
        "--allowed-admins",
        default="",
        help="Comma-separated GitHub logins permitted to be direct collaborators on a "
        "pre-existing destination repo under an organization. Defaults to none, meaning "
        "any direct collaborator on an existing org repo causes the run to refuse.",
    )
    parser.add_argument(
        "--snapshot-only",
        action="store_true",
        help="Skip SVN history entirely and import just the current revision as a single "
        "commit with no history. Use this when the full SVN history is too large for a "
        "single GitHub push, GitHub enforces a hard limit around 2GB per push. "
        "--authors-file is not required or used in this mode, and --svn-url doesn't need "
        "to point at a trunk/branches/tags layout, any URL within the repository works.",
    )
    parser.add_argument(
        "--commit-author",
        default="SVN Snapshot Import <svn-snapshot-import@localhost>",
        help='Git author and committer, "Name <email>", for the single snapshot commit. '
        "Only used with --snapshot-only.",
    )
    args = parser.parse_args()
    allowed_admins = {a.strip().lower() for a in args.allowed_admins.split(",") if a.strip()}
    if not args.snapshot_only and not args.authors_file:
        parser.error("--authors-file is required unless --snapshot-only is set")

    token = os.environ.get("GITHUB_TOKEN")
    if not token:
        sys.exit("GITHUB_TOKEN environment variable is required")
    svn_username = os.environ.get("SVN_USERNAME")
    svn_password = os.environ.get("SVN_PASSWORD")
    if bool(svn_username) != bool(svn_password):
        sys.exit(
            "SVN_USERNAME and SVN_PASSWORD must be set together when SVN authentication is required"
        )

    workdir = args.workdir or os.path.join("svn-import", args.github_repo)
    api_base = (
        "https://api.github.com"
        if args.github_host == "github.com"
        else f"https://{args.github_host}/api/v3"
    )

    for tool in ("git", "svn"):
        which_or_die(tool)
    if not args.snapshot_only:
        try:
            subprocess.run(
                ["git", "svn", "--version"],
                check=True,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
        except (subprocess.CalledProcessError, FileNotFoundError):
            sys.exit("git-svn is not installed")

    # This script always clones fresh, it never reuses a pre-existing
    # directory. An earlier version tried to validate and reuse a
    # pre-existing workdir for faster incremental syncs, comparing its
    # svn-remote.svn.url against --svn-url before trusting it. That check
    # compares a non-secret value, an attacker able to write to a shared or
    # predictable workdir path can set it to match and pass the gate, then
    # have the planted checkout's own config, hooks, filters, or refs
    # trusted from there. There's no complete fix for that short of not
    # trusting a pre-existing directory at all, so that's what this does,
    # see REQUIREMENTS.md.
    if os.path.exists(workdir):
        sys.exit(
            f"Refusing to use {workdir}: it already exists. This script always creates a "
            "fresh checkout rather than reusing a directory it can't fully vouch for. "
            "Point --workdir at a path that doesn't exist yet."
        )

    # core.hooksPath is redirected to this empty directory, and core.fsmonitor
    # is cleared, on every git invocation this script makes, including the
    # initial clone. A denylist of dangerous config keys was tried here
    # before and found incomplete (filter/merge drivers, credential.helper,
    # http.proxy, and insteadOf rewrites are all separate code-execution or
    # credential-exfiltration vectors it didn't cover), see REQUIREMENTS.md.
    # The actual fix is that this script never operates against a
    # pre-existing directory at all, these two overrides remain as cheap
    # defense in depth, not as the primary control.
    hooks_neutralize_dir = tempfile.mkdtemp()
    safe_git_args = ["-c", f"core.hooksPath={hooks_neutralize_dir}", "-c", "core.fsmonitor="]

    def safe_git(args_, cwd=None, env=None):
        run(["git", *safe_git_args, *args_], cwd=cwd, env=env)

    # Every svn and git-svn call below runs with HOME pointed at this
    # directory instead of the real one, so their config and credential
    # cache land here instead of the shared, per-user ~/.subversion.
    # 'svn --config-dir' looks like the more direct way to do this, but it
    # doesn't fully work, verified directly, git svn clone still prompts
    # interactively for a password when pointed at a --config-dir a plain
    # 'svn info' had already cached one in, apparently not routing
    # authentication through it consistently the way it does for config file
    # settings. Overriding HOME is what svn's own credential lookup actually
    # keys off, and it's what makes the plaintext SVN password never land in
    # a location any other job or workload running as the same runner user
    # would ever read from, whether or not this run's cleanup below actually
    # gets to execute.
    svn_home_dir = tempfile.mkdtemp()
    svn_env = {**os.environ, "HOME": svn_home_dir}

    def cleanup():
        shutil.rmtree(svn_home_dir, ignore_errors=True)
        if os.path.exists(svn_home_dir):
            print(
                f"Warning: failed to remove the isolated SVN config directory {svn_home_dir}, "
                "it may still contain a cached SVN credential.",
                file=sys.stderr,
            )
        shutil.rmtree(hooks_neutralize_dir, ignore_errors=True)

    try:
        if not args.snapshot_only and svn_username and svn_password:
            print("Seeding SVN credential cache")
            # --password-from-stdin keeps the password out of argv, where it
            # would otherwise be readable by any local user via
            # /proc/<pid>/cmdline or ps for the duration of this call.
            # store-plaintext-passwords=yes is required for svn to actually
            # cache it, the stock 'ask' default silently declines to persist
            # the password under --non-interactive, which would otherwise
            # make the later git-svn calls fail to authenticate with no
            # cached credential. --snapshot-only doesn't need any of this,
            # 'svn export' takes credentials directly on every call, unlike
            # git-svn it has no need to read them back out of a cache, so
            # there's no plaintext password to cache or clean up in that
            # mode at all.
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
                env=svn_env,
            )

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

        # POST /orgs/{org}/repos only works when github_org is an
        # organization, personal accounts use POST /user/repos instead. This
        # also decides whether the collaborator check below applies,
        # personal accounts always list their own owner as a collaborator,
        # that's not a squatting signal there the way it is for an org repo.
        account_type = "User"
        try:
            with gh_request(f"{api_base}/users/{args.github_org}") as resp:
                account_type = json.loads(resp.read()).get("type", "User")
        except urllib.error.HTTPError:
            pass

        def verify_repo_ownership():
            # A repo that already exists under the target name could have
            # been pre-created by someone else, e.g. a low-privileged org
            # member name-squatting the destination before the pipeline's
            # first run. Confirm it's actually private, owned by the
            # expected account, and, for an org destination, has no
            # unexpected direct collaborators, before mirroring proprietary
            # source into it. Private-and-org-owned alone isn't enough: a
            # member of an org that allows members to create their own
            # repositories can pre-create a private repo under the org and
            # still retain admin on it as its creator, which passes a
            # private/owner-only check while leaving them fully in control
            # of the repo.
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

            if account_type == "Organization":
                try:
                    with gh_request(
                        f"{api_base}/repos/{args.github_org}/{args.github_repo}/collaborators?affiliation=direct"
                    ) as resp:
                        collaborators = json.loads(resp.read())
                except urllib.error.HTTPError as e:
                    sys.exit(
                        f"Refusing to push: couldn't confirm who has direct access to "
                        f"{args.github_org}/{args.github_repo}, HTTP {e.code}."
                    )
                for collaborator in collaborators:
                    login = collaborator.get("login", "")
                    if login.lower() not in allowed_admins:
                        sys.exit(
                            f"Refusing to push: {args.github_org}/{args.github_repo} has a "
                            f"direct collaborator, '{login}', that isn't in --allowed-admins. "
                            "A repo created by an org member who added themselves this way "
                            "can retain admin access to it, even though it's private and "
                            "org-owned."
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

        parent = os.path.dirname(os.path.abspath(workdir))
        os.makedirs(parent, exist_ok=True)

        if args.snapshot_only:
            print(f"Exporting current revision (no history) from {args.svn_url} to {workdir}")
            info_cmd = ["svn", "info", "--non-interactive", "--show-item", "revision"]
            info_input = None
            if svn_username and svn_password:
                info_cmd += ["--username", svn_username, "--password-from-stdin"]
                info_input = svn_password
            info_cmd.append(args.svn_url)
            rev = subprocess.run(
                info_cmd,
                input=info_input,
                env=svn_env,
                check=True,
                capture_output=True,
                text=True,
            ).stdout.strip()
            export_cmd = ["svn", "export", "--force", "--non-interactive"]
            export_input = None
            if svn_username and svn_password:
                export_cmd += ["--username", svn_username, "--password-from-stdin"]
                export_input = svn_password.encode()
            export_cmd += [args.svn_url, workdir]
            run(export_cmd, input=export_input, env=svn_env)

            if not any(os.scandir(workdir)):
                sys.exit(
                    f"Nothing was exported from {args.svn_url}, the export produced an empty "
                    "directory. Check the URL is correct and that it actually has content at "
                    "its current revision."
                )

            author_name, _, author_email = args.commit_author.partition("<")
            author_name = author_name.strip()
            author_email = author_email.rstrip(">").strip()

            safe_git(["init", "-q", workdir])
            safe_git(["add", "-A"], cwd=workdir)
            safe_git(
                [
                    "-c", f"user.name={author_name}",
                    "-c", f"user.email={author_email}",
                    "commit", "-q", "-m",
                    f"Snapshot of SVN revision {rev} from {args.svn_url}, no history preserved",
                ],
                cwd=workdir,
            )
        else:
            print(f"Cloning full SVN history to {workdir}")
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
            safe_git(clone_cmd, env=svn_env)

        head_check = subprocess.run(
            ["git", *safe_git_args, "rev-parse", "HEAD"], cwd=workdir, capture_output=True
        )
        if head_check.returncode != 0:
            if args.snapshot_only:
                sys.exit(f"No commit was created for {args.svn_url}.")
            sys.exit(
                f"No history was imported from {args.svn_url}. This usually means the "
                "repository doesn't use the standard trunk/branches/tags layout that "
                "'git svn clone -s' expects, check the SVN URL and layout before retrying."
            )

        remote_url = f"https://{args.github_host}/{args.github_org}/{args.github_repo}.git"
        safe_git(["remote", "add", "origin", remote_url], cwd=workdir)
        safe_git(["remote", "set-url", "--push", "origin", remote_url], cwd=workdir)

        print(f"Pushing mirror to {args.github_org}/{args.github_repo}")
        auth_header = base64.b64encode(f"x-access-token:{token}".encode()).decode()
        # The header is scoped to this exact literal URL (http.<url>.extraheader)
        # rather than applied globally (http.extraheader), and supplied
        # through GIT_CONFIG_* environment variables rather than -c, so it
        # never appears in process argv. Scoping it to the literal URL also
        # means that if something in this run's own config redirected the
        # connection elsewhere, the header simply wouldn't be attached to
        # that request, since it wouldn't match the URL git actually
        # connects to.
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
