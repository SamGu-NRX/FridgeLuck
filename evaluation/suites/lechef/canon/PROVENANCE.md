# Pinned canon — suite D doneness scorer

`rules.json` is a **verbatim byte-for-byte copy** of the reviewed doneness
rulebook:

| field | value |
|---|---|
| repository | `SamGu-NRX/FridgeLuck` |
| source branch | `overhaul/food-safety-canon` |
| source commit | `0b8ddca4df9ab828ecbe468f33d1bcce17a5b6c3` |
| source path | `data/food-safety/rules.json` |
| strict follow-up | `overhaul/food-safety-canon-p2-linter` @ `4f39fa30b6617e4a9a618ecf30099f5d6a2dd89d` |
| per-file SHA256 | `ba31ca0c868268f4cc3488afaa90d08033a42dbf1ea31ed807b61a1f60e4b01b` |

The strict follow-up supersedes PR #97's `overhaul/food-safety-rules`; its
doneness rules are identical to the pinned ones (it cleans citation quotes
only). This pin is the reviewed canon file, **not** a hand table: the scorer
(`suite.py`) derives product classes, minimum temperatures (°C), required rest
minutes and the reviewed source citations from the pinned file, and verifies
the SHA256 against `provenance.json` at load time — a tampered or replaced pin
fails the scorer closed (it refuses to run).

The safety thread pins the same reviewed files for the tool layer under
`backend/gemini-agent/src/lechef/canon/`; the SHA256s must agree.

Regenerate (only to re-pin a NEW reviewed commit): copy
`data/food-safety/rules.json` from the reviewed commit, update `sha256` in
`provenance.json`, and record the new source commit here and in the PR.
Never edit the pinned file in place — that breaks the hash gate.
