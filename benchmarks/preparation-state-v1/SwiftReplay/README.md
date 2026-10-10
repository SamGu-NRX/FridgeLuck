# SwiftReplay (unrun arm in the Linux benchmark sandbox)

Replays preparation-state-v1 probes through the **real** production
`IngredientLexicon.swift` (synced verbatim by `scripts/sync_production_sources.sh`;
the synced copy is gitignored so it can never drift silently).

Status in the Python benchmark environment: **unrun — no Swift toolchain
available**. Run on macOS:

```sh
benchmarks/preparation-state-v1/SwiftReplay/scripts/sync_production_sources.sh
swift test --package-path benchmarks/preparation-state-v1/SwiftReplay
python3 - <<'EOF' > /tmp/probes.jsonl
import json
m = json.load(open('benchmarks/preparation-state-v1/manifest.json'))
for p in m['probes']:
    print(json.dumps({'probe_id': p['probe_id'], 'text': p['text']}))
EOF
swift run --package-path benchmarks/preparation-state-v1/SwiftReplay swift-replay < /tmp/probes.jsonl > swift_lexicon_replay.jsonl
```

## Full-resolver execution limits

This package replays **only the curated-lexicon arm** (`IngredientLexicon`).
The full production resolver is **not** replayable here, in this environment or
in this package:

- `IngredientCatalogResolver` requires GRDB 7.x and the bundled
  `usda_ingredient_catalog.sqlite`; the GRDB dependency is unavailable in the
  Linux benchmark sandbox (no Swift toolchain at all), and even on macOS this
  package does not declare GRDB or ship the database.
- The state-blind record selection that produces the benchmark's headline
  confusion (unique-or-nil prefix match over state records) is therefore
  covered by the **read-only Python replay** in `../run.py`
  (`production_replay` arm, port differential-verified against Swift at 186
  cases, 0 divergences — see `experiments/ingredient-recognition/differential/`).
- A full-resolver macOS replay would need a harness target that adds GRDB,
  bundles the catalog, and drives `IngredientCatalogResolver` + the identity
  pipeline directly; that is follow-up work, not a re-run of this package.

The catalog-resolution path (GRDB + the app's SQLite) stays in the Python
replay (`run.py production_replay`) until that harness exists; this package
covers the curated-lexicon arm, which is where the state-blind
`cooked rice -> rice` behavior lives (see the test named
`testLexiconIsStateBlindOnCookedModifier`).

