#!/bin/sh
set -eu

usage() {
  cat <<EOF
Usage: $0 --source-dir <path> --github-org <org> [--github-repo <repo>] [--github-host <host>] [--branch <name>] [--commit-message <msg>] [--commit-author <name-and-email>] [--allowed-admins <login1,login2>]

Required environment variable:
  GITHUB_TOKEN    GitHub token with permission to create and push to repos in --github-org

--source-dir must be an existing directory with files to import.
If --github-repo is omitted, the repository name defaults to the folder name
from --source-dir (for example, /path/to/cargo-cats -> cargo-cats).

--allowed-admins is a comma-separated list of GitHub logins permitted to be
 direct collaborators on a pre-existing destination repo under an
 organization. Defaults to none.

--commit-author defaults to:
  "Files Import <files-import@localhost>"
EOF
  exit 1
}

SOURCE_DIR=""
GITHUB_ORG=""
GITHUB_REPO=""
GITHUB_HOST="github.com"
BRANCH="main"
COMMIT_MESSAGE="Initial import from local folder"
COMMIT_AUTHOR="Files Import <files-import@localhost>"
ALLOWED_ADMINS=""

while [ $# -gt 0 ]; do
  case "$1" in
    --source-dir) SOURCE_DIR="$2"; shift 2 ;;
    --github-org) GITHUB_ORG="$2"; shift 2 ;;
    --github-repo) GITHUB_REPO="$2"; shift 2 ;;
    --github-host) GITHUB_HOST="$2"; shift 2 ;;
    --branch) BRANCH="$2"; shift 2 ;;
    --commit-message) COMMIT_MESSAGE="$2"; shift 2 ;;
    --commit-author) COMMIT_AUTHOR="$2"; shift 2 ;;
    --allowed-admins) ALLOWED_ADMINS="$2"; shift 2 ;;
    -h|--help) usage ;;
    *) echo "Unknown argument: $1" >&2; usage ;;
  esac
done

[ -n "$SOURCE_DIR" ] || { echo "Missing --source-dir" >&2; usage; }
[ -n "$GITHUB_ORG" ] || { echo "Missing --github-org" >&2; usage; }
: "${GITHUB_TOKEN:?GITHUB_TOKEN environment variable is required}"

if [ ! -d "$SOURCE_DIR" ]; then
  echo "--source-dir does not exist or is not a directory: $SOURCE_DIR" >&2
  exit 1
fi

SOURCE_DIR_TRIMMED=${SOURCE_DIR%/}
if [ -z "$GITHUB_REPO" ]; then
  GITHUB_REPO=${SOURCE_DIR_TRIMMED##*/}
fi
if [ -z "$GITHUB_REPO" ]; then
  echo "Unable to derive repository name from --source-dir '$SOURCE_DIR'. Pass --github-repo explicitly." >&2
  exit 1
fi

if [ "$GITHUB_HOST" = "github.com" ]; then
  API_BASE="https://api.github.com"
else
  API_BASE="https://$GITHUB_HOST/api/v3"
fi

for tool in git curl base64 grep sed tr mktemp find; do
  command -v "$tool" >/dev/null 2>&1 || { echo "Required tool not found: $tool" >&2; exit 1; }
done

HOOKS_NEUTRALIZE_DIR=$(mktemp -d)
safe_git() {
  git -c core.hooksPath="$HOOKS_NEUTRALIZE_DIR" -c core.fsmonitor= "$@"
}

cleanup() {
  rm -rf "$HOOKS_NEUTRALIZE_DIR"
}
trap cleanup EXIT

RESPONSE_FILE=$(mktemp)
cleanup_response_file() {
  rm -f "$RESPONSE_FILE"
}
trap cleanup_response_file EXIT

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
      echo "Refusing to push: couldn't confirm direct collaborators, HTTP $COLLAB_STATUS." >&2
      exit 1
    fi

    COLLABORATORS=$(grep -o '"login": *"[^"]*"' "$RESPONSE_FILE" | sed -E 's/.*"([^"]+)"$/\1/')
    for login in $COLLABORATORS; do
      login_lower=$(printf '%s' "$login" | tr '[:upper:]' '[:lower:]')
      allowed="no"
      OLD_IFS=$IFS
      IFS=,
      for allowed_login in $ALLOWED_ADMINS; do
        if [ "$(printf '%s' "$allowed_login" | tr '[:upper:]' '[:lower:]')" = "$login_lower" ]; then
          allowed="yes"
        fi
      done
      IFS=$OLD_IFS

      if [ "$allowed" = "no" ]; then
        echo "Refusing to push: direct collaborator '$login' is not in --allowed-admins." >&2
        exit 1
      fi
    done
  fi
}

echo "Ensuring GitHub repository $GITHUB_ORG/$GITHUB_REPO exists on $GITHUB_HOST"

ACCOUNT_TYPE=$(gh_curl GET "$API_BASE/users/$GITHUB_ORG" >/dev/null; grep -o '"type": *"[^"]*"' "$RESPONSE_FILE" | head -1 | sed -E 's/.*"([^"]+)"$/\1/')
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

if [ ! -d "$SOURCE_DIR" ]; then
  echo "Source directory no longer exists: $SOURCE_DIR" >&2
  exit 1
fi

if [ ! -d "$SOURCE_DIR/.git" ]; then
  echo "Initializing git repository in $SOURCE_DIR"
  safe_git -C "$SOURCE_DIR" init -q
fi

safe_git -C "$SOURCE_DIR" checkout -B "$BRANCH" >/dev/null 2>&1

safe_git -C "$SOURCE_DIR" add -A

COMMIT_AUTHOR_NAME="${COMMIT_AUTHOR%% <*}"
COMMIT_AUTHOR_EMAIL="${COMMIT_AUTHOR#*<}"
COMMIT_AUTHOR_EMAIL="${COMMIT_AUTHOR_EMAIL%>}"

if safe_git -C "$SOURCE_DIR" diff --cached --quiet; then
  if safe_git -C "$SOURCE_DIR" rev-parse HEAD >/dev/null 2>&1; then
    echo "No new file changes to commit, continuing with existing HEAD."
  else
    echo "No files available to commit in $SOURCE_DIR." >&2
    exit 1
  fi
else
  safe_git -C "$SOURCE_DIR" -c "user.name=$COMMIT_AUTHOR_NAME" -c "user.email=$COMMIT_AUTHOR_EMAIL" \
    commit -q -m "$COMMIT_MESSAGE"
fi

REMOTE_URL="https://$GITHUB_HOST/$GITHUB_ORG/$GITHUB_REPO.git"

if safe_git -C "$SOURCE_DIR" remote | grep -q '^origin$'; then
  safe_git -C "$SOURCE_DIR" remote set-url origin "$REMOTE_URL"
else
  safe_git -C "$SOURCE_DIR" remote add origin "$REMOTE_URL"
fi
safe_git -C "$SOURCE_DIR" remote set-url --push origin "$REMOTE_URL"

echo "Pushing branch $BRANCH to $GITHUB_ORG/$GITHUB_REPO"
AUTH_HEADER=$(printf 'x-access-token:%s' "$GITHUB_TOKEN" | base64 | tr -d '\n')
GIT_CONFIG_COUNT=1 \
GIT_CONFIG_KEY_0="http.${REMOTE_URL}.extraheader" \
GIT_CONFIG_VALUE_0="AUTHORIZATION: basic $AUTH_HEADER" \
safe_git -C "$SOURCE_DIR" push -u "$REMOTE_URL" "$BRANCH"

echo "Done. Files were committed and pushed to $GITHUB_ORG/$GITHUB_REPO on branch $BRANCH."
