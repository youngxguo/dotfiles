# dotfiles

Personal macOS/Linux dotfiles bootstrap for:
- `zsh`
- `tmux`
- `btop`
- `neovim`
- `ghostty`
- `vscode`
- `claude` / `codex` (shared global instructions)

## Prerequisites
- macOS or Linux
- Admin access (needed if package installation or `chsh` is required)
- macOS only: Xcode command line tools/license accepted (`sudo xcodebuild -license`)
- Internet access for package installs and git clone steps

## Fresh Machine Setup
```sh
git clone <this-repo>
cd dotfiles
python3 install.py
```

Optional: set login shell during install.
```sh
APPLY_LOGIN_SHELL=1 python3 install.py
```

## What Install Does
- Installs missing packages via Homebrew (or Linux package manager fallback: `apt`/`dnf`/`pacman`/`zypper`) for `zsh`, `direnv`, `fzf`, `tmux`, `neovim`, `ripgrep`, `fd`
- Installs `btop` via Homebrew when available, or a verified upstream Linux binary on supported Linux architectures
- Installs Homebrew-managed Neovim helper tools when Homebrew is available: `prettier`, `tree-sitter-cli`, `typescript-language-server`, `basedpyright`, `gh`, `chafa`, `viu`, `mercurial`
- Installs the ESLint language server from npm when `npm` is available
- Installs Oh My Zsh and shell plugins
- Symlinks configs from this repo into `$HOME`
- Applies Starship prompt config (`~/.config/starship.toml`)
- Applies tracked Claude global instructions (`~/.claude/CLAUDE.md`) when `claude/CLAUDE.md` is present
- Applies tracked Codex global instructions (`~/.codex/AGENTS.md`) when `codex/AGENTS.md` is present (in-repo symlink to `claude/CLAUDE.md`, so both tools share one source of truth)
- Applies repo-local Codex CLI config (`~/.codex/config.toml`) when `codex/config.toml` is present
- Bootstraps `lazy.nvim` and runs plugin/tree-sitter sync

The script is designed to be rerunnable and backs up pre-existing target files before replacing them with symlinks.

## Cleanup / Uninstall
Remove the symlinks this repo created, leaving everything else in place:

```sh
python3 install.py --cleanup
```

Preview first without changing anything:

```sh
python3 install.py --cleanup --dry-run
```

A target is removed only when it is a symlink that resolves back into this repo, so real files (and symlinks pointing elsewhere) are left untouched. Installed packages, cloned repos (`oh-my-zsh`), and `*.bak.*` backups are **not** removed. The link set is shared with the install flow (`managed_links()`), so cleanup never drifts from what setup created. Re-running `install.py` restores the links.

## Git Hooks (Recommended)
Enable the repo-managed hooks so `pre-push` runs an install idempotency check:

```sh
git config core.hooksPath .githooks
```

The `pre-push` hook runs:

```sh
python3 install.py --verify-idempotent
```

This uses a temporary `HOME` and skips package/network/bootstrap side effects while verifying the install flow is rerunnable.  
To bypass temporarily:

```sh
SKIP_DOTFILES_PREPUSH=1 git push
```

## Quick Verify
- `zsh --version`
- `tmux -V`
- `nvim --version`
- `nvim --headless "+checkhealth" +qa`
- `python3 install.py --verify-neovim-health`
- Confirm symlinks:
  - `ls -l ~/.zshrc`
  - `ls -l ~/.config/starship.toml`
  - `ls -l ~/.tmux.conf`
  - `ls -l ~/.config/btop/btop.conf`
  - `ls -l ~/.config/nvim`
  - `ls -l ~/.config/ghostty/config`
  - `ls -l ~/Library/Application\\ Support/Code/User/settings.json`
  - `ls -l ~/.claude/CLAUDE.md`
  - `ls -l ~/.codex/AGENTS.md`
  - `ls -l ~/.codex/config.toml` (if using a repo-local Codex config)

## Tmux Session Setup
Press `Ctrl+Space` then `t` to set up `agents`, `vim`, and `git` windows in the **current session**, rooted at the current pane's directory. It stays put — no new session, no client switch. The window you're in is claimed as the first (`agents`), so a fresh one-window session becomes exactly those three. Only missing windows are added, so it's safe to press repeatedly. (This overrides tmux's default `prefix t` clock view.)

The binding calls `~/.tmux-setup-sessions.sh` (see `tmux/.tmux-setup-sessions.sh`) in its in-place mode. You can also run the script directly:

```sh
# In-place: add the windows to an existing session (what the binding uses)
~/.tmux-setup-sessions.sh --session mywork ~/applied3

# Standalone: create (or re-use) a session named after the directory and attach
~/.tmux-setup-sessions.sh ~/applied3
~/.tmux-setup-sessions.sh --name review ~/applied3      # override the session name
~/.tmux-setup-sessions.sh --windows "agents vim git logs"
```

## Tmux Sessions Sidebar
A persistent read-only rail appears on the left of every tmux window. It shows sessions in tmux's list order with visible session numbers, the same AI idle (`!`) / thinking (`💭`) badges, and inline git branch labels used by the picker/status line. Cmd-`1`-`9` follows the numbers printed in the rail.

It's enabled automatically for existing and new windows. Press `Ctrl+Space` then `b` to hide/show it globally via `@sidebar_enabled`; new windows respect that state.

The rail is pinned to 26 columns by default (`SIDEBAR_WIDTH` overrides it). Split/rebalance hooks keep the rail fixed while spreading only the work panes. If it ever looks wrong, run `~/.tmux-sidebar.sh reset-all`.

## Commit Message Rules (Codex/AI)
Commit message guidance for Codex lives in `codex/COMMIT_RULES.md`.
These are style rules only (no Git hook/template enforcement).
