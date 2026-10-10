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

The catalog-resolution path (GRDB + the app's SQLite) stays in the Python
replay (`run.py production_replay`) until a macOS harness wires the resolver;
the Swift package covers the curated-lexicon arm, which is where the
state-blind `cooked rice -> rice` behavior lives (see the test named
`testLexiconIsStateBlindOnCookedModifier`).
