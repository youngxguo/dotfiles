#!/usr/bin/env bash
# Persistent sessions sidebar for tmux — a fixed-width, full-height rail pinned
# to the leftmost column of EVERY window, so it reads as one global sidebar that
# the windows live to the right of, rather than a per-window pane.
#
# It live-renders every session with the same AI idle (!) / thinking (💭) badges
# and git branch as the status line, fzf picker, and choose-tree. Idle sessions
# float to the top; the number shown stays each session's list-order index, so it
# matches the 1-9 hotkeys in the `prefix s` picker (and the `switch` subcommand).
#
# Always-on: every new window gets a rail via the window-linked hook, and
# ensure-all backfills existing windows at config load. The rail is created with
# split-window -bf (before + full height) so it spans the whole left edge even
# when the window already has content splits. It never steals focus (-d).
#
# The rail is lifted out of normal pane rebalancing: a whole-window even-spread
# (even-*/-E) would flatten it into an equal-width sibling, so on a rail window we
# instead hand-build a layout that keeps the rail a fixed-width, full-height left
# column and spreads only the OTHER panes evenly across the rest of the window
# (cmd_rebalance / build_sidebar_layout). `prefix b` hides/shows it everywhere at
# once — the shown/hidden state is one global flag (@sidebar_enabled), not per
# window, so it stays consistent across every window and session.
#
# AI-state and @git_branch session options are populated by ~/.tmux-ai-idle.sh
# and ~/.tmux-update-branches.sh.
#
# Subcommands:
#   toggle                      hide/show the rail everywhere (global state)
#   ensure [window]             create the rail in a window if absent (hook)
#   ensure-all                  backfill every window (config load / server start)
#   reset-all                   normalize every window to one correct rail (repair)
#   switch <n>                  switch to the Nth session (Cmd-1..9)
#   refresh                     wake sidebar panes so they redraw immediately
#   render                      the redraw loop (runs *inside* the rail pane)
#   fix <window>                pin the rail to SIDEBAR_WIDTH; tidy @has_sidebar
#   rebalance <win> [h|v]       spread the panes evenly; with a rail present keep
#                               it lifted out and only spread the rest
#   layout-hook <ev> <win> <z>  hook entrypoint: rebalance normally, but lift the
#                               rail out of the spread when one is present
#
# install.py symlinks this to ~/.tmux-sidebar.sh via its `.tmux-*.sh` glob.
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_PATH="$SCRIPT_DIR/${BASH_SOURCE[0]##*/}"
source "$SCRIPT_DIR/.tmux-lib.sh"

TMUX_BIN="$(tmux_resolve_bin)"

# Sidebar width in columns. Override with SIDEBAR_WIDTH in the environment.
WIDTH="${SIDEBAR_WIDTH:-26}"

# Whether the rail is shown. This is a single GLOBAL state (the server option
# @sidebar_enabled), not per-window: toggling in one window shows/hides the rail
# in every window of every session, so it reads as one sidebar. Unset means on,
# matching the always-open default; only an explicit "0" turns it off. The state
# survives config reloads (we never reset it) and resets to on at server start.
sidebar_enabled() {
  [ "$("$TMUX_BIN" show-options -gv @sidebar_enabled 2>/dev/null)" != "0" ]
}

# Find the sidebar pane in a window (panes carry @sidebar=1). Prints
# "<pane_id> <pane_width>" or nothing.
sidebar_pane() {
  "$TMUX_BIN" list-panes -t "$1" -F '#{pane_id} #{pane_width} #{@sidebar}' 2>/dev/null \
    | awk '$3 == "1" { print $1, $2; exit }'
}

# Pin the sidebar back to WIDTH, or tidy up if it's gone. Resizing only when the
# width actually differs keeps the after-resize-pane hook from ping-ponging.
cmd_fix() {
  local win="$1" pid w
  read -r pid w < <(sidebar_pane "$win")
  if [ -z "${pid:-}" ]; then
    "$TMUX_BIN" set-window-option -t "$win" -qu @has_sidebar 2>/dev/null
    "$TMUX_BIN" select-layout -t "$win" -E 2>/dev/null || true
    return 0
  fi
  [ "$w" != "$WIDTH" ] && "$TMUX_BIN" resize-pane -t "$pid" -x "$WIDTH" 2>/dev/null || true
}

# Compute tmux's 16-bit layout checksum over a layout body (everything after the
# leading "csum," prefix). Mirrors layout_checksum() in tmux's layout-custom.c so
# we can hand select-layout a custom layout string we built ourselves.
layout_checksum() {
  local s="$1" csum=0 i c
  for (( i=0; i<${#s}; i++ )); do
    printf -v c '%d' "'${s:i:1}"
    csum=$(( (csum >> 1) + ((csum & 1) << 15) ))
    csum=$(( (csum + c) & 0xffff ))
  done
  printf '%04x' "$csum"
}

# select-layout fills layout cells by the window's *pane order*, ignoring the pane
# ids embedded in a custom layout string — so to keep the rail pinned leftmost it
# must be the first pane. Bubble it to the front with adjacent swap-panes, which
# slides it left one slot at a time and preserves every other pane's order.
move_sidebar_front() {
  local win="$1" sid="$2" guard=0 idx i left
  local -a order
  while [ "$guard" -lt 32 ]; do
    guard=$((guard + 1))
    order=()
    while IFS= read -r i; do order+=("$i"); done \
      < <("$TMUX_BIN" list-panes -t "$win" -F '#{pane_id}' 2>/dev/null)
    idx=-1
    for i in "${!order[@]}"; do [ "${order[i]}" = "$sid" ] && { idx=$i; break; }; done
    [ "$idx" -le 0 ] && return 0
    left="${order[idx-1]}"
    "$TMUX_BIN" swap-pane -d -s "$sid" -t "$left" 2>/dev/null || return 0
  done
}

# Guess how the non-rail panes are arranged so a reflow can match it: all sharing
# a top edge is a left-to-right row (h), all sharing a left edge is a stacked
# column (v). Anything else (a grid) prints nothing, so the caller leaves the
# structure alone and only re-pins the rail.
detect_rest_orientation() {
  local win="$1" id left top sb
  local -a tops=() lefts=()
  while read -r id left top sb; do
    [ "$sb" = "1" ] && continue
    tops+=("$top"); lefts+=("$left")
  done < <("$TMUX_BIN" list-panes -t "$win" \
            -F '#{pane_id} #{pane_left} #{pane_top} #{@sidebar}' 2>/dev/null)
  local ut ul
  ut="$(printf '%s\n' "${tops[@]}" | sort -u | wc -l)"
  ul="$(printf '%s\n' "${lefts[@]}" | sort -u | wc -l)"
  if [ "$ut" -le 1 ]; then printf 'h\n'
  elif [ "$ul" -le 1 ]; then printf 'v\n'
  fi
}

# Hand-build and apply a layout that pins the rail as a fixed-width, full-height
# column on the far left and spreads the remaining panes evenly across the rest of
# the window. orientation: h = rest side-by-side, v = rest stacked. Returns
# nonzero (caller falls back to just pinning) when the window is too narrow to
# honour the rail width or there is nothing else to spread.
build_sidebar_layout() {
  local win="$1" orientation="$2" sid="$3" W H
  read -r W H < <("$TMUX_BIN" display-message -p -t "$win" \
                   '#{window_width} #{window_height}' 2>/dev/null)
  [ -n "${W:-}" ] && [ -n "${H:-}" ] || return 1

  move_sidebar_front "$win" "$sid"
  local -a order=()
  local id
  while IFS= read -r id; do order+=("$id"); done \
    < <("$TMUX_BIN" list-panes -t "$win" -F '#{pane_id}' 2>/dev/null)
  [ "${order[0]:-}" = "$sid" ] || return 1
  local -a rest=("${order[@]:1}")
  local M=${#rest[@]}
  [ "$M" -ge 1 ] || return 1

  # WIDTH cols for the rail + 1 col border leaves R cols for the M other panes.
  local sep=1 restx=$((WIDTH + 1)) R=$((W - WIDTH - 1))
  [ "$R" -ge "$M" ] || return 1

  local sidebar_leaf="${WIDTH}x${H},0,0,${sid#%}" rest_str i base rem inner
  if [ "$M" -eq 1 ]; then
    rest_str="${R}x${H},${restx},0,${rest[0]#%}"
  elif [ "$orientation" = "v" ]; then
    [ "$H" -ge "$M" ] || return 1
    inner=$((H - (M - 1))); base=$((inner / M)); rem=$((inner % M))
    local y=0 h; local -a kids=()
    for (( i=0; i<M; i++ )); do
      h=$base; [ "$i" -lt "$rem" ] && h=$((base + 1))
      kids+=("${R}x${h},${restx},${y},${rest[i]#%}"); y=$((y + h + sep))
    done
    local IFS=,; rest_str="${R}x${H},${restx},0[${kids[*]}]"
  else
    inner=$((R - (M - 1))); base=$((inner / M)); rem=$((inner % M))
    local x=$restx w; local -a kids=()
    for (( i=0; i<M; i++ )); do
      w=$base; [ "$i" -lt "$rem" ] && w=$((base + 1))
      kids+=("${w}x${H},${x},0,${rest[i]#%}"); x=$((x + w + sep))
    done
    local IFS=,; rest_str="${R}x${H},${restx},0{${kids[*]}}"
  fi

  local body="${W}x${H},0,0{${sidebar_leaf},${rest_str}}"
  "$TMUX_BIN" select-layout -t "$win" "$(layout_checksum "$body"),${body}" 2>/dev/null
}

# Rebalance a window's panes. With no rail this is the plain even-spread the split
# bindings have always done (orientation h/v) or a bare select-layout -E (none).
# With a rail present we lift it out: the rail stays a fixed-width left column and
# only the other panes share the rest. orientation defaults to the rest's current
# arrangement; an ambiguous grid is left as-is, just re-pinning the rail.
cmd_rebalance() {
  local win="$1" orientation="${2:-}" sid _w zoomed
  read -r sid _w < <(sidebar_pane "$win")
  if [ -z "${sid:-}" ]; then
    "$TMUX_BIN" set-window-option -t "$win" -qu @has_sidebar 2>/dev/null
    case "$orientation" in
      h) "$TMUX_BIN" select-layout -t "$win" even-horizontal 2>/dev/null || true ;;
      v) "$TMUX_BIN" select-layout -t "$win" even-vertical 2>/dev/null || true ;;
      *) "$TMUX_BIN" select-layout -t "$win" -E 2>/dev/null || true ;;
    esac
    return 0
  fi
  # A zoomed pane overlays the layout; reshaping now would fight the zoom, so just
  # keep the rail pinned and let the next unzoomed event re-spread.
  zoomed="$("$TMUX_BIN" display-message -p -t "$win" '#{window_zoomed_flag}' 2>/dev/null)"
  if [ "$zoomed" = "1" ]; then cmd_fix "$win"; return 0; fi
  [ -n "$orientation" ] || orientation="$(detect_rest_orientation "$win")"
  if [ -z "$orientation" ]; then cmd_fix "$win"; return 0; fi
  build_sidebar_layout "$win" "$orientation" "$sid" || true
  cmd_fix "$win"
}

# Hook entrypoint for after-resize-pane / pane-exited. With a rail present a
# terminal resize only re-pins it (cheap, and avoids a resize-hook feedback loop),
# while a pane exiting re-spreads the survivors around the rail. Without one,
# behave exactly like the old bare select-layout -E.
cmd_layout_hook() {
  local event="$1" win="$2" zoomed="${3:-0}"
  if [ "$("$TMUX_BIN" show-options -wqv -t "$win" @has_sidebar 2>/dev/null)" = "1" ]; then
    case "$event" in
      resize) cmd_fix "$win" ;;
      *)      cmd_rebalance "$win" ;;
    esac
    return 0
  fi
  case "$event" in
    resize) [ "$zoomed" = "0" ] && "$TMUX_BIN" select-layout -t "$win" -E 2>/dev/null || true ;;
    *)      "$TMUX_BIN" select-layout -t "$win" -E 2>/dev/null || true ;;
  esac
}

# Open a sidebar in a specific window. Idempotent: a no-op if one's already
# there, so it's safe to call from window-linked and ensure-all repeatedly.
open_in() {
  local win="$1" pid path new
  read -r pid _ < <(sidebar_pane "$win")
  [ -n "${pid:-}" ] && return 0
  path="$("$TMUX_BIN" display-message -p -t "$win" '#{pane_current_path}')"
  # -b: before (left). -d: keep focus on the work pane. -f: span the FULL window
  # height, so the sidebar is a true left rail even when the window already has
  # content splits — not just a column beside the active pane.
  new="$("$TMUX_BIN" split-window -hbdf -l "$WIDTH" -c "$path" -t "$win" \
    -P -F '#{pane_id}' "exec '$SCRIPT_PATH' render")" || return 0
  "$TMUX_BIN" set-option -p -t "$new" @sidebar 1
  "$TMUX_BIN" set-window-option -t "$win" @has_sidebar 1
  # Carving the rail off the active pane only shrank that one pane; lift the rail
  # out and re-spread the rest so it reads as a column the whole window sits beside.
  cmd_rebalance "$win"
}

# Close the sidebar in a specific window, if present.
close_in() {
  local win="$1" pid
  read -r pid _ < <(sidebar_pane "$win")
  [ -z "${pid:-}" ] && return 0
  # Drop the flag first so nothing tries to re-pin a now-dead pane, then close
  # it. kill-pane doesn't fire pane-exited, so spread the survivors ourselves.
  "$TMUX_BIN" set-window-option -t "$win" -qu @has_sidebar
  "$TMUX_BIN" kill-pane -t "$pid"
  "$TMUX_BIN" select-layout -t "$win" -E 2>/dev/null || true
}

# prefix b: hide/show the rail EVERYWHERE. It flips the global @sidebar_enabled
# state and applies it to every window, so closing it in one window closes it in
# all the others (and all sessions), and opening it brings it back everywhere.
cmd_toggle() {
  local w
  if sidebar_enabled; then
    "$TMUX_BIN" set-option -g @sidebar_enabled 0
    while IFS= read -r w; do close_in "$w"; done \
      < <("$TMUX_BIN" list-windows -a -F '#{window_id}')
  else
    "$TMUX_BIN" set-option -g @sidebar_enabled 1
    while IFS= read -r w; do open_in "$w"; done \
      < <("$TMUX_BIN" list-windows -a -F '#{window_id}')
  fi
}

# ensure <window>: make sure one window has a sidebar (window-linked hook). Skips
# when the rail is globally hidden, so new windows respect the current state.
cmd_ensure() {
  sidebar_enabled || return 0
  open_in "${1:-$("$TMUX_BIN" display-message -p '#{window_id}')}"
}

# ensure-all: backfill every existing window (run at config load / server start),
# unless the rail is globally hidden.
cmd_ensure_all() {
  local w
  sidebar_enabled || return 0
  while IFS= read -r w; do open_in "$w"; done \
    < <("$TMUX_BIN" list-windows -a -F '#{window_id}')
}

# Normalize one window to exactly one full-height left rail: tear down every
# @sidebar pane (handles duplicates or a rail left stranded off to the side),
# then open a fresh one — unless the rail is globally hidden, in which case it
# just clears them. Repair path for when layout churn corrupts the rail.
reset_in() {
  local win="$1" p
  for p in $("$TMUX_BIN" list-panes -t "$win" -F '#{pane_id} #{@sidebar}' 2>/dev/null | awk '$2 == "1" { print $1 }'); do
    "$TMUX_BIN" kill-pane -t "$p" 2>/dev/null || true
  done
  "$TMUX_BIN" set-window-option -t "$win" -qu @has_sidebar 2>/dev/null
  "$TMUX_BIN" select-layout -t "$win" -E 2>/dev/null || true
  sidebar_enabled && open_in "$win"
}

# reset-all: normalize every window. Run by hand if a rail ever looks wrong.
cmd_reset_all() {
  local w
  while IFS= read -r w; do reset_in "$w"; done \
    < <("$TMUX_BIN" list-windows -a -F '#{window_id}')
}

# switch <n>: jump to the Nth session in list-sessions order — the same 1-based
# numbering the sidebar prints and the `prefix s` picker uses as hotkeys. Bound
# to Cmd-1..9 via Ghostty user-keys → User1..User9 (see .tmux.conf and
# ghostty/config). switch-client with no -c targets the client that pressed the
# key, so this follows whichever client triggered it.
cmd_switch() {
  local n="$1" name
  case "$n" in *[!0-9]*|'') return 0 ;; esac
  name="$("$TMUX_BIN" list-sessions -F '#{session_name}' 2>/dev/null | sed -n "${n}p")"
  [ -n "$name" ] && "$TMUX_BIN" switch-client -t "$name" 2>/dev/null && cmd_refresh || true
}

### Rendering ###

ESC=$'\033'
RESET="${ESC}[0m"
GREY="${ESC}[38;2;88;110;117m"      # base01  – index numbers, rules
HDR="${ESC}[1;38;2;147;161;161m"    # base1   – header
NAME="${ESC}[38;2;131;148;150m"     # base0   – session names
IDLE="${ESC}[1;38;2;238;232;213;48;2;220;50;47m"  # base2 on red
THINK="${ESC}[1;38;2;0;43;54;48;2;255;215;0m"     # base03 on gold
BLUE="${ESC}[38;2;38;139;210m"      # attached marker
YELLOW="${ESC}[38;2;181;137;0m"     # git branch

sidebar_wake_dir() {
  printf '%s/tmux-sidebar-%s\n' "${TMPDIR:-/tmp}" "${UID:-$(id -u)}"
}

# Truncate a string to N display columns, appending … when cut.
truncate() {
  local s="$1" n="$2"
  if [ "${#s}" -gt "$n" ]; then
    printf '%s…' "${s:0:n-1}"
  else
    printf '%s' "$s"
  fi
}

render_once() {
  local width
  width="$("$TMUX_BIN" display-message -p -t "${TMUX_PANE:-}" '#{pane_width}' 2>/dev/null)"
  [ -n "$width" ] || width="$WIDTH"

  # A tab in read's IFS is whitespace, so an empty field collapses and shifts
  # every later column. The branch is the only field that's ever empty, so it
  # goes LAST: a trailing empty field is simply trimmed, leaving the rest intact.
  # (tmux escapes raw control-byte separators to literal text, so US/NUL are out.)
  local -a names idle think branch att
  local n id th at br count=0
  while IFS=$'\t' read -r n id th at br; do
    names[count]="$n"; idle[count]="$id"; think[count]="$th"
    att[count]="$at"; branch[count]="$br"
    count=$((count + 1))
  done < <("$TMUX_BIN" list-sessions -F \
'#{session_name}'$'\t''#{?#{@session_ai_idle},1,0}'$'\t''#{?#{@session_ai_thinking},1,0}'$'\t''#{?session_attached,1,0}'$'\t''#{@git_branch}' 2>/dev/null)

  # Header + rule.
  printf '%s SESSIONS%s\n' "$HDR" "$RESET"
  local rule i=0
  rule=""
  while [ "$i" -lt "$width" ]; do rule="${rule}─"; i=$((i + 1)); done
  printf '%s%s%s\n' "$GREY" "$rule" "$RESET"

  # Float idle to the top, then thinking, then the rest — order within each
  # group is preserved, and the printed number stays the list-order index.
  local -a order=()
  local j
  for j in $(seq 0 $((count - 1))); do [ "${idle[j]}" = "1" ] && order+=("$j"); done
  for j in $(seq 0 $((count - 1))); do
    [ "${idle[j]}" != "1" ] && [ "${think[j]}" = "1" ] && order+=("$j")
  done
  for j in $(seq 0 $((count - 1))); do
    [ "${idle[j]}" != "1" ] && [ "${think[j]}" != "1" ] && order+=("$j")
  done

  local idx num nm badge body pad
  for j in "${order[@]}"; do
    num=$((j + 1))
    if [ "${idle[j]}" = "1" ]; then badge="! "; elif [ "${think[j]}" = "1" ]; then badge="💭 "; else badge="  "; fi
    # Budget: leading space + badge(2) + number + space, leave 1 trailing.
    nm="$(truncate "${names[j]}" $((width - 5 - ${#num})))"
    if [ "${idle[j]}" = "1" ] || [ "${think[j]}" = "1" ]; then
      body=" ${badge}${num} ${nm}"
      # 💭 counts as one character but renders two columns wide, so the thinking
      # badge needs one less pad space than ${#body} implies.
      local cols=${#body}
      [ "${think[j]}" = "1" ] && cols=$((cols + 1))
      pad=""
      i=$cols; while [ "$i" -lt "$width" ]; do pad="${pad} "; i=$((i + 1)); done
      [ "${idle[j]}" = "1" ] && printf '%s%s%s%s\n' "$IDLE" "$body" "$pad" "$RESET" \
        || printf '%s%s%s%s\n' "$THINK" "$body" "$pad" "$RESET"
    else
      printf ' %s%s%d%s %s%s%s' "$GREY" "$badge" "$num" "$RESET" "$NAME" "$nm" "$RESET"
      [ "${att[j]}" = "1" ] && printf ' %s*%s' "$BLUE" "$RESET"
      printf '\n'
    fi
    # Git branch on an indented dim line when present and there's room.
    if [ -n "${branch[j]}" ] && [ "$width" -ge 14 ]; then
      printf '   %s⎇ %s%s\n' "$YELLOW" "$(truncate "${branch[j]}" $((width - 5)))" "$RESET"
    fi
  done

  printf '\n%s ⌘1-9 · prefix s%s\n' "$GREY" "$RESET"
}

cmd_refresh() {
  local pane sb fifo wake_dir
  wake_dir="$(sidebar_wake_dir)"
  while read -r pane sb; do
    [ "$sb" = "1" ] || continue
    fifo="$wake_dir/${pane#%}.fifo"
    [ -p "$fifo" ] || continue
    perl -e \
      'use Fcntl qw(O_WRONLY O_NONBLOCK); if (sysopen(my $fh, $ARGV[0], O_WRONLY|O_NONBLOCK)) { print {$fh} "\n" }' \
      "$fifo" 2>/dev/null || true
  done < <("$TMUX_BIN" list-panes -a -F '#{pane_id} #{@sidebar}' 2>/dev/null)
}

cmd_render() {
  local wake_dir wake_fifo wake_fd_open=0
  wake_dir="$(sidebar_wake_dir)"
  wake_fifo="$wake_dir/${TMUX_PANE#%}.fifo"
  mkdir -p "$wake_dir" 2>/dev/null || true
  rm -f "$wake_fifo"
  if mkfifo "$wake_fifo" 2>/dev/null && exec 3<>"$wake_fifo"; then
    wake_fd_open=1
  else
    rm -f "$wake_fifo"
  fi

  printf '%s' "${ESC}[?25l"                       # hide cursor
  trap 'printf "%s" "${ESC}[?25h"; rm -f "$wake_fifo"' EXIT INT TERM
  local out prev="" active
  # Draw once up front so a window that's never been visible still has content
  # the instant you switch to it, rather than a blank pane for a tick.
  prev="$(render_once)"; printf '%s%s' "${ESC}[H${ESC}[2J" "$prev"
  while :; do
    if [ "$wake_fd_open" = "1" ]; then
      IFS= read -r -t "${SIDEBAR_REFRESH_INTERVAL:-2}" -u 3 _ || true
    else
      sleep "${SIDEBAR_REFRESH_INTERVAL:-2}"
    fi
    # Every window has its own sidebar now, so only attached current windows work.
    active="$("$TMUX_BIN" display-message -p -t "${TMUX_PANE:-}" '#{&&:#{window_active},#{session_attached}}' 2>/dev/null)"
    [ "$active" = "1" ] || continue
    out="$(render_once)"
    if [ "$out" != "$prev" ]; then
      printf '%s%s' "${ESC}[H${ESC}[2J" "$out"  # home + clear, then redraw
      prev="$out"
    fi
  done
}

case "${1:-toggle}" in
  toggle)      cmd_toggle ;;
  ensure)      cmd_ensure "${2:-}" ;;
  ensure-all)  cmd_ensure_all ;;
  reset-all)   cmd_reset_all ;;
  switch)      cmd_switch "${2:-}" ;;
  refresh)     cmd_refresh ;;
  render)      cmd_render ;;
  fix)         cmd_fix "${2:-}" ;;
  rebalance)   cmd_rebalance "${2:-}" "${3:-}" ;;
  layout-hook) cmd_layout_hook "${2:-}" "${3:-}" "${4:-0}" ;;
  *)           printf 'usage: %s {toggle|ensure [win]|ensure-all|reset-all|switch <n>|refresh|render|fix <win>|rebalance <win> [h|v]|layout-hook <ev> <win> <z>}\n' "${0##*/}" >&2; exit 2 ;;
esac
