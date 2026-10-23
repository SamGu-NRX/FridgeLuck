# Data Provenance

All inputs are offline copies of artifacts committed elsewhere in the repo or
on read-only branches. Nothing here was fetched live, and no file was
hand-edited after copying. Every hash below was re-verified against the
upstream ref at evaluation time (2026-10-11):

```
sha256sum data/<file>
git show <ref>:<upstream path> | sha256sum
```

All four files matched byte-for-byte.

## Reverse-meal replay (primary substrate)

Upstream ref: `alpha` @ `2e77938` (integration branch PR #7 merged into).
Upstream directory: `backend/gemini-agent/evaluation-fixtures/`
(`apps/ios/Tools/reverse-meal-eval/` holds only `main.swift` and `run.sh`).

| File (here) | Upstream path | SHA-256 (verified) |
| --- | --- | --- |
| `reverse-meal-replay-v1.json` | `backend/gemini-agent/evaluation-fixtures/reverse-meal-replay-v1.json` | `0012497ee2a001a03387bfdd07241b5f026ea01f28b66f269004259b0f8e2786` |
| `reverse-meal-states-v1.jsonl` | `backend/gemini-agent/evaluation-fixtures/reverse-meal-states-v1.jsonl` | `75a76b70bb53fb4dfa1feb14e8804cb907dc9c1dde7c64bca2259990f25f60d1` |

The replay JSON provides, per episode, `proxy_reward` (the producer's
self-assessed outcome channel that the as-built app flow would store) and
`truth_reward` (independent correctness labels authored for PR #7's
A1-proxy vs A1-truth-control arms). 12 episodes in file order. The states
JSONL carries 16 spec rows with hard-failure annotations; the
held-out labels used in the analysis come from
`backend/gemini-agent/evaluation-fixtures/reverse-meal-spec-v1.md` (same ref,
"Family coverage and reference meaning" table), verified this session:
RM-03 correct / RM-04 wrong-recipe / RM-13 wrong-servings (byte-equivalent
evidence, collision group); RM-05 and RM-14 correct-with-weak-evidence;
RM-06 correct vs RM-16 portion-edit-wrong (second collision group);
RM-07 ambiguity hard-fail (top dish happens to be correct); RM-08-RM-10
boundary variants, RM-11/RM-12 guard family, RM-15 unknown-portion — the
last three not scored as outcome truth. Per the spec's own warning, RM-03/
RM-04/RM-13 and RM-06/RM-16 are reported groupwise: identical evidence
cannot receive different modes from a deterministic assessor, and the spec
forbids demanding perfect separation inside a collision group.

## Correction histories (drift substrate)

Upstream ref: `origin/obv/fl-l2-correction-drift` (PR #53's branch,
READ-ONLY — never checked out, never edited).

| File (here) | Upstream path | SHA-256 (verified) |
| --- | --- | --- |
| `scan-correction-histories.json` | `apps/ios/Tools/scan-correction-eval/data/histories.json` | `0d7cbcd8c12443c3af92c28ec60f3c9b8dce60a360876dcf037c63a92d0e2ee9` |
| `scan-correction-expected-current.json` | `apps/ios/Tools/scan-correction-eval/data/expected_current.json` | `e42162f2017e250793fe74f2399ce25f7d95213aa78766a98ffd61d10b6178ef` |

300 authored histories in 6 families of 50 seeds; only the `changed` family
(50 seeds, an authored mid-history truth flip) is consumed here — it is the
drift question Part 0 owns. Its committed `correct` column is the
per-scan truth label; the reference decisions in `expected_current.json`
come from PR #53's separate reference policy and abstentions in them carry
no measured outcome (PR #53's `HANDOFF.md` states this too) — the
confidence replay never treats the reference policy's confidence as truth.

## Swift source of record

The port (`../confidence_port.py`) mirrors
`apps/ios/Platform/Persistence/Services/ConfidenceLearningService.swift` on
`alpha` @ `2e77938` (359 lines). The Swift file was NOT copied here (it is
owned by `apps/`); fixtures in `../tests/test_port_fixtures.py` are
hand-computed from those Swift lines and cite them, and the influence/update
formulas were re-read directly from the Swift source this session
(`assessSignal` at lines 276-294, `sampleSize` at 78-80, Beta update at
206-215, `prior(for:)` at 300-330).
