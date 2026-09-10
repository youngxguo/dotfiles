#!/usr/bin/env bash
set -euo pipefail

session="${1:?usage: .tmux-setup-vim.sh SESSION [WINDOW]}"
window="${2:-vim}"

tmux_cmd=(tmux)
if [ -n "${TMUX_SETUP_SOCKET:-}" ]; then
  tmux_cmd=(tmux -L "$TMUX_SETUP_SOCKET")
fi

target="$session:$window"

"${tmux_cmd[@]}" list-windows -t "$session:" -F '#{window_name}' 2>/dev/null \
  | grep -Fxq "$window" || exit 0

cur="$("${tmux_cmd[@]}" display-message -p -t "$target" '#{pane_current_command}' 2>/dev/null || true)"
case "$cur" in
  nvim | vim | vi | nano | hx) exit 0 ;;
esac

"${tmux_cmd[@]}" send-keys -t "$target" 'nvim -c DiffviewOpen' Enter
