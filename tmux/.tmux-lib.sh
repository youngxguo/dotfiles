#!/usr/bin/env bash
TMUX_AGENT_COMMANDS=(claude codex agent cursor-agent)

_palette_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$_palette_dir/.tmux-palette.sh"

TMUX_ESC=$'\033'
TMUX_RESET="${TMUX_ESC}[0m"
TMUX_FG_BASE01_ANSI="${TMUX_ESC}[38;2;$(tmux_hex_to_rgb "$TMUX_PALETTE_BASE01")m"
TMUX_BOLD_FG_BASE1_ANSI="${TMUX_ESC}[1;38;2;$(tmux_hex_to_rgb "$TMUX_PALETTE_BASE1")m"
TMUX_FG_BASE00_ANSI="${TMUX_ESC}[38;2;$(tmux_hex_to_rgb "$TMUX_PALETTE_BASE00")m"
TMUX_YELLOW_ANSI="${TMUX_ESC}[38;2;$(tmux_hex_to_rgb "$TMUX_PALETTE_YELLOW")m"
TMUX_BLUE_FG_ANSI="${TMUX_ESC}[38;2;$(tmux_hex_to_rgb "$TMUX_PALETTE_BLUE")m"
TMUX_SELECT_ANSI="${TMUX_ESC}[1;38;2;$(tmux_hex_to_rgb "$TMUX_PALETTE_BASE3");48;2;$(tmux_hex_to_rgb "$TMUX_PALETTE_BLUE")m"
TMUX_AI_IDLE_ANSI="${TMUX_ESC}[1;38;2;$(tmux_hex_to_rgb "$TMUX_PALETTE_BASE3");48;2;$(tmux_hex_to_rgb "$TMUX_PALETTE_RED")m"
TMUX_AI_THINK_ANSI="${TMUX_ESC}[1;38;2;$(tmux_hex_to_rgb "$TMUX_PALETTE_BASE03");48;2;$(tmux_hex_to_rgb "$TMUX_PALETTE_YELLOW")m"

# A snap update replaces the tmux binary under a running server; on Linux
# /proc/<pid>/exe still points at the one the server runs. macOS has no /proc.
tmux_resolve_bin() {
  local pid exe
  if [ -n "${TMUX:-}" ]; then
    pid="$(printf '%s' "$TMUX" | cut -d, -f2)"
    if [ -n "$pid" ] && [ -e "/proc/$pid/exe" ]; then
      exe="$(readlink -f "/proc/$pid/exe" 2>/dev/null)"
      if [ -n "$exe" ]; then
        printf '%s\n' "$exe"
        return
      fi
    fi
  fi
  command -v tmux 2>/dev/null || printf 'tmux\n'
}

# Snap updates can wipe the private /tmp that holds the socket.
tmux_recreate_socket_dir() {
  local socket_dir
  [ -n "${TMUX:-}" ] || return 0
  socket_dir="$(dirname "${TMUX%%,*}")"
  [ -d "$socket_dir" ] || mkdir -p "$socket_dir" 2>/dev/null || true
}

tmux_git_branch() {
  ( cd "$1" 2>/dev/null && git rev-parse --abbrev-ref HEAD 2>/dev/null ) || true
}

tmux_is_agent_command() {
  local candidate="${1##*/}" name
  for name in "${TMUX_AGENT_COMMANDS[@]}"; do
    [ "$candidate" = "$name" ] && return 0
  done
  return 1
}

tmux_launch_agent() {
  local target="$1" cmd="${2:-}"
  shift 2
  [ -n "$cmd" ] || cmd=claude
  "$@" send-keys -t "$target" "$cmd" Enter
}
