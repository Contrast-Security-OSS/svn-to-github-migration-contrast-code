#!/usr/bin/env python3
"""Import an SVN repository into GitHub so Contrast Scan can pick it up on push.

Follows https://docs.github.com/en/migrations/importing-source-code/using-the-command-line-to-import-source-code/importing-a-subversion-repository
"""
import argparse
import base64
import json
import os
import shutil
import subprocess
import sys
import urllib.error
import urllib.request


def which_or_die(tool):
    if shutil.which(tool) is None:
        sys.exit(f"Required tool not found: {tool}")


def run(cmd, cwd=None):
    subprocess.run(cmd, cwd=cwd, check=True)


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

    if svn_username and svn_password:
        print("Seeding SVN credential cache")
        run(
            [
                "svn",
                "info",
                "--non-interactive",
                "--username",
                svn_username,
                "--password",
                svn_password,
                args.svn_url,
            ]
        )

    print(f"Ensuring GitHub repository {args.github_org}/{args.github_repo} exists on {args.github_host}")
    req = urllib.request.Request(
        f"{api_base}/orgs/{args.github_org}/repos",
        data=json.dumps(
            {"name": args.github_repo, "auto_init": False, "private": True}
        ).encode(),
        headers={
            "Authorization": f"token {token}",
            "Accept": "application/vnd.github+json",
            "Content-Type": "application/json",
        },
        method="POST",
    )
    try:
        with urllib.request.urlopen(req):
            print("Repository created.")
    except urllib.error.HTTPError as e:
        if e.code == 422:
            print("Repository already exists, continuing.")
        else:
            sys.exit(f"Failed to create repository, HTTP {e.code}: {e.read().decode(errors='replace')}")

    git_dir = os.path.join(workdir, ".git")
    if os.path.isdir(git_dir):
        print(f"Existing checkout found at {workdir}, fetching incremental updates")
        run(["git", "svn", "rebase"], cwd=workdir)
    else:
        print(f"No existing checkout, cloning full SVN history to {workdir}")
        parent = os.path.dirname(os.path.abspath(workdir))
        os.makedirs(parent, exist_ok=True)
        clone_cmd = [
            "git",
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
        run(clone_cmd)

    remote_url = f"https://{args.github_host}/{args.github_org}/{args.github_repo}.git"
    existing_remotes = subprocess.run(
        ["git", "remote"], cwd=workdir, check=True, capture_output=True, text=True
    ).stdout.split()
    if "origin" in existing_remotes:
        run(["git", "remote", "set-url", "origin", remote_url], cwd=workdir)
    else:
        run(["git", "remote", "add", "origin", remote_url], cwd=workdir)

    print(f"Pushing mirror to {args.github_org}/{args.github_repo}")
    auth_header = base64.b64encode(f"x-access-token:{token}".encode()).decode()
    run(
        [
            "git",
            "-c",
            f"http.extraheader=AUTHORIZATION: basic {auth_header}",
            "push",
            "--mirror",
            "origin",
        ],
        cwd=workdir,
    )

    print("Done. GitHub will trigger the Contrast Scan integration from this push.")


if __name__ == "__main__":
    main()
