#!/bin/sh
input=$(cat)

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

# Which subscription the session is on. Every account runs this one statusline
# out of ~/.claude, so the account cannot come from where the script lives, and
# CLAUDE_CONFIG_DIR is unset on the default one; the transcript sits under the
# config dir actually in use, so it answers for all four.
transcript=$(echo "$input" | python3 -c "import sys,json; print(json.load(sys.stdin).get('transcript_path',''))")
account=$(TRANSCRIPT="$transcript" python3 -c "
import os, re
transcript = os.environ['TRANSCRIPT']
config_dir = transcript.split('/projects/')[0] if '/projects/' in transcript else ''
config_dir = config_dir or os.path.expanduser(os.environ.get('CLAUDE_CONFIG_DIR') or '~/.claude')
name = os.path.basename(config_dir.rstrip('/'))
match = re.fullmatch(r'\.?claude(\d*)', name)
print('c' + (match.group(1) or '1') if match else name)
")

CLAUDE_DIR="$HOME/.claude"
TRACKING_DIR="$CLAUDE_DIR/cost-tracking"
mkdir -p "$TRACKING_DIR"

refresh_if_stale() {
  cache=$1; shift
  if [ ! -f "$cache" ] || [ -n "$(find "$cache" -mmin +1 2>/dev/null)" ]; then
    touch "$cache"
    nohup "$@" </dev/null >/dev/null 2>&1 &
  fi
}

# Claude Code's cost.total_cost_usd is per CLI process, not per conversation: it
# does not reset on /clear or /new; only session_id rotates.
session_id=$(echo "$input" | python3 -c "import sys,json; print(json.load(sys.stdin).get('session_id',''))")
if [ -n "$session_id" ]; then
  BASELINE_DIR="$TRACKING_DIR/session-baselines"
  mkdir -p "$BASELINE_DIR"
  baseline_file="$BASELINE_DIR/$session_id"
  if [ ! -f "$baseline_file" ]; then
    printf '%s' "$session_cost" > "$baseline_file"
    find "$BASELINE_DIR" -type f -mtime +7 -delete 2>/dev/null
  fi
  baseline=$(cat "$baseline_file" 2>/dev/null)
  session_cost=$(python3 -c "print(max(0.0, float('$session_cost') - float('$baseline' or 0)))")
fi

CCUSAGE_REFRESH="$CLAUDE_DIR/ccusage-refresh.sh"
if [ -x "$CCUSAGE_REFRESH" ]; then
  MONTHLY_BUDGET=1500
  if [ -f "$CLAUDE_DIR/monthly-budget" ]; then
    MONTHLY_BUDGET=$(cat "$CLAUDE_DIR/monthly-budget" | tr -d '[:space:]')
  fi

  DAILY_BUDGET=$(python3 -c "import calendar,datetime; d=datetime.date.today(); print(round($MONTHLY_BUDGET / calendar.monthrange(d.year, d.month)[1], 2))" 2>/dev/null || echo 50)

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

fmt_cost() {
  python3 -c "print('%.2f' % float('${1}'))"
}

session_cost_fmt=$(fmt_cost "$session_cost")

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

# One colour per account, so which subscription a window is on reads at a
# glance rather than by spelling out the label.
case $account in
  c1) account_color=34 ;;
  c2) account_color=36 ;;
  c3) account_color=33 ;;
  c4) account_color=32 ;;
  c5) account_color=31 ;;
  c6) account_color=35 ;;
  *) account_color=37 ;;
esac
printf "\033[01;%sm%s\033[00m | " "$account_color" "$account"
printf "\033[01;35m%s\033[00m" "$model"

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

# Claude Code's own footer shows a PR only for a session it linked one to
# itself, so a resumed session, or a branch whose PR was opened outside it, gets
# nothing there; this looks the PR up by branch instead. --state all keeps it
# showing once merged or closed.
pr_state="" pr_number="" pr_url="" pr_label=""
if [ -n "$git_branch" ] && command -v gh >/dev/null 2>&1; then
  PR_CACHE_DIR="$CLAUDE_DIR/pr-cache"
  pr_cache="$PR_CACHE_DIR/$(printf '%s' "$repo_root/$git_branch" | tr -c 'A-Za-z0-9._-' '_')"
  if [ ! -f "$pr_cache" ]; then
    mkdir -p "$PR_CACHE_DIR"
    find "$PR_CACHE_DIR" -type f -mtime +7 -delete 2>/dev/null
  fi
  refresh_if_stale "$pr_cache" sh -c '
    cd "$1" && gh pr list --state all --head "$2" --limit 1 --json number,state,isDraft,url \
      --jq ".[0] // empty | (if .isDraft then \"draft\" else (.state | ascii_downcase) end) + \" \" + (.number | tostring) + \" \" + .url" \
      > "$3.tmp" && mv -f "$3.tmp" "$3" || rm -f "$3.tmp"
  ' _ "$workspace_dir" "$git_branch" "$pr_cache"

  [ -f "$pr_cache" ] && read -r pr_state pr_number pr_url < "$pr_cache"
  if [ -n "$pr_number" ]; then
    case $pr_state in
      open) pr_color='01;32' ;;
      draft) pr_color=90 ;;
      merged) pr_color='01;35' ;;
      *) pr_color='01;31' ;;
    esac
    pr_label="#$pr_number"
    [ "$pr_state" = open ] || pr_label="$pr_label $pr_state"
    pr_text=$pr_label
    if [ -n "$pr_url" ]; then
      # OSC 8: ESC ] 8 ; ; <url> ST <text> ESC ] 8 ; ; ST, with ESC \ as ST.
      # $pr_label stays plain text for the herdr token below.
      pr_text=$(printf '\033]8;;%s\033\\%s\033]8;;\033\\' "$pr_url" "$pr_label")
    fi
    printf " \033[%sm %s\033[00m" "$pr_color" "$pr_text"
  fi
fi

# herdr has no repo, branch or PR token for agent rows, so they go out as pane
# metadata. A token's color is fixed in herdr/config.toml, so the PR is sent as
# one of pr_open, pr_draft, pr_merged or pr_closed, each colored there to match
# the statusline. herdr strips escape bytes from metadata, so the PR cannot be a
# hyperlink; prefix+p opens it instead.
if [ -n "$HERDR_PANE_ID" ]; then
  herdr_bin=${HERDR_BIN_PATH:-herdr}
  # herdr cuts a row at the sidebar's width and cannot wrap. It saves the width
  # to session.json next to the socket. Claude Code writes an ai-title transcript
  # line when it titles a session and a custom-title line for /rename or --name.
  herdr_session=${HERDR_SOCKET_PATH:+${HERDR_SOCKET_PATH%/*}/session.json}
  : "${herdr_session:=$HOME/.config/herdr/session.json}"
  # `herdr agent list` returns agents in workspace, tab, pane order, the
  # sidebar's "spaces" sort; focus_agent (cmd+1..9) reaches only the first nine.
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
    title_rows=$(tail -c 262144 "$transcript" | HERDR_SESSION_FILE="$herdr_session" python3 -c "
import json, os, sys, textwrap
width = 26
state_dot_and_padding = 4
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
rows = textwrap.wrap(title, max(10, width - state_dot_and_padding), initial_indent='  ', max_lines=3, placeholder='…')
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
  case $pr_state in
    open | draft | merged) pr_token=pr_$pr_state ;;
    *) pr_token=pr_closed ;;
  esac
  for state in open draft merged closed; do
    if [ -n "$pr_label" ] && [ "pr_$state" = "$pr_token" ]; then
      set -- "$@" --token "pr_$state= $pr_label"
    else
      set -- "$@" --clear-token "pr_$state"
    fi
  done
  nohup "$herdr_bin" pane report-metadata "$HERDR_PANE_ID" --source claude-statusline "$@" \
    </dev/null >/dev/null 2>&1 &
fi

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

printf " | \033[01;36msession:\$%s\033[00m" "$session_cost_fmt"

if [ -x "$CCUSAGE_REFRESH" ]; then
  daily_cost_fmt=$(fmt_cost "$daily_cost")
  monthly_cost_fmt=$(fmt_cost "$monthly_cost")

  daily_budget_int=$(python3 -c "print(int(float('$DAILY_BUDGET')))")
  daily_pct=$(python3 -c "print(float('$daily_cost') / float('$DAILY_BUDGET') * 100)")
  daily_bar=$(build_bar "$daily_pct")
  printf " | \$%s/\$%s today %s" "$daily_cost_fmt" "$daily_budget_int" "$daily_bar"

  monthly_pct=$(python3 -c "print(float('$monthly_cost') / float('$MONTHLY_BUDGET') * 100)")
  monthly_bar=$(build_bar "$monthly_pct")
  printf " | \$%s/\$%s mo %s" "$monthly_cost_fmt" "$MONTHLY_BUDGET" "$monthly_bar"
fi

if [ -n "$used_pct" ]; then
  ctx_bar=$(build_bar "$used_pct")
  pct_int=$(python3 -c "print(int(float('$used_pct')))")
  printf " | ctx:%s%% %s" "$pct_int" "$ctx_bar"
fi
