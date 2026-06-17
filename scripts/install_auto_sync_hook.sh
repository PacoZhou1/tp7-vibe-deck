#!/usr/bin/env bash
set -euo pipefail

git_root="$(git rev-parse --show-toplevel 2>/dev/null)" || {
  echo "install_auto_sync_hook: not inside a Git repository" >&2
  exit 1
}

git_dir="$(git -C "$git_root" rev-parse --git-dir)"
case "$git_dir" in
  /*) ;;
  *) git_dir="$git_root/$git_dir" ;;
esac

hook_path="$git_dir/hooks/post-commit"
mkdir -p "$(dirname "$hook_path")"

cat > "$hook_path" <<'HOOK'
#!/usr/bin/env bash
set -euo pipefail

git_root="$(git rev-parse --show-toplevel)"
"$git_root/scripts/sync_to_github.sh"
HOOK

chmod +x "$hook_path"
echo "Installed auto-sync post-commit hook at $hook_path"
