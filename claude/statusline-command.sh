#!/bin/sh

input=$(cat)

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
# effort.level is present only on models that take an effort setting.
thinking=$(echo "$input" | python3 -c "
import sys, json
d = json.load(sys.stdin)
if (d.get('thinking') or {}).get('enabled') is False:
    print('no thinking')
else:
    print((d.get('effort') or {}).get('level') or '')
")

# Which subscription the session is on. Every account runs this one statusline
# out of ~/.claude, so the account cannot come from where the script lives, and
# CLAUDE_CONFIG_DIR is unset on the default one; the transcript sits under the
# config dir actually in use, so it answers for every configured account.
transcript=$(echo "$input" | python3 -c "import sys,json; print(json.load(sys.stdin).get('transcript_path',''))")
# The login email comes from the account's .claude.json: the default account
# keeps that state file beside ~/.claude, every other account keeps it inside
# its config dir.
{ read -r account; read -r account_email; } <<EOF
$(TRANSCRIPT="$transcript" python3 -c "
import json, os, re
transcript = os.environ['TRANSCRIPT']
config_dir = transcript.split('/projects/')[0] if '/projects/' in transcript else ''
config_dir = config_dir or os.path.expanduser(os.environ.get('CLAUDE_CONFIG_DIR') or '~/.claude')
config_dir = os.path.realpath(config_dir)
def cseat_seat_name():
    try:
        import tomllib
        base = os.environ.get('XDG_CONFIG_HOME') or os.path.expanduser('~/.config')
        with open(os.path.join(base, 'cseat', 'config.toml'), 'rb') as f:
            seats = tomllib.load(f).get('seats') or {}
    except (ImportError, OSError, ValueError):
        return ''
    for seat, cfg in seats.items():
        if isinstance(cfg, dict) and cfg.get('dir') and os.path.realpath(os.path.expanduser(cfg['dir'])) == config_dir:
            return seat
    return ''
name = os.path.basename(config_dir.rstrip('/'))
match = re.fullmatch(r'\.?claude(\d*)', name)
print(cseat_seat_name() or ('c' + (match.group(1) or '1') if match else name))
default_dir = os.path.realpath(os.path.expanduser('~/.claude'))
state = os.path.expanduser('~/.claude.json') if config_dir == default_dir else os.path.join(config_dir, '.claude.json')
try:
    email = (json.load(open(state)).get('oauthAccount') or {}).get('emailAddress') or ''
except (OSError, ValueError, AttributeError):
    email = ''
print(email)
")
EOF

CLAUDE_DIR="$HOME/.claude"

session_id=$(echo "$input" | python3 -c "import sys,json; print(json.load(sys.stdin).get('session_id',''))")

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

# A fixed palette, not an account allowlist. Numbered subscriptions cycle through
# seven slots; named ones use FNV-1a.
account_slot=$(ACCOUNT="$account" python3 -c '
import os, re
name = os.environ["ACCOUNT"]
match = re.fullmatch(r"c([0-9]+)", name)
value = 2166136261
for byte in name.encode():
    value = ((value ^ byte) * 16777619) & 0xffffffff
print((int(match.group(1)) - 1 if match else value) % 7 + 1)
')
case $account_slot in
  1) account_color=34 ;;
  2) account_color=36 ;;
  3) account_color=33 ;;
  4) account_color=32 ;;
  5) account_color=31 ;;
  6) account_color=35 ;;
  7) account_color=95 ;;
  *) account_color=33 ;;
esac
printf "\033[01;%sm%s\033[00m" "$account_color" "$account"
[ -n "$account_email" ] && printf " \033[02m%s\033[00m" "$account_email"
printf " | "
printf "\033[01;35m%s\033[00m" "$model"
[ -n "$thinking" ] && printf " \033[35m%s\033[00m" "$thinking"

workspace_dir=$(echo "$input" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('workspace',{}).get('current_dir') or d.get('cwd') or '')")
if [ -n "$workspace_dir" ] && [ -d "$workspace_dir" ]; then
  git_branch=$(git -C "$workspace_dir" rev-parse --abbrev-ref HEAD 2>/dev/null)
  if [ "$git_branch" = HEAD ]; then
    git_branch=$(git -C "$workspace_dir" rev-parse --short HEAD 2>/dev/null)
  fi
  if [ -n "$git_branch" ]; then
    printf " | \033[01;32m %s\033[00m" "$git_branch"
  fi
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

if [ -n "$used_pct" ]; then
  ctx_bar=$(build_bar "$used_pct")
  pct_int=$(python3 -c "print(int(float('$used_pct')))")
  printf " | ctx:%s%% %s" "$pct_int" "$ctx_bar"
fi
