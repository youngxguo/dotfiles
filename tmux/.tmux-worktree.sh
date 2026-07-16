#!/usr/bin/env bash
# Create a git worktree and a matching tmux session in one step, with Codex and
# Neovim side by side in a single window.
#
# `prefix W` prompts for a NAME, then this script:
#   1. resolves the primary repo root from the pane's directory (errors if not a
#      repo),
#   2. adds a worktree at ../<repo>-worktrees/<NAME> on a new branch <NAME>,
#      forked from the local tip of the repo's default branch (main/master),
#   3. creates a <repo>-<NAME> session with one "work" window containing two
#      side-by-side panes rooted in the new worktree,
#   4. launches Codex in the left pane and Neovim in the right pane.
#
# Idempotent: if the worktree and session already exist they are reused without
# duplicating panes or relaunching Codex/Neovim. install.py symlinks this to
# ~/.tmux-worktree.sh via its `.tmux-*.sh` glob.
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/.tmux-lib.sh"

# Drive tmux through the same socket the sibling setup helpers use. Normally
# that's the default socket (tmux_resolve_bin); TMUX_SETUP_SOCKET overrides it so
# the whole flow can be exercised end-to-end on a throwaway socket under test.
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
../<repo>-worktrees/NAME, then a tmux session <repo>-NAME with one side-by-side
Codex/Neovim window. The repo prefix keeps sidebar entries identifiable.

Options:
  --name NAME   Worktree and branch name (required)
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

seed_local_agent_instructions() {
  local src_root="$1"
  local dst_root="$2"
  local rel src dst exclude_file

  for rel in AGENTS.md CLAUDE.md; do
    src="$src_root/$rel"
    dst="$dst_root/$rel"
    [ -f "$src" ] || continue
    [ ! -e "$dst" ] || continue
    git -C "$src_root" ls-files --error-unmatch -- "$rel" >/dev/null 2>&1 && continue

    cp -p "$src" "$dst" || fail "could not copy local $rel into worktree"
    exclude_file="$(git -C "$dst_root" rev-parse --git-path info/exclude 2>/dev/null)" || continue
    mkdir -p "$(dirname "$exclude_file")" || fail "could not create git exclude dir"
    touch "$exclude_file" || fail "could not update git exclude file"
    grep -Fxq "/$rel" "$exclude_file" 2>/dev/null || printf '/%s\n' "$rel" >>"$exclude_file"
  done
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

seed_local_agent_instructions "$current_repo_root" "$worktree_path"
[ "$current_repo_root" = "$repo_root" ] || seed_local_agent_instructions "$repo_root" "$worktree_path"

# Prefix the task/branch name with the main repository folder so the sidebar
# keeps enough project context when several repositories have worktree sessions.
# tmux target syntax gives "." and ":" special meaning, so fold both to "_".
session="$(basename "$repo_root")-$name"
session="${session//[.:]/_}"
if ! "${tmux_bin[@]}" has-session -t "$session" 2>/dev/null; then
  codex_pane="$("${tmux_bin[@]}" new-session -d -s "$session" -n work \
    -c "$worktree_path" -P -F '#{pane_id}')" \
    || fail "session setup failed"
  vim_pane="$("${tmux_bin[@]}" split-window -h -d -t "$codex_pane" \
    -c "$worktree_path" -P -F '#{pane_id}')" \
    || fail "Neovim pane setup failed"
  "${tmux_bin[@]}" select-layout -t "$session:work" even-horizontal >/dev/null \
    || fail "pane layout failed"
  tmux_launch_agent "$codex_pane" codex "${tmux_bin[@]}"
  "${tmux_bin[@]}" send-keys -t "$vim_pane" nvim Enter
fi

"${tmux_bin[@]}" set-option -qt "$session" @git_branch "$name" 2>/dev/null || true
"${tmux_bin[@]}" switch-client -t "$session" 2>/dev/null || true
