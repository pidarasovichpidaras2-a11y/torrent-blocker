#!/usr/bin/env bash
# Publish repo to GitHub. Requires: GITHUB_TOKEN (repo scope) and GITHUB_USER
set -euo pipefail

REPO_NAME="${1:-remnanode-torrent-block}"
DIR="$(cd "$(dirname "$0")" && pwd)"

: "${GITHUB_TOKEN:?Set GITHUB_TOKEN — GitHub -> Settings -> Developer settings -> PAT}"
: "${GITHUB_USER:?Set GITHUB_USER — your GitHub username or org}"

cd "$DIR"
git init -b main 2>/dev/null || git checkout -B main
git add install.sh README.md panel-torrent-block-config.json
git commit -m "$(cat <<'EOF'
Add Remnawave node torrent block server installer.

One-command setup for logs, tblocker, egress filter backup, and docker-compose patching.
EOF
)" 2>/dev/null || true

export GH_TOKEN="$GITHUB_TOKEN"
gh auth setup-git 2>/dev/null || true

if gh repo view "$GITHUB_USER/$REPO_NAME" >/dev/null 2>&1; then
  echo "Repo exists, pushing..."
  git remote remove origin 2>/dev/null || true
  git remote add origin "https://github.com/$GITHUB_USER/$REPO_NAME.git"
  git push -u origin main --force
else
  gh repo create "$REPO_NAME" --public --source=. --remote=origin --push \
    --description "One-command server setup for torrent blocking on Remnawave nodes"
fi

echo
echo "Install on any server:"
echo "  curl -fsSL https://raw.githubusercontent.com/$GITHUB_USER/$REPO_NAME/main/install.sh | bash"
