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

if [ -n "${SVN_USERNAME:-}" ] && [ -n "${SVN_PASSWORD:-}" ]; then
  echo "Seeding SVN credential cache"
  svn info --non-interactive --username "$SVN_USERNAME" --password "$SVN_PASSWORD" "$SVN_URL" >/dev/null
fi

echo "Ensuring GitHub repository $GITHUB_ORG/$GITHUB_REPO exists on $GITHUB_HOST"
RESPONSE_FILE=$(mktemp)
CREATE_STATUS=$(curl -s -o "$RESPONSE_FILE" -w '%{http_code}' \
  -X POST \
  -H "Authorization: token $GITHUB_TOKEN" \
  -H "Accept: application/vnd.github+json" \
  "$API_BASE/orgs/$GITHUB_ORG/repos" \
  -d "{\"name\":\"$GITHUB_REPO\",\"auto_init\":false,\"private\":true}")

case "$CREATE_STATUS" in
  201) echo "Repository created." ;;
  422) echo "Repository already exists, continuing." ;;
  *)
    echo "Failed to create repository, HTTP $CREATE_STATUS" >&2
    cat "$RESPONSE_FILE" >&2
    rm -f "$RESPONSE_FILE"
    exit 1
    ;;
esac
rm -f "$RESPONSE_FILE"

if [ -d "$WORKDIR/.git" ]; then
  echo "Existing checkout found at $WORKDIR, fetching incremental updates"
  ( cd "$WORKDIR" && git svn rebase )
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

REMOTE_URL="https://$GITHUB_HOST/$GITHUB_ORG/$GITHUB_REPO.git"
if git remote | grep -q '^origin$'; then
  git remote set-url origin "$REMOTE_URL"
else
  git remote add origin "$REMOTE_URL"
fi

echo "Pushing mirror to $GITHUB_ORG/$GITHUB_REPO"
AUTH_HEADER=$(printf 'x-access-token:%s' "$GITHUB_TOKEN" | base64 | tr -d '\n')
git -c http.extraheader="AUTHORIZATION: basic $AUTH_HEADER" push --mirror origin

echo "Done. GitHub will trigger the Contrast Scan integration from this push."
