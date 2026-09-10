#!/usr/bin/env bash
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
script="$here/.tmux-sidebar.sh"
ai_script="$here/.tmux-ai-state.sh"
real_tmux="$(command -v tmux)"

WIDTH=26
WIN_W=200
WIN_H=50

work="$(mktemp -d)"
SOCKET="sidebar_test_$$"
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
export HOME="$work/home"
export SIDEBAR_WIDTH="$WIDTH"
unset TMUX TMUX_PANE 2>/dev/null || true
mkdir -p "$HOME"
# zsh runs its newuser-install wizard in a HOME with no .zshrc; the wizard would swallow the typed `exit`.
: > "$HOME/.zshrc"

t() { tmux "$@"; }

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

rail_ok() {
  local sess="$1" expect_h="${2:-$WIN_H}"
  t list-panes -t "$sess" -F '#{@sidebar} #{pane_width} #{pane_height}' \
    | awk -v w="$WIDTH" -v h="$expect_h" '$1=="1"{ exit !($2==w && $3==h) }'
}

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

is_grid() {
  local sess="$1"
  t list-panes -t "$sess" -F '#{pane_left} #{pane_top} #{@sidebar}' \
    | awk '$3!="1"{ L[$1]=1; T[$2]=1 }
           END{ nl=0; for(k in L)nl++; nt=0; for(k in T)nt++; exit !(nl>=2 && nt>=2) }'
}

railh="$(make_window winh)"
t split-window -h -t winh
t split-window -h -t winh
"$script" rebalance winh h
rail_ok winh;            check "h: rail pinned to width, full height" "$?"
rest_even winh width;    check "h: three work panes are even in width" "$?"

victim="$(t list-panes -t winh -F '#{@sidebar} #{pane_id}' | awk '$1!="1"{print $2; exit}')"
t kill-pane -t "$victim"
"$script" rebalance winh h
rail_ok winh;            check "h: rail still pinned after a pane exits" "$?"
rest_even winh width;    check "h: two surviving work panes re-even" "$?"

railv="$(make_window winv)"
workv="$(t list-panes -t winv -F '#{@sidebar} #{pane_id}' | awk '$1!="1"{print $2; exit}')"
t split-window -v -t "$workv"
t split-window -v -t "$workv"
"$script" rebalance winv v
rail_ok winv;            check "v: rail pinned to width, full height" "$?"
rest_even winv height;   check "v: three work panes are even in height" "$?"

rail1="$(make_window win1)"
"$script" rebalance win1 h
rail_ok win1;            check "single work pane: rail still pinned" "$?"

t resize-pane -t "$rail1" -x $((WIDTH + 20)) 2>/dev/null || true
"$script" fix win1
rail_ok win1;            check "fix re-pins a rail that drifted wider" "$?"

railw="$(make_window winw)"
t split-window -h -t winw
t split-window -h -t winw
"$script" rebalance winw h
t resize-window -t winw -x 120 -y 40
"$script" layout-hook window-resize winw 0
rail_ok winw 40;         check "window-resize: rail pinned after shrink" "$?"
rest_even winw width;    check "window-resize: work panes re-even after shrink" "$?"

railg="$(make_window wing)"
gwork="$(t list-panes -t wing -F '#{pane_id} #{@sidebar}' | awk '$2!="1"{print $1; exit}')"
t split-window -h -t "$gwork"
"$script" rebalance wing h
gright="$(t list-panes -t wing -F '#{pane_left} #{pane_id} #{@sidebar}' \
  | awk '$3!="1"{print $1, $2}' | sort -n | tail -1 | awk '{print $2}')"
t split-window -v -t "$gright"
"$script" rebalance wing v
rail_ok wing;            check "grid (v hint): rail stays pinned through a mixed split" "$?"
is_grid wing;            check "grid (v hint): the 2-D layout survives, not flattened" "$?"

railg2="$(make_window wing2)"
g2work="$(t list-panes -t wing2 -F '#{pane_id} #{@sidebar}' | awk '$2!="1"{print $1; exit}')"
t split-window -v -t "$g2work"
"$script" rebalance wing2 v
g2bottom="$(t list-panes -t wing2 -F '#{pane_top} #{pane_id} #{@sidebar}' \
  | awk '$3!="1"{print $1, $2}' | sort -n | tail -1 | awk '{print $2}')"
t split-window -h -t "$g2bottom"
"$script" rebalance wing2 h
rail_ok wing2;           check "grid (h hint): rail stays pinned through a mixed split" "$?"
is_grid wing2;           check "grid (h hint): the 2-D layout survives, not flattened" "$?"

make_render_window() {
  local name="$1" rail
  t new-session -d -s "$name" -x "$WIN_W" -y "$WIN_H"
  rail="$(t split-window -hbdf -l "$WIDTH" -e SIDEBAR_REFRESH_INTERVAL=1 \
            -P -F '#{pane_id}' -t "$name" "exec '$script' render")"
  t set-option -p -t "$rail" @sidebar 1
  t set-window-option -t "$name" @has_sidebar 1
}

make_render_window winself
selfwork="$(t list-panes -t winself -F '#{pane_id} #{@sidebar}' | awk '$2!="1"{print $1; exit}')"
t kill-pane -t "$selfwork"
gone=1
for _ in $(seq 1 8); do
  t has-session -t winself 2>/dev/null || { gone=0; break; }
  sleep 0.5
done
check "self-close: a lone rail running the loop deletes itself" "$gone"

make_render_window winself2
t split-window -h -t winself2 >/dev/null
self2victim="$(t list-panes -t winself2 -F '#{pane_id} #{@sidebar}' | awk '$2!="1"{print $1; exit}')"
t kill-pane -t "$self2victim"
sleep 1.5
if t has-session -t winself2 2>/dev/null; then self2_alive=0; else self2_alive=1; fi
check "self-close: rail stays while a work pane remains" "$self2_alive"

t set-hook -g after-resize-pane "run-shell '$script layout-hook resize #{window_id} #{window_zoomed_flag}'"
t set-hook -g pane-exited       "run-shell '$script layout-hook exit #{window_id}'"
t set-hook -g after-kill-pane   "run-shell '$script layout-hook exit #{window_id}'"

make_hooked_render_window() {
  local name="$1" rail
  t new-session -d -s "$name" -x "$WIN_W" -y "$WIN_H"
  rail="$(t split-window -hbdf -l "$WIDTH" -e SIDEBAR_REFRESH_INTERVAL=60 \
            -P -F '#{pane_id}' -t "$name" "exec '$script' render")"
  t set-option -p -t "$rail" @sidebar 1
  t set-window-option -t "$name" @has_sidebar 1
}

closed_fast() {
  local name="$1" _
  for _ in $(seq 1 24); do
    t has-session -t "$name" 2>/dev/null || return 0
    sleep 0.25
  done
  return 1
}

make_hooked_render_window winkill
killwork="$(t list-panes -t winkill -F '#{pane_id} #{@sidebar}' | awk '$2!="1"{print $1; exit}')"
t kill-pane -t "$killwork"
if closed_fast winkill; then r=0; else r=1; fi
check "hook-close: a killed last work pane closes the rail fast" "$r"

make_hooked_render_window winexit
exitwork="$(t list-panes -t winexit -F '#{pane_id} #{@sidebar}' | awk '$2!="1"{print $1; exit}')"
t send-keys -t "$exitwork" "exit" Enter
if closed_fast winexit; then r=0; else r=1; fi
check "hook-close: an exited last work pane closes the rail fast" "$r"

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

# shellcheck source=/dev/null
source "$script"

make_window winalone >/dev/null
alonerail="$(t list-panes -t winalone -F '#{pane_id} #{@sidebar}' | awk '$2=="1"{print $1; exit}')"
alonework="$(t list-panes -t winalone -F '#{pane_id} #{@sidebar}' | awk '$2!="1"{print $1; exit}')"
if TMUX_PANE="$alonerail" rail_is_alone; then r=1; else r=0; fi
check "rail_is_alone: false while a work pane is present" "$r"
t kill-pane -t "$alonework"
if TMUX_PANE="$alonerail" rail_is_alone; then r=0; else r=1; fi
check "rail_is_alone: true once the rail is the only pane" "$r"

if cmd_refresh; then r=0; else r=1; fi
check "refresh: exits 0 even when work panes trail the rail" "$r"

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

make_window winwake >/dev/null
wakerail="$(t list-panes -t winwake -F '#{pane_id} #{@sidebar}' | awk '$2=="1"{print $1; exit}')"
wdir="$(sidebar_wake_dir)"; mkdir -p "$wdir"
wfifo="$wdir/${wakerail#%}.fifo"; rm -f "$wfifo"; mkfifo "$wfifo"
exec 7<>"$wfifo"
cmd_fix winwake
if IFS= read -r -t 2 -u 7 _; then r=0; else r=1; fi
check "layout-wake: cmd_fix wakes the rail even when the width is unchanged" "$r"
exec 7>&-; rm -f "$wfifo"

make_window winwake2 >/dev/null
t split-window -h -t winwake2
wakerail2="$(t list-panes -t winwake2 -F '#{pane_id} #{@sidebar}' | awk '$2=="1"{print $1; exit}')"
wfifo2="$wdir/${wakerail2#%}.fifo"; rm -f "$wfifo2"; mkfifo "$wfifo2"
exec 7<>"$wfifo2"
cmd_rebalance winwake2 h
if IFS= read -r -t 2 -u 7 _; then r=0; else r=1; fi
check "layout-wake: cmd_rebalance wakes the rail after a split-driven spread" "$r"
exec 7>&-; rm -f "$wfifo2"

t new-session -d -s winai -x "$WIN_W" -y "$WIN_H"
airail="$(t split-window -hbdf -l "$WIDTH" -P -F '#{pane_id}' -t winai)"
t set-option -p -t "$airail" @sidebar 1
aiwork="$(t list-panes -t winai -F '#{pane_id} #{@sidebar}' | awk '$2!="1"{print $1; exit}')"
render() { ( set +e; TMUX_PANE="$airail" render_once 2>/dev/null ); }
ai_line() { render | grep -F winai; }
has_badge() { ai_line | grep -q "$1"; }

t set-option -p -t "$aiwork" @ai_state idle
has_badge '!'; check "render: an idle pane shows the ! badge" "$?"

t set-option -p -t "$aiwork" @ai_state thinking
has_badge '💭'; check "render: a thinking pane shows the 💭 badge" "$?"

aiwork2="$(t split-window -hdf -t winai -P -F '#{pane_id}')"
t set-option -p -t "$aiwork2" @ai_state idle
has_badge '💭'; check "render: thinking outranks idle across panes" "$?"
t kill-pane -t "$aiwork2"

t kill-pane -t "$aiwork"
if ai_line | grep -qe '!' -e '💭'; then r=1; else r=0; fi
check "render: badge clears when the agent's pane dies (self-heal)" "$r"

strip_ansi() { sed -r 's/\x1b\[[0-9;]*m//g'; }
has_truecolor_bg() { grep -q '48;2'; }
t set-option -t winai @git_branch feature-xyz
brline="$(render | strip_ansi | grep -F feature-xyz)"
if printf '%s' "$brline" | grep -q winai; then r=1; else r=0; fi
check "render: branch is on its own line, not the name row" "$r"
if printf '%s' "$brline" | grep -qE '^ +'; then r=0; else r=1; fi
check "render: branch line is indented under the name" "$r"
if render | grep -F feature-xyz | has_truecolor_bg; then r=0; else r=1; fi
check "render: the highlight bar covers the branch line of a selected row" "$r"
t set-option -t winai -u @git_branch

t new-session -d -s zdiv1 -x "$WIN_W" -y "$WIN_H"
t new-session -d -s zdiv2 -x "$WIN_W" -y "$WIN_H"
t new-session -d -s zdiv3 -x "$WIN_W" -y "$WIN_H"
t set-option -p -t "$(t list-panes -t zdiv1 -F '#{pane_id}' | head -1)" @ai_state thinking
t set-option -p -t "$(t list-panes -t zdiv2 -F '#{pane_id}' | head -1)" @ai_state thinking
is_rule() { [ -n "$1" ] && [ -z "$(printf '%s' "$1" | tr -d '─ ')" ]; }
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

notify_log="$work/idle-notifications"
TMUX_PANE="$syncwork" bash "$ai_script" thinking
TMUX_TEST_CLIENT_TTY=/dev/fd/9 TMUX_PANE="$syncwork" bash "$ai_script" idle 9>>"$notify_log"
first_notification_size="$(wc -c <"$notify_log" | tr -d ' ')"
TMUX_TEST_CLIENT_TTY=/dev/fd/9 TMUX_PANE="$syncwork" bash "$ai_script" idle 9>>"$notify_log"
second_notification_size="$(wc -c <"$notify_log" | tr -d ' ')"
[ "$first_notification_size" -gt 0 ] && [ "$second_notification_size" = "$first_notification_size" ]
check "ai-state: duplicate idle signals produce one desktop notification" "$?"
TMUX_PANE="$syncwork" bash "$ai_script" clear

brrepo="$work/brrepo"; mkdir -p "$brrepo"
git -C "$brrepo" init -q -b on-feature
git -C "$brrepo" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
t new-session -d -s winbr -x "$WIN_W" -y "$WIN_H" -c "$brrepo"
brwork="$(t list-panes -t winbr -F '#{pane_id} #{@sidebar}' | awk '$2!="1"{print $1; exit}')"
TMUX_PANE="$brwork" bash "$ai_script" thinking
[ "$(t show-options -qv -t winbr @git_branch)" = on-feature ]
check "ai-state: publishes the agent pane's branch onto @git_branch" "$?"

t new-session -d -s winbr2 -x "$WIN_W" -y "$WIN_H" -c "$work"
t set-option -t winbr2 @git_branch stale
br2work="$(t list-panes -t winbr2 -F '#{pane_id} #{@sidebar}' | awk '$2!="1"{print $1; exit}')"
TMUX_PANE="$br2work" bash "$ai_script" thinking
[ -z "$(t show-options -qv -t winbr2 @git_branch)" ]
check "ai-state: clears @git_branch when the pane is not in a repo" "$?"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
