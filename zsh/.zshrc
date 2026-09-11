export ZSH="$HOME/.oh-my-zsh"

export PATH="$HOME/.local/bin:$PATH"
export PATH="/usr/local/go/bin:$PATH"

# brew shellenv also sets MANPATH and INFOPATH, so run it even where brew is
# already on PATH.
for _brew in /opt/homebrew/bin/brew /usr/local/bin/brew \
             /home/linuxbrew/.linuxbrew/bin/brew "$HOME/.linuxbrew/bin/brew"; do
  if [ -x "$_brew" ]; then
    eval "$("$_brew" shellenv)"
    break
  fi
done
unset _brew

ZSH_THEME=""
ZSH_AUTOSUGGEST_HIGHLIGHT_STYLE="fg=10"

# zsh-syntax-highlighting wraps ZLE widgets last, so it must load before
# zsh-autosuggestions.
plugins=(
  zsh-syntax-highlighting
  zsh-autosuggestions
)

source $ZSH/oh-my-zsh.sh

command -v starship >/dev/null 2>&1 && eval "$(starship init zsh)"

HISTSIZE=100000
SAVEHIST=100000
setopt HIST_IGNORE_ALL_DUPS
setopt HIST_IGNORE_SPACE
setopt HIST_REDUCE_BLANKS
setopt HIST_VERIFY
setopt SHARE_HISTORY
setopt EXTENDED_HISTORY

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
    # fzf re-sets every zsh option on load; on zsh 5.9 that includes the
    # unchangeable zle and monitor, which print "can't change option" to stderr.
  } 2> >(grep -v "can't change option:" >&2)
  _dotfiles_fzf_rc=1
fi
if (( ${+commands[fd]} )); then
  export FZF_DEFAULT_COMMAND='fd --type f --hidden --follow --exclude .git'
  export FZF_CTRL_T_COMMAND="$FZF_DEFAULT_COMMAND"
  export FZF_ALT_C_COMMAND='fd --type d --hidden --follow --exclude .git'
fi

command -v direnv >/dev/null 2>&1 && eval "$(direnv hook zsh)"

export EDITOR=nvim
export VISUAL=nvim

export GIT_EDITOR=nvim

alias gs="git status"
alias gd="git diff"
alias gdc="git diff --cached"
alias gco="git checkout"
alias gcm='git switch "$(git show-ref --verify --quiet refs/heads/main && printf main || printf master)"'
alias gl="git log"
alias gp="git push"
alias gpu="git pull"
alias grm='git pull --rebase origin "$(git show-ref --verify --quiet refs/remotes/origin/main && printf main || printf master)"'
alias gcomm="git commit -m"
alias gcom="git commit"
alias gcoma="git commit --amend"
alias vim="nvim"
alias cx="codex"
alias gcb="git checkout -b"

alias c="claude --chrome"
alias c2="CLAUDE_CONFIG_DIR=~/.claude2 claude --chrome"
alias c3="CLAUDE_CONFIG_DIR=~/.claude3 claude --chrome"
alias c4="CLAUDE_CONFIG_DIR=~/.claude4 claude --chrome"
alias c5="CLAUDE_CONFIG_DIR=~/.claude5 claude --chrome"
alias c6="CLAUDE_CONFIG_DIR=~/.claude6 claude --chrome"

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

  _tmux_clear_ai_state() {
    emulate -L zsh
    [[ -n $(command tmux show-options -pqv -t "$TMUX_PANE" @ai_state 2>/dev/null) ]] || return
    command ~/.tmux-ai-state.sh clear 2>/dev/null
  }
  add-zsh-hook precmd _tmux_clear_ai_state
fi

# --no-use skips nvm's default-version resolution, the slow (~600ms) part of
# sourcing it.
export NVM_DIR="$HOME/.nvm"
if [ -s "$NVM_DIR/nvm.sh" ]; then
  \. "$NVM_DIR/nvm.sh" --no-use
  [ -s "$NVM_DIR/bash_completion" ] && \. "$NVM_DIR/bash_completion"
  [ -r "$NVM_DIR/alias/default" ] &&
    export PATH="$NVM_DIR/versions/node/v$(<"$NVM_DIR/alias/default")/bin:$PATH"
fi

[ -r "$HOME/.personal-plugins/.shell_config" ] && source "$HOME/.personal-plugins/.shell_config"
