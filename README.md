# dotfiles

```sh
git clone https://github.com/youngxguo/dotfiles.git
cd dotfiles
python3 install.py
```

`install.py` is idempotent and works on macOS and Linux. Rerun it after
pulling to pick up new configs; `--update-plugins` also moves neovim's
plugins forward and rewrites `lazy-lock.json`.

## What is here

| directory  | tool                | how it reaches the machine                                        |
| ---------- | ------------------- | ----------------------------------------------------------------- |
| `zsh/`     | zsh, oh-my-zsh      | symlink                                                           |
| `starship/`| starship prompt     | symlink                                                           |
| `ghostty/` | ghostty terminal    | symlink (config, shaders, themes)                                 |
| `herdr/`   | herdr multiplexer   | symlink (config, auto-title env) plus `herdr plugin link` for `plugins/` |
| `neovim/`  | neovim              | symlink of the whole directory to `~/.config/nvim`                |
| `btop/`    | btop                | symlink                                                           |
| `claude/`  | Claude Code         | symlinks for skills, hooks and statusline; `settings.json` keys merged into every login |
| `pi/`      | pi coding agent     | symlinks for extensions; `settings.json` keys merged into the live file |
| `codex/`   | codex               | symlink for pets; `config.example.toml` copied once, then left alone |
| `agents/`  | shared agent rules  | `global-rules.md` linked into every Claude login and `~/.codex`   |
| `skills/`  | public agent skills | not installed; published for the Skills CLI (`npx skills add`)    |
| `github/`  | repo settings       | `repository_settings.py` applies branch rules to a GitHub repo    |

Three strategies cover every config: a symlink when the tool never writes to
the file, a key merge when it does (Claude and Pi write runtime state next to
the settings), and a one-time template copy when the file is mostly account
state (Codex).

### Claude subscriptions

`install.py` configures `~/.claude`, all existing numbered `~/.claudeN`
directories, and named `~/.claude*` logins containing `.claude.json` (cseat's
normal discovery convention). Set `CLAUDE_CONFIG_DIR` when installing a login
elsewhere. New machines start with only the default account; after adding a
login, rerun the installer to apply the shared rules, skills, and integrations.

Zsh discovers numbered `cN` shortcuts when it starts; open a new shell after
adding a login. Claude and Pi use a fixed subscription color palette in Herdr,
so new labels require no config edits or additional sidebar rows. Colors repeat
across accounts; the label remains the account's identity.

## Checks

```sh
make check        # lint + test, what CI runs
make lint         # pre-commit: ruff, shellcheck, json/toml/yaml
make test-python  # every *_test.py, then install.py --verify-idempotent
make test-pi      # tsc + node tests for pi/extensions
make test-neovim  # headless neovim tests (local only; needs the plugins)
```

Tests live next to the file they cover (`claude/statusline_test.py` tests
`claude/statusline-command.sh`). `install.py` installs the pre-commit hook.
