#!/bin/sh
# Stamp the start of each turn per session so the statusline can show how long
# the current prompt has been running (claude/statusline-command.sh reads the
# stamp; statusLine.refreshInterval=1 makes it tick every second).
# Wired in claude/settings.json: UserPromptSubmit -> start, Stop/SessionEnd -> clear.
# install.py symlinks this to ~/.claude/hooks/prompt-timer.sh.
# Known gap: Stop doesn't fire on an Escape interrupt, so the stamp lingers
# until the next prompt — same limitation as the tmux @ai_state badge.
TIMER_DIR="$HOME/.claude/prompt-timer"
mkdir -p "$TIMER_DIR"

session_id=$(python3 -c "import sys,json; print(json.load(sys.stdin).get('session_id',''))" 2>/dev/null)
[ -n "$session_id" ] || exit 0

case "${1:-}" in
  start)
    date +%s > "$TIMER_DIR/$session_id"
    # Prune stamps from long-dead sessions so the dir stays small.
    find "$TIMER_DIR" -type f -mtime +7 -delete 2>/dev/null
    ;;
  clear)
    rm -f "$TIMER_DIR/$session_id"
    ;;
esac
exit 0
