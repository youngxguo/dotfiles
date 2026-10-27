# Claude accounts

Claude subscriptions live side by side (`~/.claude`, numbered `~/.claudeN`,
or named login directories). Start new Claude agents through
`cseat run --handoff`, which chooses an account with headroom, picks the model
from cseat's policy unless one is pinned, and moves the session to another
account when that one reaches a usage limit. The kickoff skill handles this
automatically. cseat is the only handoff mechanism; `cseat usage` shows every
account's windows.
