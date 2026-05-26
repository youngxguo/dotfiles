#!/usr/bin/env bash
# Split the current tmux pane, rebalancing the layout to match the existing
# split bindings. If the source pane is running a known agent CLI
# (TMUX_AGENT_COMMANDS in ~/.tmux-lib.sh), launch that same command in the new
# pane so you don't have to retype it.
#
# Usage: .tmux-agent-split.sh <orientation> <pane_id>
#   orientation: h (horizontal split) | v (vertical split)
#   pane_id:     tmux pane id of the pane being split (e.g. %3)
set -u
source "$HOME/.tmux-lib.sh"

TMUX_BIN="$(tmux_resolve_bin)"

orientation="${1:-h}"
pane_id="${2:-}"

case "$orientation" in
  v) split_flag="-v"; layout="even-vertical" ;;
  *) split_flag="-h"; layout="even-horizontal" ;;
esac

# Window/pane that should be the source of the agent command we mirror, named
# explicitly so we don't depend on whichever pane tmux considers "current".
target=()
[ -n "$pane_id" ] && target=(-t "$pane_id")

pane_path="$("$TMUX_BIN" display-message -p "${target[@]}" '#{pane_current_path}')"
pane_pid="$("$TMUX_BIN" display-message -p "${target[@]}" '#{pane_pid}')"

# Walk the pane's process subtree and return the first known agent CLI found
# (TMUX_AGENT_COMMANDS, shared with the idle detector). Matches on `comm` (the
# executable basename), which reports `claude`/`codex` reliably even when the app
# rewrites its process title (claude shows its version string in
# pane_current_command, but comm stays `claude`).
detect_agent() {
  local pid="$1" child comm result
  for child in $(pgrep -P "$pid" 2>/dev/null); do
    comm="$(ps -o comm= -p "$child" 2>/dev/null)"
    if tmux_is_agent_command "$comm"; then
      printf '%s\n' "${comm##*/}"
      return 0
    fi
    if result="$(detect_agent "$child")"; then
      printf '%s\n' "$result"
      return 0
    fi
  done
  return 1
}

agent_cmd="$(detect_agent "$pane_pid" || true)"

new_pane="$("$TMUX_BIN" split-window "$split_flag" -c "$pane_path" "${target[@]}" -P -F '#{pane_id}')"
"$TMUX_BIN" select-layout "${target[@]}" "$layout"

if [ -n "$agent_cmd" ]; then
  "$TMUX_BIN" send-keys -t "$new_pane" "$agent_cmd" Enter
fi
