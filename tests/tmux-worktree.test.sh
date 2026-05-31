#!/usr/bin/env bash
# Tests for .tmux-worktree.sh. Uses a dedicated tmux socket and throwaway git
# repos so it never touches your real sessions or worktrees. Run directly:
#   bash tests/tmux-worktree.test.sh
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
script="$here/../tmux/.tmux-worktree.sh"

SOCKET="worktree_test_$$"
export TMUX_SETUP_SOCKET="$SOCKET"
tmux_t() { tmux -L "$SOCKET" "$@"; }

work="$(mktemp -d)"
export HOME="$work/home"
mkdir -p "$HOME"
cleanup() {
  tmux_t kill-server 2>/dev/null || true
  rm -rf "$work" 2>/dev/null || {
    sleep 0.2
    rm -rf "$work" 2>/dev/null || true
  }
}
trap cleanup EXIT

pass=0
fail=0
check() {
  local desc="$1" cond="$2"
  if [ "$cond" = "0" ]; then
    printf 'ok   - %s\n' "$desc"
    pass=$((pass + 1))
  else
    printf 'FAIL - %s\n' "$desc"
    fail=$((fail + 1))
  fi
}

run() { "$script" "$@"; }

# A throwaway repo with one commit on main, plus a detached client so
# switch-client has a context to act on (as it would under a real `prefix W`).
repo="$work/myrepo"
mkdir -p "$repo"
git -C "$repo" init -q -b main
git -C "$repo" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
tmux_t new-session -d -s bootstrap -c "$repo"

wt_dir="$work/myrepo-worktrees"

# --- fresh: creates worktree + branch off main, seeds windows, launches agent ---
run --name feature-x --path "$repo" >/dev/null 2>&1 || true

[ -d "$wt_dir/feature-x" ]
check "fresh creates the sibling worktree dir" "$?"

git -C "$repo" worktree list | grep -Fq "$wt_dir/feature-x"
check "worktree is registered with git" "$?"

[ "$(git -C "$wt_dir/feature-x" rev-parse --abbrev-ref HEAD)" = "feature-x" ]
check "worktree is on a new branch named after the worktree" "$?"

tmux_t has-session -t feature-x 2>/dev/null
check "session is created" "$?"

got="$(tmux_t list-windows -t feature-x -F '#{window_name}' | tr '\n' ' ' | sed 's/ $//')"
[ "$got" = "agents vim git" ]
check "session seeds the default windows" "$?"

# Every window is *spawned* in the worktree. We check pane_start_path, not
# pane_current_path: the latter follows the live shell and lags during zsh/
# oh-my-zsh init (it can briefly read as the shell's startup dir), which made an
# earlier version of this assertion flaky. start_path is where tmux spawned the
# pane and is stable. macOS symlinks /var -> /private/var, so compare by inode.
wt_real="$(cd "$wt_dir/feature-x" && pwd -P)"
roots_ok=0
while IFS= read -r p; do
  [ "$(cd "$p" 2>/dev/null && pwd -P)" = "$wt_real" ] || roots_ok=1
done < <(tmux_t list-windows -t feature-x -F '#{pane_start_path}')
check "all windows are spawned in the worktree" "$roots_ok"

# The agent command was typed into the agents window (default: claude). The test
# host may lack a claude binary, so we assert the prompt history, not a process.
tmux_t capture-pane -p -t feature-x:agents | grep -q 'claude'
check "an agent (claude) is launched in the agents window" "$?"

# Forks from the LOCAL default-branch tip, including commits not pushed to
# origin. Simulate a repo whose local master is ahead of origin/master (the
# push-to-master case) and assert the worktree starts from the local tip.
ahead="$work/ahead"
git clone -q "$repo" "$ahead"          # origin = repo, fresh clone on its default branch
# Advance local default branch one commit past origin.
git -C "$ahead" -c user.email=t@t -c user.name=t commit -q --allow-empty -m local-only
local_tip="$(git -C "$ahead" rev-parse HEAD)"
origin_tip="$(git -C "$ahead" rev-parse '@{upstream}')"
run --name ahead-feat --path "$ahead" >/dev/null 2>&1 || true
forked_from="$(git -C "$work/ahead-worktrees/ahead-feat" rev-parse HEAD 2>/dev/null)"
[ "$forked_from" = "$local_tip" ] && [ "$local_tip" != "$origin_tip" ]
check "forks from the local default-branch tip, not the (stale) origin tip" "$?"

# --- idempotent: re-running reuses the worktree and does not duplicate it ---
before="$(git -C "$repo" worktree list | wc -l | tr -d ' ')"
run --name feature-x --path "$repo" >/dev/null 2>&1 || true
after="$(git -C "$repo" worktree list | wc -l | tr -d ' ')"
[ "$before" = "$after" ]
check "re-running reuses the worktree (idempotent)" "$?"

# --- existing branch, no worktree dir: attaches a worktree to that branch ---
git -C "$repo" branch hotfix main >/dev/null 2>&1
run --name hotfix --path "$repo" >/dev/null 2>&1 || true
[ "$(git -C "$wt_dir/hotfix" rev-parse --abbrev-ref HEAD)" = "hotfix" ]
check "existing branch is reused for the worktree" "$?"

# --- errors: existing target dir must be a real worktree ---
mkdir -p "$wt_dir/not-a-worktree"
if run --name not-a-worktree --path "$repo" >/dev/null 2>&1; then rc=0; else rc=1; fi
check "errors when target dir exists but is not a worktree" "$([ "$rc" -ne 0 ] && echo 0 || echo 1)"

# --- errors: not a repo, and missing name ---
# if-guarded so set -e doesn't abort the suite on the (expected) non-zero exit.
if run --name nope --path "$work" >/dev/null 2>&1; then rc=0; else rc=1; fi
check "errors when the path is not a git repo" "$([ "$rc" -ne 0 ] && echo 0 || echo 1)"

if run --path "$repo" >/dev/null 2>&1; then rc=0; else rc=1; fi
check "errors when no name is given" "$([ "$rc" -ne 0 ] && echo 0 || echo 1)"

# --- summary ---
printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
