#!/bin/sh
# Claude Code statusline: model | git branch + PR | prompt timer | session cost |
# daily/monthly budget bars | context bar. Reads the statusLine JSON payload on
# stdin and writes one line. install.py symlinks this to
# ~/.claude/statusline-command.sh; claude/settings.json points statusLine here.
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

# Run "$@" in the background when cache file $1 is missing or over a minute
# old. Renders only ever read the cache, so they never wait on the network.
# Touching the cache first acts as a lease: this script runs every second and a
# refresh takes longer than that, so without it renders would stack up refreshes.
refresh_if_stale() {
  cache=$1; shift
  if [ ! -f "$cache" ] || [ -n "$(find "$cache" -mmin +1 2>/dev/null)" ]; then
    touch "$cache"
    nohup "$@" </dev/null >/dev/null 2>&1 &
  fi
}

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

  # Read daily/monthly totals from the ccusage cache.
  CACHE="$TRACKING_DIR/ccusage-cache.json"
  read daily_cost monthly_cost <<EOF
$(python3 -c "
import json
try:
    d = json.load(open('$CACHE'))
    print(d.get('daily', 0.0), d.get('monthly', 0.0))
except Exception:
    print(0.0, 0.0)
")
EOF
  refresh_if_stale "$CACHE" "$CCUSAGE_REFRESH"
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

# Git branch of the workspace, only when the cwd is inside a repo. One rev-parse
# yields the repo root (the PR cache key) and the branch; detached HEAD prints
# the literal "HEAD", which is swapped for the short SHA. The glyph is
# nf-dev-git_branch (U+E725), the one neovim's statusline puts before the branch.
workspace_dir=$(echo "$input" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('workspace',{}).get('current_dir') or d.get('cwd') or '')")
if [ -n "$workspace_dir" ] && [ -d "$workspace_dir" ]; then
  { read -r repo_root; read -r git_branch; read -r git_dir; read -r git_common_dir; } <<EOF
$(git -C "$workspace_dir" rev-parse --show-toplevel --abbrev-ref HEAD --git-dir --git-common-dir 2>/dev/null)
EOF
  if [ "$git_branch" = HEAD ]; then
    git_branch=$(git -C "$workspace_dir" rev-parse --short HEAD 2>/dev/null)
  fi
  if [ -n "$git_branch" ]; then
    printf " | \033[01;32m %s\033[00m" "$git_branch"
  fi
fi

# Inside herdr, hand the repo and branch to the agent sidebar: herdr/config.toml
# shows them as the $repo and $branch tokens on the pane's third row, and herdr
# has no built-in tokens for either on agent rows. The repo is the main
# checkout's name even from a linked worktree (the common git dir's parent), so
# worktrees of hsys all read "hsys". The branch carries the same nerd-font
# glyph as the statusline (herdr's metadata sanitizer keeps glyphs, but strips
# escape bytes). Backgrounded so the render never waits on the socket, and
# re-sent every refresh so a restarted server picks it up.
if [ -n "$HERDR_PANE_ID" ]; then
  herdr_bin=${HERDR_BIN_PATH:-herdr}
  # The session title, wrapped into $title1..3 so the sidebar shows it whole:
  # herdr cuts a row at the sidebar's width and cannot wrap. Read from the
  # transcript's last title line, so a restarted server gets it back too.
  # Claude Code writes an ai-title line when it generates a title from the
  # first prompt (and again on accepting a plan), and a custom-title line for
  # /rename or --name; the newest of either wins, as it does in Claude Code's
  # own picker. The wrap width follows the sidebar: herdr saves its width to
  # session.json next to the socket, and the rows lose 4 columns to the state
  # dot and padding.
  transcript=$(echo "$input" | python3 -c "import sys,json; print(json.load(sys.stdin).get('transcript_path',''))")
  herdr_session=${HERDR_SOCKET_PATH:+${HERDR_SOCKET_PATH%/*}/session.json}
  : "${herdr_session:=$HOME/.config/herdr/session.json}"
  # This agent's position in the sidebar, which is the key focus_agent
  # (cmd+1..9 in herdr/config.toml) switches to it with. `herdr agent list`
  # returns agents in workspace, tab, pane order, which is what the sidebar's
  # "spaces" sort shows; only the first nine have a key.
  agent_num=$("$herdr_bin" agent list 2>/dev/null | python3 -c "
import json, os, sys
try:
    agents = json.load(sys.stdin)['result']['agents']
except (ValueError, KeyError, TypeError):
    agents = []
for i, agent in enumerate(agents, 1):
    if agent.get('pane_id') == os.environ.get('HERDR_PANE_ID') and i <= 9:
        print(i)
")
  if [ -n "$agent_num" ]; then
    set -- --token "num=$agent_num"
  else
    set -- --clear-token num
  fi
  if [ -n "$transcript" ] && [ -f "$transcript" ]; then
    # The first row also carries the number and a space, hence the indent.
    title_rows=$(tail -c 262144 "$transcript" | HERDR_SESSION_FILE="$herdr_session" python3 -c "
import json, os, sys, textwrap
width = 26
try:
    width = int(json.load(open(os.environ['HERDR_SESSION_FILE'])).get('sidebar_width') or width)
except (OSError, ValueError, TypeError):
    pass
title = ''
for line in sys.stdin:
    if '\"custom-title\"' not in line and '\"ai-title\"' not in line:
        continue
    try:
        entry = json.loads(line)
    except ValueError:
        continue
    if entry.get('type') == 'custom-title':
        title = entry.get('customTitle') or title
    elif entry.get('type') == 'ai-title':
        title = entry.get('aiTitle') or title
rows = textwrap.wrap(title, max(10, width - 4), initial_indent='  ', max_lines=3, placeholder='…')
for part in rows:
    print(part.strip())
")
    n=0
    while IFS= read -r chunk; do
      [ -n "$chunk" ] || continue
      n=$((n + 1))
      set -- "$@" --token "title$n=$chunk"
    done <<EOF
$title_rows
EOF
    while [ "$n" -lt 3 ]; do
      n=$((n + 1))
      set -- "$@" --clear-token "title$n"
    done
  fi
  if [ -n "$git_branch" ]; then
    if [ "$git_dir" = "$git_common_dir" ]; then
      repo_name=${repo_root##*/}
    else
      repo_dir=${git_common_dir%/.git}
      repo_name=${repo_dir##*/}
    fi
    set -- "$@" --token "repo=📁 $repo_name" --token "branch= $git_branch"
  else
    set -- "$@" --clear-token repo --clear-token branch
  fi
  nohup "$herdr_bin" pane report-metadata "$HERDR_PANE_ID" --source claude-statusline "$@" \
    </dev/null >/dev/null 2>&1 &
fi

# Pull request for the branch, colored by state: open green, draft grey, merged
# magenta, closed red. Looked up with `gh pr list --state all` so the PR keeps
# showing after it merges or closes instead of vanishing. gh takes ~0.5s, so the
# refresher runs in the background and writes a pre-rendered "<state> <number>"
# line (empty when the branch has no PR) to a per-repo+branch cache file.
if [ -n "$git_branch" ] && command -v gh >/dev/null 2>&1; then
  PR_CACHE_DIR="$CLAUDE_DIR/pr-cache"
  pr_cache="$PR_CACHE_DIR/$(printf '%s' "$repo_root/$git_branch" | tr -c 'A-Za-z0-9._-' '_')"
  if [ ! -f "$pr_cache" ]; then
    mkdir -p "$PR_CACHE_DIR"
    # Prune caches untouched for 7+ days so the dir stays small.
    find "$PR_CACHE_DIR" -type f -mtime +7 -delete 2>/dev/null
  fi
  refresh_if_stale "$pr_cache" sh -c '
    cd "$1" && gh pr list --state all --head "$2" --limit 1 --json number,state,isDraft \
      --jq ".[0] // empty | (if .isDraft then \"draft\" else (.state | ascii_downcase) end) + \" \" + (.number | tostring)" \
      > "$3.tmp" && mv -f "$3.tmp" "$3" || rm -f "$3.tmp"
  ' _ "$workspace_dir" "$git_branch" "$pr_cache"

  pr_state="" pr_number=""
  [ -f "$pr_cache" ] && read -r pr_state pr_number < "$pr_cache"
  if [ -n "$pr_number" ]; then
    case $pr_state in
      open) pr_color='01;32' ;;
      draft) pr_color=90 ;;
      merged) pr_color='01;35' ;;
      *) pr_color='01;31' ;;
    esac
    pr_label="#$pr_number"
    [ "$pr_state" = open ] || pr_label="$pr_label $pr_state"
    printf " \033[%sm %s\033[00m" "$pr_color" "$pr_label"
  fi
fi

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
