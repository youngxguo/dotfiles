#!/usr/bin/env bash
set -euo pipefail

default_windows="agents vim git adp"

root="${TMUX_SETUP_ROOT:-$HOME}"
specs_text="${TMUX_SETUP_SPECS:-}"
sessions_text="${TMUX_SETUP_SESSIONS:-}"
windows_text="${TMUX_SETUP_WINDOWS:-$default_windows}"
attach=1
dry_run=0

usage() {
  cat <<'EOF'
Usage: .tmux-setup-sessions.sh [options] [session[=directory] ...]

Create or update tmux work sessions. By default this creates:
  applied3=$HOME/applied3
  applied4=$HOME/applied4
  applied5=$HOME/applied5
  applied6=$HOME/applied6
  1earn=$HOME/applied3
  2eview=$HOME/applied3
  core-stack=$HOME/core-stack
  dotfiles=$HOME/Documents/dotfiles
  skills=$HOME/claude-code-shared

Each session gets these windows:
  agents vim git adp

Options:
  --root DIR           Parent directory for session worktrees (default: $HOME)
  --specs LIST         Space- or comma-separated session[=directory] specs
  --sessions LIST      Space- or comma-separated session names under --root
  --windows LIST       Space- or comma-separated window names
  --no-attach          Create sessions/windows but do not attach or switch
  --dry-run            Print tmux commands without running them
  -h, --help           Show this help

Environment:
  TMUX_SETUP_ROOT      Same as --root
  TMUX_SETUP_SPECS     Same as --specs
  TMUX_SETUP_SESSIONS  Same as --sessions
  TMUX_SETUP_WINDOWS   Same as --windows
  TMUX_SETUP_SOCKET    Use a named tmux socket, useful for testing
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --root)
      root="${2:?missing value for --root}"
      shift 2
      ;;
    --specs)
      specs_text="${2:?missing value for --specs}"
      shift 2
      ;;
    --sessions)
      sessions_text="${2:?missing value for --sessions}"
      shift 2
      ;;
    --windows)
      windows_text="${2:?missing value for --windows}"
      shift 2
      ;;
    --no-attach)
      attach=0
      shift
      ;;
    --dry-run)
      dry_run=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --)
      shift
      break
      ;;
    -*)
      printf 'unknown option: %s\n\n' "$1" >&2
      usage >&2
      exit 2
      ;;
    *)
      break
      ;;
  esac
done

if [ "$#" -gt 0 ]; then
  specs_text="$*"
elif [ -z "$specs_text" ] && [ -n "$sessions_text" ]; then
  specs_text="$sessions_text"
elif [ -z "$specs_text" ]; then
  specs_text="applied3=$root/applied3 applied4=$root/applied4 applied5=$root/applied5 applied6=$root/applied6 1earn=$root/applied3 2eview=$root/applied3 core-stack=$root/core-stack dotfiles=$root/Documents/dotfiles skills=$root/claude-code-shared"
fi

specs_text="${specs_text//,/ }"
windows_text="${windows_text//,/ }"
read -r -a specs <<< "$specs_text"
read -r -a windows <<< "$windows_text"

if [ "${#specs[@]}" -eq 0 ] || [ -z "${specs[0]}" ]; then
  printf 'no session specs requested\n' >&2
  exit 2
fi

if [ "${#windows[@]}" -eq 0 ] || [ -z "${windows[0]}" ]; then
  printf 'no windows requested\n' >&2
  exit 2
fi

tmux_cmd=(tmux)
if [ -n "${TMUX_SETUP_SOCKET:-}" ]; then
  tmux_cmd=(tmux -L "$TMUX_SETUP_SOCKET")
fi

quote_cmd() {
  printf '%q ' "${tmux_cmd[@]}" "$@"
  printf '\n'
}

run_tmux() {
  if [ "$dry_run" -eq 1 ]; then
    quote_cmd "$@"
    return 0
  fi

  "${tmux_cmd[@]}" "$@"
}

capture_tmux() {
  "${tmux_cmd[@]}" "$@"
}

session_exists() {
  capture_tmux has-session -t "$1" 2>/dev/null
}

window_exists() {
  local session="$1"
  local window="$2"

  capture_tmux list-windows -t "$session:" -F '#{window_name}' 2>/dev/null | grep -Fxq "$window"
}

workdir_for_session() {
  local session="$1"

  if [[ "$session" = /* ]]; then
    printf '%s\n' "$session"
  else
    printf '%s/%s\n' "$root" "$session"
  fi
}

normalize_workdir() {
  local dir="$1"

  case "$dir" in
    "~")
      printf '%s\n' "$HOME"
      ;;
    "~/"*)
      printf '%s/%s\n' "$HOME" "${dir#"~/"}"
      ;;
    /*)
      printf '%s\n' "$dir"
      ;;
    *)
      printf '%s/%s\n' "$root" "$dir"
      ;;
  esac
}

parse_spec() {
  local spec="$1"
  local session
  local dir

  if [[ "$spec" == *=* ]]; then
    session="${spec%%=*}"
    dir="${spec#*=}"
  else
    session="$spec"
    dir="$(workdir_for_session "$session")"
  fi

  if [ -z "$session" ] || [ -z "$dir" ]; then
    return 1
  fi

  printf '%s\t%s\n' "$session" "$(normalize_workdir "$dir")"
}

created_sessions=()
available_sessions=()

for spec in "${specs[@]}"; do
  [ -n "$spec" ] || continue

  if ! parsed="$(parse_spec "$spec")"; then
    printf 'skipping invalid session spec: %s\n' "$spec" >&2
    continue
  fi

  session="${parsed%%$'\t'*}"
  dir="${parsed#*$'\t'}"

  if [ ! -d "$dir" ]; then
    printf 'skipping %s: %s does not exist\n' "$session" "$dir" >&2
    continue
  fi

  if ! session_exists "$session"; then
    run_tmux new-session -d -s "$session" -n "${windows[0]}" -c "$dir"
    created_sessions+=("$session")
  fi
  available_sessions+=("$session")

  for window in "${windows[@]:1}"; do
    [ -n "$window" ] || continue

    if window_exists "$session" "$window"; then
      continue
    fi

    run_tmux new-window -d -t "$session:" -n "$window" -c "$dir"
  done
done

if [ "${#available_sessions[@]}" -eq 0 ]; then
  printf 'no requested sessions exist\n' >&2
  exit 1
elif [ "${#created_sessions[@]}" -eq 0 ]; then
  first_session="${available_sessions[0]}"
else
  first_session="${created_sessions[0]}"
fi

if [ "$dry_run" -eq 1 ]; then
  if [ "$attach" -eq 1 ]; then
    if [ -n "${TMUX:-}" ]; then
      run_tmux switch-client -t "$first_session"
    else
      run_tmux attach-session -t "$first_session"
    fi
  fi
  exit 0
fi

if [ "$attach" -eq 1 ]; then
  if [ -n "${TMUX:-}" ]; then
    run_tmux switch-client -t "$first_session"
  else
    run_tmux attach-session -t "$first_session"
  fi
fi
