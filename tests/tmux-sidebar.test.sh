#!/usr/bin/env bash
# Tests for .tmux-sidebar.sh's layout logic (spread_around_sidebar / cmd_fix):
# the rail must stay a fixed-width, full-height left column while the remaining
# work panes are spread evenly. Runs on a dedicated tmux socket via a PATH shim,
# so the unmodified script drives the throwaway server. Run directly:
#   bash tests/tmux-sidebar.test.sh
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
script="$here/../tmux/.tmux-sidebar.sh"
ai_script="$here/../tmux/.tmux-ai-state.sh"
real_tmux="$(command -v tmux)"

WIDTH=26
WIN_W=200
WIN_H=50

work="$(mktemp -d)"
SOCKET="sidebar_test_$$"
# A PATH shim so `command -v tmux` inside the script finds a tmux that always
# targets our throwaway socket. The script resolves tmux via PATH, so this drives
# the whole run onto SOCKET without touching the real server.
shim_dir="$work/bin"
mkdir -p "$shim_dir"
cat >"$shim_dir/tmux" <<EOF
#!/bin/sh
exec "$real_tmux" -L "$SOCKET" "\$@"
EOF
chmod +x "$shim_dir/tmux"
export PATH="$shim_dir:$PATH"
export HOME="$work/home"          # empty HOME => no ~/.tmux.conf side effects
export SIDEBAR_WIDTH="$WIDTH"
unset TMUX TMUX_PANE 2>/dev/null || true
mkdir -p "$HOME"

t() { tmux "$@"; }   # uses the shim

cleanup() {
  t kill-server 2>/dev/null || true
  rm -rf "$work" 2>/dev/null || true
}
trap cleanup EXIT

pass=0
fail=0
check() {
  local desc="$1" cond="$2"
  if [ "$cond" = "0" ]; then printf 'ok   - %s\n' "$desc"; pass=$((pass + 1))
  else printf 'FAIL - %s\n' "$desc"; fail=$((fail + 1)); fi
}

# Create a window with a rail pane on the left, marked like open_in does.
make_window() {
  local name="$1"
  t new-session -d -s "$name" -x "$WIN_W" -y "$WIN_H" 2>/dev/null \
    || t new-window -t bootstrap -n "$name"
  local rail
  rail="$(t split-window -hbdf -l "$WIDTH" -P -F '#{pane_id}' -t "$name")"
  t set-option -p -t "$rail" @sidebar 1
  t set-window-option -t "$name" @has_sidebar 1
  printf '%s\n' "$rail"
}

rail_ok() {       # rail pinned to WIDTH and full height?
  local sess="$1" expect_h="${2:-$WIN_H}"
  t list-panes -t "$sess" -F '#{@sidebar} #{pane_width} #{pane_height}' \
    | awk -v w="$WIDTH" -v h="$expect_h" '$1=="1"{ exit !($2==w && $3==h) }'
}

# Are the work (non-rail) panes even along DIM (width|height), within 1 cell?
rest_even() {
  local sess="$1" dim="$2" fld
  [ "$dim" = "width" ] && fld='#{pane_width}' || fld='#{pane_height}'
  t list-panes -t "$sess" -F '#{@sidebar} '"$fld" \
    | awk '$1!="1"{ v[n++]=$2 } END{
        if (n<2) exit 0
        mn=v[0]; mx=v[0]
        for (i=1;i<n;i++){ if(v[i]<mn)mn=v[i]; if(v[i]>mx)mx=v[i] }
        exit !((mx-mn)<=1)
      }'
}

# --- horizontal rest: three side-by-side work panes spread evenly ---------------
railh="$(make_window winh)"
t split-window -h -t winh
t split-window -h -t winh
"$script" rebalance winh h
rail_ok winh;            check "h: rail pinned to width, full height" "$?"
rest_even winh width;    check "h: three work panes are even in width" "$?"

# --- a work pane exits: survivors re-spread evenly around the rail --------------
victim="$(t list-panes -t winh -F '#{@sidebar} #{pane_id}' | awk '$1!="1"{print $2; exit}')"
t kill-pane -t "$victim"
"$script" rebalance winh h
rail_ok winh;            check "h: rail still pinned after a pane exits" "$?"
rest_even winh width;    check "h: two surviving work panes re-even" "$?"

# --- vertical rest: three stacked work panes spread evenly ----------------------
railv="$(make_window winv)"
workv="$(t list-panes -t winv -F '#{@sidebar} #{pane_id}' | awk '$1!="1"{print $2; exit}')"
t split-window -v -t "$workv"
t split-window -v -t "$workv"
"$script" rebalance winv v
rail_ok winv;            check "v: rail pinned to width, full height" "$?"
rest_even winv height;   check "v: three work panes are even in height" "$?"

# --- single work pane: nothing to even, rail still pinned -----------------------
rail1="$(make_window win1)"
"$script" rebalance win1 h
rail_ok win1;            check "single work pane: rail still pinned" "$?"

# --- fix subcommand re-pins a rail that drifted wide ----------------------------
t resize-pane -t "$rail1" -x $((WIDTH + 20)) 2>/dev/null || true
"$script" fix win1
rail_ok win1;            check "fix re-pins a rail that drifted wider" "$?"

# --- window shrink: work panes re-even around the pinned rail -----------------
railw="$(make_window winw)"
t split-window -h -t winw
t split-window -h -t winw
"$script" rebalance winw h
t resize-window -t winw -x 120 -y 40
"$script" layout-hook window-resize winw 0
rail_ok winw 40;         check "window-resize: rail pinned after shrink" "$?"
rest_even winw width;    check "window-resize: work panes re-even after shrink" "$?"

# --- self-close: a rail running the render loop deletes itself once alone --------
# Drives the *real* render loop (fast tick) so we exercise the actual self-detect,
# not a stand-in. No pane-exited hook here, so this is the pure next-tick path —
# the same backstop any explicit kill (prefix x, mouse) relies on.
make_render_window() {           # like make_window, but the rail runs `render`
  local name="$1" rail
  t new-session -d -s "$name" -x "$WIN_W" -y "$WIN_H"
  rail="$(t split-window -hbdf -l "$WIDTH" -e SIDEBAR_REFRESH_INTERVAL=1 \
            -P -F '#{pane_id}' -t "$name" "exec '$script' render")"
  t set-option -p -t "$rail" @sidebar 1
  t set-window-option -t "$name" @has_sidebar 1
}

make_render_window winself
selfwork="$(t list-panes -t winself -F '#{pane_id} #{@sidebar}' | awk '$2!="1"{print $1; exit}')"
t kill-pane -t "$selfwork"       # rail is now the only pane in winself
gone=1
for _ in $(seq 1 8); do
  t has-session -t winself 2>/dev/null || { gone=0; break; }
  sleep 0.5
done
check "self-close: a lone rail running the loop deletes itself" "$gone"

# --- a work pane survives: the rail keeps running, the window stays --------------
make_render_window winself2
t split-window -h -t winself2 >/dev/null     # rail + two work panes
self2victim="$(t list-panes -t winself2 -F '#{pane_id} #{@sidebar}' | awk '$2!="1"{print $1; exit}')"
t kill-pane -t "$self2victim"                # one work pane left beside the rail
sleep 1.5                                     # a couple of render ticks
if t has-session -t winself2 2>/dev/null; then self2_alive=0; else self2_alive=1; fi
check "self-close: rail stays while a work pane remains" "$self2_alive"

# --- hook-driven close: the rail wakes on the layout hook, NOT the backstop ------
# Installs the real hooks and uses a LONG backstop, so the rail can only close in
# time if a hook actually wakes it. This guards the regression where the exit/kill
# hook called cmd_rebalance->cmd_fix on a lone rail: pinning a sole pane to WIDTH
# can't shrink it, so after-resize-pane re-fires in a storm that jams the command
# queue and the wake never lands — the rail then only closed on the slow backstop.
# pane-exited covers a process ending; after-kill-pane covers an explicit kill.
t set-hook -g after-resize-pane "run-shell '$script layout-hook resize #{window_id} #{window_zoomed_flag}'"
t set-hook -g pane-exited       "run-shell '$script layout-hook exit #{window_id}'"
t set-hook -g after-kill-pane   "run-shell '$script layout-hook exit #{window_id}'"

make_hooked_render_window() {    # rail runs `render` with a LONG backstop tick
  local name="$1" rail
  t new-session -d -s "$name" -x "$WIN_W" -y "$WIN_H"
  rail="$(t split-window -hbdf -l "$WIDTH" -e SIDEBAR_REFRESH_INTERVAL=60 \
            -P -F '#{pane_id}' -t "$name" "exec '$script' render")"
  t set-option -p -t "$rail" @sidebar 1
  t set-window-option -t "$name" @has_sidebar 1
}

closed_fast() {                  # window gone within ~6s? (well under the 60s tick)
  local name="$1" _
  for _ in $(seq 1 24); do
    t has-session -t "$name" 2>/dev/null || return 0
    sleep 0.25
  done
  return 1
}

# Explicit kill of the last work pane -> after-kill-pane wakes the rail.
make_hooked_render_window winkill
killwork="$(t list-panes -t winkill -F '#{pane_id} #{@sidebar}' | awk '$2!="1"{print $1; exit}')"
t kill-pane -t "$killwork"
if closed_fast winkill; then r=0; else r=1; fi
check "hook-close: a killed last work pane closes the rail fast" "$r"

# Process exit of the last work pane -> pane-exited wakes the rail.
make_hooked_render_window winexit
exitwork="$(t list-panes -t winexit -F '#{pane_id} #{@sidebar}' | awk '$2!="1"{print $1; exit}')"
t send-keys -t "$exitwork" "exit" Enter
if closed_fast winexit; then r=0; else r=1; fi
check "hook-close: an exited last work pane closes the rail fast" "$r"

# A surviving work pane keeps the rail; the hook re-spreads instead of closing.
make_hooked_render_window winkeep
t split-window -h -t winkeep >/dev/null
keepvictim="$(t list-panes -t winkeep -F '#{pane_id} #{@sidebar}' | awk '$2!="1"{print $1; exit}')"
t kill-pane -t "$keepvictim"
sleep 1
if t has-session -t winkeep 2>/dev/null; then keep_alive=0; else keep_alive=1; fi
check "hook-close: rail survives a kill while a work pane remains" "$keep_alive"

t set-hook -gu after-resize-pane 2>/dev/null || true
t set-hook -gu pane-exited 2>/dev/null || true
t set-hook -gu after-kill-pane 2>/dev/null || true

# --- pure helper: folder_label_for_path (sidebar labels) ------------------------
# The dispatch guard lets us source the script for its functions without running
# a subcommand. These paths don't exist as git repos, so the label falls through
# to the path-walking logic we want to exercise.
# shellcheck source=/dev/null
source "$script"

# --- pure helper: rail_is_alone -------------------------------------------------
# The predicate the render loop self-closes on. Drive it directly by pointing
# TMUX_PANE at a rail (no render loop needed), so it's deterministic.
make_window winalone >/dev/null
alonerail="$(t list-panes -t winalone -F '#{pane_id} #{@sidebar}' | awk '$2=="1"{print $1; exit}')"
alonework="$(t list-panes -t winalone -F '#{pane_id} #{@sidebar}' | awk '$2!="1"{print $1; exit}')"
if TMUX_PANE="$alonerail" rail_is_alone; then r=1; else r=0; fi
check "rail_is_alone: false while a work pane is present" "$r"
t kill-pane -t "$alonework"          # rail (a plain shell here) is now the only pane
if TMUX_PANE="$alonerail" rail_is_alone; then r=0; else r=1; fi
check "rail_is_alone: true once the rail is the only pane" "$r"

# --- refresh exits 0 even when the last pane isn't a rail -----------------------
# wake_rails' loop ends on `[ "$sb" = "1" ]`, which is false for a work pane and
# would leak as a nonzero exit — tmux's run-shell then reports `refresh returned 1`
# on every new pane. Guard that the wake stays fire-and-forget (exit 0).
if cmd_refresh; then r=0; else r=1; fi
check "refresh: exits 0 even when work panes trail the rail" "$r"

[ "$(folder_label_for_path "$work/proj/sub" fallback)" = "sub" ]
check "label: plain path uses its basename" "$?"

[ "$(folder_label_for_path "$work/myrepo-worktrees/feature-x" fallback)" = "myrepo" ]
check "label: a path under <repo>-worktrees shows the repo name" "$?"

# --- render: a session's badge is the live aggregate of its pane @ai_state ------
# State lives on the agent's pane; the rail derives the badge from the live pane
# states each render, so a killed/exited agent can't leave a stale badge behind.
aidir="$work/aiproj"; mkdir -p "$aidir"          # unique folder label to grep for
t new-session -d -s winai -x "$WIN_W" -y "$WIN_H" -c "$aidir"
airail="$(t split-window -hbdf -l "$WIDTH" -c "$aidir" -P -F '#{pane_id}' -t winai)"
t set-option -p -t "$airail" @sidebar 1
aiwork="$(t list-panes -t winai -F '#{pane_id} #{@sidebar}' | awk '$2!="1"{print $1; exit}')"
# render_once uses `[ … ] && …` lines that go non-zero on the false branch; the
# live loop runs without errexit, so disable it here to drive it the same way.
ai_line() { ( set +e; TMUX_PANE="$airail" render_once 2>/dev/null ) | grep -F aiproj; }
has_badge() { ai_line | grep -q "$1"; }            # $1: ! or 💭

t set-option -p -t "$aiwork" @ai_state idle
has_badge '!'; check "render: an idle pane shows the ! badge" "$?"

t set-option -p -t "$aiwork" @ai_state thinking
has_badge '💭'; check "render: a thinking pane shows the 💭 badge" "$?"

aiwork2="$(t split-window -hdf -t winai -P -F '#{pane_id}')"
t set-option -p -t "$aiwork2" @ai_state idle    # one thinking, one idle
has_badge '💭'; check "render: thinking outranks idle across panes" "$?"
t kill-pane -t "$aiwork2"

t kill-pane -t "$aiwork"                          # the agent's pane goes away
if ai_line | grep -qe '!' -e '💭'; then r=1; else r=0; fi
check "render: badge clears when the agent's pane dies (self-heal)" "$r"

# --- ai-state script: sets the pane and mirrors it onto the session ------------
make_window winsync >/dev/null
syncwork="$(t list-panes -t winsync -F '#{pane_id} #{@sidebar}' | awk '$2!="1"{print $1; exit}')"
TMUX_PANE="$syncwork" bash "$ai_script" idle
[ "$(t show-options -pqv -t "$syncwork" @ai_state)" = idle ]
check "ai-state: idle sets the pane @ai_state" "$?"
[ "$(t show-options -qv -t winsync @session_ai_idle)" = 1 ]
check "ai-state: idle mirrors @session_ai_idle for the prefix-s tree" "$?"
TMUX_PANE="$syncwork" bash "$ai_script" clear
[ -z "$(t show-options -pqv -t "$syncwork" @ai_state)" ]
check "ai-state: clear unsets the pane @ai_state" "$?"
[ -z "$(t show-options -qv -t winsync @session_ai_idle)" ]
check "ai-state: clear re-syncs the session mirror off" "$?"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
