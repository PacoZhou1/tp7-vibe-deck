#!/usr/bin/env bash
set -euo pipefail

remote="${1:-origin}"
git_root="$(git rev-parse --show-toplevel 2>/dev/null)" || {
  echo "sync_to_github: not inside a Git repository" >&2
  exit 1
}

cd "$git_root"
branch="$(git symbolic-ref --quiet --short HEAD 2>/dev/null || true)"
if [[ -z "$branch" ]]; then
  echo "sync_to_github: refusing to sync from detached HEAD" >&2
  exit 1
fi

git remote get-url "$remote" >/dev/null 2>&1 || {
  echo "sync_to_github: remote '$remote' is not configured" >&2
  exit 1
}

if ! git diff --quiet || ! git diff --cached --quiet; then
  echo "sync_to_github: warning: uncommitted changes are not synced" >&2
fi

echo "sync_to_github: pushing $branch to $remote"
git push -u "$remote" "HEAD:refs/heads/$branch"
echo "sync_to_github: pushing tags to $remote"
git push "$remote" --tags
echo "sync_to_github: done"
