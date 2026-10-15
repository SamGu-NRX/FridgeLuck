# Acquisition fault lab

A loopback-only fault-injection lab for the Nutrition5K acquisition adapter
(`experiments/nutrition5k-portion/src/download_imagery.py`, PR #41). It serves
deterministic synthetic payloads from 127.0.0.1 with declared faults, pins
every fixture contract with tests, and measures what the adapter actually
does — including the silent-corruption paths that motivated this work.

Nothing here touches the network: the server binds 127.0.0.1 only, every
scenario is synthetic (deterministic bytes, no real imagery), and the runner
installs a urllib opener that fails fast on any non-loopback URL.

## Files

| File | Role |
|---|---|
| `fixture_server.py` | Threaded HTTP fixture server, loopback guard, guarded opener |
| `gen_scenarios.py` | Deterministic generator for the 16 scenarios (`--check` to diff) |
| `scenarios.json` | Committed scenario manifest with exact expected-byte records |
| `scenario_counts.json` | Committed per-fault scenario counts (kept in sync by tests) |
| `run.py` | Drives the real adapter against every scenario, writes `results.json` |
| `report.py` | Renders `results.json` into `report.md` (measured findings only) |
| `results.json` / `report.md` | Output of the committed measurement run |
| `MUTATIONS.md` | Mutation-verification evidence for the test suite |
| `tests/` | 54 pytest tests pinning fixtures, manifest, and loopback safety |

## Use

```bash
# 1. Verify the fixtures and manifest (fast, no adapter needed)
python3 -m pytest tools/acquisition-faultlab/tests -q

# 2. Measure the adapter (writes results.json)
python3 tools/acquisition-faultlab/run.py

# 3. Render the report
python3 tools/acquisition-faultlab/report.py --results tools/acquisition-faultlab/results.json \
  --out tools/acquisition-faultlab/report.md
```

## Scenario families

`clean` (control + stale-cache variants), `truncation` (clean EOF and TCP
RST), `wrong_content_length` (understated and overstated), `wrong_content_type`,
`wrong_hash` (same-size corruption), `redirect` (1 hop, 3 hops, final 404),
`empty`, `transient_status` (503 that recovers, 429 that never does). Each
scenario declares `expect` records (sizes + sha256) for both the true content
and the bytes actually sent over the wire; the test suite re-derives them
from the scenario seeds so the manifest cannot drift silently.
