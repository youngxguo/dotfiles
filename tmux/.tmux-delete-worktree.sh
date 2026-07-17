#!/usr/bin/env bash
# Permanently retire the worktree workspace behind the current tmux session.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/.tmux-lib.sh"

tmux_bin=("$(tmux_resolve_bin)")
[ -n "${TMUX_SETUP_SOCKET:-}" ] && tmux_bin+=(-L "$TMUX_SETUP_SOCKET")

session="${1:-}"
client="${2:-}"
src_path="${3:-$PWD}"

fail() {
  "${tmux_bin[@]}" display-message "delete worktree: $*" 2>/dev/null || true
  printf 'delete worktree: %s\n' "$*" >&2
  exit 1
}

exact_target() {
  printf '=%s' "$1"
}

[ -n "$session" ] || session="$("${tmux_bin[@]}" display-message -p '#{session_name}' 2>/dev/null || true)"
[ -n "$session" ] || fail "could not resolve the current session"

worktree_root="$(git -C "$src_path" rev-parse --show-toplevel 2>/dev/null)" \
  || fail "$src_path is not a git worktree"
repo_root="$(git -C "$worktree_root" worktree list --porcelain 2>/dev/null | sed -n '1s/^worktree //p')" \
  || fail "could not resolve the main worktree"
[ -n "$repo_root" ] || fail "could not resolve the main worktree"
[ "$worktree_root" != "$repo_root" ] || fail "the main worktree cannot be deleted"

branch="$(git -C "$worktree_root" symbolic-ref --quiet --short HEAD 2>/dev/null)" \
  || fail "detached worktrees must be cleaned up manually"

if [ -n "$(git -C "$worktree_root" status --porcelain --untracked-files=all 2>/dev/null)" ]; then
  fail "worktree has uncommitted or untracked changes"
fi

git_dir="$(git -C "$worktree_root" rev-parse --absolute-git-dir 2>/dev/null)" \
  || fail "could not resolve worktree metadata"
[ ! -e "$git_dir/locked" ] || fail "worktree is locked"

# Match `git branch -d`: prefer the branch's upstream, otherwise require it to
# be merged into the branch checked out in the main worktree.
upstream="$(git -C "$repo_root" for-each-ref --format='%(upstream)' "refs/heads/$branch")"
merge_target="${upstream:-HEAD}"
git -C "$repo_root" merge-base --is-ancestor "$branch" "$merge_target" 2>/dev/null \
  || fail "branch $branch is not merged into ${upstream:-the main worktree branch}"

target="$(
  "${tmux_bin[@]}" list-sessions -F '#{session_name}' 2>/dev/null \
    | awk -v current="$session" '$0 != current { print; exit }'
)"
if [ -n "$target" ] && [ -n "$client" ]; then
  "${tmux_bin[@]}" switch-client -c "$client" -t "$(exact_target "$target")" 2>/dev/null \
    || "${tmux_bin[@]}" switch-client -t "$(exact_target "$target")" 2>/dev/null \
    || fail "could not switch away from $session"
fi

"${tmux_bin[@]}" kill-session -t "$(exact_target "$session")" 2>/dev/null \
  || fail "could not kill session $session"

# The status check above protects normal untracked files. --force permits Git to
# remove ignored build output while still respecting our explicit dirty check.
git -C "$repo_root" worktree remove --force "$worktree_root" \
  || fail "session closed, but could not remove $worktree_root"
git -C "$repo_root" branch --delete -- "$branch" >/dev/null \
  || fail "worktree removed, but could not delete branch $branch"

"${tmux_bin[@]}" display-message "deleted worktree and branch $branch" 2>/dev/null || true
