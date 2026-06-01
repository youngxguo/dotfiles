#!/usr/bin/env bash
# Persistent sessions sidebar for tmux — a fixed-width, full-height rail pinned
# to the leftmost column of EVERY window, so it reads as one global sidebar that
# the windows live to the right of, rather than a per-window pane.
#
# It live-renders every session with AI idle (!) / thinking (💭) badges and git
# branch. Sessions stay
# in tmux list order and always show their list-order number, so Cmd-1..9 maps
# directly to the visible rail labels.
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
# (cmd_rebalance / spread_around_sidebar). `prefix b` hides/shows it everywhere at
# once — the shown/hidden state is one global flag (@sidebar_enabled), not per
# window, so it stays consistent across every window and session.
#
# AI-state session options (@session_ai_*) are populated by ~/.tmux-ai-idle.sh,
# which this rail runs on its own refresh tick (ai_idle_tick) rather than from
# the tmux status line; the rail reads the git branch directly from each
# session's pane path.
#
# Subcommands:
#   toggle                      hide/show the rail everywhere (global state)
#   ensure [window]             create the rail in a window if absent (hook)
#   ensure-all                  backfill every window (config load / server start)
#   reset-all                   normalize every window to one correct rail (repair)
#   switch <n>                  switch to the Nth session (Cmd-1..9)
#   refresh                     wake sidebar panes so they redraw immediately
#   render                      the redraw loop (runs *inside* the rail pane);
#                               also self-closes when it's the last pane left
#   fix <window>                pin the rail to SIDEBAR_WIDTH; tidy @has_sidebar
#   rebalance <win> [h|v]       spread the panes evenly; with a rail present keep
#                               it lifted out and only spread the rest
#   layout-hook <ev> <win> <z>  hook entrypoint: window-resize re-spreads work
#                               panes; resize re-pins the rail; exit rebalances
#                               survivors and wakes the rail to self-close
#
# install.py symlinks this to ~/.tmux-sidebar.sh via its `.tmux-*.sh` glob.
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_PATH="$SCRIPT_DIR/${BASH_SOURCE[0]##*/}"
source "$SCRIPT_DIR/.tmux-lib.sh"

TMUX_BIN="$(tmux_resolve_bin)"

# The AI idle/thinking detector. The rail drives it from its refresh tick (see
# ai_idle_tick) instead of the tmux status line, so all AI-state bookkeeping
# lives next to the rail that renders it.
AI_IDLE_SCRIPT="$SCRIPT_DIR/.tmux-ai-idle.sh"

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

# even-horizontal fills the row by the window's *pane order*, so to keep the rail
# pinned leftmost it must be the first pane. Bubble it to the front with adjacent
# swap-panes, which slides it left one slot at a time and preserves every other
# pane's order.
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

# Spread the non-rail panes evenly while keeping the rail a fixed-width, full-
# height left column. orientation: h = rest side-by-side, v = rest stacked. Uses
# only public tmux commands (select-layout / resize-pane), so it isn't coupled to
# tmux's internal layout-string format the way a hand-built layout would be.
#
#   h: lay every pane out in one row (even-horizontal fills by pane order, so the
#      rail must be leftmost first — move_sidebar_front), shrink the rail back to
#      WIDTH, then re-even the work panes by width so the columns reclaimed from
#      the rail are shared evenly instead of dumped on the rail's neighbour.
#   v: the rail is already a full-height left column with the work panes stacked
#      to its right — it was carved off with split-window -bdf and work splits
#      only ever target work panes — so just pin the rail and even their heights.
#
# Returns nonzero (caller falls back to just pinning) when the window geometry is
# unreadable. With 0 or 1 work pane there is nothing to even, so it only pins.
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

  # Collect the work panes in visual order (top-to-bottom for v, left-to-right
  # for h). @sidebar is empty for work panes, "1" for the rail.
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

  # Size the first M-1 work panes to an even slice; the last absorbs the
  # remainder. resize-pane steals from the adjacent pane, so left-to-right /
  # top-to-bottom keeps every slice equal.
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
  spread_around_sidebar "$win" "$orientation" "$sid" || true
  cmd_fix "$win"
}

# Hook entrypoint for window-resized / after-resize-pane / pane-exited. With a
# rail present a whole-window resize re-spreads work panes around the fixed rail
# (window-resize), a manual pane resize only re-pins the rail (resize — cheap,
# and avoids fighting the user's drag), and a pane exiting re-spreads the
# survivors and wakes the rail (exit) — which then closes itself if it's now the
# only pane left (see rail_is_alone). Without a rail, behave like the old bare
# select-layout -E.
cmd_layout_hook() {
  local event="$1" win="$2" zoomed="${3:-0}"
  if [ "$("$TMUX_BIN" show-options -wqv -t "$win" @has_sidebar 2>/dev/null)" = "1" ]; then
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
  # Inactive panes are dimmed globally (window-style in ~/.tmux.conf); pin the
  # rail to the active (undimmed) background so it never reads as dimmed even
  # though it never holds focus.
  "$TMUX_BIN" set-option -p -t "$new" window-style "bg=#{@solarized_base03}"
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

# switch <n> [client]: jump to the Nth session in list-sessions order — the same
# ordering shown in the sidebar rail. Bound to Cmd-1..9 via Ghostty
# user-keys → User1..User9 (see .tmux.conf and ghostty/config). Passing the
# triggering client lets us refresh just the visible rails touched by the switch,
# instead of waking every sidebar pane in the server on every rapid keypress.
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

folder_label_for_path() {
  local path="$1" fallback="$2" root dir parent parent_base repo base
  root="$(git -C "$path" rev-parse --show-toplevel 2>/dev/null || true)"
  [ -n "$root" ] && path="$root"

  # Worktrees created by prefix-W live under ../<repo>-worktrees/<name>. Show the
  # original repo folder, leaving the worktree/branch name for the bracketed ref.
  dir="${path%/}"
  while [ -n "$dir" ] && [ "$dir" != "/" ] && [ "$dir" != "." ]; do
    parent="${dir%/*}"
    [ "$parent" = "$dir" ] && break
    parent_base="${parent##*/}"
    case "$parent_base" in
      *-worktrees)
        repo="${parent_base%-worktrees}"
        [ -n "$repo" ] && { printf '%s\n' "$repo"; return 0; }
        ;;
    esac
    dir="$parent"
  done

  base="${path%/}"; base="${base##*/}"
  printf '%s\n' "${base:-$fallback}"
}

render_once() {
  local width current_session
  width="$("$TMUX_BIN" display-message -p -t "${TMUX_PANE:-}" '#{pane_width}' 2>/dev/null)"
  [ -n "$width" ] || width="$WIDTH"
  current_session="$("$TMUX_BIN" display-message -p -t "${TMUX_PANE:-}" '#{session_name}' 2>/dev/null)"

  # The branch is read straight from each session's pane path (tmux_git_branch)
  # rather than the @git_branch option, so the rail is always current without
  # depending on ~/.tmux-update-branches.sh; folder_label_for_path already forks
  # git per session, so this adds no meaningful cost. pane_current_path is the
  # last field and never empty, so the tab split stays aligned.
  local -a names idle think branch folder
  local n id th path count=0 base
  while IFS=$'\t' read -r n id th path; do
    base="$(folder_label_for_path "$path" "$n")"
    names[count]="$n"; folder[count]="$base"; idle[count]="$id"; think[count]="$th"
    branch[count]="$(tmux_git_branch "$path")"
    count=$((count + 1))
  done < <("$TMUX_BIN" list-sessions -F \
'#{session_name}'$'\t''#{?#{@session_ai_idle},1,0}'$'\t''#{?#{@session_ai_thinking},1,0}'$'\t''#{pane_current_path}' 2>/dev/null)

  local j nm br badge pad prefix prefix_cols branch_part name_budget branch_budget selected label_width label
  local i=0
  label_width=${#count}
  for j in $(seq 0 $((count - 1))); do
    if [ "${idle[j]}" = "1" ]; then badge="! "; elif [ "${think[j]}" = "1" ]; then badge="💭 "; else badge="  "; fi
    printf -v label "%${label_width}d" "$((j + 1))"
    prefix=" ${label} ${badge}"
    prefix_cols=${#prefix}
    [ "${think[j]}" = "1" ] && prefix_cols=$((prefix_cols + 1))

    branch_part=""
    branch_budget=$((width / 3))
    if [ -n "${branch[j]}" ] && [ "$width" -ge 14 ] && [ "$branch_budget" -ge 3 ]; then
      br="$(truncate "${branch[j]}" "$branch_budget")"
      branch_part=" [${br}]"
    fi

    name_budget=$((width - prefix_cols - ${#branch_part}))
    if [ "$name_budget" -lt 3 ]; then
      branch_part=""
      name_budget=$((width - prefix_cols))
    fi
    nm="$(truncate "${folder[j]}" "$name_budget")"

    selected=0
    [ "${names[j]}" = "$current_session" ] && selected=1
    if [ "$selected" = "1" ]; then
      local cols=$((prefix_cols + ${#nm} + ${#branch_part}))
      pad=""
      i=$cols; while [ "$i" -lt "$width" ]; do pad="${pad} "; i=$((i + 1)); done
      printf '%s%s%s%s%s\n' "$SELECT" "$prefix" "$nm" "$branch_part" "${pad}${RESET}"
    elif [ "${idle[j]}" = "1" ] || [ "${think[j]}" = "1" ]; then
      local cols=$((prefix_cols + ${#nm} + ${#branch_part}))
      pad=""
      i=$cols; while [ "$i" -lt "$width" ]; do pad="${pad} "; i=$((i + 1)); done
      if [ "${idle[j]}" = "1" ]; then
        printf '%s%s%s%s%s\n' "$IDLE" "$prefix" "$nm" "$branch_part" "${pad}${RESET}"
      else
        printf '%s%s%s%s%s%s\n' "$THINK" "${prefix}${nm}" "$YELLOW" "$branch_part" "$THINK" "${pad}${RESET}"
      fi
    else
      printf '%s%s%s%s' "$prefix" "$NAME" "$nm" "$RESET"
      [ -n "$branch_part" ] && printf ' %s%s%s' "$YELLOW" "${branch_part# }" "$RESET"
      printf '\n'
    fi
  done

  printf '\n'
}

wake_sidebar_pane() {
  local pane="$1" fifo wake_dir
  wake_dir="$(sidebar_wake_dir)"
  fifo="$wake_dir/${pane#%}.fifo"
  [ -p "$fifo" ] || return 0
  # Open the fifo read+write so the open never blocks even if the render loop
  # isn't reading this tick, write one byte to wake it, then close. The render
  # loop holds its own read fd, so this just drops a token into the buffer.
  { exec 4<>"$fifo" && printf '\n' >&4 && exec 4>&-; } 2>/dev/null || true
}

cmd_refresh_window() {
  local win="$1" pane sb
  [ -n "$win" ] || return 0
  while read -r pane sb; do
    [ "$sb" = "1" ] || continue
    wake_sidebar_pane "$pane"
  done < <("$TMUX_BIN" list-panes -t "$win" -F '#{pane_id} #{@sidebar}' 2>/dev/null)
}

cmd_refresh() {
  local pane sb
  while read -r pane sb; do
    [ "$sb" = "1" ] || continue
    wake_sidebar_pane "$pane"
  done < <("$TMUX_BIN" list-panes -a -F '#{pane_id} #{@sidebar}' 2>/dev/null)
}

# Run the AI idle/thinking detector in the background so a slow pane scan never
# stalls the redraw. A non-blocking flock keeps ticks from stacking up: if the
# previous run is still going, this tick is simply skipped. It publishes
# @session_ai_* (and fires idle notifications), which the next render reads.
ai_idle_tick() {
  [ -e "$AI_IDLE_SCRIPT" ] || return 0
  local lock="${TMPDIR:-/tmp}/tmux-ai-idle-${UID:-$(id -u 2>/dev/null || echo user)}.lock"
  if command -v flock >/dev/null 2>&1; then
    ( flock -n 9 || exit 0; "$AI_IDLE_SCRIPT" >/dev/null 2>&1 ) 9>"$lock" &
  else
    "$AI_IDLE_SCRIPT" >/dev/null 2>&1 &
  fi
}

# True when the rail is the only pane left in its window — every work pane it sat
# beside is gone. The render loop checks this each tick and exits when it's true:
# ending its own process closes the pane, and with it the now-empty window (and
# the session, if it was the last). One rule retires a stranded empty sidebar no
# matter how the last work pane went away — exit, prefix x, mouse, kill — so we
# don't have to enumerate and hook each of those paths.
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
  # Draw once up front so a window that's never been visible still has content
  # the instant you switch to it, rather than a blank pane for a tick.
  prev="$(render_once)"; printf '%s%s' "${ESC}[H${ESC}[2J" "$prev"
  while :; do
    if [ "$wake_fd_open" = "1" ]; then
      IFS= read -r -t "${SIDEBAR_REFRESH_INTERVAL:-2}" -u 3 _ || true
    else
      sleep "${SIDEBAR_REFRESH_INTERVAL:-2}"
    fi
    # Nothing left to sit beside — delete ourselves and let the window close. The
    # pane-exited hook wakes us, so a process ending closes the rail near-instantly;
    # an explicit kill we'd otherwise miss is still caught by the next tick.
    rail_is_alone && break
    # Every window has its own sidebar now, so only attached current windows work.
    active="$("$TMUX_BIN" display-message -p -t "${TMUX_PANE:-}" '#{&&:#{window_active},#{session_attached}}' 2>/dev/null)"
    [ "$active" = "1" ] || continue
    ai_idle_tick
    out="$(render_once)"
    if [ "$out" != "$prev" ]; then
      printf '%s%s' "${ESC}[H${ESC}[2J" "$out"  # home + clear, then redraw
      prev="$out"
    fi
  done
}

# Only dispatch when executed directly; sourcing (e.g. from tests) just defines
# the functions above without running a subcommand.
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
