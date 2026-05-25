#!/usr/bin/env bash
# Publish each session's current git branch as the @git_branch session option,
# consumed by the status line, the choose-tree binding, and the fzf picker.
source "$HOME/.tmux-lib.sh"

TMUX_BIN="$(tmux_resolve_bin)"
tmux_recreate_socket_dir

while IFS= read -r s; do
  path=$("$TMUX_BIN" display-message -p -t "$s:" '#{pane_current_path}' 2>/dev/null) || continue
  if branch="$(tmux_git_branch "$path")" && [ -n "$branch" ]; then
    "$TMUX_BIN" set-option -qt "$s" @git_branch "$branch"
  else
    "$TMUX_BIN" set-option -qut "$s" @git_branch
  fi
done < <("$TMUX_BIN" list-sessions -F '#{session_name}')
