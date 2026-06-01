#!/usr/bin/env bash
# Tests for .tmux-sidebar.sh's layout logic (spread_around_sidebar / cmd_fix):
# the rail must stay a fixed-width, full-height left column while the remaining
# work panes are spread evenly. Runs on a dedicated tmux socket via a PATH shim,
# so the unmodified script drives the throwaway server. Run directly:
#   bash tests/tmux-sidebar.test.sh
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
script="$here/../tmux/.tmux-sidebar.sh"
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

[ "$(folder_label_for_path "$work/proj/sub" fallback)" = "sub" ]
check "label: plain path uses its basename" "$?"

[ "$(folder_label_for_path "$work/myrepo-worktrees/feature-x" fallback)" = "myrepo" ]
check "label: a path under <repo>-worktrees shows the repo name" "$?"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
