#!/usr/bin/env bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/.tmux-lib.sh"

TMUX_BIN="$(tmux_resolve_bin)"
tmux_recreate_socket_dir

refresh_one() {
  local s="$1" path branch
  path=$("$TMUX_BIN" display-message -p -t "$s:" '#{pane_current_path}' 2>/dev/null) || return 0
  if branch="$(tmux_git_branch "$path")" && [ -n "$branch" ]; then
    "$TMUX_BIN" set-option -qt "$s" @git_branch "$branch"
  else
    "$TMUX_BIN" set-option -qut "$s" @git_branch
  fi
}

if [ -n "${1:-}" ]; then
  refresh_one "$1"
else
  while IFS= read -r s; do
    refresh_one "$s"
  done < <("$TMUX_BIN" list-sessions -F '#{session_name}')
fi
