# LeChef live runner — runbook

The live runner compares the three LeChef designs (coach / companion /
planner) against a **real provider**. It is strictly opt-in: without an
explicit key in the environment **no request can ever be sent** — not from
tests, not from the default CLI mode, not from a stray import.

This file documents the mechanism. It is NOT authorization to run it: a
live run needs Sam's explicit key, scope, and cap approval (the operator
records the request; this runner never allocates spend on its own).

## Commands

```bash
# plan (default): keyless, prints the arms/slots/caps/prices and the exact
# live command — safe to run anytime, never sends anything
bun src/lechef/run/live.ts --sessions=<dir-or-file>

# live: requires the key AND both caps in the environment, or it refuses
LECHEF_LIVE_API_KEY=... \
LECHEF_LIVE_MAX_SPEND_USD=0.25 \
LECHEF_LIVE_MAX_REQUESTS=40 \
  bun src/lechef/run/live.ts --sessions=<dir-or-file> --mode=live
```

Same `bun run lechef:live -- ...` shortcut works from `backend/gemini-agent`.

## Environment contract

| Variable | Required | Meaning |
| --- | --- | --- |
| `LECHEF_LIVE_API_KEY` | live only | The key. Read from the environment once at startup; never logged, never written to disk, never accepted from a file. Tests never require it. |
| `LECHEF_LIVE_MAX_SPEND_USD` | live (default `1`) | Run-wide spend cap in USD — hard ceiling on committed estimates; a request that would breach it is never sent. |
| `LECHEF_LIVE_MAX_REQUESTS` | live (default `20`) | Run-wide request cap — same fail-closed enforcement. Whichever cap binds first stops the run cleanly. |
| `LECHEF_LIVE_MODEL` | no | Model name (default `gemini-2.0-flash`). |
| `LECHEF_LIVE_ENDPOINT` | no | Base URL override (a `/v1beta`/`/v1` suffix is stripped). Point at a proxy for a dry-run rehearsal. |
| `LECHEF_LIVE_MAX_OUTPUT_TOKENS` | no | Per-request output ceiling (default 512) — also feeds the pre-request cost estimate. |
| `LECHEF_LIVE_MAX_TOOL_ROUNDS` | no | Tool-round budget per assistant slot (default 4) before the slot closes. |
| `LECHEF_LIVE_PRICE_IN_PER_MTOK`, `LECHEF_LIVE_PRICE_OUT_PER_MTOK` | no | Price overrides for models missing from the table (`live/pricing.ts`). |
| `LECHEF_LIVE_OUT_DIR` | no | Run-output root (default `evaluation/lechef-live-runs/` — gitignored). |

Caps are enforced by a single run-wide ledger: every request is authorized
BEFORE it is sent; estimates commit upfront and reconcile from the real
token usage when the response carries it. A cap breach aborts the whole
run (no further arm or session starts), writes `summary.json` with the
cap state, and exits 1.

## Outputs (never committed)

Per run, `evaluation/lechef-live-runs/<runId>/` receives:

- `summary.json` — per-arm sessions/requests/cost and the run's cap state
- `<arm>--<session>.jsonl` — every exchange, request, tool dispatch, tool
  result, suppression, cap-abort, error, and session end, one JSON per line
- `<arm>--<session>.record.json` — the RunRecord-shaped output (pinned
  Part-2 scorer contract) assembled from the session

## Sessions input

`--sessions` takes one session-script JSON file or a directory of them —
the same shape the offline harness CLI (`src/lechef/run/cli.ts`) consumes.
Session scripts are derived from the suite D sources by the harness
conversion flow; the derived files are evaluation inputs, not tracked
sources.

## Test isolation

`bun test src/__tests__` (449 baseline + live-runner + adapter tests) uses
the injected mock transport only. The Gemini adapter's send path is
constructed solely by `--mode=live`; its pure request/response mappers are
unit-tested in `geminiAdapter.test.ts` without any client construction.
