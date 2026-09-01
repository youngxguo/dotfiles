#!/bin/sh
# Claude Code statusline: model | prompt timer | session cost | daily/monthly
# budget bars | context bar. Reads the statusLine JSON payload on stdin and
# writes one line. install.py symlinks this to ~/.claude/statusline-command.sh;
# claude/settings.json points statusLine here.
input=$(cat)

# Extract fields from JSON input using python3
session_cost=$(echo "$input" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('cost', {}).get('total_cost_usd', 0) or 0)")
used_pct=$(echo "$input" | python3 -c "import sys,json; d=json.load(sys.stdin); v=d.get('context_window',{}).get('used_percentage'); print(v if v is not None else '')")
model=$(echo "$input" | python3 -c "
import sys, json
d = json.load(sys.stdin)
m = d.get('model', {})
if isinstance(m, dict):
    display = m.get('display_name', '') or m.get('id', 'unknown')
else:
    display = str(m)
print(display)
")

# Paths for persistent cost tracking
CLAUDE_DIR="$HOME/.claude"
TRACKING_DIR="$CLAUDE_DIR/cost-tracking"
mkdir -p "$TRACKING_DIR"

# Claude Code's cost.total_cost_usd is scoped to the CLI process, not the
# conversation, so it does NOT reset on /clear or /new (the process keeps
# running; only the session_id rotates). Derive a per-session cost by
# snapshotting the process total the first time each new session_id is seen,
# then displaying the delta. On /new the fresh session_id snapshots the current
# total, so the displayed figure drops to ~0 and climbs with the new session.
session_id=$(echo "$input" | python3 -c "import sys,json; print(json.load(sys.stdin).get('session_id',''))")
if [ -n "$session_id" ]; then
  BASELINE_DIR="$TRACKING_DIR/session-baselines"
  mkdir -p "$BASELINE_DIR"
  baseline_file="$BASELINE_DIR/$session_id"
  if [ ! -f "$baseline_file" ]; then
    printf '%s' "$session_cost" > "$baseline_file"
    # Prune baselines untouched for 7+ days so the dir stays small.
    find "$BASELINE_DIR" -type f -mtime +7 -delete 2>/dev/null
  fi
  baseline=$(cat "$baseline_file" 2>/dev/null)
  session_cost=$(python3 -c "print(max(0.0, float('$session_cost') - float('$baseline' or 0)))")
fi

# Daily/monthly budget bars are fed by the ccusage cache refresher. It is
# machine-local, so skip those bars where it is absent.
CCUSAGE_REFRESH="$CLAUDE_DIR/ccusage-refresh.sh"
if [ -x "$CCUSAGE_REFRESH" ]; then
  # Read monthly budget from config file, default 1500
  MONTHLY_BUDGET=1500
  if [ -f "$CLAUDE_DIR/monthly-budget" ]; then
    MONTHLY_BUDGET=$(cat "$CLAUDE_DIR/monthly-budget" | tr -d '[:space:]')
  fi

  # Derive daily budget from monthly budget / days in month
  DAILY_BUDGET=$(python3 -c "import calendar,datetime; d=datetime.date.today(); print(round($MONTHLY_BUDGET / calendar.monthrange(d.year, d.month)[1], 2))" 2>/dev/null || echo 50)

  # Read daily/monthly totals from ccusage cache. Kick off a background refresh
  # if the cache is stale or missing — statusline renders stay fast.
  CACHE="$TRACKING_DIR/ccusage-cache.json"
  REFRESH_TTL=60
  read daily_cost monthly_cost cache_age <<EOF
$(python3 -c "
import json, time, os
try:
    d = json.load(open('$CACHE'))
    age = int(time.time() - d.get('updated_at', 0))
    print(d.get('daily', 0.0), d.get('monthly', 0.0), age)
except Exception:
    print(0.0, 0.0, 999999)
")
EOF

  if [ "$cache_age" -gt "$REFRESH_TTL" ]; then
    nohup "$CCUSAGE_REFRESH" </dev/null >/dev/null 2>&1 &
  fi
fi

# Format a dollar amount to exactly 2 decimal places
fmt_cost() {
  python3 -c "print('%.2f' % float('${1}'))"
}

session_cost_fmt=$(fmt_cost "$session_cost")

# Build a colored 5-char bar with overflow indicator
build_bar() {
  pct=$1
  python3 -c "
pct = float('$pct')
width = 5
filled = min(int(pct / 100 * width + 0.5), width)
empty = width - filled
bar = '▓' * filled + '░' * empty
overflow = '+' if pct > 100 else ' '
if pct >= 90:
    color = '\033[31m'
elif pct >= 70:
    color = '\033[33m'
else:
    color = '\033[32m'
reset = '\033[0m'
print(color + bar + reset + overflow, end='')
"
}

# Model in bright magenta
printf "\033[01;35m%s\033[00m" "$model"

# Elapsed time on the in-flight prompt, stamped by hooks/prompt-timer.sh on
# UserPromptSubmit and removed on Stop, so it only shows while a turn runs.
# Ticks because statusLine.refreshInterval=1 re-runs this script every second.
timer_file="$CLAUDE_DIR/prompt-timer/$session_id"
if [ -n "$session_id" ] && [ -f "$timer_file" ]; then
  elapsed_fmt=$(python3 -c "
import time
try:
    s = int(time.time()) - int(open('$timer_file').read().strip())
except (OSError, ValueError):
    s = -1
if s >= 0:
    h, rem = divmod(s, 3600)
    m, sec = divmod(rem, 60)
    print('%dh%02dm' % (h, m) if h else '%dm%02ds' % (m, sec) if m else '%ds' % sec)
")
  if [ -n "$elapsed_fmt" ]; then
    printf " | \033[01;33m⏱ %s\033[00m" "$elapsed_fmt"
  fi
fi

# Session cost in bright cyan
printf " | \033[01;36msession:\$%s\033[00m" "$session_cost_fmt"

if [ -x "$CCUSAGE_REFRESH" ]; then
  daily_cost_fmt=$(fmt_cost "$daily_cost")
  monthly_cost_fmt=$(fmt_cost "$monthly_cost")

  # Daily cost with bar
  daily_budget_int=$(python3 -c "print(int(float('$DAILY_BUDGET')))")
  daily_pct=$(python3 -c "print(float('$daily_cost') / float('$DAILY_BUDGET') * 100)")
  daily_bar=$(build_bar "$daily_pct")
  printf " | \$%s/\$%s today %s" "$daily_cost_fmt" "$daily_budget_int" "$daily_bar"

  # Monthly cost with bar
  monthly_pct=$(python3 -c "print(float('$monthly_cost') / float('$MONTHLY_BUDGET') * 100)")
  monthly_bar=$(build_bar "$monthly_pct")
  printf " | \$%s/\$%s mo %s" "$monthly_cost_fmt" "$MONTHLY_BUDGET" "$monthly_bar"
fi

# Context window utilization bar, only shown when data is available
if [ -n "$used_pct" ]; then
  ctx_bar=$(build_bar "$used_pct")
  pct_int=$(python3 -c "print(int(float('$used_pct')))")
  printf " | ctx:%s%% %s" "$pct_int" "$ctx_bar"
fi
