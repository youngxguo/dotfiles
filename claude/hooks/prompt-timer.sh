#!/bin/sh
# Claude Code fires no Stop hook on an Escape interrupt, so a stamp can linger
# until the next prompt.
TIMER_DIR="$HOME/.claude/prompt-timer"
mkdir -p "$TIMER_DIR"

session_id=$(python3 -c "import sys,json; print(json.load(sys.stdin).get('session_id',''))" 2>/dev/null)
[ -n "$session_id" ] || exit 0

case "${1:-}" in
  start)
    date +%s > "$TIMER_DIR/$session_id"
    find "$TIMER_DIR" -type f -mtime +7 -delete 2>/dev/null
    ;;
  clear)
    rm -f "$TIMER_DIR/$session_id"
    ;;
esac
exit 0
