#!/usr/bin/env bash
# Interactive test harness for the SVN to GitHub migration scripts.
# Intended to run inside the Debian test container described in TESTING.md,
# not against a real SVN or GitHub repository.
set -euo pipefail

REPO_PATH="/svn-repos/testrepo"
WC_PATH="/work/testrepo-wc"
HOST_FILES_DIR="${HOST_FILES_DIR:-/host-files}"
AUTHORS_FILE="/work/authors.txt"
SCRIPTS_DIR="${SCRIPTS_DIR:-/scripts}"

if [ ! -d "$REPO_PATH" ]; then
  echo "Creating SVN repository at $REPO_PATH"
  mkdir -p "$(dirname "$REPO_PATH")"
  svnadmin create "$REPO_PATH"
  # git svn clone -s expects the standard trunk/branches/tags layout, without
  # this the clone silently finds nothing to import and the later push sends
  # zero refs with no error.
  echo "Creating standard trunk/branches/tags layout"
  svn mkdir -q -m "Set up standard layout" \
    "file://$REPO_PATH/trunk" \
    "file://$REPO_PATH/branches" \
    "file://$REPO_PATH/tags"
fi

if [ ! -d "$WC_PATH/.svn" ]; then
  echo "Checking out working copy to $WC_PATH"
  mkdir -p "$(dirname "$WC_PATH")"
  svn checkout "file://$REPO_PATH/trunk" "$WC_PATH"
fi

cd "$WC_PATH"

while true; do
  echo ""
  echo "Files available under $HOST_FILES_DIR:"
  find "$HOST_FILES_DIR" -maxdepth 2 -type f 2>/dev/null | head -50
  echo ""
  read -rp "Enter path(s) to file(s) to commit, space separated, or leave blank to stop adding files: " -a SELECTED
  if [ "${#SELECTED[@]}" -eq 0 ]; then
    break
  fi
  for f in "${SELECTED[@]}"; do
    if [ ! -f "$f" ]; then
      echo "Skipping, not found: $f"
      continue
    fi
    cp "$f" "$WC_PATH/$(basename "$f")"
    svn add --force "$WC_PATH/$(basename "$f")" >/dev/null
    echo "Staged: $(basename "$f")"
  done
  read -rp "Add more files? (y/N): " MORE
  case "$MORE" in
    y|Y) continue ;;
    *) break ;;
  esac
done

if svn status | grep -q .; then
  read -rp "Commit message [Test commit]: " COMMIT_MSG
  COMMIT_MSG="${COMMIT_MSG:-Test commit}"
  svn commit -m "$COMMIT_MSG"
  # Without this, the working copy's local metadata stays pinned to whatever
  # revision it was checked out at, and `svn log` with no arguments comes up
  # empty even though the commit succeeded.
  svn update -q
else
  echo "Nothing staged, skipping commit."
fi

echo ""
echo "=== svn status ==="
svn status
echo ""
echo "=== svn log ==="
svn log
echo ""
echo "=== svn list, repository contents ==="
svn list "file://$REPO_PATH"

COMMITTER=$(whoami)
if [ ! -f "$AUTHORS_FILE" ]; then
  echo "$COMMITTER = Test User <test@example.com>" > "$AUTHORS_FILE"
  echo ""
  echo "Wrote a placeholder authors file for this test run to $AUTHORS_FILE"
fi

echo ""
read -rp "Migrate this repository to GitHub now? (y/N): " DO_MIGRATE
case "$DO_MIGRATE" in
  y|Y) ;;
  *) echo "Skipping migration."; exit 0 ;;
esac

read -rp "GitHub repository URL, e.g. https://github.com/my-org/my-repo: " GH_URL
read -rp "GitHub username: " GH_USERNAME
read -rsp "GitHub personal access token: " GH_TOKEN
echo ""

GH_URL_CLEAN="${GH_URL%.git}"
GH_ORG=$(echo "$GH_URL_CLEAN" | sed -E 's#.*[:/]([^/]+)/([^/]+)$#\1#')
GH_REPO=$(echo "$GH_URL_CLEAN" | sed -E 's#.*[:/]([^/]+)/([^/]+)$#\2#')

if [ -z "$GH_ORG" ] || [ -z "$GH_REPO" ] || [ "$GH_ORG" = "$GH_URL_CLEAN" ]; then
  echo "Could not parse an organization and repository name out of: $GH_URL" >&2
  exit 1
fi

echo "Parsed organization: $GH_ORG"
echo "Parsed repository: $GH_REPO"
echo "Note, the GitHub username ($GH_USERNAME) isn't used for authentication by the migration script," \
     "which authenticates with the token alone. It's captured here for the test record only."

export GITHUB_TOKEN="$GH_TOKEN"

"$SCRIPTS_DIR/import_svn_to_github.sh" \
  --svn-url "file://$REPO_PATH" \
  --github-org "$GH_ORG" \
  --github-repo "$GH_REPO" \
  --authors-file "$AUTHORS_FILE" \
  --workdir "/work/git-svn-clone"
