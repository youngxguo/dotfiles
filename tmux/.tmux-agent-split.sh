#!/usr/bin/env bash
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

target=()
[ -n "$pane_id" ] && target=(-t "$pane_id")

pane_path="$("$TMUX_BIN" display-message -p "${target[@]}" '#{pane_current_path}')"
pane_pid="$("$TMUX_BIN" display-message -p "${target[@]}" '#{pane_pid}')"

# Match on `comm`: claude rewrites its process title, so pane_current_command
# shows its version string while comm stays `claude`.
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

"$SCRIPT_DIR/.tmux-sidebar.sh" rebalance "$split_window_id" "$orientation" 2>/dev/null || true

if [ -n "$agent_cmd" ]; then
  tmux_launch_agent "$new_pane" "$agent_cmd" "$TMUX_BIN"
fi
