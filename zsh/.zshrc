# zsh
export ZSH="$HOME/.oh-my-zsh"

# prompt: starship replaces the oh-my-zsh theme (config in starship/starship.toml)
ZSH_THEME=""
ZSH_AUTOSUGGEST_HIGHLIGHT_STYLE="fg=10"

# basic plugins
# zsh-syntax-highlighting wraps ZLE widgets last, so it must load before
# zsh-autosuggestions — keep autosuggestions at the end of the list.
plugins=(
  git
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

# scm breeze
[ -s "$HOME/.scm_breeze/scm_breeze.sh" ] && source "$HOME/.scm_breeze/scm_breeze.sh"

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
alias gcomm="git commit -m"
alias gcom="git commit"
alias gcoma="git commit --amend"
alias vim="nvim"
alias tmsu="$HOME/.tmux-setup-sessions.sh"
alias tmux-setup="$HOME/.tmux-setup-sessions.sh"
alias fep='docker port "$(cat "$(git rev-parse --show-toplevel)/.dev_docker_name")" 8080/tcp | sed -n "s/.*://p" | head -n1'

export PATH="$HOME/.local/bin:$PATH"

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
