#!/bin/sh
set -eu

usage() {
  cat <<EOF
Usage: $0 --svn-url <url> --github-org <org> --github-repo <repo> --authors-file <path> [--workdir <path>] [--github-host <host>] [--allowed-admins <login1,login2>]
       $0 --svn-url <url> --github-org <org> --github-repo <repo> --snapshot-only [--commit-author <name-and-email>] [--workdir <path>] [--github-host <host>] [--allowed-admins <login1,login2>]

Required environment variable:
  GITHUB_TOKEN    GitHub token with permission to create and push to repos in --github-org

Optional environment variables:
  SVN_USERNAME    SVN username, if the source repo requires authentication
  SVN_PASSWORD    SVN password, if the source repo requires authentication

--workdir must not already exist. This script always clones fresh into it,
it never reuses a pre-existing directory, see REQUIREMENTS.md for why.

--allowed-admins is a comma-separated list of GitHub logins permitted to be
direct collaborators on a pre-existing destination repo under an
organization. Defaults to none, meaning any direct collaborator on an
existing org repo causes the run to refuse rather than push into it.

--snapshot-only skips SVN history entirely and imports just the current
revision as a single commit with no history. Use this when the full SVN
history is too large for a single GitHub push, GitHub enforces a hard limit
around 2GB per push, and a full-history git-svn clone of a large, old SVN
repository routinely exceeds that even when the current code is small. Not
required or used in this mode: --authors-file, and the standard
trunk/branches/tags layout, --svn-url can point at any URL within the
repository, a specific branch included.

--commit-author sets the Git author and committer for the single snapshot
commit, in "Name <email>" form, only used with --snapshot-only. Defaults to
"SVN Snapshot Import <svn-snapshot-import@localhost>".
EOF
  exit 1
}

SVN_URL=""
GITHUB_ORG=""
GITHUB_REPO=""
AUTHORS_FILE=""
WORKDIR=""
GITHUB_HOST="github.com"
ALLOWED_ADMINS=""
SNAPSHOT_ONLY=0
COMMIT_AUTHOR="SVN Snapshot Import <svn-snapshot-import@localhost>"

while [ $# -gt 0 ]; do
  case "$1" in
    --svn-url) SVN_URL="$2"; shift 2 ;;
    --github-org) GITHUB_ORG="$2"; shift 2 ;;
    --github-repo) GITHUB_REPO="$2"; shift 2 ;;
    --authors-file) AUTHORS_FILE="$2"; shift 2 ;;
    --workdir) WORKDIR="$2"; shift 2 ;;
    --github-host) GITHUB_HOST="$2"; shift 2 ;;
    --allowed-admins) ALLOWED_ADMINS="$2"; shift 2 ;;
    --snapshot-only) SNAPSHOT_ONLY=1; shift ;;
    --commit-author) COMMIT_AUTHOR="$2"; shift 2 ;;
    -h|--help) usage ;;
    *) echo "Unknown argument: $1" >&2; usage ;;
  esac
done

[ -n "$SVN_URL" ] || { echo "Missing --svn-url" >&2; usage; }
[ -n "$GITHUB_ORG" ] || { echo "Missing --github-org" >&2; usage; }
[ -n "$GITHUB_REPO" ] || { echo "Missing --github-repo" >&2; usage; }
if [ "$SNAPSHOT_ONLY" != "1" ]; then
  [ -n "$AUTHORS_FILE" ] || { echo "Missing --authors-file" >&2; usage; }
fi
: "${GITHUB_TOKEN:?GITHUB_TOKEN environment variable is required}"

if { [ -n "${SVN_USERNAME:-}" ] && [ -z "${SVN_PASSWORD:-}" ]; } || \
   { [ -z "${SVN_USERNAME:-}" ] && [ -n "${SVN_PASSWORD:-}" ]; }; then
  echo "SVN_USERNAME and SVN_PASSWORD must be set together when SVN authentication is required." >&2
  exit 1
fi

WORKDIR="${WORKDIR:-./svn-import/$GITHUB_REPO}"

if [ "$GITHUB_HOST" = "github.com" ]; then
  API_BASE="https://api.github.com"
else
  API_BASE="https://$GITHUB_HOST/api/v3"
fi

for tool in git svn curl base64; do
  command -v "$tool" >/dev/null 2>&1 || { echo "Required tool not found: $tool" >&2; exit 1; }
done
if [ "$SNAPSHOT_ONLY" != "1" ]; then
  git svn --version >/dev/null 2>&1 || { echo "git-svn is not installed" >&2; exit 1; }
fi

# core.hooksPath is redirected to this empty directory, and core.fsmonitor is
# cleared, on every git invocation this script makes, including the initial
# clone. A denylist of dangerous config keys was tried here before and found
# incomplete (filter/merge drivers, credential.helper, http.proxy, and
# insteadOf rewrites are all separate code-execution or credential-exfiltration
# vectors it didn't cover), see REQUIREMENTS.md. The actual fix is that this
# script never operates against a pre-existing directory at all, see the
# workdir handling below, these two overrides remain as cheap defense in
# depth, not as the primary control.
HOOKS_NEUTRALIZE_DIR=$(mktemp -d)
safe_git() {
  git -c core.hooksPath="$HOOKS_NEUTRALIZE_DIR" -c core.fsmonitor= "$@"
}

# Every svn and git-svn call below runs with HOME pointed at this directory
# instead of the real one, so their config and credential cache land here
# instead of the shared, per-user ~/.subversion. 'svn --config-dir' looks like
# the more direct way to do this, but it doesn't fully work, verified
# directly, git svn clone still prompts interactively for a password when
# pointed at a --config-dir a plain 'svn info' had already cached one in,
# apparently not routing authentication through it consistently the way it
# does for config file settings. Overriding HOME is what svn's own credential
# lookup actually keys off, and it's what makes the plaintext SVN password
# never land in a location any other job or workload running as the same
# runner user would ever read from, whether or not this run's cleanup below
# actually gets to execute.
SVN_CONFIG_DIR=$(mktemp -d)

cleanup() {
  if ! rm -rf "$SVN_CONFIG_DIR"; then
    echo "Warning: failed to remove the isolated SVN config directory $SVN_CONFIG_DIR, it may still contain a cached SVN credential." >&2
  fi
  rm -rf "$HOOKS_NEUTRALIZE_DIR"
}
trap cleanup EXIT

if [ "$SNAPSHOT_ONLY" != "1" ] && [ -n "${SVN_USERNAME:-}" ] && [ -n "${SVN_PASSWORD:-}" ]; then
  echo "Seeding SVN credential cache"
  # --password-from-stdin keeps the password out of argv, where it would
  # otherwise be readable by any local user via /proc/<pid>/cmdline or ps for
  # the duration of this call. store-plaintext-passwords=yes is required for
  # svn to actually cache it, the stock 'ask' default silently declines to
  # persist the password under --non-interactive, which would otherwise make
  # the later git-svn calls fail to authenticate with no cached credential.
  # --snapshot-only doesn't need any of this, 'svn export' takes credentials
  # directly on every call, unlike git-svn it has no need to read them back
  # out of a cache, so there's no plaintext password to cache or clean up in
  # that mode at all.
  printf '%s' "$SVN_PASSWORD" | HOME="$SVN_CONFIG_DIR" svn info --non-interactive \
    --config-option servers:global:store-plaintext-passwords=yes \
    --username "$SVN_USERNAME" --password-from-stdin "$SVN_URL" >/dev/null
fi

# Every GitHub API call below goes through this helper so GITHUB_TOKEN is
# supplied to curl over stdin via -K, never as a -H argument, which would
# otherwise sit in that curl process's argv, readable by any local user via
# /proc/<pid>/cmdline or ps for the life of the request.
RESPONSE_FILE=$(mktemp)
gh_curl() {
  METHOD="$1"
  URL="$2"
  DATA="${3:-}"
  {
    printf 'header = "Authorization: token %s"\n' "$GITHUB_TOKEN"
    printf 'header = "Accept: application/vnd.github+json"\n'
    printf 'url = "%s"\n' "$URL"
    printf 'request = "%s"\n' "$METHOD"
    printf 'silent\n'
    if [ -n "$DATA" ]; then
      ESCAPED_DATA=$(printf '%s' "$DATA" | sed 's/\\/\\\\/g; s/"/\\"/g')
      printf 'header = "Content-Type: application/json"\n'
      printf 'data = "%s"\n' "$ESCAPED_DATA"
    fi
    printf 'write-out = "%%{http_code}"\n'
  } | curl -K - -o "$RESPONSE_FILE"
}

echo "Ensuring GitHub repository $GITHUB_ORG/$GITHUB_REPO exists on $GITHUB_HOST"

# POST /orgs/{org}/repos only works when GITHUB_ORG is an organization, GitHub
# has no such endpoint for personal accounts, creating there is POST
# /user/repos instead. This also decides whether the collaborator check below
# applies, personal accounts always list their own owner as a collaborator,
# that's not a squatting signal there the way it is for an org repo.
ACCOUNT_TYPE=$(gh_curl GET "$API_BASE/users/$GITHUB_ORG" >/dev/null; grep -o '"type": *"[^"]*"' "$RESPONSE_FILE" | head -1 | sed -E 's/.*"([^"]+)"$/\1/')

# A repo that already exists under the target name could have been
# pre-created by someone else, e.g. a low-privileged org member name-squatting
# the destination before the pipeline's first run. Confirm it's actually
# private, owned by the expected account, and, for an org destination, has no
# unexpected direct collaborators, before mirroring proprietary source into
# it. Private-and-org-owned alone isn't enough: a member of an org that allows
# members to create their own repositories can pre-create a private repo
# under the org and still retain admin on it as its creator, which passes a
# private/owner-only check while leaving them fully in control of the repo.
verify_repo_ownership() {
  gh_curl GET "$API_BASE/repos/$GITHUB_ORG/$GITHUB_REPO" >/dev/null
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

  if [ "$ACCOUNT_TYPE" = "Organization" ]; then
    COLLAB_STATUS=$(gh_curl GET "$API_BASE/repos/$GITHUB_ORG/$GITHUB_REPO/collaborators?affiliation=direct")
    if [ "$COLLAB_STATUS" != "200" ]; then
      echo "Refusing to push: couldn't confirm who has direct access to $GITHUB_ORG/$GITHUB_REPO, HTTP $COLLAB_STATUS." >&2
      exit 1
    fi
    COLLABORATORS=$(grep -o '"login": *"[^"]*"' "$RESPONSE_FILE" | sed -E 's/.*"([^"]+)"$/\1/')
    for login in $COLLABORATORS; do
      login_lower=$(printf '%s' "$login" | tr '[:upper:]' '[:lower:]')
      allowed="no"
      OLD_IFS=$IFS
      IFS=,
      for allowed_login in $ALLOWED_ADMINS; do
        [ "$(printf '%s' "$allowed_login" | tr '[:upper:]' '[:lower:]')" = "$login_lower" ] && allowed="yes"
      done
      IFS=$OLD_IFS
      if [ "$allowed" = "no" ]; then
        echo "Refusing to push: $GITHUB_ORG/$GITHUB_REPO has a direct collaborator, '$login', that isn't in --allowed-admins." >&2
        echo "A repo created by an org member who allowed themselves to be added this way can retain admin access to it, even though it's private and org-owned." >&2
        exit 1
      fi
    done
  fi
}

EXISTS_STATUS=$(gh_curl GET "$API_BASE/repos/$GITHUB_ORG/$GITHUB_REPO")

if [ "$EXISTS_STATUS" = "200" ]; then
  echo "Repository already exists, verifying it before pushing."
  verify_repo_ownership
  echo "Ownership and visibility confirmed, continuing."
else
  if [ "$ACCOUNT_TYPE" = "Organization" ]; then
    CREATE_URL="$API_BASE/orgs/$GITHUB_ORG/repos"
  else
    CREATE_URL="$API_BASE/user/repos"
  fi

  CREATE_STATUS=$(gh_curl POST "$CREATE_URL" "{\"name\":\"$GITHUB_REPO\",\"auto_init\":false,\"private\":true}")

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
      exit 1
      ;;
  esac
fi

# This script always clones fresh, it never reuses a pre-existing directory.
# An earlier version tried to validate and reuse a pre-existing workdir for
# faster incremental syncs, comparing its svn-remote.svn.url against
# --svn-url before trusting it. That check compares a non-secret value, an
# attacker able to write to a shared or predictable workdir path can set it
# to match and pass the gate, then have the planted checkout's own config,
# hooks, filters, or refs trusted from there. There's no complete fix for
# that short of not trusting a pre-existing directory at all, so that's what
# this does, see REQUIREMENTS.md.
if [ -e "$WORKDIR" ]; then
  echo "Refusing to use $WORKDIR: it already exists." >&2
  echo "This script always creates a fresh checkout rather than reusing a directory it can't fully vouch for. Point --workdir at a path that doesn't exist yet." >&2
  exit 1
fi

mkdir -p "$(dirname "$WORKDIR")"

if [ "$SNAPSHOT_ONLY" = "1" ]; then
  echo "Exporting current revision (no history) from $SVN_URL to $WORKDIR"
  if [ -n "${SVN_USERNAME:-}" ] && [ -n "${SVN_PASSWORD:-}" ]; then
    SVN_REV=$(printf '%s' "$SVN_PASSWORD" | HOME="$SVN_CONFIG_DIR" svn info --non-interactive --show-item revision \
      --username "$SVN_USERNAME" --password-from-stdin "$SVN_URL")
    printf '%s' "$SVN_PASSWORD" | HOME="$SVN_CONFIG_DIR" svn export --force --non-interactive \
      --username "$SVN_USERNAME" --password-from-stdin "$SVN_URL" "$WORKDIR" >/dev/null
  else
    SVN_REV=$(HOME="$SVN_CONFIG_DIR" svn info --non-interactive --show-item revision "$SVN_URL")
    HOME="$SVN_CONFIG_DIR" svn export --force --non-interactive "$SVN_URL" "$WORKDIR" >/dev/null
  fi

  if [ -z "$(find "$WORKDIR" -mindepth 1 -print -quit 2>/dev/null)" ]; then
    echo "Nothing was exported from $SVN_URL, the export produced an empty directory." >&2
    echo "Check the URL is correct and that it actually has content at its current revision." >&2
    exit 1
  fi

  COMMIT_AUTHOR_NAME="${COMMIT_AUTHOR%% <*}"
  COMMIT_AUTHOR_EMAIL="${COMMIT_AUTHOR#*<}"
  COMMIT_AUTHOR_EMAIL="${COMMIT_AUTHOR_EMAIL%>}"

  safe_git init -q "$WORKDIR"
  cd "$WORKDIR"
  safe_git add -A
  safe_git -c "user.name=$COMMIT_AUTHOR_NAME" -c "user.email=$COMMIT_AUTHOR_EMAIL" \
    commit -q -m "Snapshot of SVN revision $SVN_REV from $SVN_URL, no history preserved"
else
  echo "Cloning full SVN history to $WORKDIR"
  if [ -n "${SVN_USERNAME:-}" ]; then
    HOME="$SVN_CONFIG_DIR" safe_git svn clone -s "$SVN_URL" "$WORKDIR" --authors-file "$AUTHORS_FILE" --username "$SVN_USERNAME"
  else
    HOME="$SVN_CONFIG_DIR" safe_git svn clone -s "$SVN_URL" "$WORKDIR" --authors-file "$AUTHORS_FILE"
  fi
  cd "$WORKDIR"
fi

if ! safe_git rev-parse HEAD >/dev/null 2>&1; then
  if [ "$SNAPSHOT_ONLY" = "1" ]; then
    echo "No commit was created for $SVN_URL." >&2
  else
    echo "No history was imported from $SVN_URL." >&2
    echo "This usually means the repository doesn't use the standard trunk/branches/tags layout that 'git svn clone -s' expects, check the SVN URL and layout before retrying." >&2
  fi
  exit 1
fi

REMOTE_URL="https://$GITHUB_HOST/$GITHUB_ORG/$GITHUB_REPO.git"
safe_git remote add origin "$REMOTE_URL"
safe_git remote set-url --push origin "$REMOTE_URL"

echo "Pushing mirror to $GITHUB_ORG/$GITHUB_REPO"
AUTH_HEADER=$(printf 'x-access-token:%s' "$GITHUB_TOKEN" | base64 | tr -d '\n')
# The header is scoped to this exact literal URL (http.<url>.extraheader)
# rather than applied globally (http.extraheader), and supplied through
# GIT_CONFIG_* environment variables rather than -c, so it never appears in
# process argv. Scoping it to the literal URL also means that if something in
# this run's own config redirected the connection elsewhere, the header
# simply wouldn't be attached to that request, since it wouldn't match the
# URL git actually connects to.
GIT_CONFIG_COUNT=1 \
GIT_CONFIG_KEY_0="http.${REMOTE_URL}.extraheader" \
GIT_CONFIG_VALUE_0="AUTHORIZATION: basic $AUTH_HEADER" \
safe_git push --mirror "$REMOTE_URL"

echo "Done. GitHub will trigger the Contrast Scan integration from this push."
