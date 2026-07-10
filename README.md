# dotfiles

my mac/linux configs — zsh, tmux, neovim, ghostty, vscode, btop, plus shared claude/codex instructions.

## setup

```sh
git clone <this-repo>
cd dotfiles
python3 install.py
```

optional: `APPLY_LOGIN_SHELL=1 python3 install.py` if you want zsh as login shell.

installs deps (brew or linux pkg mgr), oh-my-zsh, symlinks into `$HOME`, lazy.nvim bootstrap. safe to re-run; existing targets get backed up first.

Codex uses repo-managed `codex/AGENTS.md`; local config is seeded once from
`codex/config.example.toml`, and the installer merges the tmux AI-state lifecycle
hooks from `codex/ai-state-hooks.json` into `~/.codex/hooks.json`.

## cleanup

```sh
python3 install.py --cleanup          # remove repo symlinks only
python3 install.py --cleanup --dry-run
```

doesn't uninstall packages or delete your backups.

## hacking this repo

```sh
git config core.hooksPath .githooks
```

pre-push runs `install.py --verify-idempotent`. skip once: `SKIP_DOTFILES_PREPUSH=1 git push`

## tmux cheatsheet

prefix: **ctrl-space** (not ctrl-b)

| key | what |
|-----|------|
| `c` | new window (current dir) |
| `C` | new session (asks name) |
| `W` | new git worktree + agents/vim session |
| `t` | add agents / vim windows in current session |
| `X` | kill session (confirm) |
| `b` | toggle left sidebar |
| `s` | session picker (git branches, ai idle badges) |
| `e` | scratch shell popup |
| `g` | git TUI popup (lazygit / gitui / tig) |
| cmd-`1`–`9` | jump to session by sidebar number |

sidebar stuck? `~/.tmux-sidebar.sh reset-all`

commit message notes for agents live in `codex/COMMIT_RULES.md`
