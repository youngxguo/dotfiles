#!/usr/bin/env bash
# Split the current tmux pane, rebalancing the layout to match the existing
# split bindings. In the "agents" window only, if the source pane is running a
# known agent CLI (claude, codex), launch that same command in the new pane so
# you don't have to retype it.
#
# Usage: .tmux-agent-split.sh <orientation> <pane_id>
#   orientation: h (horizontal split) | v (vertical split)
#   pane_id:     tmux pane id of the pane being split (e.g. %3)
set -u

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

window_name="$(tmux display-message -p "${target[@]}" '#{window_name}')"
pane_path="$(tmux display-message -p "${target[@]}" '#{pane_current_path}')"
pane_pid="$(tmux display-message -p "${target[@]}" '#{pane_pid}')"

# Walk the pane's process subtree and return the first known agent CLI found.
# Matches on `comm` (the executable basename), which reports `claude`/`codex`
# reliably even when the app rewrites its process title (claude shows its
# version string in pane_current_command, but comm stays `claude`).
detect_agent() {
  local pid="$1" child comm base result
  for child in $(pgrep -P "$pid" 2>/dev/null); do
    comm="$(ps -o comm= -p "$child" 2>/dev/null)"
    base="${comm##*/}"
    case "$base" in
      claude|codex) printf '%s\n' "$base"; return 0 ;;
    esac
    if result="$(detect_agent "$child")"; then
      printf '%s\n' "$result"
      return 0
    fi
  done
  return 1
}

agent_cmd=""
if [ "$window_name" = "agents" ]; then
  agent_cmd="$(detect_agent "$pane_pid" || true)"
fi

new_pane="$(tmux split-window "$split_flag" -c "$pane_path" "${target[@]}" -P -F '#{pane_id}')"
tmux select-layout "${target[@]}" "$layout"

if [ -n "$agent_cmd" ]; then
  tmux send-keys -t "$new_pane" "$agent_cmd" Enter
fi
