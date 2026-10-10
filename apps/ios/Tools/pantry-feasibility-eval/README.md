# Pantry Feasibility Evaluation

Measures the gap between production's makeability predicate and what the
data model actually supports, over a frozen, seeded corpus of pantry states.

## The question

`RecipeRepository.findMakeable` (and `findNearMatch`) decide "can I cook
this?" by ingredient-ID membership: every required ID present in the pantry
means makeable. The data model — inventory lots with known grams, estimated
lots, zero-remaining lots — supports a stronger feasibility judgment:

- a required ingredient with no known quantity anywhere (all lots estimated)
  is only presence-assumed, never a confirmed amount;
- a required ingredient whose known grams are below the recipe requirement
  is a quantity shortfall production cannot see.

The corpus plants counterexamples for both and measures the production
predicate against an independent oracle (`oracle.py`, transcribed from the
inventory, health-profile, and allergen domain models).

## Layout

- `oracle.py` — Python feasibility oracle and diet/allergen semantics.
- `generate_states.py` — regenerates the frozen corpus (seeded, deterministic):
  5,200 states in eight families plus the catalog snapshot of all 166
  bundled recipes. Rewriting changes `manifest.sha256` and fails every
  downstream check, by design.
- `check_states.py` — validates the frozen corpus invariants (planted
  counterexamples, agreement probes, family counts, manifest hashes).
- `run_eval.py` — scores the replay: false-complete and false-block rates
  by family, recall on oracle-feasible pairs, planted false-complete rate.
  Writes `runs/report.json`.
- `verify_replay.py` — cross-language gate: rebuilds the Swift package,
  replays the corpus, and asserts (1) the vendored production allergen
  membership table matches `CORE_MEMBERSHIPS` in `oracle.py` row for row,
  (2) the Swift oracle verdict matches the Python oracle on all
  863,200 (state, recipe) pairs, and (3) the Swift production predicate
  matches an independent Python transcription of it. Writes
  `runs/replay_verification.json`.
- `swift/` — Swift package (builds on Linux, exercised under the repo's
  hosted macOS CI): models, the vendored `AllergenGroupMembership.swift`
  (verbatim from production), the oracle, the production-predicate
  transcription, and a replay CLI.

## Usage

```sh
python3 check_states.py        # frozen-corpus invariants
python3 -m pytest -q           # unit tests for oracle + corpus
python3 verify_replay.py       # Swift rebuild + replay + cross-language gate
python3 run_eval.py            # metrics -> runs/report.json
```

The Swift CLI can be driven directly:

```sh
cd swift && swift build
.build/debug/PantryFeasibilityReplay replay --corpus-dir ../runs --output out.jsonl
.build/debug/PantryFeasibilityReplay export-memberships
```

## Results (frozen corpus, 5,200 states x 166 recipes = 863,200 pairs)

- Production calls 25,524 pairs makeable; the data model refutes 11,846 of
  them (46.4%) — every one a quantity shortfall or unknown-quantity
  assumption production cannot represent.
- In the planted false-complete family, 64.2% of production-makeable claims
  are refuted by the oracle.
- Recall on oracle-feasible pairs is 1.0: production never hides a recipe
  the data model calls feasible. The gap is entirely one-sided
  (over-promising), which is the risk profile you would expect from
  ID-membership matching.
- The two implementations (Swift replay and Python oracle) agree on all
  863,200 rows, and the vendored allergen membership table is identical to
  the oracle transcription (50 rows).
- Live production arm: the real `RecipeRepository.findMakeable` /
  `findNearMatch`, running on real migrated in-memory databases seeded from
  the frozen corpus, agrees with the transcribed arm on every one of the
  5,200 states — the makeable and near-match ID sets are identical
  (`runs/production_verification.json`, agreement rate 1.0). The 46.4%
  false-complete finding is therefore not a transcription artifact: the
  production code itself over-promises on exactly those pairs.

## Caveats

- Quantity fidelity of the bundled data is the fidelity audited separately
  (see the recipe-import fidelity work); this tool compares predicates over
  whatever quantities the snapshot carries.
- The oracle treats estimated lots as unknown rather than imputing a value;
  a production change that imputes quantities would change the planted
  family's rate, not the corpus.
