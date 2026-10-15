# portion-intervals

Interval-method study over PR41's portion-estimation outputs: point errors say
nothing about how often an amount RANGE covers the truth, so this study
measures calibrated interval coverage, width, and undercoverage on the frozen
Nutrition5k benchmark.

Read-only with respect to `experiments/nutrition5k-portion` (PR41): the source
data, models, and scorer are never modified, re-fitted, or re-scored. Where a
method needs per-record development predictions that PR41 did not commit, the
study emits an explicit **unavailable** arm instead of rebuilding PR41's
acquisition/fit.

## Run

```bash
python3 -m pytest experiments/portion-intervals/tests -q      # contract tests + negative controls
python3 experiments/portion-intervals/check_inputs.py          # validate inputs, commit eligible/unknown counts
python3 experiments/portion-intervals/evaluate.py --seed 20261010 --out experiments/portion-intervals/results
python3 experiments/portion-intervals/score.py --verify-report # regenerate + verify REPORT.md
```

Stdlib only; pytest for the test suite. See `NOMINAL_LEVELS.json` for the
protocol declared before any test scoring, `REPORT.md` for results, and
`results/` for machine-readable outputs.
