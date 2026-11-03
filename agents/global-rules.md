# Claude accounts

Claude subscriptions live side by side (`~/.claude`, numbered `~/.claudeN`,
or named login directories). Start new Claude agents through
`cseat run --handoff`, which chooses an account with headroom, picks the model
from cseat's policy unless one is pinned, and moves the session to another
account when that one reaches a usage limit. The kickoff skill handles this
automatically. cseat is the only handoff mechanism; `cseat usage` shows every
account's windows.

# The bar for a change

Aim for simple, comprehensive and elegant. Find the change that removes the
cause rather than one that patches where it showed up, and build it with the
least machinery that does the job: reshaping what exists usually beats adding
a runner, a ledger or a new process. Beyond a small, clear fix, challenge your
own approach before presenting it or opening a PR. Ask whether it goes deep
enough that the problem won't come back, and whether a simpler shape would do,
then say what that review changed.
