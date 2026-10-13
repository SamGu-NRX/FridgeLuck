# sqlite-state-diff (scaffold)

Read-only comparison command for two **closed synthetic** SQLite regression
fixtures: precise schema, row, and typed-value differences — no epsilon, no
file-hash equality claims.

Status: **scaffold checkpoint.** Comparison core, literal tests, and full
documentation land in following checkpoints; see the draft PR for the
authoritative Handoff.

Pinned contract (already in the CLI): exit `0` equal · `1` different ·
`2` invalid input or refusal · `3` limited by bounds. A partial or timed-out
comparison is never reported equal.
