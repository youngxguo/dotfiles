#!/usr/bin/env bash
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/.tmux-lib.sh"
TMUX_BIN="$(tmux_resolve_bin)"
SIDEBAR="$SCRIPT_DIR/.tmux-sidebar.sh"

pane="${TMUX_PANE:-}"
[ -n "$pane" ] || exit 0
session="$("$TMUX_BIN" display-message -p -t "$pane" '#{session_id}' 2>/dev/null)" || exit 0
[ -n "$session" ] || exit 0

set_idle()     { "$TMUX_BIN" set-option -pqt "$pane" @ai_state idle; }
set_thinking() { "$TMUX_BIN" set-option -pqt "$pane" @ai_state thinking; }
clear_pane()   { "$TMUX_BIN" set-option -pqut "$pane" @ai_state; }
pane_state()   { "$TMUX_BIN" show-options -pqv -t "$pane" @ai_state 2>/dev/null; }

# choose-tree formats can only read session-scoped options, so mirror the pane
# states onto the session.
sync_session() {
  local any_think=0 any_idle=0 st
  while IFS= read -r st; do
    case "$st" in thinking) any_think=1 ;; idle) any_idle=1 ;; esac
  done < <("$TMUX_BIN" list-panes -s -t "$session" -F '#{@ai_state}' 2>/dev/null)
  if [ "$any_think" = 1 ]; then
    "$TMUX_BIN" set-option -qt "$session" @session_ai_thinking 1
    "$TMUX_BIN" set-option -qut "$session" @session_ai_idle
  elif [ "$any_idle" = 1 ]; then
    "$TMUX_BIN" set-option -qt "$session" @session_ai_idle 1
    "$TMUX_BIN" set-option -qut "$session" @session_ai_thinking
  else
    "$TMUX_BIN" set-option -qut "$session" @session_ai_idle
    "$TMUX_BIN" set-option -qut "$session" @session_ai_thinking
  fi
}

sync_branch() {
  local path branch
  path="$("$TMUX_BIN" display-message -p -t "$pane" '#{pane_current_path}' 2>/dev/null)"
  [ -n "$path" ] || return 0
  branch="$(tmux_git_branch "$path")"
  if [ -n "$branch" ]; then
    "$TMUX_BIN" set-option -qt "$session" @git_branch "$branch"
  else
    "$TMUX_BIN" set-option -qut "$session" @git_branch
  fi
}

osc9_notify() { printf '\033]9;%s\a' "$1"; }

notify_idle() {
  local attached name path idx branch label msg ctty
  attached="$("$TMUX_BIN" display-message -p -t "$pane" '#{session_attached}' 2>/dev/null)"
  [ "${attached:-0}" != "0" ] && return 0
  name="$("$TMUX_BIN" display-message -p -t "$pane" '#{session_name}' 2>/dev/null)"
  path="$("$TMUX_BIN" display-message -p -t "$pane" '#{pane_current_path}' 2>/dev/null)"
  idx="$("$TMUX_BIN" list-sessions -F '#{session_id}' 2>/dev/null | grep -nxF "$session" | cut -d: -f1)"
  branch="$(tmux_git_branch "$path")"
  label="(${idx:-?}) ${name}${branch:+ $branch}"
  msg="❕ AI Idle"$'\n'" • ${label}"
  while IFS= read -r ctty; do
    [ -n "$ctty" ] && osc9_notify "$msg" > "$ctty" 2>/dev/null || true
  done < <("$TMUX_BIN" list-clients -F '#{client_tty}' 2>/dev/null)
}

case "${1:-}" in
  thinking) set_thinking ;;
  idle)
    previous_state="$(pane_state)"
    set_idle
    [ "$previous_state" = idle ] || notify_idle
    ;;
  clear)    clear_pane ;;
  *) printf 'usage: %s {thinking|idle|clear}\n' "${0##*/}" >&2; exit 2 ;;
esac

sync_session
sync_branch
"$TMUX_BIN" refresh-client -S >/dev/null 2>&1 || true
"$SIDEBAR" refresh >/dev/null 2>&1 || true
