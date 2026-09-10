#!/usr/bin/env bash
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_PATH="$SCRIPT_DIR/${BASH_SOURCE[0]##*/}"
source "$SCRIPT_DIR/.tmux-lib.sh"

TMUX_BIN="$(tmux_resolve_bin)"

WIDTH="${SIDEBAR_WIDTH:-26}"
SEP=$'\x1f'

SIDEBAR_BUSY_TTL=10
layout_quiet_begin() {
  local now; printf -v now '%(%s)T' -1
  "$TMUX_BIN" set-option -g @sidebar_busy "$now" 2>/dev/null || true
}
layout_quiet_end() { "$TMUX_BIN" set-option -gqu @sidebar_busy 2>/dev/null || true; }
layout_is_busy() {
  local since now
  since="$("$TMUX_BIN" show-options -gqv @sidebar_busy 2>/dev/null)"
  [ -n "$since" ] || return 1
  printf -v now '%(%s)T' -1
  [ "$((now - since))" -lt "$SIDEBAR_BUSY_TTL" ]
}
run_quiet() {
  layout_quiet_begin
  trap layout_quiet_end EXIT INT TERM
  "$@"
  local rc=$?
  layout_quiet_end
  trap - EXIT INT TERM
  return "$rc"
}

install_layout_hooks() {
  local p="$SCRIPT_PATH" gate="if-shell -F '#{?#{@sidebar_busy},,1}'"
  "$TMUX_BIN" set-hook -g window-resized \
    "$gate \"run-shell '$p layout-hook window-resize #{window_id} #{window_zoomed_flag}'\""
  "$TMUX_BIN" set-hook -g after-resize-pane \
    "$gate \"run-shell '$p layout-hook resize #{window_id} #{window_zoomed_flag}'\""
  "$TMUX_BIN" set-hook -g pane-exited \
    "$gate \"run-shell '$p layout-hook exit #{window_id}'\""
  "$TMUX_BIN" set-hook -g after-kill-pane \
    "$gate \"run-shell '$p layout-hook exit #{window_id}'\""
}

sidebar_enabled() {
  [ "$("$TMUX_BIN" show-options -gqv @sidebar_enabled 2>/dev/null)" != "0" ]
}

sidebar_pane() {
  "$TMUX_BIN" list-panes -t "$1" -F '#{pane_id} #{pane_width} #{@sidebar}' 2>/dev/null \
    | awk '$3 == "1" { print $1, $2; exit }'
}

window_has_one_pane() {
  [ "$("$TMUX_BIN" display-message -p -t "$1" '#{window_panes}' 2>/dev/null)" = "1" ]
}

cmd_fix() {
  local win="$1" pid w
  read -r pid w < <(sidebar_pane "$win")
  if [ -z "${pid:-}" ]; then
    "$TMUX_BIN" set-window-option -t "$win" -qu @has_sidebar 2>/dev/null
    "$TMUX_BIN" select-layout -t "$win" -E 2>/dev/null || true
    return 0
  fi
  [ "$w" != "$WIDTH" ] && "$TMUX_BIN" resize-pane -t "$pid" -x "$WIDTH" 2>/dev/null || true
  wake_sidebar_pane "$pid"
}

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

cmd_rebalance() {
  local win="$1" orientation="${2:-}" sid _w zoomed detected
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
  zoomed="$("$TMUX_BIN" display-message -p -t "$win" '#{window_zoomed_flag}' 2>/dev/null)"
  if [ "$zoomed" = "1" ]; then cmd_fix "$win"; return 0; fi
  detected="$(detect_rest_orientation "$win")"
  if [ -z "$detected" ]; then cmd_fix "$win"; return 0; fi
  [ -n "$orientation" ] || orientation="$detected"
  spread_around_sidebar "$win" "$orientation" "$sid" || true
  cmd_fix "$win"
}

cmd_layout_hook() {
  local event="$1" win="$2" zoomed="${3:-0}"
  layout_is_busy && return 0
  if [ "$("$TMUX_BIN" show-options -wqv -t "$win" @has_sidebar 2>/dev/null)" = "1" ]; then
    if window_has_one_pane "$win"; then
      cmd_refresh_window "$win"
      return 0
    fi
    case "$event" in
      window-resize|exit) cmd_rebalance "$win" ;;
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

open_in() {
  local win="$1" pid path new
  read -r pid _ < <(sidebar_pane "$win")
  [ -n "${pid:-}" ] && return 0
  path="$("$TMUX_BIN" display-message -p -t "$win" '#{pane_current_path}')"
  new="$("$TMUX_BIN" split-window -hbdf -l "$WIDTH" -c "$path" -t "$win" \
    -P -F '#{pane_id}' "exec '$SCRIPT_PATH' render")" || return 0
  "$TMUX_BIN" set-option -p -t "$new" @sidebar 1
  "$TMUX_BIN" set-option -p -t "$new" window-style "bg=#{@solarized_base03}"
  "$TMUX_BIN" set-window-option -t "$win" @has_sidebar 1
  cmd_rebalance "$win"
}

close_in() {
  local win="$1" pid
  read -r pid _ < <(sidebar_pane "$win")
  [ -z "${pid:-}" ] && return 0
  "$TMUX_BIN" set-window-option -t "$win" -qu @has_sidebar
  "$TMUX_BIN" kill-pane -t "$pid"
  "$TMUX_BIN" select-layout -t "$win" -E 2>/dev/null || true
}

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

cmd_ensure() {
  sidebar_enabled || return 0
  open_in "${1:-$("$TMUX_BIN" display-message -p '#{window_id}')}"
}

cmd_ensure_all() {
  local w
  sidebar_enabled || return 0
  while IFS= read -r w; do open_in "$w"; done \
    < <("$TMUX_BIN" list-windows -a -F '#{window_id}')
}

reset_in() {
  local win="$1" p
  for p in $("$TMUX_BIN" list-panes -t "$win" -F '#{pane_id} #{@sidebar}' 2>/dev/null | awk '$2 == "1" { print $1 }'); do
    "$TMUX_BIN" kill-pane -t "$p" 2>/dev/null || true
  done
  "$TMUX_BIN" set-window-option -t "$win" -qu @has_sidebar 2>/dev/null
  "$TMUX_BIN" select-layout -t "$win" -E 2>/dev/null || true
  sidebar_enabled && open_in "$win"
}

cmd_reset_all() {
  local w
  while IFS= read -r w; do reset_in "$w"; done \
    < <("$TMUX_BIN" list-windows -a -F '#{window_id}')
}

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

list_sessions_with_branch() {
  "$TMUX_BIN" list-sessions -F '#{session_name}'"$SEP"'#{@git_branch}' 2>/dev/null
}

session_index_at_row() {
  local wanted="$1" row=0 index=0 name branch
  case "$wanted" in *[!0-9]*|'') return 1 ;; esac

  while IFS="$SEP" read -r name branch; do
    index=$((index + 1))
    [ "$index" -gt 1 ] && row=$((row + 1))

    if [ "$wanted" -eq "$row" ]; then
      printf '%s\n' "$index"
      return 0
    fi
    row=$((row + 1))

    if [ -n "$branch" ]; then
      if [ "$wanted" -eq "$row" ]; then
        printf '%s\n' "$index"
        return 0
      fi
      row=$((row + 1))
    fi
  done < <(list_sessions_with_branch)
  return 1
}

cmd_click() {
  local row="$1" client="${2:-}" index
  index="$(session_index_at_row "$row")" || return 0
  cmd_switch "$index" "$client"
}

ESC=$'\033'
RESET="${ESC}[0m"
HIDE_CURSOR="${ESC}[?25l"
SHOW_CURSOR="${ESC}[?25h"
CLEAR_SCREEN="${ESC}[H${ESC}[2J"
GREY="$TMUX_FG_BASE01_ANSI"
NAME="$TMUX_FG_BASE00_ANSI"
IDLE="$TMUX_AI_IDLE_ANSI"
THINK="$TMUX_AI_THINK_ANSI"
SELECT="$TMUX_SELECT_ANSI"
YELLOW="$TMUX_YELLOW_ANSI"

sidebar_wake_dir() {
  printf '%s/tmux-sidebar-%s\n' "${TMPDIR:-/tmp}" "${UID:-$(id -u)}"
}

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

  local -A ai_state=()
  local sn ps
  while IFS="$SEP" read -r sn ps; do
    case "$ps" in
      thinking) ai_state[$sn]=thinking ;;
      idle)     [ "${ai_state[$sn]:-}" = thinking ] || ai_state[$sn]=idle ;;
    esac
  done < <("$TMUX_BIN" list-panes -a -F '#{session_name}'"$SEP"'#{@ai_state}' 2>/dev/null)

  local -a names idle think branch
  local n br count=0 st
  while IFS="$SEP" read -r n br; do
    st="${ai_state[$n]:-}"
    names[count]="$n"
    idle[count]=0; think[count]=0
    case "$st" in idle) idle[count]=1 ;; thinking) think[count]=1 ;; esac
    branch[count]="$br"
    count=$((count + 1))
  done < <(list_sessions_with_branch)

  local j nm badge pad prefix prefix_cols name_budget selected cols label_width label color indent brname rule divider
  label_width=${#count}
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

    color=""
    [ "${idle[j]}" = "1" ] && color="$IDLE"
    [ "${think[j]}" = "1" ] && color="$THINK"
    [ "$selected" = "1" ] && color="$SELECT"

    [ "$j" -gt 0 ] && printf '%s\n' "$divider"

    cols=$((prefix_cols + ${#nm}))
    printf -v pad '%*s' "$(( width - cols > 0 ? width - cols : 0 ))" ''
    if [ -n "$color" ]; then
      printf '%s%s%s%s\n' "$color" "$prefix" "$nm" "${pad}${RESET}"
    else
      printf '%s%s%s%s\n' "$prefix" "$NAME" "$nm" "$RESET"
    fi

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

# A fifo opened read+write never blocks on open, even with no reader on the other end.
wake_sidebar_pane() {
  local pane="$1" fifo
  fifo="$(sidebar_wake_dir)/${pane#%}.fifo"
  [ -p "$fifo" ] || return 0
  { exec 4<>"$fifo" && printf '\n' >&4 && exec 4>&-; } 2>/dev/null || true
}

wake_rails() {
  local pane sb
  while read -r pane sb; do
    [ "$sb" = "1" ] && wake_sidebar_pane "$pane"
  done < <("$TMUX_BIN" list-panes "$@" -F '#{pane_id} #{@sidebar}' 2>/dev/null)
  return 0
}

cmd_refresh_window() { [ -n "${1:-}" ] && wake_rails -t "$1" || true; }
cmd_refresh() { wake_rails -a; }

rail_is_alone() {
  window_has_one_pane "${TMUX_PANE:-}"
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

  printf '%s' "$HIDE_CURSOR"
  trap 'printf "%s" "$SHOW_CURSOR"; rm -f "$wake_fifo"' EXIT INT TERM
  local out prev="" active woke
  prev="$(render_once)"; printf '%s%s' "$CLEAR_SCREEN" "$prev"
  while :; do
    woke=0
    if [ "$wake_fd_open" = "1" ]; then
      IFS= read -r -t "${SIDEBAR_REFRESH_INTERVAL:-30}" -u 3 _ && woke=1
    else
      sleep "${SIDEBAR_REFRESH_INTERVAL:-30}"
    fi
    rail_is_alone && break
    active="$("$TMUX_BIN" display-message -p -t "${TMUX_PANE:-}" '#{&&:#{window_active},#{session_attached}}' 2>/dev/null)"
    [ "$active" = "1" ] || continue
    out="$(render_once)"
    # tmux repaints only cells it saw change, so after a layout reshuffle the client's
    # copy of an unchanged rail can go stale; a wake always redraws to re-dirty every cell.
    if [ "$woke" = "1" ] || [ "$out" != "$prev" ]; then
      printf '%s%s' "$CLEAR_SCREEN" "$out"
      prev="$out"
    fi
  done
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  case "${1:-toggle}" in
    toggle)      run_quiet cmd_toggle ;;
    ensure)      run_quiet cmd_ensure "${2:-}" ;;
    ensure-all)  run_quiet cmd_ensure_all ;;
    reset-all)   run_quiet cmd_reset_all ;;
    switch)      cmd_switch "${2:-}" "${3:-}" ;;
    click)       cmd_click "${2:-}" "${3:-}" ;;
    refresh)     cmd_refresh ;;
    render)      cmd_render ;;
    fix)         cmd_fix "${2:-}" ;;
    rebalance)   cmd_rebalance "${2:-}" "${3:-}" ;;
    layout-hook) cmd_layout_hook "${2:-}" "${3:-}" "${4:-0}" ;;
    install-hooks) install_layout_hooks ;;
    *)           printf 'usage: %s {toggle|ensure [win]|ensure-all|reset-all|switch <n>|click <row> [client]|refresh|render|fix <win>|rebalance <win> [h|v]|layout-hook <ev> <win> <z>|install-hooks}\n' "${0##*/}" >&2; exit 2 ;;
  esac
fi
