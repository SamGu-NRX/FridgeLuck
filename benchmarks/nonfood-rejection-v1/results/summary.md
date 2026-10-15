# nonfood-rejection-v1 — scored run 2026-10-10 (r2)

Frozen manifest: 1,200 Open Images (CC-BY-2.0) — 300 `empty_visible`,
300 `opaque_unknown`, 600 `food_control`; dev/test 50/50, photographer-
and series-leak-safe. Scoring: dev-selected thresholds, group-level
false-addition metrics, scored outputs reproduce under `score.py --verify`
(all eight — four arms × two policies — verified this run).

## Two policies

- **`measured` (headline)** — the verdict policy is stratum-blind: it sees
  arm output and dev-selected thresholds only. `tests/test_policy_blindness.py`
  mutation-tests this end-to-end: permuting the manifest's ground truth
  (stratum and role) with arm outputs held byte-identical changes
  **no measured prediction** while the computed metrics do move — and the
  oracle's predictions do move, pinning its privilege.
- **`oracle` (privileged upper bound)** — additionally reads the frozen
  stratum, so it can protect opaque-unknown images from certain-empty and
  restrict certain-empty to visibly-empty ones. That is target information
  the production pipeline does not have at prediction time. Oracle numbers
  are reported separately and never mixed with measured ones. The
  production mapper is unchanged by this benchmark either way.

## Headline (measured policy)

**No measured arm can reject nonfood at the 1% false-addition cap while
keeping any control recall.** The dish-centric classifier unconditionally
hallucinates dishes on empty kitchens; zero-shot CLIP barely separates
food from empty-shelf photos; the only arms that hit the cap do so by
never admitting anything — and under the stratum-blind policy they then
declare **every** negative group, sealed containers included, certainly
empty.

## Results — measured policy (test split; dev in parentheses)

| Arm | False-add rate | Certain-empty (of all neg. groups) | Control recall |
|---|---|---|---|
| `food101-mobilenet` | **1.000** (1.000) | 0.000 (0.000) | 1.000 (1.000) |
| `clip-zeroshot` | **0.901** (0.880) | 0.095 (0.120) | 1.000 (0.987) |
| `constant-0.5` baseline | 0.000 | **1.000** (1.000) | 0.000 |
| `reject-everything` baseline | 0.000 | **1.000** (1.000) | 0.000 |

Threshold note: neither real arm meets the 1% dev cap. `food101-mobilenet`
minimizes at a dev false-addition rate of 1.000; `clip-zeroshot` selects
`tau_high=0.5` at the cap-violating minimum (0.880 dev).

## Results — oracle policy (privileged upper bound, test split)

| Arm | False-add rate | Certain-empty | Control recall |
|---|---|---|---|
| `food101-mobilenet` | 1.000 | 0.000 | 1.000 |
| `clip-zeroshot` | 0.901 | 0.087 | 1.000 |
| `constant-0.5` baseline | 0.000 | 0.458 | 0.000 |
| `reject-everything` baseline | 0.000 | 0.458 | 0.000 |

The oracle↔measured gap is itself a result: for the no-information arms,
certain-empty jumps from 0.458 to 1.000 once the policy can no longer see
which images it could not see inside. The oracle's "never call a sealed
container empty" protection costs that knowledge; the measured numbers
price what a real stratum-blind pipeline actually risks.

## What the numbers say

- **`food101-mobilenet` cannot ever say "empty."** A Food-101 classifier
  produces a dish label on every photo — an empty cupboard comes back
  "prime rib" at 0.5–0.9 confidence (negative-score histogram puts mass in
  0.3–0.6). Under both policies every negative group is a false addition
  (258/258 dev, 253/253 test) and no photo is ever certified empty.
- **Zero-shot CLIP is not a shortcut.** With a two-prompt food/empty probe
  and temperature-1 cosine calibration, 261 of 300 dev negative images
  land in the 0.5–0.6 bin: the probe separates almost nothing. The
  threshold machinery still does its job — it refuses to claim the 1% cap
  and reports the honest 88–90% false-add rate. Its few certain-empty
  verdicts include opaque containers (31 dev / 24 test groups measured
  vs 26 / 22 oracle).
- **Truth-mutation safety is pinned, not promised.** `score.py --verify`
  re-derives every scored output from the raw report; the new blindness
  suite additionally flips the manifest's ground truth and shows measured
  predictions are bit-identical while metrics move.

## Implication for the scan pipeline

The production resolver should not ask "which dish is this?" of a shelf
photo and trust the argmax. Nonfood rejection needs evidence that is
explicitly absent-vs-present (detector-grounded or multi-probe with
calibration), and the confirm-before-add flow should treat
low-confidence-empty as unknown — exactly the verdict class this
benchmark scores. If the production pipeline can know "the camera could
not see inside" from capture-time signals (not from ground truth), that
is a legitimate measured input, not an oracle leak; the oracle policy
here deliberately uses the frozen stratum instead, which is why it is
labeled privileged.

## Reproduce

```sh
python3 -m pytest tests/ -q        # 40 tests, incl. truth-mutation blindness
python3 check_manifest.py --cache-dir <cache>
python3 run.py --arm arms/food101_mobilenet.py --cache-dir <cache>
python3 run.py --arm arms/clip_zeroshot.py --cache-dir <cache>
python3 run.py --arm arms/constant_baseline.py --cache-dir <cache>
python3 run.py --arm arms/reject_everything.py --cache-dir <cache>
# measured (default) and privileged oracle scoring for each report:
python3 score.py --report reports/raw/<arm>.json
python3 score.py --report reports/raw/<arm>.json --policy oracle
python3 score.py --report reports/raw/<arm>.json --verify results/scored-<arm>.json
```

Raw and scored reports are committed under `reports/` and `results/`;
each pins the manifest sha256 and re-verifies.

## Handoff

- **State:** measured/oracle policy split, truth-mutation blindness suite,
  and regenerated scored run r2 are on `obv/fl-l2-nonfood` (this PR).
  40/40 tests pass; all eight scored outputs verify; raw reports were
  **not** re-run — no arm output changed, only scoring.
- **Verified here:** manifest check (`check_manifest.py` → `manifest OK`),
  full suite, `score.py --verify` × 8.
- **Not verified here:** no Swift toolchain on Linux — the production
  mapper was neither run nor modified; hosted macOS CI on this branch has
  not been observed yet.
- **Picks for a successor:** (1) production-observable "cannot see inside"
  evidence at capture time would let the pipeline protect opaque
  containers *measured* instead of only in the oracle; (2) a detector-
  grounded absence arm (not another dish classifier) is the most promising
  candidate against the 1% cap; (3) the CLIP probe needs multi-prompt
  calibration before any production consideration.
- **Committed reports:** `reports/raw/*.json` (arm outputs, unchanged from
  r1), `results/scored-*.json` (r2, both policies), `build_stats.json`,
  `manifest.json` (sha256-pinned).
