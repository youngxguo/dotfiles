#!/usr/bin/env bash
# Shared helpers for the tmux companion scripts. Source it, don't execute it:
#   source "$HOME/.tmux-lib.sh"
# install.py symlinks this to ~/.tmux-lib.sh via its `.tmux-*.sh` glob, alongside
# the scripts that source it.
#
# The status-line script (~/.tmux-ai-idle.sh) is Python and can't source this, so
# it reimplements tmux_resolve_bin / tmux_recreate_socket_dir and keeps its own
# copy of TMUX_AGENT_COMMANDS. Keep that copy in sync with the list below.

# Canonical set of agent CLIs we treat specially (idle detection, split mirror).
TMUX_AGENT_COMMANDS=(claude codex agent cursor-agent)

# Resolve the tmux binary. On Linux, prefer the exact binary backing the running
# server (exposed at /proc/<pid>/exe) so we never drive the server with a since-
# replaced binary, e.g. after a snap update. macOS has no /proc, so fall back to
# whatever tmux is on PATH.
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

# Recreate the tmux socket's parent directory. Snap updates can wipe the private
# /tmp that holds the socket, leaving the server unable to re-bind.
tmux_recreate_socket_dir() {
  local socket_dir
  [ -n "${TMUX:-}" ] || return 0
  socket_dir="$(dirname "${TMUX%%,*}")"
  [ -d "$socket_dir" ] || mkdir -p "$socket_dir" 2>/dev/null || true
}

# Print the current git branch for a directory, or nothing if it isn't a repo.
tmux_git_branch() {
  ( cd "$1" 2>/dev/null && git rev-parse --abbrev-ref HEAD 2>/dev/null ) || true
}

# Return 0 if the given command (path or basename) is one of our agent CLIs.
tmux_is_agent_command() {
  local candidate="${1##*/}" name
  for name in "${TMUX_AGENT_COMMANDS[@]}"; do
    [ "$candidate" = "$name" ] && return 0
  done
  return 1
}
