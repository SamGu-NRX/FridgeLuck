# Acquisition fault lab — measurement report

*Run 2026-10-11T06:54:11Z · adapter `/home/user/work/frl-faultlab-20261011/experiments/nutrition5k-portion/src/download_imagery.py` (sha256 `ec05b12c3ac6510c…`, repo `85526906ebd6`) · Python 3.13.14*

Clean control gate: **PASSED** — the adapter round-tripped the fault-free scenario byte-exactly before any fault was measured. All traffic stayed on `127.0.0.1:41925` (loopback only; a guarded urllib opener made any non-loopback URL fail fast). All payloads were synthetic.

## Measured verdicts

| Scenario | Fault | Attempts | Adapter verdict | Disk bytes | Disk sha == expected |
|---|---|---|---|---|---|
| `clean-rgb-control` | clean | 1 | ok-intact | 2048 | yes |
| `truncation-rgb-clean-eof` | truncation | 4 | fetch-failed | — | no |
| `truncation-depth-clean-eof` | truncation | 4 | fetch-failed | — | no |
| `interrupted-write-rgb-rst` | truncation | 4 | fetch-failed | — | no |
| `wrong-content-length-understated` | wrong_content_length | 1 | ok-truncated | 1792 | no |
| `wrong-content-length-overstated` | wrong_content_length | 4 | fetch-failed | — | no |
| `wrong-content-type-html` | wrong_content_type | 1 | ok-intact | 2048 | yes |
| `wrong-hash-same-size-depth` | wrong_hash | 1 | ok-corrupt | 1536 | no |
| `redirect-one-hop` | redirect | 2 | ok-intact | 2048 | yes |
| `redirect-three-hops` | redirect | 4 | ok-intact | 2048 | yes |
| `redirect-final-404` | redirect | 2 | missing-404 | — | no |
| `empty-depth-raw` | empty | 1 | ok-zero-bytes | 0 | no |
| `transient-503-recovers` | transient_status | 3 | ok-intact | 2048 | yes |
| `transient-429-exhausted` | transient_status | 4 | fetch-failed | — | no |
| `stale-cache-manifest-skip` | clean | 0 | skipped-cached | 512 | no |
| `stale-cache-partial-overwrite` | clean | 1 | ok-intact | 2048 | yes |

Verdict totals: 6 ok-intact, 1 ok-truncated, 1 ok-zero-bytes, 1 ok-corrupt, 5 fetch-failed, 1 missing-404, 1 skipped-cached.

## What the measurements show

- **Silent corruption is the dominant failure mode.** In 3 of 16 scenarios the adapter returned `status: ok` while the bytes on disk were wrong — truncated (wrong-content-length-understated), zero-byte (empty-depth-raw), or same-size corrupt (wrong-hash-same-size-depth). Affected scenarios: `wrong-content-length-understated`, `wrong-hash-same-size-depth`, `empty-depth-raw`. The adapter computes and records a per-download sha256 but never compares it (source review of the adapter), so integrity faults propagate silently into training data.
- **SHA-256 is recorded but never enforced.** The adapter computed the digest of corrupted bytes (`wrong-hash-same-size-depth`) and still returned `ok`. Adding a post-read digest comparison against a trusted manifest would convert these silent faults into loud failures.
- **No HTTP Range resume.** Across 5 truncation / wrong-content-length scenarios (17 requests total), the adapter never sent a `Range` header — every retry restarts from byte 0 and the final failure discards all progress.
- **Cache trust without verification.** `stale-cache-manifest-skip`: the manifest claimed `status: ok` with the correct digest, while the actual file on disk was 512B (truncated from a previous run). The adapter skipped the download and left the corrupt file in place — the exact mechanism behind the zero-byte `depth_raw.png` observed in production (PR #41).
- **Overwrite recovery works when the fetch actually runs.** `stale-cache-partial-overwrite`: a pre-existing partial file (1024B) was fully replaced with correct bytes because no manifest entry said *done*.
- **Bounded retries work for recoverable faults.** `transient-503-recovers`: recovered after 3 attempts with correct bytes. `transient-429-exhausted`: a persistent 429 exhausted all 4 attempts and failed cleanly — no crash, and no partial file was ever written.
- **Content-Type is never inspected.** `wrong-content-type-html`: an HTML error page served as `text/html` with intact PNG bytes was accepted as `ok` (the bytes matched, so this one is benign in isolation — but it means an HTML error page with a 200 status would also be written verbatim).

## Reproduce

```bash
# fixture-contract suite (54 tests)
python3 -m pytest tools/acquisition-faultlab/tests -q
# re-run the measurement (writes results.json, then render report.md)
python3 tools/acquisition-faultlab/run.py
python3 tools/acquisition-faultlab/report.py --results tools/acquisition-faultlab/results.json \
  --out tools/acquisition-faultlab/report.md
```

Everything is synthetic and loopback-only: the fixture server binds 127.0.0.1 with no outbound capability, installs a fail-fast guard against non-loopback URLs for the whole process, and every expected byte record in `scenarios.json` is re-derived from the scenario seed by the test suite.
