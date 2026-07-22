#!/usr/bin/env bash
# Tests for .tmux-ai-status.sh: render idle AI sessions as compact status-right
# numbers, using the same live pane @ai_state aggregation as the sidebar.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
script="$here/.tmux-ai-status.sh"
real_tmux="$(command -v tmux)"

work="$(mktemp -d)"
SOCKET="ai_status_test_$$"
shim_dir="$work/bin"
mkdir -p "$shim_dir"
cat >"$shim_dir/tmux" <<EOF
#!/bin/sh
exec "$real_tmux" -L "$SOCKET" "\$@"
EOF
chmod +x "$shim_dir/tmux"
export PATH="$shim_dir:$PATH"
export HOME="$work/home"
unset TMUX TMUX_PANE 2>/dev/null || true
mkdir -p "$HOME"
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

strip_styles() { sed -E 's/#\[[^]]*\]//g; s/^ +//; s/ +$//'; }
status_raw() { "$script"; }
status_numbers() { "$script" | strip_styles; }

t new-session -d -s s1 -x 120 -y 30
t new-session -d -s s2 -x 120 -y 30
t new-session -d -s s3 -x 120 -y 30

[ -z "$(status_numbers)" ]
check "status: no idle panes renders nothing" "$?"

one_pane="$(t list-panes -t s1 -F '#{pane_id}' | head -1)"
three_pane="$(t list-panes -t s3 -F '#{pane_id}' | head -1)"
t set-option -p -t "$one_pane" @ai_state idle
t set-option -p -t "$three_pane" @ai_state idle

[ "$(status_numbers)" = "1 | 3" ]
check "status: idle sessions render as separated list-order numbers" "$?"

two_pane="$(t list-panes -t s2 -F '#{pane_id}' | head -1)"
t set-option -p -t "$two_pane" @ai_state thinking
[ "$(status_numbers)" = "1 | 2 | 3" ]
check "status: thinking sessions render alongside idle sessions" "$?"
status_raw | grep -q 'bg=#b58900'
check "status: thinking sessions use the yellow block style" "$?"

three_pane_2="$(t split-window -hdf -t s3 -P -F '#{pane_id}')"
t set-option -p -t "$three_pane_2" @ai_state thinking
[ "$(status_numbers)" = "1 | 2 | 3" ]
check "status: thinking outranks idle within a session" "$?"

t kill-pane -t "$one_pane"
[ "$(status_numbers)" = "1 | 2" ]
check "status: killed idle pane self-heals out of the indicator" "$?"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
