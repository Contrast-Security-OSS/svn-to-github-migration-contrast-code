#!/bin/sh
set -eu

usage() {
  cat <<EOF
Usage: $0 --svn-url <url> --github-org <org> --github-repo <repo> --authors-file <path> [--workdir <path>] [--github-host <host>]

Required environment variable:
  GITHUB_TOKEN    GitHub token with permission to create and push to repos in --github-org

Optional environment variables:
  SVN_USERNAME    SVN username, if the source repo requires authentication
  SVN_PASSWORD    SVN password, if the source repo requires authentication
EOF
  exit 1
}

SVN_URL=""
GITHUB_ORG=""
GITHUB_REPO=""
AUTHORS_FILE=""
WORKDIR=""
GITHUB_HOST="github.com"

while [ $# -gt 0 ]; do
  case "$1" in
    --svn-url) SVN_URL="$2"; shift 2 ;;
    --github-org) GITHUB_ORG="$2"; shift 2 ;;
    --github-repo) GITHUB_REPO="$2"; shift 2 ;;
    --authors-file) AUTHORS_FILE="$2"; shift 2 ;;
    --workdir) WORKDIR="$2"; shift 2 ;;
    --github-host) GITHUB_HOST="$2"; shift 2 ;;
    -h|--help) usage ;;
    *) echo "Unknown argument: $1" >&2; usage ;;
  esac
done

[ -n "$SVN_URL" ] || { echo "Missing --svn-url" >&2; usage; }
[ -n "$GITHUB_ORG" ] || { echo "Missing --github-org" >&2; usage; }
[ -n "$GITHUB_REPO" ] || { echo "Missing --github-repo" >&2; usage; }
[ -n "$AUTHORS_FILE" ] || { echo "Missing --authors-file" >&2; usage; }
: "${GITHUB_TOKEN:?GITHUB_TOKEN environment variable is required}"

WORKDIR="${WORKDIR:-./svn-import/$GITHUB_REPO}"

if [ "$GITHUB_HOST" = "github.com" ]; then
  API_BASE="https://api.github.com"
else
  API_BASE="https://$GITHUB_HOST/api/v3"
fi

for tool in git svn curl base64; do
  command -v "$tool" >/dev/null 2>&1 || { echo "Required tool not found: $tool" >&2; exit 1; }
done
git svn --version >/dev/null 2>&1 || { echo "git-svn is not installed" >&2; exit 1; }

# core.hooksPath is redirected to this empty directory, and core.fsmonitor is
# cleared, on every git invocation that touches $WORKDIR. Without this, a
# workdir reused from a shared/cached CI path could carry a planted
# .git/hooks/* script or a core.fsmonitor command that executes arbitrary
# code the moment git refreshes its index, e.g. during 'git svn rebase'.
HOOKS_NEUTRALIZE_DIR=$(mktemp -d)
safe_git() {
  git -c core.hooksPath="$HOOKS_NEUTRALIZE_DIR" -c core.fsmonitor= "$@"
}

SVN_AUTH_SEEDED=0
cleanup() {
  # The SVN credential only needs to live on disk long enough for the git-svn
  # calls below to read it, git-svn has no way to accept a password directly.
  # Remove it again once this run is done, success or failure, rather than
  # leaving it in the shared auth cache indefinitely.
  if [ "$SVN_AUTH_SEEDED" = "1" ]; then
    HOSTPART=$(printf '%s' "$SVN_URL" | sed -E 's#^([a-zA-Z]+://[^/]+).*#\1#')
    svn auth --remove "$SVN_USERNAME" "$HOSTPART" >/dev/null 2>&1 || true
  fi
  rm -rf "$HOOKS_NEUTRALIZE_DIR"
}
trap cleanup EXIT

if [ -n "${SVN_USERNAME:-}" ] && [ -n "${SVN_PASSWORD:-}" ]; then
  echo "Seeding SVN credential cache"
  # --password-from-stdin keeps the password out of argv, where it would
  # otherwise be readable by any local user via /proc/<pid>/cmdline or ps for
  # the duration of this call. store-plaintext-passwords=yes is required for
  # svn to actually cache it, the stock 'ask' default silently declines to
  # persist the password under --non-interactive, which would otherwise make
  # the later git-svn calls fail to authenticate with no cached credential.
  printf '%s' "$SVN_PASSWORD" | svn info --non-interactive \
    --config-option servers:global:store-plaintext-passwords=yes \
    --username "$SVN_USERNAME" --password-from-stdin "$SVN_URL" >/dev/null
  SVN_AUTH_SEEDED=1
fi

echo "Ensuring GitHub repository $GITHUB_ORG/$GITHUB_REPO exists on $GITHUB_HOST"
RESPONSE_FILE=$(mktemp)

# A repo that already exists under the target name could have been
# pre-created by someone else, e.g. a low-privileged org member name-squatting
# the destination before the pipeline's first run. Confirm it's actually
# private and owned by the expected account before mirroring proprietary
# source into it.
verify_repo_ownership() {
  curl -s -H "Authorization: token $GITHUB_TOKEN" -H "Accept: application/vnd.github+json" \
    -o "$RESPONSE_FILE" "$API_BASE/repos/$GITHUB_ORG/$GITHUB_REPO"
  PRIVATE_VAL=$(grep -o '"private": *[a-z]*' "$RESPONSE_FILE" | head -1 | sed -E 's/.*: *//')
  OWNER_LOGIN=$(grep -o '"login": *"[^"]*"' "$RESPONSE_FILE" | head -1 | sed -E 's/.*"([^"]+)"$/\1/')

  if [ "$PRIVATE_VAL" != "true" ]; then
    echo "Refusing to push: $GITHUB_ORG/$GITHUB_REPO is not private, or its visibility couldn't be confirmed." >&2
    exit 1
  fi
  OWNER_LOWER=$(printf '%s' "$OWNER_LOGIN" | tr '[:upper:]' '[:lower:]')
  ORG_LOWER=$(printf '%s' "$GITHUB_ORG" | tr '[:upper:]' '[:lower:]')
  if [ "$OWNER_LOWER" != "$ORG_LOWER" ]; then
    echo "Refusing to push: $GITHUB_ORG/$GITHUB_REPO is owned by '$OWNER_LOGIN', not '$GITHUB_ORG'." >&2
    exit 1
  fi
}

EXISTS_STATUS=$(curl -s -o /dev/null -w '%{http_code}' \
  -H "Authorization: token $GITHUB_TOKEN" \
  -H "Accept: application/vnd.github+json" \
  "$API_BASE/repos/$GITHUB_ORG/$GITHUB_REPO")

if [ "$EXISTS_STATUS" = "200" ]; then
  echo "Repository already exists, verifying it before pushing."
  verify_repo_ownership
  echo "Ownership and visibility confirmed, continuing."
else
  # POST /orgs/{org}/repos only works when GITHUB_ORG is an organization, GitHub
  # has no such endpoint for personal accounts, creating there is POST /user/repos
  # instead. Ask the API which kind of account this is before picking one.
  ACCOUNT_TYPE=$(curl -s \
    -H "Authorization: token $GITHUB_TOKEN" \
    -H "Accept: application/vnd.github+json" \
    "$API_BASE/users/$GITHUB_ORG" | grep -o '"type": *"[^"]*"' | sed -E 's/.*"([^"]+)"$/\1/')

  if [ "$ACCOUNT_TYPE" = "Organization" ]; then
    CREATE_URL="$API_BASE/orgs/$GITHUB_ORG/repos"
  else
    CREATE_URL="$API_BASE/user/repos"
  fi

  CREATE_STATUS=$(curl -s -o "$RESPONSE_FILE" -w '%{http_code}' \
    -X POST \
    -H "Authorization: token $GITHUB_TOKEN" \
    -H "Accept: application/vnd.github+json" \
    "$CREATE_URL" \
    -d "{\"name\":\"$GITHUB_REPO\",\"auto_init\":false,\"private\":true}")

  case "$CREATE_STATUS" in
    201) echo "Repository created." ;;
    422)
      echo "Repository already exists, verifying it before pushing."
      verify_repo_ownership
      echo "Ownership and visibility confirmed, continuing."
      ;;
    *)
      echo "Failed to create repository, HTTP $CREATE_STATUS" >&2
      cat "$RESPONSE_FILE" >&2
      rm -f "$RESPONSE_FILE"
      exit 1
      ;;
  esac
fi
rm -f "$RESPONSE_FILE"

if [ -d "$WORKDIR/.git" ]; then
  # A pre-existing workdir is only trustworthy if it's actually a checkout of
  # the SVN URL this run was asked to import, not a directory an attacker
  # planted at the same shared/cached path with a different svn-remote,
  # malicious hooks, or a hijacked push destination.
  EXISTING_SVN_URL=$(safe_git -C "$WORKDIR" config --get svn-remote.svn.url 2>/dev/null || true)
  if [ "$EXISTING_SVN_URL" != "$SVN_URL" ]; then
    echo "Refusing to reuse $WORKDIR: it's configured for SVN URL '$EXISTING_SVN_URL', not '$SVN_URL'." >&2
    echo "If this is a stale or untrusted cache, clear it manually and retry." >&2
    exit 1
  fi
  echo "Existing checkout found at $WORKDIR, fetching incremental updates"
  ( cd "$WORKDIR" && safe_git svn rebase )
else
  echo "No existing checkout, cloning full SVN history to $WORKDIR"
  mkdir -p "$(dirname "$WORKDIR")"
  if [ -n "${SVN_USERNAME:-}" ]; then
    git svn clone -s "$SVN_URL" "$WORKDIR" --authors-file "$AUTHORS_FILE" --username "$SVN_USERNAME"
  else
    git svn clone -s "$SVN_URL" "$WORKDIR" --authors-file "$AUTHORS_FILE"
  fi
fi

cd "$WORKDIR"

if ! safe_git rev-parse HEAD >/dev/null 2>&1; then
  echo "No history was imported from $SVN_URL." >&2
  echo "This usually means the repository doesn't use the standard trunk/branches/tags layout that 'git svn clone -s' expects, check the SVN URL and layout before retrying." >&2
  exit 1
fi

REMOTE_URL="https://$GITHUB_HOST/$GITHUB_ORG/$GITHUB_REPO.git"
if safe_git remote | grep -q '^origin$'; then
  safe_git remote set-url origin "$REMOTE_URL"
else
  safe_git remote add origin "$REMOTE_URL"
fi
# set-url without --push only touches remote.origin.url, a planted
# remote.origin.pushurl in a reused workdir would otherwise survive and take
# precedence over it on push.
safe_git remote set-url --push origin "$REMOTE_URL"

echo "Pushing mirror to $GITHUB_ORG/$GITHUB_REPO"
AUTH_HEADER=$(printf 'x-access-token:%s' "$GITHUB_TOKEN" | base64 | tr -d '\n')
# The header is scoped to this exact literal URL (http.<url>.extraheader)
# rather than applied globally (http.extraheader), and supplied through
# GIT_CONFIG_* environment variables rather than -c, so it never appears in
# process argv. Scoping it to the literal URL also means that if a planted
# pushurl or a url.*.insteadOf rewrite in a reused workdir redirects the
# connection elsewhere, the header simply won't be attached to that request,
# since it won't match the URL git actually connects to.
GIT_CONFIG_COUNT=1 \
GIT_CONFIG_KEY_0="http.${REMOTE_URL}.extraheader" \
GIT_CONFIG_VALUE_0="AUTHORIZATION: basic $AUTH_HEADER" \
safe_git push --mirror "$REMOTE_URL"

echo "Done. GitHub will trigger the Contrast Scan integration from this push."
