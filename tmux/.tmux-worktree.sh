#!/usr/bin/env bash
# Create a git worktree and a matching tmux session in one step, seeded with the
# same agents/vim windows as `prefix t`, with an agent launched and ready.
#
# `prefix W` prompts for a NAME, then this script:
#   1. resolves the primary repo root from the pane's directory (errors if not a
#      repo),
#   2. adds a worktree at ../<repo>-worktrees/<NAME> on a new branch <NAME>,
#      forked from the local tip of the repo's default branch (main/master),
#   3. delegates session + window creation to .tmux-setup-sessions.sh and the
#      editor launch to .tmux-setup-vim.sh (the same helpers `prefix t` uses),
#   4. launches an agent in the "agents" window via tmux_launch_agent.
#
# Idempotent: if the worktree already exists it is reused, and setup-sessions
# re-attaches rather than duplicating windows. The worktree mechanics are the
# only new logic here; everything structural is reused. install.py symlinks this
# to ~/.tmux-worktree.sh via its `.tmux-*.sh` glob.
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/.tmux-lib.sh"

# Drive tmux through the same socket the sibling setup helpers use. Normally
# that's the default socket (tmux_resolve_bin); TMUX_SETUP_SOCKET overrides it so
# the whole flow can be exercised end-to-end on a throwaway socket under test,
# matching .tmux-setup-sessions.sh / .tmux-setup-vim.sh.
tmux_bin=("$(tmux_resolve_bin)")
[ -n "${TMUX_SETUP_SOCKET:-}" ] && tmux_bin+=(-L "$TMUX_SETUP_SOCKET")

# Where worktrees live: a sibling dir next to the repo, ../<repo>-worktrees/.
# Never inside the repo (no gitignore upkeep, no tools recursing in) and easy to
# find. Override the parent layout by editing worktree_path below.
worktree_root_suffix="-worktrees"

name=""
src_path="$PWD"

usage() {
  cat <<'EOF'
Usage: .tmux-worktree.sh --name NAME [--path DIR]

Create a git worktree (branch NAME, forked from the repo default branch) at
../<repo>-worktrees/NAME, then a tmux session NAME with agents/vim windows
and an agent launched in the agents window.

Options:
  --name NAME   Worktree, branch, and session name (required)
  --path DIR    A directory inside the target repo (default: cwd)
  -h, --help    Show this help
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --name) name="${2:?missing value for --name}"; shift 2 ;;
    --path) src_path="${2:?missing value for --path}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'unknown argument: %s\n\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
done

# Surface failures in tmux's message line (run-shell output is otherwise hidden
# in a copy buffer) as well as on stderr.
fail() {
  "${tmux_bin[@]}" display-message "worktree: $*" 2>/dev/null || true
  printf 'worktree: %s\n' "$*" >&2
  exit 1
}

[ -n "$name" ] || fail "a name is required"

current_repo_root="$(git -C "$src_path" rev-parse --show-toplevel 2>/dev/null)" \
  || fail "$src_path is not a git repository"
repo_root="$(git -C "$src_path" worktree list --porcelain 2>/dev/null | sed -n '1s/^worktree //p')" \
  || fail "could not resolve the main worktree"
[ -n "$repo_root" ] || repo_root="$current_repo_root"

worktree_path="$(dirname "$repo_root")/$(basename "$repo_root")$worktree_root_suffix/$name"

# Create the worktree unless it's already there (reuse-if-present). Branch off the
# default branch's tip; if a branch named NAME already exists, attach the
# worktree to it rather than failing on -b.
if [ -d "$worktree_path" ]; then
  existing_root="$(git -C "$worktree_path" rev-parse --show-toplevel 2>/dev/null)" \
    || fail "$worktree_path exists but is not a git worktree"
  [ "$existing_root" = "$worktree_path" ] \
    || fail "$worktree_path exists but resolves to a nested git repo"
else
  mkdir -p "$(dirname "$worktree_path")" || fail "could not create worktree parent dir"
  if git -C "$repo_root" show-ref --verify -q "refs/heads/$name"; then
    git -C "$repo_root" worktree add "$worktree_path" "$name" \
      || fail "git worktree add (existing branch $name) failed"
  else
    base="$(tmux_default_branch "$repo_root")" \
      || fail "could not resolve a default branch to fork from"
    git -C "$repo_root" worktree add -b "$name" "$worktree_path" "$base" \
      || fail "git worktree add -b $name from $base failed"
  fi
fi

# Structural session + windows, then the editor launch — the exact helpers
# `prefix t` uses, so behavior stays in sync. We pass --no-attach and switch the
# invoking client ourselves below, rather than relying on setup-sessions' attach
# branch: that branch keys off $TMUX, which tmux does not reliably export into
# the run-shell environment `prefix W` runs us in.
"$SCRIPT_DIR/.tmux-setup-sessions.sh" --no-attach --name "$name" "$worktree_path" \
  || fail "session setup failed"
"$SCRIPT_DIR/.tmux-setup-vim.sh" "$name" || true

# tmux folds "." and ":" in session names; mirror setup-sessions so we target the
# right session.
session="${name//[.:]/_}"
"${tmux_bin[@]}" set-option -qt "$session" @git_branch "$name" 2>/dev/null || true
tmux_launch_agent "$session:agents" "" "${tmux_bin[@]}"
"${tmux_bin[@]}" switch-client -t "$session" 2>/dev/null || true
