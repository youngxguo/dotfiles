#!/usr/bin/env bash
# Shared helpers for the tmux companion scripts. Source it, don't execute it:
#   source "$HOME/.tmux-lib.sh"
# install.py symlinks this to ~/.tmux-lib.sh via its `.tmux-*.sh` glob, alongside
# the scripts that source it.
#
# The status-line script (~/.tmux-ai-idle.sh) is Python and can't source this, so
# it reimplements tmux_resolve_bin / tmux_recreate_socket_dir and keeps its own
# copy of TMUX_AGENT_COMMANDS. Keep that copy in sync with the list below; the
# pre-push hook fails if the two agent-command lists drift.

# Canonical set of agent CLIs we treat specially (idle detection, split mirror).
TMUX_AGENT_COMMANDS=(claude codex agent cursor-agent)

# AI idle/thinking badge colors (Solarized: base2 on red, base03 on gold). Bash
# scripts source these; ~/.tmux-ai-idle.sh (Python) can't source bash.
TMUX_AI_IDLE_ANSI=$'\033'"[1;38;2;238;232;213;48;2;220;50;47m"
TMUX_AI_THINK_ANSI=$'\033'"[1;38;2;0;43;54;48;2;255;215;0m"
TMUX_AI_RESET=$'\033'"[0m"

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

# Launch an agent CLI in a tmux target by typing it at the target's shell prompt
# (not running it as the pane command), so quitting the agent drops back to a
# shell. Shared by the split-mirror (.tmux-agent-split.sh) and the worktree
# launcher (.tmux-worktree.sh) so "how we start an agent" — and the default of
# claude — lives in one place.
#
# The tmux invocation is taken as the trailing arguments rather than a single
# word, so a socket-qualified command (tmux -L sock) passes through intact.
# Usage: tmux_launch_agent <target> <command|""> <tmux-bin> [tmux-args...]
#   command "" selects the default (claude).
tmux_launch_agent() {
  local target="$1" cmd="${2:-}"
  shift 2
  [ -n "$cmd" ] || cmd=claude
  "$@" send-keys -t "$target" "$cmd" Enter
}

# Print the git ref a new worktree branch should fork from: the repo's default
# branch at its LOCAL tip. We fork from the local branch (not origin/...) so a
# new worktree includes commits pushed straight to the default branch but not
# yet re-fetched — the common case in personal repos that push directly to
# master. origin/HEAD is consulted only to learn the default branch's *name*;
# the tip is always taken locally. Falls back to a local main/master, then to
# the remote-tracking tip if no local branch exists. Prints nothing and returns
# 1 if none is found. Usage: <repo-dir>
tmux_default_branch() {
  local dir="$1" head ref defname=""
  ref="$(git -C "$dir" symbolic-ref -q refs/remotes/origin/HEAD 2>/dev/null)"
  [ -n "$ref" ] && defname="${ref##*/}"
  for head in ${defname:+"$defname"} main master; do
    if git -C "$dir" show-ref --verify -q "refs/heads/$head"; then
      printf '%s\n' "$head"
      return 0
    fi
  done
  if [ -n "$defname" ] && git -C "$dir" show-ref --verify -q "refs/remotes/origin/$defname"; then
    printf '%s\n' "origin/$defname"
    return 0
  fi
  return 1
}
