#!/usr/bin/env bash
# Companion to .tmux-setup-sessions.sh, invoked by the `prefix t` binding after
# the (purely structural) setup helper has ensured the windows exist. Drops the
# session's "vim" window into Neovim + Diffview (the same working-tree view as
# <leader>gd) so a fresh project setup lands ready to review changes.
#
# App-launching and pane-probing live here, not in the setup helper, which is
# kept structural on purpose (see .githooks/pre-push). Idempotent: if the vim
# window is already running an editor it's left alone, so re-running `prefix t`
# never disturbs an open session.
set -euo pipefail

session="${1:?usage: .tmux-setup-vim.sh SESSION [WINDOW]}"
window="${2:-vim}"

tmux_cmd=(tmux)
if [ -n "${TMUX_SETUP_SOCKET:-}" ]; then
  tmux_cmd=(tmux -L "$TMUX_SETUP_SOCKET")
fi

target="$session:$window"

# No matching window (e.g. a custom --windows set without "vim"): nothing to do.
"${tmux_cmd[@]}" list-windows -t "$session:" -F '#{window_name}' 2>/dev/null \
  | grep -Fxq "$window" || exit 0

# Already editing there? Leave it be so re-running setup is non-destructive.
cur="$("${tmux_cmd[@]}" display-message -p -t "$target" '#{pane_current_command}' 2>/dev/null || true)"
case "$cur" in
  nvim | vim | vi | nano | hx) exit 0 ;;
esac

# -c DiffviewOpen runs after startup and triggers the lazy-loaded plugin,
# matching open_diff() (<leader>gd) on a fresh session. Typed into the window's
# shell rather than run as its command, so quitting Neovim returns to a prompt.
"${tmux_cmd[@]}" send-keys -t "$target" 'nvim -c DiffviewOpen' Enter
