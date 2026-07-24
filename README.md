# dotfiles

my mac/linux configs — zsh, tmux, herdr, neovim, ghostty, vscode, btop, plus shared claude/codex instructions.

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
hooks from `codex/ai-state-hooks.json` into `~/.codex/hooks.json`. Custom pets in
`codex/pets/` are linked into `~/.codex/pets/`; Piggy comes from
[codex-pet.com](https://www.codex-pet.com/pets/piggy).

Personal agent skills live in `skills/` and are linked into Codex and Claude Code by the installer.

## cleanup

```sh
python3 install.py --cleanup          # remove repo symlinks only
python3 install.py --cleanup --dry-run
```

doesn't uninstall packages or delete your backups.

## contributing

Make changes on a branch and open a pull request into `master`. GitHub CI runs
the installer, tmux, shell, and agent-skill checks; local checks are optional.

## tmux / herdr cheatsheet

prefix: **ctrl-space** (not ctrl-b)

Herdr workspaces replace tmux sessions; tabs replace tmux windows. The prefix
and main navigation stay the same:

| key | tmux | herdr |
|-----|------|-------|
| `c` | new window (current dir) | new tab in the current directory |
| `,` | — | rename current tab |
| `C` | new session (asks name) | new workspace (asks name) |
| `W` | new git worktree + repo-prefixed Codex / Neovim session | — |
| `D` | delete current worktree session + local branch (confirm) | — |
| `t` | add agents / vim windows in current session | — |
| `X` | kill session (confirm) | — |
| `b` | toggle left sidebar | — |
| `s` | session picker (git branches, ai idle badges) | workspace picker |
| `e` | scratch shell popup | — |
| `g` | git TUI popup (lazygit / gitui / tig) | — |
| shift-left / shift-right | — | previous / next tab |
| `\` or `%` | — | split pane right |
| `-` or `"` | — | split pane down |
| ctrl-`h`/`j`/`k`/`l` | — | focus split left / down / up / right |
| cmd-`1`–`9` | jump to session by sidebar number | jump to workspace by sidebar number |

tmux sidebar stuck? `~/.tmux-sidebar.sh reset-all`
