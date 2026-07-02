#!/usr/bin/env bash
# Auto-name the session from the first user prompt, once per session.
# Wired to the UserPromptSubmit hook. Reads the hook JSON from stdin and emits
# hookSpecificOutput.sessionTitle, which has the same effect as /rename and
# shows the name on the prompt bar.

input=$(cat)

session_id=$(printf '%s' "$input" | jq -r '.session_id // ""' 2>/dev/null)
prompt=$(printf '%s' "$input" | jq -r '.prompt // ""' 2>/dev/null)

# Nothing to name from.
if [ -z "$prompt" ]; then
  exit 0
fi

# Only name once per session, tracked by a marker file keyed on session id, so
# later prompts don't keep overwriting the title.
marker_dir="$HOME/.claude/.session-autoname"
marker="$marker_dir/${session_id:-unknown}"
if [ -n "$session_id" ] && [ -f "$marker" ]; then
  exit 0
fi

# Derive a short title: first line, collapse whitespace, trim to 50 chars.
title=$(printf '%s' "$prompt" | tr '\n' ' ' | sed -E 's/[[:space:]]+/ /g; s/^ //; s/ $//' | cut -c1-50 | sed -E 's/ *$//')

if [ -z "$title" ]; then
  exit 0
fi

# Mark this session as named.
if [ -n "$session_id" ]; then
  mkdir -p "$marker_dir"
  : > "$marker"
fi

jq -cn --arg t "$title" '{hookSpecificOutput: {hookEventName: "UserPromptSubmit", sessionTitle: $t}}'
