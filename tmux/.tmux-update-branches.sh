#!/usr/bin/env bash
# Publish a session's current git branch as its @git_branch option, consumed by
# the sidebar and the choose-tree binding.
#
# With a session NAME argument, refresh only that one; with none, refresh every
# session. The focus / session-change hooks pass the focused session (see
# ~/.tmux.conf), so a branch switched OUTSIDE tmux — another terminal, a GUI git
# client, an editor — is picked up the moment you look at or switch to its
# session, re-deriving just that session rather than walking them all. The
# argument-less walk stays the startup backfill and the `prefix s` refresh.
#
# install.py symlinks this to ~/.tmux-update-branches.sh via its `.tmux-*.sh` glob.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/.tmux-lib.sh"

TMUX_BIN="$(tmux_resolve_bin)"
tmux_recreate_socket_dir

# Set (or clear) one session's @git_branch from its active pane's directory.
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
