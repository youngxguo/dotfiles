# Claude accounts

Claude subscriptions live side by side (`~/.claude`, numbered `~/.claudeN`,
or named login directories). The kickoff skill starts new Claude agents in
Orca, and Orca's Claude command decides the account and the model: on a
machine set up with `cseat`, that command asks cseat for an account with
headroom. A chat session stays on the account it started on. In a terminal,
`cseat run --handoff` makes the same pick and also moves the session to
another account when that one reaches a usage limit. cseat is the only handoff
mechanism; `cseat usage` shows every account's windows.

# The bar for a change

Aim for simple, comprehensive and elegant. Find the change that removes the
cause rather than one that patches where it showed up, and build it with the
least machinery that does the job: reshaping what exists usually beats adding
a runner, a ledger or a new process. Beyond a small, clear fix, challenge your
own approach before presenting it or opening a PR. Ask whether it goes deep
enough that the problem won't come back, and whether a simpler shape would do,
then say what that review changed.
