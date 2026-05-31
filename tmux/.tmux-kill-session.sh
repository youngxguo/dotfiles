#!/usr/bin/env bash
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/.tmux-lib.sh"

TMUX_BIN="$(tmux_resolve_bin)"

current="${1:-}"
client="${2:-}"

[ -n "$current" ] || current="$("$TMUX_BIN" display-message -p '#{session_name}' 2>/dev/null || true)"
[ -n "$current" ] || exit 0

exact_target() {
  printf '=%s' "$1"
}

target="$(
  "$TMUX_BIN" list-sessions -F '#{session_name}' 2>/dev/null \
    | awk -v current="$current" '$0 != current { print; exit }'
)"

if [ -n "$target" ]; then
  if [ -n "$client" ]; then
    "$TMUX_BIN" switch-client -c "$client" -t "$(exact_target "$target")" 2>/dev/null \
      || "$TMUX_BIN" switch-client -t "$(exact_target "$target")" 2>/dev/null \
      || exit 1
  else
    "$TMUX_BIN" switch-client -t "$(exact_target "$target")" 2>/dev/null || exit 1
  fi
fi

"$TMUX_BIN" kill-session -t "$(exact_target "$current")" 2>/dev/null || true
