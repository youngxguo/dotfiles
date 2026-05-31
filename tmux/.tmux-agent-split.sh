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
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/.tmux-lib.sh"

TMUX_BIN="$(tmux_resolve_bin)"

orientation="${1:-h}"
pane_id="${2:-}"

case "$orientation" in
  v) split_flag="-v"; orientation="v" ;;
  *) split_flag="-h"; orientation="h" ;;
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
split_window_id="$("$TMUX_BIN" display-message -p -t "$new_pane" '#{window_id}')"

# Rebalance the window evenly. The sidebar helper handles both cases: with a
# sessions rail present it lifts the rail out — pinning it as a fixed-width left
# column and spreading only the other panes — instead of letting the even-spread
# flatten it into an equal-width sibling; with no rail it's the plain even-*
# spread the split bindings have always done. See ~/.tmux-sidebar.sh.
"$SCRIPT_DIR/.tmux-sidebar.sh" rebalance "$split_window_id" "$orientation" 2>/dev/null || true

if [ -n "$agent_cmd" ]; then
  tmux_launch_agent "$new_pane" "$agent_cmd" "$TMUX_BIN"
fi
