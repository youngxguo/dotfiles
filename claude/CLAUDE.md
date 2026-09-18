# Claude accounts

Several Claude subscriptions live side by side (`~/.claude`, `~/.claude2`,
`~/.claude3`, `~/.claude4`, `~/.claude5`, `~/.claude6`). Start new Claude
agents through `cseat run --handoff`, which chooses an account with headroom,
pins the model, and moves the session safely when that account reaches a usage
limit. The kickoff skill handles this automatically. A conditional
`StopFailure` hook self-rebumps plain Claude sessions started inside Herdr, but
skips cseat children (`CSEAT_SEAT` is set) so the two mechanisms never race.
