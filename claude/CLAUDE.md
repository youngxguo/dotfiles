# Claude accounts

Several Claude subscriptions live side by side (`~/.claude`, `~/.claude2`,
`~/.claude3`, `~/.claude4`, `~/.claude5`, `~/.claude6`, selected with
`CLAUDE_CONFIG_DIR`). Before starting a claude agent in a herdr pane, or
delegating work that starts one, use the rebump skill's `pick` to choose an
account with headroom and start the pane with that `CLAUDE_CONFIG_DIR`. If a
delegated claude session stops on a usage limit, rebump it rather than
restarting it or prompting it again.
