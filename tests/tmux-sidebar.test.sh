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
if [ -n "\${TMUX_TEST_CLIENT_TTY:-}" ] && [ "\${1:-}" = list-clients ]; then
  printf '%s\n' "\$TMUX_TEST_CLIENT_TTY"
  exit 0
fi
exec "$real_tmux" -L "$SOCKET" "\$@"
EOF
chmod +x "$shim_dir/tmux"
export PATH="$shim_dir:$PATH"
export HOME="$work/home"          # empty HOME => no ~/.tmux.conf side effects
export SIDEBAR_WIDTH="$WIDTH"
unset TMUX TMUX_PANE 2>/dev/null || true
mkdir -p "$HOME"
# An empty .zshrc marks the throwaway HOME as configured so an interactive zsh
# work pane skips the newuser-install wizard -- otherwise the wizard swallows the
# typed `exit` and the pane-exited close test never sees the pane go away.
: > "$HOME/.zshrc"

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

# Do the work panes form a 2-D grid (>=2 distinct lefts AND >=2 distinct tops)?
# A grid means a mixed split's layout survived instead of being flattened into a
# single row/column by a 1-D even-spread. @sidebar goes LAST: it's empty on work
# panes, and as a leading field its empty value collapses under awk's whitespace
# splitting and shifts every later column (the same hazard render_once documents).
is_grid() {
  local sess="$1"
  t list-panes -t "$sess" -F '#{pane_left} #{pane_top} #{@sidebar}' \
    | awk '$3!="1"{ L[$1]=1; T[$2]=1 }
           END{ nl=0; for(k in L)nl++; nt=0; for(k in T)nt++; exit !(nl>=2 && nt>=2) }'
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

# --- mixed split makes a 2-D grid: the rail stays pinned and the grid survives ---
# A row whose right pane is split vertically (or a column whose bottom pane is split
# horizontally) is a grid no single orientation can even. An explicit h/v hint from
# the split binding must NOT force a 1-D spread there — that flattens the layout. The
# rebalance has to defer to the actual arrangement and leave the grid alone.
# @sidebar goes last in every pane selector below, for the column-shift reason in
# is_grid's comment.
railg="$(make_window wing)"
gwork="$(t list-panes -t wing -F '#{pane_id} #{@sidebar}' | awk '$2!="1"{print $1; exit}')"
t split-window -h -t "$gwork"                 # rail + two work panes in a row
"$script" rebalance wing h
gright="$(t list-panes -t wing -F '#{pane_left} #{pane_id} #{@sidebar}' \
  | awk '$3!="1"{print $1, $2}' | sort -n | tail -1 | awk '{print $2}')"
t split-window -v -t "$gright"                # split the right pane -> 2-D grid
"$script" rebalance wing v                    # the v hint must not mangle the grid
rail_ok wing;            check "grid (v hint): rail stays pinned through a mixed split" "$?"
is_grid wing;            check "grid (v hint): the 2-D layout survives, not flattened" "$?"

# The mirror case: a column whose bottom pane is split horizontally, rebalanced with
# an h hint — guards specifically against even-horizontal collapsing it to one row.
railg2="$(make_window wing2)"
g2work="$(t list-panes -t wing2 -F '#{pane_id} #{@sidebar}' | awk '$2!="1"{print $1; exit}')"
t split-window -v -t "$g2work"                # rail + two work panes stacked
"$script" rebalance wing2 v
g2bottom="$(t list-panes -t wing2 -F '#{pane_top} #{pane_id} #{@sidebar}' \
  | awk '$3!="1"{print $1, $2}' | sort -n | tail -1 | awk '{print $2}')"
t split-window -h -t "$g2bottom"              # split the bottom pane -> 2-D grid
"$script" rebalance wing2 h                    # the h hint must not even-horizontal it
rail_ok wing2;           check "grid (h hint): rail stays pinned through a mixed split" "$?"
is_grid wing2;           check "grid (h hint): the 2-D layout survives, not flattened" "$?"

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

# --- pure helpers: source the script for its functions -------------------------
# The dispatch guard lets us source the script for its functions (render_once,
# rail_is_alone, cmd_refresh) without running a subcommand.
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

# --- click mapping: name + branch rows select; divider rows do nothing ---------
# The first two sessions give us a deterministic prefix of the rendered list. Give
# the first a branch so it occupies rows 0 and 1; row 2 is the divider; the second
# session starts on row 3. Stub cmd_switch so this stays a pure mapping test and
# does not need an attached client on the throwaway server.
first_session="$(t list-sessions -F '#{session_name}' | sed -n '1p')"
t set-option -t "$first_session" @git_branch click-test
clicked=""
cmd_switch() { clicked="$1/$2"; }
cmd_click 0 click-client
[ "$clicked" = "1/click-client" ]
check "click: session name row switches to that session" "$?"
clicked=""
cmd_click 1 click-client
[ "$clicked" = "1/click-client" ]
check "click: git branch row switches to its session" "$?"
clicked=""
cmd_click 2 click-client
[ -z "$clicked" ]
check "click: divider row does nothing" "$?"
clicked=""
cmd_click 3 click-client
[ "$clicked" = "2/click-client" ]
check "click: next session name maps past the divider" "$?"
t set-option -t "$first_session" -u @git_branch

# --- a settled layout wakes the rail so the client redraw can't drift -----------
# A split/close/resize pins the rail back to WIDTH but leaves its content identical;
# the rail must still be woken so its render loop forces a full redraw and the
# client's copy can't drift stale (the regression behind "the sidebar looks wrong
# after I change the layout"). cmd_fix is the last step of every settle, so it owns
# the wake. The render loop normally owns the wake fifo; here we stand in for it —
# make the fifo and hold it open so the write never blocks, then assert a byte lands.
make_window winwake >/dev/null
wakerail="$(t list-panes -t winwake -F '#{pane_id} #{@sidebar}' | awk '$2=="1"{print $1; exit}')"
wdir="$(sidebar_wake_dir)"; mkdir -p "$wdir"
wfifo="$wdir/${wakerail#%}.fifo"; rm -f "$wfifo"; mkfifo "$wfifo"
exec 7<>"$wfifo"
cmd_fix winwake                              # rail already at WIDTH: no resize, but still wakes
if IFS= read -r -t 2 -u 7 _; then r=0; else r=1; fi
check "layout-wake: cmd_fix wakes the rail even when the width is unchanged" "$r"
exec 7>&-; rm -f "$wfifo"

# The split path (agent-split -> cmd_rebalance) settles through cmd_fix, so it wakes
# too — guard that a spread after a split drops a byte on the rail's wake fifo.
make_window winwake2 >/dev/null
t split-window -h -t winwake2
wakerail2="$(t list-panes -t winwake2 -F '#{pane_id} #{@sidebar}' | awk '$2=="1"{print $1; exit}')"
wfifo2="$wdir/${wakerail2#%}.fifo"; rm -f "$wfifo2"; mkfifo "$wfifo2"
exec 7<>"$wfifo2"
cmd_rebalance winwake2 h
if IFS= read -r -t 2 -u 7 _; then r=0; else r=1; fi
check "layout-wake: cmd_rebalance wakes the rail after a split-driven spread" "$r"
exec 7>&-; rm -f "$wfifo2"

# --- render: a session's badge is the live aggregate of its pane @ai_state ------
# State lives on the agent's pane; the rail derives the badge from the live pane
# states each render, so a killed/exited agent can't leave a stale badge behind.
# The rail labels each row by session name, so grep for the unique session name.
t new-session -d -s winai -x "$WIN_W" -y "$WIN_H"
airail="$(t split-window -hbdf -l "$WIDTH" -P -F '#{pane_id}' -t winai)"
t set-option -p -t "$airail" @sidebar 1
aiwork="$(t list-panes -t winai -F '#{pane_id} #{@sidebar}' | awk '$2!="1"{print $1; exit}')"
# render_once uses `[ … ] && …` lines that go non-zero on the false branch; the
# live loop runs without errexit, so disable it here to drive it the same way.
render() { ( set +e; TMUX_PANE="$airail" render_once 2>/dev/null ); }
ai_line() { render | grep -F winai; }              # the winai name row
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

# --- render: the git branch sits on its own indented line under the name --------
# @git_branch is a session option; the rail prints it on a second, indented row
# rather than inline with the session name. winai is the rendered pane's session,
# so it's the selected row — its highlight bar should cover the branch line too.
strip_ansi() { sed -r 's/\x1b\[[0-9;]*m//g'; }
t set-option -t winai @git_branch feature-xyz
brline="$(render | strip_ansi | grep -F feature-xyz)"
if printf '%s' "$brline" | grep -q winai; then r=1; else r=0; fi
check "render: branch is on its own line, not the name row" "$r"
if printf '%s' "$brline" | grep -qE '^ +'; then r=0; else r=1; fi
check "render: branch line is indented under the name" "$r"
# 48;2;… is a truecolor background — only a highlighted bar carries one, so its
# presence on the branch line proves the bar spans both rows of the selected row.
if render | grep -F feature-xyz | grep -q '48;2'; then r=0; else r=1; fi
check "render: the highlight bar covers the branch line of a selected row" "$r"
t set-option -t winai -u @git_branch

# --- render: a rule sits between EVERY pair of adjacent sessions ----------------
# The rule is always present so the list reads consistently, whatever the state —
# it isn't gated on a row being highlighted. zdiv1/zdiv2 are thinking, zdiv3 is
# plain: a rule sits directly above zdiv2 (predecessor zdiv1) AND above zdiv3
# (predecessor zdiv2, a plain row), but never above the very first session. Names
# are 'z'-prefixed so they sort last and adjacent; none carry a branch, so each row
# is one line and the line directly above a row is its separator. A rule line is all
# ─ (plus any padding); tr -d strips ─ and spaces, so an emptied line was a rule.
t new-session -d -s zdiv1 -x "$WIN_W" -y "$WIN_H"
t new-session -d -s zdiv2 -x "$WIN_W" -y "$WIN_H"
t new-session -d -s zdiv3 -x "$WIN_W" -y "$WIN_H"   # left plain (no @ai_state)
t set-option -p -t "$(t list-panes -t zdiv1 -F '#{pane_id}' | head -1)" @ai_state thinking
t set-option -p -t "$(t list-panes -t zdiv2 -F '#{pane_id}' | head -1)" @ai_state thinking
is_rule() { [ -n "$1" ] && [ -z "$(printf '%s' "$1" | tr -d '─ ')" ]; }
# awk reads to EOF (capturing the line above the match in END) rather than exiting
# at the match — an early exit SIGPIPEs the upstream sed, which pipefail then turns
# into a nonzero pipeline and trips the suite's set -e.
divsep="$(render | strip_ansi | awk '/zdiv2/{r=prev} {prev=$0} END{print r}')"
if is_rule "$divsep"; then r=0; else r=1; fi
check "render: a rule separates adjacent sessions" "$r"
plainsep="$(render | strip_ansi | awk '/zdiv3/{r=prev} {prev=$0} END{print r}')"
if is_rule "$plainsep"; then r=0; else r=1; fi
check "render: the rule is always present, even next to a plain row" "$r"
firstline="$(render | strip_ansi | sed -n '1p')"
if is_rule "$firstline"; then r=1; else r=0; fi
check "render: no rule above the first session row" "$r"
t kill-session -t zdiv1 2>/dev/null || true
t kill-session -t zdiv2 2>/dev/null || true
t kill-session -t zdiv3 2>/dev/null || true

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

# Codex may report the same completed turn through both its Stop hook and the
# legacy `notify` callback. Only the thinking -> idle transition should ping.
notify_log="$work/idle-notifications"
TMUX_PANE="$syncwork" bash "$ai_script" thinking
TMUX_TEST_CLIENT_TTY=/dev/fd/9 TMUX_PANE="$syncwork" bash "$ai_script" idle 9>>"$notify_log"
first_notification_size="$(wc -c <"$notify_log" | tr -d ' ')"
TMUX_TEST_CLIENT_TTY=/dev/fd/9 TMUX_PANE="$syncwork" bash "$ai_script" idle 9>>"$notify_log"
second_notification_size="$(wc -c <"$notify_log" | tr -d ' ')"
[ "$first_notification_size" -gt 0 ] && [ "$second_notification_size" = "$first_notification_size" ]
check "ai-state: duplicate idle signals produce one desktop notification" "$?"
TMUX_PANE="$syncwork" bash "$ai_script" clear

# --- ai-state: republishes the agent pane's git branch onto @git_branch ---------
# A branch switched while an agent (not a shell) holds the pane has no precmd to
# push it, so the hook re-derives it from the pane's cwd. The work pane is cwd'd
# into a repo on a known branch; running the hook must publish that branch — and a
# pane in a non-repo dir must clear a stale value.
brrepo="$work/brrepo"; mkdir -p "$brrepo"
git -C "$brrepo" init -q -b on-feature
git -C "$brrepo" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
t new-session -d -s winbr -x "$WIN_W" -y "$WIN_H" -c "$brrepo"
brwork="$(t list-panes -t winbr -F '#{pane_id} #{@sidebar}' | awk '$2!="1"{print $1; exit}')"
TMUX_PANE="$brwork" bash "$ai_script" thinking
[ "$(t show-options -qv -t winbr @git_branch)" = on-feature ]
check "ai-state: publishes the agent pane's branch onto @git_branch" "$?"

t new-session -d -s winbr2 -x "$WIN_W" -y "$WIN_H" -c "$work"   # $work is no repo
t set-option -t winbr2 @git_branch stale                        # the hook must clear it
br2work="$(t list-panes -t winbr2 -F '#{pane_id} #{@sidebar}' | awk '$2!="1"{print $1; exit}')"
TMUX_PANE="$br2work" bash "$ai_script" thinking
[ -z "$(t show-options -qv -t winbr2 @git_branch)" ]
check "ai-state: clears @git_branch when the pane is not in a repo" "$?"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
