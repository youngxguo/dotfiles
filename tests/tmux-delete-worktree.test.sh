#!/usr/bin/env bash
# Tests for prefix-D worktree cleanup on a throwaway tmux socket and repository.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
script="$here/../tmux/.tmux-delete-worktree.sh"

SOCKET="delete_worktree_test_$$"
export TMUX_SETUP_SOCKET="$SOCKET"
tmux_t() { tmux -L "$SOCKET" "$@"; }

work="$(mktemp -d)"
cleanup() {
  tmux_t kill-server 2>/dev/null || true
  rm -rf "$work"
}
trap cleanup EXIT

pass=0
fail=0
check() {
  if [ "$2" = 0 ]; then
    printf 'ok   - %s\n' "$1"
    pass=$((pass + 1))
  else
    printf 'FAIL - %s\n' "$1"
    fail=$((fail + 1))
  fi
}

repo="$work/repo"
mkdir -p "$repo"
git -C "$repo" init -q -b main
git -C "$repo" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
tmux_t new-session -d -s bootstrap -c "$repo"

make_worktree() {
  local name="$1"
  git -C "$repo" worktree add -q -b "$name" "$work/repo-worktrees/$name" main
  tmux_t new-session -d -s "repo-$name" -c "$work/repo-worktrees/$name"
}

make_worktree done
"$script" repo-done "" "$work/repo-worktrees/done" >/dev/null 2>&1
[ ! -d "$work/repo-worktrees/done" ] \
  && ! git -C "$repo" show-ref --verify -q refs/heads/done \
  && ! tmux_t has-session -t repo-done 2>/dev/null
check "deletes the session, clean worktree, and merged branch" "$?"

make_worktree dirty
touch "$work/repo-worktrees/dirty/untracked"
if "$script" repo-dirty "" "$work/repo-worktrees/dirty" >/dev/null 2>&1; then rc=1; else rc=0; fi
[ "$rc" = 0 ] && [ -d "$work/repo-worktrees/dirty" ] \
  && git -C "$repo" show-ref --verify -q refs/heads/dirty \
  && tmux_t has-session -t repo-dirty 2>/dev/null
check "refuses a dirty worktree without closing its session" "$?"

make_worktree unmerged
git -C "$work/repo-worktrees/unmerged" -c user.email=t@t -c user.name=t commit -q --allow-empty -m work
if "$script" repo-unmerged "" "$work/repo-worktrees/unmerged" >/dev/null 2>&1; then rc=1; else rc=0; fi
[ "$rc" = 0 ] && [ -d "$work/repo-worktrees/unmerged" ] \
  && git -C "$repo" show-ref --verify -q refs/heads/unmerged \
  && tmux_t has-session -t repo-unmerged 2>/dev/null
check "refuses an unmerged branch without closing its session" "$?"

tmux_t new-session -d -s repo-main -c "$repo"
if "$script" repo-main "" "$repo" >/dev/null 2>&1; then rc=1; else rc=0; fi
[ "$rc" = 0 ] && [ -d "$repo" ] && tmux_t has-session -t repo-main 2>/dev/null
check "refuses to delete the main worktree" "$?"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
