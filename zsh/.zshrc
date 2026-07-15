# zsh
export ZSH="$HOME/.oh-my-zsh"

export PATH="$HOME/.local/bin:$PATH"
export PATH="/usr/local/go/bin:$PATH"

# prompt: starship replaces the oh-my-zsh theme (config in starship/starship.toml)
ZSH_THEME=""
ZSH_AUTOSUGGEST_HIGHLIGHT_STYLE="fg=10"

# basic plugins
# zsh-syntax-highlighting wraps ZLE widgets last, so it must load before
# zsh-autosuggestions — keep autosuggestions at the end of the list.
plugins=(
  zsh-syntax-highlighting
  zsh-autosuggestions
)

source $ZSH/oh-my-zsh.sh

# starship prompt (overrides the oh-my-zsh theme)
command -v starship >/dev/null 2>&1 && eval "$(starship init zsh)"

# history
HISTSIZE=100000
SAVEHIST=100000
setopt HIST_IGNORE_ALL_DUPS   # keep only the most recent copy of a command
setopt HIST_IGNORE_SPACE      # skip commands typed with a leading space
setopt HIST_REDUCE_BLANKS     # collapse superfluous whitespace before saving
setopt HIST_VERIFY            # show expanded history line instead of running it
setopt SHARE_HISTORY          # live-share history across running shells
setopt EXTENDED_HISTORY       # record timestamps

# fzf — Ctrl+R / Ctrl+T / Esc-c (repeat `source ~/.zshrc`: no-op)
if [[ -z ${_dotfiles_fzf_rc-} && -o zle ]] && (( ${+commands[fzf]} )); then
  () {
    emulate -L zsh
    local fzhome="$commands[fzf]:A"
    local fzf_shell="$fzhome:h/../shell"
    if [[ -f ~/.fzf.zsh ]]; then
      source ~/.fzf.zsh
    elif [[ -r $fzf_shell/key-bindings.zsh ]]; then
      [[ -r $fzf_shell/completion.zsh ]] && source "$fzf_shell/completion.zsh"
      source "$fzf_shell/key-bindings.zsh"
    else
      source <(command fzf --zsh 2>/dev/null)
    fi
    # fzf's option save/restore re-sets every zsh option on load; on zsh 5.9
    # that includes the unchangeable `zle`/`monitor`, which print a harmless
    # "can't change option" to stderr. Drop just those lines; keep real errors.
  } 2> >(grep -v "can't change option:" >&2)
  _dotfiles_fzf_rc=1
fi
# fzf: use fd (faster, respects .gitignore) for Ctrl+T and Esc-c
if (( ${+commands[fd]} )); then
  export FZF_DEFAULT_COMMAND='fd --type f --hidden --follow --exclude .git'
  export FZF_CTRL_T_COMMAND="$FZF_DEFAULT_COMMAND"
  export FZF_ALT_C_COMMAND='fd --type d --hidden --follow --exclude .git'
fi

command -v direnv >/dev/null 2>&1 && eval "$(direnv hook zsh)"

# git
export GIT_EDITOR=nvim

# git aliases
alias gs="git status"
alias gd="git diff"
alias gdc="git diff --cached"
alias gco="git checkout"
alias gcm='git switch "$(git show-ref --verify --quiet refs/heads/main && printf main || printf master)"'
alias gl="git log"
alias gp="git push"
alias gcomm="git commit -m"
alias gcom="git commit"
alias gcoma="git commit --amend"
alias vim="nvim"
alias cx="codex"

# tmux: push the current git branch into the session's @git_branch option so the
# sessions sidebar and status line read it instead of forking git on a timer.
# Only fires when the branch changes (cheap next to starship's own per-prompt git
# check); chpwd covers `cd`, precmd catches an in-place `git checkout`.
if [[ -n ${TMUX_PANE:-} ]]; then
  autoload -Uz add-zsh-hook
  _tmux_push_branch() {
    emulate -L zsh
    local branch
    branch=$(command git rev-parse --abbrev-ref HEAD 2>/dev/null)
    [[ $branch == ${_tmux_last_branch-__unset__} ]] && return
    _tmux_last_branch=$branch
    if [[ -n $branch ]]; then
      command tmux set-option -qt "$TMUX_PANE" @git_branch "$branch"
    else
      command tmux set-option -qut "$TMUX_PANE" @git_branch
    fi
    command tmux run-shell -b "~/.tmux-sidebar.sh refresh" 2>/dev/null
  }
  add-zsh-hook chpwd _tmux_push_branch
  add-zsh-hook precmd _tmux_push_branch

  # When a shell prompt reappears in this pane, any agent that was running here is
  # gone, so retire its AI badge. This is the self-heal for agents whose own hooks
  # can't (Codex has no exit hook) or didn't fire (a crash/kill mid-turn): the
  # pane's @ai_state would otherwise sit there idle forever. The show-options guard
  # keeps the normal case — a shell that never ran an agent — to a single cheap
  # query with no extra work; only a leftover state pays for the clear + redraw.
  _tmux_clear_ai_state() {
    emulate -L zsh
    [[ -n $(command tmux show-options -pqv -t "$TMUX_PANE" @ai_state 2>/dev/null) ]] || return
    command ~/.tmux-ai-state.sh clear 2>/dev/null
  }
  add-zsh-hook precmd _tmux_clear_ai_state
fi

# nvm — lazy-loaded to keep shell startup fast. The default node version stays
# on PATH immediately (so node/npm work in scripts and subshells); the full nvm
# machinery loads on first use of nvm/node/npm/npx.
export NVM_DIR="$HOME/.nvm"
if [ -d "$NVM_DIR" ]; then
  if [ -r "$NVM_DIR/alias/default" ]; then
    _nvm_default="$(<"$NVM_DIR/alias/default")"
    _nvm_default_bin=("$NVM_DIR"/versions/node/v${_nvm_default}*/bin(Nn[-1]))
    [ -n "$_nvm_default_bin" ] && export PATH="$_nvm_default_bin:$PATH"
    unset _nvm_default _nvm_default_bin
  fi
  _nvm_lazy() {
    unset -f nvm node npm npx 2>/dev/null
    [ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
    [ -s "$NVM_DIR/bash_completion" ] && \. "$NVM_DIR/bash_completion"
  }
  for _cmd in nvm node npm npx; do
    eval "${_cmd}() { _nvm_lazy; ${_cmd} \"\$@\"; }"
  done
  unset _cmd
fi

# personal aliases/functions/secrets live outside the dotfiles repo
[ -r "$HOME/.personal-plugins/.shell_config" ] && source "$HOME/.personal-plugins/.shell_config"
