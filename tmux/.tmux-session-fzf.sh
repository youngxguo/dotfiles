#!/usr/bin/env bash
# fzf-driven tmux session picker, an alternative to choose-tree (prefix s).
# Shows the AI idle (!) / thinking (💭) badge and per-session git branch with
# the same Solarized colors as the choose-tree binding, previews the active
# pane of the highlighted session, and lets 1-9 jump straight to a session.
# Meant to run inside a `display-popup -E` overlay; see `bind-key S` in
# .tmux.conf. AI-state and @git_branch session options are populated by
# ~/.tmux-ai-idle.sh and ~/.tmux-update-branches.sh respectively.
set -euo pipefail

# Emit one line per session as: <name>\t<ANSI-styled display column>.
# tmux prints raw fields; awk paints them so colors survive the pipe (fzf
# --ansi renders them). NR is the stable 1-based index shown as the hotkey.
list() {
  tmux list-sessions -F \
'#{session_name}'$'\t''#{?#{@session_ai_idle},1,0}'$'\t''#{?#{@session_ai_thinking},1,0}'$'\t''#{@git_branch}'$'\t''#{?session_attached,1,0}' \
  | awk -F'\t' '
    {
      e   = sprintf("%c", 27); r = e "[0m";
      num = e "[38;2;88;110;117m" NR "." r;                  # base01
      # For AI sessions the state background spans the badge AND the session
      # name (with a trailing pad), so the whole entry is filled, not just the
      # icon. Idle: base2 on red. Thinking: base03 on gold. Others: plain.
      if ($2 == "1")      seg = e "[1;38;2;238;232;213;48;2;220;50;47m ! " $1 " " r;
      else if ($3 == "1") seg = e "[1;38;2;0;43;54;48;2;255;215;0m 💭 " $1 " " r;
      else                seg = "    " $1;
      disp = num " " seg;
      if ($4 != "") disp = disp " " e "[38;2;181;137;0m[" $4 "]" r;   # yellow branch
      if ($5 == "1") disp = disp " " e "[38;2;38;139;210m*" r;        # blue attached
      print $1 "\t" disp;
    }'
}

# fzf reloads via this path after a kill, skipping the branch refresh.
case "${1:-}" in
  --list) list; exit 0 ;;
esac

~/.tmux-update-branches.sh 2>/dev/null || true

# 1-9 jump to and switch that session. Bare digits mean they can't be typed
# into the fuzzy filter (letters still work); swap to alt-N below to change.
hotkeys=()
for n in 1 2 3 4 5 6 7 8 9; do hotkeys+=(--bind "$n:pos($n)+accept"); done

sel=$(
  list | fzf --ansi \
    --delimiter='\t' --with-nth=2 \
    --reverse --no-sort --cycle \
    --preview 'tmux capture-pane -ep -t {1}' \
    --preview-window=right:55%:wrap \
    --header 'enter/1-9: switch  ·  ctrl-x: kill session' \
    --bind "ctrl-x:execute-silent(tmux kill-session -t {1})+reload($0 --list)" \
    "${hotkeys[@]}" \
  | cut -f1
) || exit 0

[ -n "${sel:-}" ] && tmux switch-client -t "$sel"
