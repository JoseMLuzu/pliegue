#!/bin/bash
set -euo pipefail

project_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_root"

# Keep the existing README and stage only the file requested for the first commit.
git init
git add README.md
if ! git rev-parse --verify HEAD >/dev/null 2>&1; then
    git commit -m "docs: introduce Pliegue project overview"
elif ! git diff --cached --quiet -- README.md; then
    git commit -m "docs: introduce Pliegue project overview" -- README.md
fi

git branch -M main
repository_url="https://github.com/JoseMLuzu/pliegue.git"
if git remote get-url origin >/dev/null 2>&1; then
    git remote set-url origin "$repository_url"
else
    git remote add origin "$repository_url"
fi

git log -1 --oneline
git remote -v
git status --short --branch
printf '\nLocal setup complete. No push was performed.\n'
