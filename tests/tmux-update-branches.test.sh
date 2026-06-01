#!/usr/bin/env bash
# Tests for .tmux-update-branches.sh: it publishes each session's git branch onto
# the @git_branch session option, all sessions at once or just one by name (the
# single-session form the focus / session-change hooks use). Runs on a dedicated
# tmux socket via a PATH shim — the script resolves tmux through PATH, so the shim
# drives the whole run onto a throwaway server. Run directly:
#   bash tests/tmux-update-branches.test.sh
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
script="$here/../tmux/.tmux-update-branches.sh"
real_tmux="$(command -v tmux)"

work="$(mktemp -d)"
SOCKET="update_branches_test_$$"
shim_dir="$work/bin"
mkdir -p "$shim_dir"
cat >"$shim_dir/tmux" <<EOF
#!/bin/sh
exec "$real_tmux" -L "$SOCKET" "\$@"
EOF
chmod +x "$shim_dir/tmux"
export PATH="$shim_dir:$PATH"
export HOME="$work/home"          # empty HOME => no ~/.tmux.conf side effects
unset TMUX TMUX_PANE 2>/dev/null || true
mkdir -p "$HOME"

t() { tmux "$@"; }   # uses the shim

cleanup() {
  t kill-server 2>/dev/null || true
  rm -rf "$work" 2>/dev/null || true
}
trap cleanup EXIT

pass=0
fail=0
check() {
  local desc="$1" cond="$2"
  if [ "$cond" = "0" ]; then printf 'ok   - %s\n' "$desc"; pass=$((pass + 1))
  else printf 'FAIL - %s\n' "$desc"; fail=$((fail + 1)); fi
}

newrepo() {  # newrepo <dir> <branch>
  mkdir -p "$1"
  git -C "$1" init -q -b "$2"
  git -C "$1" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
}

newrepo "$work/r1" alpha
newrepo "$work/r2" beta
t new-session -d -s s1 -c "$work/r1" -x 80 -y 24
t new-session -d -s s2 -c "$work/r2" -x 80 -y 24

# --- all-sessions: seed every session's branch -----------------------------------
bash "$script"
[ "$(t show-options -qv -t s1 @git_branch)" = alpha ]
check "all: s1 picks up its repo's branch" "$?"
[ "$(t show-options -qv -t s2 @git_branch)" = beta ]
check "all: s2 picks up its repo's branch" "$?"

# --- single-session: refresh only the named session ------------------------------
# Simulate a branch switched outside tmux, then refresh only s1: s1 tracks the new
# branch and s2 is left untouched (a focus event re-derives just the focused one).
git -C "$work/r1" branch -m alpha gamma
bash "$script" s1
[ "$(t show-options -qv -t s1 @git_branch)" = gamma ]
check "single: the named session tracks the new branch" "$?"
[ "$(t show-options -qv -t s2 @git_branch)" = beta ]
check "single: other sessions are left untouched" "$?"

# --- clearing: a session not in a repo loses any stale value ---------------------
mkdir -p "$work/plain"
t new-session -d -s s3 -c "$work/plain" -x 80 -y 24
t set-option -t s3 @git_branch stale
bash "$script" s3
[ -z "$(t show-options -qv -t s3 @git_branch)" ]
check "clear: a non-repo session's @git_branch is unset" "$?"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
