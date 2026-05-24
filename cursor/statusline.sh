#!/usr/bin/env bash
# Cursor CLI status line (stdin: StatusLinePayload JSON). Mirrors Codex TUI cues:
# model (+ params) · cwd · git branch, then context as a horizontal bar.

set -euo pipefail

if ! command -v jq >/dev/null 2>&1; then
  printf '%b\n' '\033[33m⚠ jq not found — install jq for Cursor status line\033[0m'
  exit 1
fi

payload="$(cat)"
[[ -z "$payload" ]] && exit 1

c_reset=$'\033[0m'
c_dim=$'\033[90m'
c_dir=$'\033[33m'
c_branch=$'\033[32m'
c_sep=$'\033[36m'
c_hi=$'\033[97m'

model="$(echo "$payload" | jq -r '.model.display_name // .model.id // "model"')"
param="$(echo "$payload" | jq -r '.model.param_summary // empty')"
cwd="$(echo "$payload" | jq -r '.workspace.current_dir // .cwd // ""')"
term_w="$(echo "$payload" | jq -r '.render_width_chars // 80')"
pct_raw="$(echo "$payload" | jq -r '.context_window.used_percentage // 0')"
tok="$(echo "$payload" | jq -r '.context_window.total_input_tokens // empty')"
worktree="$(echo "$payload" | jq -r '.worktree.name // empty')"
sess="$(echo "$payload" | jq -r '.session_name // empty')"
max_mode="$(echo "$payload" | jq -r '.model.max_mode // false')"
vim_mode="$(echo "$payload" | jq -r '.vim.mode // empty')'

pct="$(printf '%.0f\n' "$pct_raw" 2>/dev/null || echo 0)"
if ! [[ "$pct" =~ ^[0-9]+$ ]]; then pct=0; fi
if (( pct > 100 )); then pct=100; fi

short_home() {
  local p="$1"
  [[ -z "$p" ]] && { echo ""; return; }
  if [[ -n "${HOME:-}" && "$p" == "$HOME" ]]; then echo "~"; return; fi
  if [[ -n "${HOME:-}" && "$p" == "$HOME"/* ]]; then echo "~/${p#$HOME/}"; return; fi
  echo "$p"
}

SHORT_PATH="$(short_home "$cwd")"

branch=""
if [[ -n "$cwd" ]] && git -C "$cwd" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  branch="$(git -C "$cwd" branch --show-current 2>/dev/null || true)"
  if [[ -z "$branch" ]]; then
    h="$(git -C "$cwd" rev-parse --short HEAD 2>/dev/null || true)"
    [[ -n "$h" ]] && branch="detached@${h}"
  fi
fi

sep="${c_dim} · ${c_reset}"

model_bits="${c_hi}${model}${c_reset}"
[[ -n "$param" ]] && model_bits+=" ${param}"
[[ "$max_mode" == "true" ]] && model_bits+=" ${c_sep}MAX${c_reset}"
[[ -n "$worktree" ]] && model_bits+=" ${c_dim}@${worktree}${c_reset}"
[[ -n "$sess" ]] && model_bits+=" ${c_dim}(${sess})${c_reset}"
[[ -n "$vim_mode" ]] && model_bits+=" ${c_sep}${vim_mode}${c_reset}"

line1="$model_bits"
[[ -n "$SHORT_PATH" ]] && line1+="${sep}${c_dir}${SHORT_PATH}${c_reset}"
[[ -n "$branch" ]] && line1+="${sep}${c_branch}${branch}${c_reset}"

bar_w=$((term_w / 5))
(( bar_w < 14 )) && bar_w=14
(( bar_w > 36 )) && bar_w=36
filled=$(( pct * bar_w / 100))
(( filled > bar_w )) && filled=$bar_w
empty=$(( bar_w - filled ))
bar=""
if (( filled > 0 )); then
  pad="$(printf '%*s' "$filled" '')"
  bar+="${pad// /█}"
fi
if (( empty > 0 )); then
  pad="$(printf '%*s' "$empty" '')"
  bar+="${pad// /░}"
fi

bar_color=$'\033[32m'
if (( pct >= 85 )); then
  bar_color=$'\033[31m'
elif (( pct >= 55 )); then
  bar_color=$'\033[33m'
fi

tok_suffix=""
if [[ -n "$tok" ]] && [[ "$tok" != "null" ]]; then
  if (( tok >= 1000 )); then
    tok_suffix=" ${c_dim}(~$((tok / 1000))k in)${c_reset}"
  else
    tok_suffix=" ${c_dim}(~${tok} tok in)${c_reset}"
  fi
fi

line2="${c_dim}ctx${c_reset} ${bar_color}${bar}${c_reset} ${pct}%"

printf '%s\n' "$line1"
printf '%s%s%s\n' "$line2" "$tok_suffix" "$c_reset"
