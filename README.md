# dotfiles

## install

```sh
git clone https://github.com/youngxguo/dotfiles.git
cd dotfiles
python3 install.py
```

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
