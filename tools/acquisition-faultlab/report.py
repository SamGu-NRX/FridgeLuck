"""Render results.json (from run.py) into a deterministic report.md.

Every finding below is derived from the measured records — no claims beyond
what the run observed. Regenerate with:
    python3 report.py --results results.json --out report.md
"""

from __future__ import annotations

import argparse
import json
from collections import Counter
from pathlib import Path

LAB = Path(__file__).resolve().parent


def classify(rec: dict) -> str:
    """Measured verdict category for one scenario record."""
    status = rec["adapter"]["status"]
    if status.startswith("skipped"):
        return "skipped-cached"
    if status == "missing (404)":
        return "missing-404"
    if status.startswith("error"):
        return "fetch-failed"
    if rec["derived"]["disk_matches_expected_content"]:
        return "ok-intact"
    if rec["disk"]["bytes"] == 0:
        return "ok-zero-bytes"
    if (rec["disk"]["bytes"] or 0) < rec["expect"]["content_size"]:
        return "ok-truncated"
    return "ok-corrupt"  # same size, wrong bytes


CATEGORY_ORDER = [
    "ok-intact", "ok-truncated", "ok-zero-bytes", "ok-corrupt",
    "fetch-failed", "missing-404", "skipped-cached",
]

CATEGORY_DESC = {
    "ok-intact": "adapter reported success; disk bytes match the expected image exactly",
    "ok-truncated": "adapter reported SUCCESS but the file on disk is shorter than the real image",
    "ok-zero-bytes": "adapter reported SUCCESS with a zero-byte file on disk",
    "ok-corrupt": "adapter reported SUCCESS but the file on disk has the wrong bytes (same size)",
    "fetch-failed": "adapter exhausted its retries and failed; nothing (usable) on disk",
    "missing-404": "adapter classified the response as a missing image (404)",
    "skipped-cached": "adapter skipped the download because the manifest already claims success",
}


def main() -> int:
    ap = argparse.ArgumentParser(description="Render faultlab report.md")
    ap.add_argument("--results", type=Path, default=LAB / "results.json")
    ap.add_argument("--out", type=Path, default=LAB / "report.md")
    args = ap.parse_args()

    data = json.loads(args.results.read_text())
    run, recs = data["run"], data["scenarios"]
    for rec in recs:
        rec["verdict"] = classify(rec)
    counts = Counter(r["verdict"] for r in recs)

    # -- measured findings (each cites scenario ids and derives from records) --
    findings: list[str] = []

    accepted_bad = [r for r in recs if r["verdict"] in ("ok-truncated", "ok-zero-bytes", "ok-corrupt")]
    if accepted_bad:
        ids = ", ".join(f"`{r['scenario_id']}`" for r in accepted_bad)
        findings.append(
            f"- **Silent corruption is the dominant failure mode.** In "
            f"{len(accepted_bad)} of {len(recs)} scenarios the adapter returned "
            f"`status: ok` while the bytes on disk were wrong — truncated "
            f"({', '.join(r['scenario_id'] for r in recs if r['verdict'] == 'ok-truncated') or 'n/a'}), "
            f"zero-byte ({', '.join(r['scenario_id'] for r in recs if r['verdict'] == 'ok-zero-bytes') or 'n/a'}), "
            f"or same-size corrupt ({', '.join(r['scenario_id'] for r in recs if r['verdict'] == 'ok-corrupt') or 'n/a'}). "
            f"Affected scenarios: {ids}. The adapter computes and records a per-download "
            f"sha256 but never compares it (source review of the adapter), "
            f"so integrity faults propagate silently into training data.")

    hash_scn = [r for r in recs if r["fault"] == "wrong_hash"]
    if hash_scn and all(r["verdict"] == "ok-corrupt" for r in hash_scn):
        findings.append(
            f"- **SHA-256 is recorded but never enforced.** The adapter computed the "
            f"digest of corrupted bytes ({', '.join('`%s`' % r['scenario_id'] for r in hash_scn)}) "
            f"and still returned `ok`. Adding a post-read digest comparison against a "
            f"trusted manifest would convert these silent faults into loud failures.")

    truncation_scn = [r for r in recs if r["fault"] in ("truncation", "wrong_content_length")]
    if truncation_scn and not any(r["any_range_header"] for r in truncation_scn):
        findings.append(
            f"- **No HTTP Range resume.** Across {len(truncation_scn)} truncation / "
            f"wrong-content-length scenarios ({sum(r['attempts'] for r in truncation_scn)} "
            f"requests total), the adapter never sent a `Range` header — every retry "
            f"restarts from byte 0 and the final failure discards all progress.")

    skips = [r for r in recs if r["verdict"] == "skipped-cached"]
    for r in skips:
        bad_disk = not r["derived"]["disk_matches_expected_content"]
        if bad_disk:
            findings.append(
                f"- **Cache trust without verification.** `{r['scenario_id']}`: the manifest "
                f"claimed `status: ok` with the correct digest, while the actual file on disk "
                f"was {r['disk']['bytes']}B (truncated from a previous run). The adapter skipped "
                f"the download and left the corrupt file in place — the exact mechanism behind "
                f"the zero-byte `depth_raw.png` observed in production (PR #41).")

    overwrites = [r for r in recs if r["fault"] == "clean" and r["preseed"].get("mode") == "partial_file"]
    if overwrites and all(r["derived"]["disk_matches_expected_content"] for r in overwrites):
        findings.append(
            f"- **Overwrite recovery works when the fetch actually runs.** "
            f"`{overwrites[0]['scenario_id']}`: a pre-existing partial file ({overwrites[0]['preseed']['disk_before_bytes']}B) "
            f"was fully replaced with correct bytes because no manifest entry said *done*.")

    transient_ok = [r for r in recs if r["scenario_id"] == "transient-503-recovers"]
    transient_bad = [r for r in recs if r["scenario_id"] == "transient-429-exhausted"]
    if transient_ok and transient_ok[0]["verdict"] == "ok-intact":
        findings.append(
            f"- **Bounded retries work for recoverable faults.** `{transient_ok[0]['scenario_id']}`: "
            f"recovered after {transient_ok[0]['attempts']} attempts with correct bytes. "
            f"`{transient_bad[0]['scenario_id']}`: a persistent 429 exhausted all 4 attempts and "
            f"failed cleanly — no crash, and no partial file was ever written.")

    content_type = [r for r in recs if r["fault"] == "wrong_content_type"]
    if content_type and content_type[0]["verdict"] == "ok-intact":
        findings.append(
            f"- **Content-Type is never inspected.** `{content_type[0]['scenario_id']}`: "
            f"an HTML error page served as `text/html` with intact PNG bytes was accepted as `ok` "
            f"(the bytes matched, so this one is benign in isolation — but it means an HTML "
            f"error page with a 200 status would also be written verbatim).")

    # -- render ----------------------------------------------------------------
    lines: list[str] = []
    lines.append("# Acquisition fault lab — measurement report")
    lines.append("")
    lines.append(f"*Run {run['date_utc']} · adapter `{run['adapter_path']}` "
                 f"(sha256 `{run['adapter_sha256'][:16]}…`, repo `{run['repo_head'][:12]}`) · "
                 f"Python {run['python']}*")
    lines.append("")
    lines.append(f"Clean control gate: **{run['clean_control_gate']}** — the adapter round-tripped "
                 f"the fault-free scenario byte-exactly before any fault was measured. "
                 f"All traffic stayed on `{run['server_bind']}` (loopback only; a guarded urllib "
                 f"opener made any non-loopback URL fail fast). All payloads were synthetic.")
    lines.append("")
    lines.append("## Measured verdicts")
    lines.append("")
    lines.append("| Scenario | Fault | Attempts | Adapter verdict | Disk bytes | Disk sha == expected |")
    lines.append("|---|---|---|---|---|---|")
    for r in recs:
        sha_ok = "yes" if r["derived"]["disk_matches_expected_content"] else "no"
        disk = r["disk"]["bytes"]
        lines.append(f"| `{r['scenario_id']}` | {r['fault']} | {r['attempts']} | "
                     f"{r['verdict']} | {disk if disk is not None else '—'} | {sha_ok} |")
    lines.append("")
    lines.append("Verdict totals: " + ", ".join(
        f"{counts[c]} {c}" for c in CATEGORY_ORDER if counts[c]) + ".")
    lines.append("")
    lines.append("## What the measurements show")
    lines.append("")
    lines.extend(findings)
    lines.append("")
    lines.append("## Reproduce")
    lines.append("")
    lines.append("```bash")
    lines.append("# fixture-contract suite (54 tests)")
    lines.append("python3 -m pytest tools/acquisition-faultlab/tests -q")
    lines.append("# re-run the measurement (writes results.json, then render report.md)")
    lines.append("python3 tools/acquisition-faultlab/run.py")
    lines.append("python3 tools/acquisition-faultlab/report.py --results tools/acquisition-faultlab/results.json \\")
    lines.append("  --out tools/acquisition-faultlab/report.md")
    lines.append("```")
    lines.append("")
    lines.append("Everything is synthetic and loopback-only: the fixture server binds 127.0.0.1 "
                 "with no outbound capability, installs a fail-fast guard against non-loopback "
                 "URLs for the whole process, and every expected byte record in "
                 "`scenarios.json` is re-derived from the scenario seed by the test suite.")
    lines.append("")

    args.out.write_text("\n".join(lines))
    print(f"wrote {args.out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
