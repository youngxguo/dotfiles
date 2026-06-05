#!/usr/bin/env bash
# Status-right AI idle indicator. The state is still owned by each agent pane's
# @ai_state option; this only renders the idle sessions as their list-order
# numbers so the bottom-right bar stays compact.
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/.tmux-lib.sh"

TMUX_BIN="$(tmux_resolve_bin)"

declare -A ai_state=()
while IFS=$'\t' read -r sid st; do
  case "$st" in
    thinking) ai_state[$sid]=thinking ;;
    idle)     [ "${ai_state[$sid]:-}" = thinking ] || ai_state[$sid]=idle ;;
  esac
done < <("$TMUX_BIN" list-panes -a -F '#{session_id}'$'\t''#{@ai_state}' 2>/dev/null)

blocks=()
idx=1
while IFS=$'\t' read -r sid _name; do
  case "${ai_state[$sid]:-}" in
    thinking) blocks+=("thinking:$idx") ;;
    idle)     blocks+=("idle:$idx") ;;
  esac
  idx=$((idx + 1))
done < <("$TMUX_BIN" list-sessions -F '#{session_id}'$'\t''#{session_name}' 2>/dev/null)

[ "${#blocks[@]}" -gt 0 ] || exit 0
for i in "${!blocks[@]}"; do
  if [ "$i" -gt 0 ]; then
    printf '#[fg=%s,bg=%s,nobold]|' "$TMUX_PALETTE_BASE01" "$TMUX_PALETTE_BASE02"
  fi
  state="${blocks[i]%%:*}"
  number="${blocks[i]#*:}"
  case "$state" in
    thinking) printf '#[fg=%s,bg=%s,bold] %s ' "$TMUX_PALETTE_BASE03" "$TMUX_PALETTE_YELLOW" "$number" ;;
    idle)     printf '#[fg=%s,bg=%s,bold] %s ' "$TMUX_PALETTE_BASE3" "$TMUX_PALETTE_RED" "$number" ;;
  esac
done
