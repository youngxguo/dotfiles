#!/usr/bin/env bash
# Persistent sessions sidebar for tmux: a fixed-width, full-height rail pinned to
# the left of EVERY window, so it reads as one global sidebar the windows sit
# beside. It lists every session by name in tmux order (so Cmd-1..9 maps to the
# visible numbers) with AI idle (!) / thinking (💭) badges and the session's git
# branch indented on a second line beneath it.
#
# A new window gets its rail from the window-linked hook; ensure-all backfills at
# config load. The rail is split with -bdf (before, no focus, full height) so it
# spans the whole left edge even past content splits. It's lifted out of normal
# rebalancing — an even spread would flatten it into an equal sibling — so
# cmd_rebalance keeps it a fixed-width column and only spreads the other panes.
# `prefix b` toggles it everywhere via one global flag (@sidebar_enabled).
#
# Nothing polls. AI state is pushed onto each agent's own pane (@ai_state) by
# ~/.tmux-ai-state.sh; the branch onto @git_branch by the shell hook. The rail
# aggregates those per session as it renders (so a dead agent can't leave a stale
# badge) and redraws on a wake event plus a slow backstop tick.
#
# Subcommands: toggle | ensure [win] | ensure-all | reset-all | switch <n> |
# refresh | render | fix <win> | rebalance <win> [h|v] | layout-hook <ev> <win> <z>.
# render runs inside the rail pane and self-closes when it's the last pane left.
#
# install.py symlinks this to ~/.tmux-sidebar.sh via its `.tmux-*.sh` glob.
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_PATH="$SCRIPT_DIR/${BASH_SOURCE[0]##*/}"
source "$SCRIPT_DIR/.tmux-lib.sh"

TMUX_BIN="$(tmux_resolve_bin)"

# Sidebar width in columns. Override with SIDEBAR_WIDTH in the environment.
WIDTH="${SIDEBAR_WIDTH:-26}"

# Shown unless the global @sidebar_enabled is explicitly "0" (flipped by prefix b).
# It's global, not per-window, so the rail stays consistent everywhere; unset means
# on, and it resets to on at server start.
sidebar_enabled() {
  [ "$("$TMUX_BIN" show-options -gv @sidebar_enabled 2>/dev/null)" != "0" ]
}

# The rail pane in a window (it carries @sidebar=1). Prints "<id> <width>" or nothing.
sidebar_pane() {
  "$TMUX_BIN" list-panes -t "$1" -F '#{pane_id} #{pane_width} #{@sidebar}' 2>/dev/null \
    | awk '$3 == "1" { print $1, $2; exit }'
}

# Pin the rail back to WIDTH, or tidy @has_sidebar if it's gone. Resizing only when
# the width differs keeps the after-resize-pane hook from ping-ponging.
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

# even-horizontal fills by pane order, so the rail must be the first pane to stay
# leftmost. Bubble it to the front one adjacent swap at a time, preserving the
# others' order.
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

# Guess the work panes' arrangement so a reflow can match it: a shared top edge is
# a row (h), a shared left edge is a column (v). A grid prints nothing, so the
# caller leaves the structure alone and only re-pins the rail.
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

# Spread the work panes evenly while keeping the rail a fixed-width, full-height
# left column, using only select-layout/resize-pane (no internal layout strings).
# h: lay every pane in one row (even-horizontal fills by order, so move the rail
# leftmost first), shrink the rail, then re-even the work widths. v: the rail is
# already a left column, so just pin it and even the heights. Returns nonzero if
# the geometry is unreadable; with <2 work panes there's nothing to even.
spread_around_sidebar() {
  local win="$1" orientation="$2" sid="$3" W H
  read -r W H < <("$TMUX_BIN" display-message -p -t "$win" \
                   '#{window_width} #{window_height}' 2>/dev/null)
  [ -n "${W:-}" ] && [ -n "${H:-}" ] || return 1

  if [ "$orientation" = "h" ]; then
    move_sidebar_front "$win" "$sid"
    "$TMUX_BIN" select-layout -t "$win" even-horizontal 2>/dev/null || return 1
  fi
  "$TMUX_BIN" resize-pane -t "$sid" -x "$WIDTH" 2>/dev/null || true

  # Work panes in visual order (top-to-bottom for v, left-to-right for h); @sidebar
  # is "1" on the rail, empty on work panes.
  local sort_key
  [ "$orientation" = "v" ] && sort_key='#{pane_top}' || sort_key='#{pane_left}'
  local -a rest=()
  local pos id sb
  while read -r pos id sb; do
    [ "$sb" = "1" ] || rest+=("$id")
  done < <("$TMUX_BIN" list-panes -t "$win" \
            -F "$sort_key"' #{pane_id} #{@sidebar}' 2>/dev/null | sort -n)
  local M=${#rest[@]}
  [ "$M" -ge 2 ] || return 0

  # Even slices for the first M-1; the last absorbs the remainder. resize-pane steals
  # from the adjacent pane, so going in visual order keeps every slice equal.
  local span base i
  if [ "$orientation" = "v" ]; then
    span=$(( H - (M - 1) )); base=$(( span / M ))
    [ "$base" -ge 1 ] || return 0
    for (( i=0; i<M-1; i++ )); do
      "$TMUX_BIN" resize-pane -t "${rest[i]}" -y "$base" 2>/dev/null || true
    done
  else
    span=$(( W - WIDTH - 1 - (M - 1) )); base=$(( span / M ))
    [ "$base" -ge 1 ] || return 0
    for (( i=0; i<M-1; i++ )); do
      "$TMUX_BIN" resize-pane -t "${rest[i]}" -x "$base" 2>/dev/null || true
    done
  fi
}

# Rebalance a window. No rail: the plain even-spread (h/v) or a bare select-layout
# -E. With a rail: keep it a fixed-width column and spread only the rest; the
# orientation defaults to the rest's current arrangement, and an ambiguous grid is
# left as-is (just re-pin the rail).
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
  # A zoomed pane overlays the layout, so just pin the rail and let the next
  # unzoomed event re-spread.
  zoomed="$("$TMUX_BIN" display-message -p -t "$win" '#{window_zoomed_flag}' 2>/dev/null)"
  if [ "$zoomed" = "1" ]; then cmd_fix "$win"; return 0; fi
  [ -n "$orientation" ] || orientation="$(detect_rest_orientation "$win")"
  if [ -z "$orientation" ]; then cmd_fix "$win"; return 0; fi
  spread_around_sidebar "$win" "$orientation" "$sid" || true
  cmd_fix "$win"
}

# Hook entry for window-resized / after-resize-pane / pane-exited / after-kill-pane.
# With a rail: a whole-window resize re-spreads work panes (window-resize), a manual
# pane resize only re-pins it (resize, so a drag isn't fought), and a pane leaving
# re-spreads the survivors and wakes the rail (exit). No rail: a bare select-layout -E.
cmd_layout_hook() {
  local event="$1" win="$2" zoomed="${3:-0}"
  if [ "$("$TMUX_BIN" show-options -wqv -t "$win" @has_sidebar 2>/dev/null)" = "1" ]; then
    # Rail alone: nothing to rebalance, and pinning a sole pane to WIDTH can't shrink
    # it (no neighbour to cede columns) — the failed resize just re-fires
    # after-resize-pane in a storm that jams tmux's command queue. So skip all of
    # that and only wake the rail; its loop sees rail_is_alone and closes itself.
    # Every strand-the-rail event lands here (a process exit fires pane-exited; a
    # kill fires after-kill-pane), so the rail closes promptly however it happened.
    if [ "$("$TMUX_BIN" display-message -p -t "$win" '#{window_panes}' 2>/dev/null)" = "1" ]; then
      cmd_refresh_window "$win"
      return 0
    fi
    case "$event" in
      window-resize|exit)
        cmd_rebalance "$win"
        cmd_refresh_window "$win"
        ;;
      resize) cmd_fix "$win" ;;
      *)      cmd_rebalance "$win" ;;
    esac
    return 0
  fi
  case "$event" in
    resize|window-resize)
      [ "$zoomed" = "0" ] && "$TMUX_BIN" select-layout -t "$win" -E 2>/dev/null || true
      ;;
    *) "$TMUX_BIN" select-layout -t "$win" -E 2>/dev/null || true ;;
  esac
}

# Create the rail in a window, unless it already has one — so it's safe to call
# repeatedly from window-linked / ensure-all.
open_in() {
  local win="$1" pid path new
  read -r pid _ < <(sidebar_pane "$win")
  [ -n "${pid:-}" ] && return 0
  path="$("$TMUX_BIN" display-message -p -t "$win" '#{pane_current_path}')"
  # -b before, -d no focus, -f full height: a true left rail even past content splits.
  new="$("$TMUX_BIN" split-window -hbdf -l "$WIDTH" -c "$path" -t "$win" \
    -P -F '#{pane_id}' "exec '$SCRIPT_PATH' render")" || return 0
  "$TMUX_BIN" set-option -p -t "$new" @sidebar 1
  # Pin to the active (undimmed) background: inactive panes are dimmed globally and
  # the rail never holds focus, so this stops it reading as dimmed.
  "$TMUX_BIN" set-option -p -t "$new" window-style "bg=#{@solarized_base03}"
  "$TMUX_BIN" set-window-option -t "$win" @has_sidebar 1
  # Carving the rail off only shrank the active pane; re-spread so the whole window
  # sits beside it.
  cmd_rebalance "$win"
}

# Close the rail in a window, if present.
close_in() {
  local win="$1" pid
  read -r pid _ < <(sidebar_pane "$win")
  [ -z "${pid:-}" ] && return 0
  # Drop the flag before killing so nothing re-pins a dead pane; kill-pane doesn't
  # fire pane-exited, so re-spread the survivors here.
  "$TMUX_BIN" set-window-option -t "$win" -qu @has_sidebar
  "$TMUX_BIN" kill-pane -t "$pid"
  "$TMUX_BIN" select-layout -t "$win" -E 2>/dev/null || true
}

# prefix b: hide/show the rail in EVERY window at once via the global flag.
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

# window-linked hook: give a window a rail, unless globally hidden.
cmd_ensure() {
  sidebar_enabled || return 0
  open_in "${1:-$("$TMUX_BIN" display-message -p '#{window_id}')}"
}

# Backfill every window at config load / server start, unless globally hidden.
cmd_ensure_all() {
  local w
  sidebar_enabled || return 0
  while IFS= read -r w; do open_in "$w"; done \
    < <("$TMUX_BIN" list-windows -a -F '#{window_id}')
}

# Normalize a window to exactly one rail: kill every @sidebar pane (clears
# duplicates or a stranded rail), then re-open one. Repair path for layout churn.
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

# switch <n> [client]: jump to the Nth session in list order — what the rail
# numbers show (Cmd-1..9 via Ghostty user-keys → User1..User9). With a client,
# refresh only the rails it touched instead of every pane in the server.
cmd_switch() {
  local n="$1" client="${2:-}" name old_win new_win
  case "$n" in *[!0-9]*|'') return 0 ;; esac
  name="$("$TMUX_BIN" list-sessions -F '#{session_name}' 2>/dev/null | sed -n "${n}p")"
  [ -n "$name" ] || return 0

  if [ -n "$client" ]; then
    old_win="$("$TMUX_BIN" display-message -p -c "$client" '#{window_id}' 2>/dev/null || true)"
    "$TMUX_BIN" switch-client -c "$client" -t "$name" 2>/dev/null || return 0
    new_win="$("$TMUX_BIN" display-message -p -c "$client" '#{window_id}' 2>/dev/null || true)"
    cmd_refresh_window "$old_win"
    [ "$new_win" != "$old_win" ] && cmd_refresh_window "$new_win"
    return 0
  fi

  "$TMUX_BIN" switch-client -t "$name" 2>/dev/null && cmd_refresh || true
}

### Rendering ###

ESC=$'\033'
RESET="${ESC}[0m"
GREY="$TMUX_FG_BASE01_ANSI"    # index numbers, rules
HDR="$TMUX_BOLD_FG_BASE1_ANSI" # header
NAME="$TMUX_FG_BASE00_ANSI"     # session names
IDLE="$TMUX_AI_IDLE_ANSI"
THINK="$TMUX_AI_THINK_ANSI"
SELECT="$TMUX_SELECT_ANSI"     # base3 on blue
BLUE="$TMUX_BLUE_FG_ANSI"      # attached marker
YELLOW="$TMUX_YELLOW_ANSI"     # git branch (same yellow as status)

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
  local width current_session
  width="$("$TMUX_BIN" display-message -p -t "${TMUX_PANE:-}" '#{pane_width}' 2>/dev/null)"
  [ -n "$width" ] || width="$WIDTH"
  current_session="$("$TMUX_BIN" display-message -p -t "${TMUX_PANE:-}" '#{session_name}' 2>/dev/null)"

  # Each session's badge is the live aggregate of its panes' @ai_state (thinking
  # outranks idle, neither shows nothing), pushed by the agent hooks — so a killed
  # or exited agent's pane takes its badge with it. Tab-split with the empty-able
  # field LAST: tab is whitespace-IFS, so `read` collapses empties and a blank
  # field in the middle would shift every later column.
  local -A ai_state=()
  local sn ps
  while IFS=$'\t' read -r sn ps; do
    case "$ps" in
      thinking) ai_state[$sn]=thinking ;;
      idle)     [ "${ai_state[$sn]:-}" = thinking ] || ai_state[$sn]=idle ;;
    esac
  done < <("$TMUX_BIN" list-panes -a -F '#{session_name}'$'\t''#{@ai_state}' 2>/dev/null)

  # One row per session: its name on top, the git branch indented beneath. Branch
  # comes from @git_branch (pushed by the shell hook and the agent state hook,
  # backfilled by ~/.tmux-update-branches.sh) so we don't fork git per session each
  # redraw. It's the empty-able field, so it goes last too (see the tab note above).
  local -a names idle think branch
  local n br count=0 st
  while IFS=$'\t' read -r n br; do
    st="${ai_state[$n]:-}"
    names[count]="$n"
    idle[count]=0; think[count]=0
    case "$st" in idle) idle[count]=1 ;; thinking) think[count]=1 ;; esac
    branch[count]="$br"
    count=$((count + 1))
  done < <("$TMUX_BIN" list-sessions -F \
'#{session_name}'$'\t''#{@git_branch}' 2>/dev/null)

  local j nm badge pad prefix prefix_cols name_budget selected cols label_width label color indent brname rule divider
  label_width=${#count}
  # A thin grey rule between every session, so the list always reads as separate
  # blocks — consistent whatever the state, and it keeps adjacent colour bars (e.g.
  # several sessions thinking at once) from merging into one indistinguishable slab.
  # A full-width run of ─ (built once): base01 on the rail's bg.
  printf -v rule '%*s' "$width" ''
  divider="${GREY}${rule// /─}${RESET}"
  for j in $(seq 0 $((count - 1))); do
    if [ "${idle[j]}" = "1" ]; then badge="! "; elif [ "${think[j]}" = "1" ]; then badge="💭 "; else badge="  "; fi
    printf -v label "%${label_width}d" "$((j + 1))"
    prefix=" ${label} ${badge}"
    prefix_cols=${#prefix}
    [ "${think[j]}" = "1" ] && prefix_cols=$((prefix_cols + 1))   # 💭 is 2 cols, 1 char

    name_budget=$((width - prefix_cols))
    nm="$(truncate "${names[j]}" "$name_budget")"
    selected=0
    [ "${names[j]}" = "$current_session" ] && selected=1

    # Row colour: selected / idle / thinking fill the whole row — the name line and
    # the branch line both — with one solid-bar colour, selected winning the tie. A
    # plain row has no fill.
    color=""
    [ "${idle[j]}" = "1" ] && color="$IDLE"
    [ "${think[j]}" = "1" ] && color="$THINK"
    [ "$selected" = "1" ] && color="$SELECT"

    # Rule above every row but the first, so sessions stay visually separate.
    [ "$j" -gt 0 ] && printf '%s\n' "$divider"

    # Name line: index, AI badge, session name.
    cols=$((prefix_cols + ${#nm}))
    printf -v pad '%*s' "$(( width - cols > 0 ? width - cols : 0 ))" ''
    if [ -n "$color" ]; then
      printf '%s%s%s%s\n' "$color" "$prefix" "$nm" "${pad}${RESET}"
    else
      printf '%s%s%s%s\n' "$prefix" "$NAME" "$nm" "$RESET"
    fi

    # Branch line: indented to sit under the name. A highlighted row carries the
    # same solid bar across it; a plain row shows the branch in yellow. Skipped when
    # the session has no branch or the rail is too narrow (rows are 1 or 2 tall).
    indent=$prefix_cols
    if [ -n "${branch[j]}" ] && [ "$((width - indent))" -ge 3 ]; then
      brname="$(truncate "${branch[j]}" "$((width - indent))")"
      cols=$((indent + ${#brname}))
      printf -v pad '%*s' "$(( width - cols > 0 ? width - cols : 0 ))" ''
      if [ -n "$color" ]; then
        printf '%s%*s%s%s\n' "$color" "$indent" '' "$brname" "${pad}${RESET}"
      else
        printf '%*s%s%s%s\n' "$indent" '' "$YELLOW" "$brname" "$RESET"
      fi
    fi
  done

  printf '\n'
}

# Wake a rail's render loop so it redraws now. Open the fifo read+write so the open
# never blocks even when the loop isn't reading this tick, drop one byte, close.
wake_sidebar_pane() {
  local pane="$1" fifo
  fifo="$(sidebar_wake_dir)/${pane#%}.fifo"
  [ -p "$fifo" ] || return 0
  { exec 4<>"$fifo" && printf '\n' >&4 && exec 4>&-; } 2>/dev/null || true
}

# Wake the rail panes among the given list-panes targets (-a for all, -t <win>).
# return 0 so we don't leak the loop's exit status: when the last pane isn't a rail
# the trailing `[ "$sb" = "1" ]` test is false, which would otherwise bubble up as a
# nonzero exit that tmux's run-shell reports as `… refresh returned 1`.
wake_rails() {
  local pane sb
  while read -r pane sb; do
    [ "$sb" = "1" ] && wake_sidebar_pane "$pane"
  done < <("$TMUX_BIN" list-panes "$@" -F '#{pane_id} #{@sidebar}' 2>/dev/null)
  return 0
}

cmd_refresh_window() { [ -n "${1:-}" ] && wake_rails -t "$1" || true; }
cmd_refresh() { wake_rails -a; }

# True when the rail is the only pane left — every work pane it sat beside is gone.
# The render loop breaks on this and exits, which closes the now-empty window (and
# the session, if it was the last). One rule retires a stranded rail no matter how
# the last work pane went away.
rail_is_alone() {
  [ "$("$TMUX_BIN" display-message -p -t "${TMUX_PANE:-}" '#{window_panes}' 2>/dev/null)" = "1" ]
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
  # Draw once up front so a freshly-shown window isn't blank for a tick.
  prev="$(render_once)"; printf '%s%s' "${ESC}[H${ESC}[2J" "$prev"
  while :; do
    # Block on the wake fifo (AI/branch pushes, session/window changes, pane exits)
    # and only fall through on the slow backstop — redraws are event-driven now.
    if [ "$wake_fd_open" = "1" ]; then
      IFS= read -r -t "${SIDEBAR_REFRESH_INTERVAL:-30}" -u 3 _ || true
    else
      sleep "${SIDEBAR_REFRESH_INTERVAL:-30}"
    fi
    rail_is_alone && break          # last pane left — close ourselves and the window
    # Only the attached, current window is on screen, so skip rendering the rest.
    active="$("$TMUX_BIN" display-message -p -t "${TMUX_PANE:-}" '#{&&:#{window_active},#{session_attached}}' 2>/dev/null)"
    [ "$active" = "1" ] || continue
    out="$(render_once)"
    if [ "$out" != "$prev" ]; then
      printf '%s%s' "${ESC}[H${ESC}[2J" "$out"  # home + clear, then redraw
      prev="$out"
    fi
  done
}

# Only dispatch when executed directly; sourcing (e.g. from tests) just defines the
# functions above.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  case "${1:-toggle}" in
    toggle)      cmd_toggle ;;
    ensure)      cmd_ensure "${2:-}" ;;
    ensure-all)  cmd_ensure_all ;;
    reset-all)   cmd_reset_all ;;
    switch)      cmd_switch "${2:-}" "${3:-}" ;;
    refresh)     cmd_refresh ;;
    render)      cmd_render ;;
    fix)         cmd_fix "${2:-}" ;;
    rebalance)   cmd_rebalance "${2:-}" "${3:-}" ;;
    layout-hook) cmd_layout_hook "${2:-}" "${3:-}" "${4:-0}" ;;
    *)           printf 'usage: %s {toggle|ensure [win]|ensure-all|reset-all|switch <n>|refresh|render|fix <win>|rebalance <win> [h|v]|layout-hook <ev> <win> <z>}\n' "${0##*/}" >&2; exit 2 ;;
  esac
fi
