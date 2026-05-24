#!/usr/bin/env bash
# Claude Code statusline — Codex-parity segments with visual bars.
# Reads the statusLine JSON payload on stdin and writes one line.
#
# Segments (left to right):
#   model + effort · cwd · git branch · ctx [bar] N% · 5h [bar] N% · 7d [bar] N%
# Bars use 1/8-step block characters for sub-cell precision and tint
# green / yellow / red as utilization climbs.

set -u

input="$(cat)"

q() { jq -r "$1 // empty" <<<"$input" 2>/dev/null; }

model=$(q '.model.display_name')
effort=$(q '.effort.level')
cwd=$(q '.workspace.current_dir')
ctx_pct=$(q '.context_window.used_percentage')
five_h=$(q '.rate_limits.five_hour.used_percentage')
seven_d=$(q '.rate_limits.seven_day.used_percentage')
worktree_branch=$(q '.worktree.branch')

RESET=$'\e[0m'
DIM=$'\e[2m'
BLUE=$'\e[38;5;33m'
VIOLET=$'\e[38;5;61m'
GREEN=$'\e[38;5;64m'
YELLOW=$'\e[38;5;136m'
RED=$'\e[38;5;160m'

round_pct() {
  awk -v x="${1:-0}" 'BEGIN { if (x=="") x=0; printf "%d", x + 0.5 }'
}

# bar PCT [WIDTH=8] — render a fixed-width progress bar with eighth-step fill.
bar() {
  local pct=${1:-0} width=${2:-8}
  local clamped eighths full remainder empty color
  clamped=$(awk -v p="${pct:-0}" 'BEGIN {
    if (p == "") p = 0
    if (p < 0) p = 0
    if (p > 100) p = 100
    print p
  }')
  eighths=$(awk -v p="$clamped" -v w="$width" 'BEGIN {
    printf "%d", (p / 100.0) * w * 8 + 0.5
  }')
  full=$((eighths / 8))
  remainder=$((eighths % 8))
  if [ "$remainder" -gt 0 ]; then
    empty=$((width - full - 1))
  else
    empty=$((width - full))
  fi

  local partials=("" "▏" "▎" "▍" "▌" "▋" "▊" "▉")
  local pct_int
  pct_int=$(round_pct "$clamped")
  if [ "$pct_int" -ge 80 ]; then
    color=$RED
  elif [ "$pct_int" -ge 50 ]; then
    color=$YELLOW
  else
    color=$GREEN
  fi

  local fill_str=""
  local i
  for ((i = 0; i < full; i++)); do fill_str+="█"; done
  [ "$remainder" -gt 0 ] && fill_str+="${partials[$remainder]}"
  local empty_str=""
  for ((i = 0; i < empty; i++)); do empty_str+=" "; done

  printf '%s▕%s%s%s%s%s▏%s' \
    "$DIM" "$RESET" "$color" "$fill_str" "$DIM" "$empty_str" "$RESET"
}

home_short="${cwd/#$HOME/\~}"

branch="$worktree_branch"
if [ -z "$branch" ] && [ -n "$cwd" ] && [ -d "$cwd" ]; then
  branch=$(git -C "$cwd" branch --show-current 2>/dev/null)
fi

SEP="${DIM} · ${RESET}"
parts=()

if [ -n "$model" ]; then
  if [ -n "$effort" ]; then
    parts+=("${model} ${DIM}${effort}${RESET}")
  else
    parts+=("$model")
  fi
fi

[ -n "$home_short" ] && parts+=("${BLUE}${home_short}${RESET}")
[ -n "$branch" ] && parts+=("${VIOLET}${branch}${RESET}")

if [ -n "$ctx_pct" ]; then
  parts+=("${DIM}ctx${RESET} $(bar "$ctx_pct" 8) $(round_pct "$ctx_pct")%")
fi
if [ -n "$five_h" ]; then
  parts+=("${DIM}5h${RESET} $(bar "$five_h" 8) $(round_pct "$five_h")%")
fi
if [ -n "$seven_d" ]; then
  parts+=("${DIM}7d${RESET} $(bar "$seven_d" 8) $(round_pct "$seven_d")%")
fi

out=""
for i in "${!parts[@]}"; do
  if [ "$i" -eq 0 ]; then
    out="${parts[$i]}"
  else
    out+="${SEP}${parts[$i]}"
  fi
done

printf '%s' "$out"
