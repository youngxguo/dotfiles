#!/usr/bin/env bash
# Push-based AI idle/thinking state for the sessions sidebar. Agent CLIs call this
# from their own hooks instead of the sidebar polling pane contents:
#   - Claude Code: UserPromptSubmit -> thinking, Stop -> idle, SessionEnd -> clear
#                  (see claude/ai-state-hooks.json, merged in by install.py)
#   - Codex:       notify (turn complete) -> idle (see codex/config.toml)
#
# State lives on the PANE the agent runs in (@ai_state = thinking|idle, unset when
# no agent is there). $TMUX_PANE is inherited by the hook, so it points at that
# pane. Keeping the truth on the pane is what lets it self-heal — a badge can't
# outlive the agent:
#   - the agent exits back to a shell -> the shell's precmd hook clears the pane
#     (~/.zshrc), which also covers Codex (it has no exit hook) and hard crashes;
#   - the pane is killed outright       -> tmux drops the pane option with the pane.
# The sidebar aggregates the live pane states per session every time it renders, so
# nothing has to poll to retire a stale badge. We also mirror the aggregate onto
# the session (@session_ai_idle / @session_ai_thinking) for the `prefix s` tree
# menu, which can only read session-scoped options.
#
# `idle` also fires a desktop notification, so finishing a turn pings you — but
# only for a session you're NOT currently watching.
#
# This replaces the old capture-pane poller entirely: agents the hooks can't reach
# (e.g. one running an ssh hop past the host the tmux server lives on) simply show
# no badge rather than being scraped.
#
# Subcommands (the target pane is always $TMUX_PANE):
#   thinking   mark the pane busy   (set thinking)
#   idle       mark the pane idle    (set idle, notify)
#   clear      clear the pane         (agent gone)
#
# install.py symlinks this to ~/.tmux-ai-state.sh via its `.tmux-*.sh` glob.
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/.tmux-lib.sh"
TMUX_BIN="$(tmux_resolve_bin)"
SIDEBAR="$SCRIPT_DIR/.tmux-sidebar.sh"

# Hooks run inside the agent's pane, so $TMUX_PANE points at it. Without it we
# can't attribute state — bail quietly (agent run outside tmux, or one ssh hop
# away where the local tmux socket isn't reachable).
pane="${TMUX_PANE:-}"
[ -n "$pane" ] || exit 0
session="$("$TMUX_BIN" display-message -p -t "$pane" '#{session_id}' 2>/dev/null)" || exit 0
[ -n "$session" ] || exit 0

set_idle()     { "$TMUX_BIN" set-option -pqt "$pane" @ai_state idle; }
set_thinking() { "$TMUX_BIN" set-option -pqt "$pane" @ai_state thinking; }
clear_pane()   { "$TMUX_BIN" set-option -pqut "$pane" @ai_state; }

# Re-derive the session-level mirror from the live pane states, so the tree menu
# (prefix s) and any other session-scoped reader stay in step with the panes.
# thinking outranks idle (any busy pane => the session reads busy); neither set
# clears both flags.
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

# Mirror the old poller's idle ping: "❕ AI Idle / • (N) name branch" via OSC 9 to
# every client tty, so it surfaces on the attached terminal (incl. over ssh).
# Skip it when the just-idled session is the one you're already attached to —
# you don't need a notification for the pane in front of you.
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
    [ -n "$ctty" ] && printf '\033]9;%s\a' "$msg" > "$ctty" 2>/dev/null || true
  done < <("$TMUX_BIN" list-clients -F '#{client_tty}' 2>/dev/null)
}

case "${1:-}" in
  thinking) set_thinking ;;
  idle)     set_idle; notify_idle ;;
  clear)    clear_pane ;;
  *) printf 'usage: %s {thinking|idle|clear}\n' "${0##*/}" >&2; exit 2 ;;
esac

# Refresh the session mirror and wake the visible rail(s) so the badge change
# shows immediately.
sync_session
"$SIDEBAR" refresh >/dev/null 2>&1 || true
