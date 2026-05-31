#!/usr/bin/env bash
set -euo pipefail

default_windows="agents vim"

dir=""
name="${TMUX_SETUP_NAME:-}"
target_session=""
target_window=""
windows_text="${TMUX_SETUP_WINDOWS:-$default_windows}"
attach=1
dry_run=0

usage() {
  cat <<'EOF'
Usage: .tmux-setup-sessions.sh [options] [directory]

Ensure agents and vim windows exist for one directory

Two modes:
  In-place (--session NAME): add any missing windows to an existing session,
    rooted at the directory. Does not create a new session or switch clients.
    This is what the `prefix + T` tmux binding uses on the current session.
  Standalone (default): create (or re-use) a session named after the directory's
    basename, add the windows, then attach/switch to it.

The directory defaults to the current directory.

Options:
  --session NAME       In-place: set up windows in this existing session
  --window ID          In-place: claim this window for the first name (rename it
                       instead of leaving it alongside the new windows)
  --name NAME          Standalone: session name (default: basename of directory)
  --windows LIST       Space- or comma-separated window names
  --no-attach          Standalone: create the session/windows but do not attach
  --dry-run            Print tmux commands without running them
  -h, --help           Show this help

Environment:
  TMUX_SETUP_NAME      Same as --name
  TMUX_SETUP_WINDOWS   Same as --windows
  TMUX_SETUP_SOCKET    Use a named tmux socket, useful for testing
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --session)
      target_session="${2:?missing value for --session}"
      shift 2
      ;;
    --window)
      target_window="${2:?missing value for --window}"
      shift 2
      ;;
    --name)
      name="${2:?missing value for --name}"
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
  dir="$1"
fi

dir="${dir:-$PWD}"

case "$dir" in
  "~")   dir="$HOME" ;;
  "~/"*) dir="$HOME/${dir#"~/"}" ;;
esac

if ! dir="$(cd "$dir" 2>/dev/null && pwd)"; then
  printf 'no such directory: %s\n' "$dir" >&2
  exit 1
fi

windows_text="${windows_text//,/ }"
read -r -a windows <<< "$windows_text"

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

ensure_window() {
  local session="$1"
  local window="$2"

  [ -n "$window" ] || return 0
  if window_exists "$session" "$window"; then
    return 0
  fi

  run_tmux new-window -d -t "$session:" -n "$window" -c "$dir"
}

is_target_window() {
  local candidate="$1" window
  for window in "${windows[@]}"; do
    [ "$candidate" = "$window" ] && return 0
  done
  return 1
}

# In-place mode: set up the windows in the current session and stay put. The
# window the user is in is claimed for the first name (e.g. renamed to "agents")
# rather than left alongside, so a fresh one-window session becomes exactly the
# requested set.
if [ -n "$target_session" ]; then
  if ! session_exists "$target_session"; then
    printf 'session does not exist: %s\n' "$target_session" >&2
    exit 1
  fi

  first="${windows[0]}"
  if [ -n "$first" ] && ! window_exists "$target_session" "$first"; then
    curname=""
    if [ -n "$target_window" ]; then
      curname="$(capture_tmux display-message -p -t "$target_window" '#{window_name}' 2>/dev/null || true)"
    fi

    # Only reuse the current window if it isn't already one of the other
    # requested windows; otherwise create the first one fresh.
    if [ -n "$target_window" ] && ! is_target_window "$curname"; then
      run_tmux rename-window -t "$target_window" "$first"
    else
      ensure_window "$target_session" "$first"
    fi
  fi

  for window in "${windows[@]:1}"; do
    ensure_window "$target_session" "$window"
  done

  exit 0
fi

# Standalone mode: create (or re-use) a session named after the directory.
# tmux forbids "." and ":" in session names; fold them to "_".
session="${name:-$(basename "$dir")}"
session="${session//[.:]/_}"

if [ -z "$session" ]; then
  printf 'could not derive a session name from %s\n' "$dir" >&2
  exit 2
fi

if ! session_exists "$session"; then
  run_tmux new-session -d -s "$session" -n "${windows[0]}" -c "$dir"
fi

for window in "${windows[@]:1}"; do
  ensure_window "$session" "$window"
done

if [ "$attach" -eq 1 ]; then
  if [ -n "${TMUX:-}" ]; then
    run_tmux switch-client -t "$session"
  else
    run_tmux attach-session -t "$session"
  fi
fi
