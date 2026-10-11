#!/usr/bin/env python3
"""Byte-stable report verification — full canonical regeneration.

REPORT.md is a generated artifact (scoring/render_report.py). Verification
must therefore regenerate the COMPLETE report byte-for-byte, not merely agree
with summary/table rows, and must re-execute the GRDB catalog replay rather
than trusting committed outputs. Checks, all of which must pass:

1. Scoring determinism: re-running scoring/score.py on each final observation
   file is byte-identical across two fresh processes and matches the
   committed scores.json artifacts (modulo the recorded invocation path).
2. Report regeneration: rendering REPORT.md from the committed artifacts
   reproduces the committed file byte-for-byte.
3. GRDB replay: the mirrored production resolver's sha256 matches both the
   repository file and the generated manifest; re-executing the Swift replay
   reproduces the committed grdb_replay_results.jsonl and meta byte-for-byte;
   regenerating the Python port answers reproduces
   python_catalog_results.jsonl; the differential is zero.

Exit code 0 prints VERIFIED; anything else fails loudly.
"""
from __future__ import annotations

import argparse
import gzip
import json
import subprocess
import sys
import tempfile
from pathlib import Path

EXPERIMENT = Path(__file__).resolve().parent.parent
SCORE = EXPERIMENT / "scoring" / "score.py"
REPORT = EXPERIMENT / "REPORT.md"
DIFF_DIR = EXPERIMENT / "differential"
REPO_ROOT = EXPERIMENT.parent.parent
MIRROR = (
    REPO_ROOT / "apps/ios/Tools/catalog-resolver-replay"
    / "Sources/CatalogReplayCore/ProductionMirror"
)
PACKAGE = REPO_ROOT / "apps/ios/Tools/catalog-resolver-replay"

sys.path.insert(0, str(EXPERIMENT / "scoring"))
sys.path.insert(0, str(DIFF_DIR))

import render_report  # noqa: E402

FINAL_RUNS = render_report.FINAL_RUNS


def _read_bytes(p: Path) -> bytes:
    if p.suffix == ".gz":
        with gzip.open(p, "rb") as f:
            return f.read()
    return p.read_bytes()


def check_rescoring(td: Path) -> list[str]:
    """Check 1: score.py reruns byte-identical and match committed artifacts."""
    problems: list[str] = []
    for stem, _label, _threshold, _bold in FINAL_RUNS:
        obs = EXPERIMENT / "observations" / f"openmodel_{stem}.jsonl.gz"
        committed_scores = EXPERIMENT / "scoring" / f"{stem}_scores.json"
        for out_dir in [td / f"{stem}-a", td / f"{stem}-b"]:
            proc = subprocess.run(
                [sys.executable, str(SCORE), "--observations", str(obs), "--split", "validation",
                 "--out-prefix", stem, "--out-dir", str(out_dir)],
                capture_output=True, text=True,
            )
            if proc.returncode != 0:
                problems.append(f"{stem}: score.py failed: {proc.stderr[-300:]}")
                break
        if problems:
            continue
        for name in [f"{stem}_scores.json", f"{stem}_per_class.csv"]:
            if (td / f"{stem}-a" / name).read_bytes() != (td / f"{stem}-b" / name).read_bytes():
                problems.append(f"{stem}: {name} not deterministic across runs")
        with gzip.open(td / f"{stem}-a" / f"{stem}_per_image.jsonl.gz", "rt") as fa, \
             gzip.open(td / f"{stem}-b" / f"{stem}_per_image.jsonl.gz", "rt") as fb:
            if fa.read() != fb.read():
                problems.append(f"{stem}: per_image records not deterministic")
        fresh = json.loads((td / f"{stem}-a" / f"{stem}_scores.json").read_text())
        committed = json.loads(committed_scores.read_text())
        fresh.pop("observations", None)
        committed.pop("observations", None)
        if fresh != committed:
            problems.append(f"{stem}: rescored scores.json differs from committed {committed_scores.name}")
    return problems


def check_report_bytes(root: Path = EXPERIMENT, report_path: Path = REPORT) -> str | None:
    """Check 2: the committed report IS the canonical render of its inputs."""
    rendered = render_report.render(render_report.load(root))
    committed = report_path.read_text(encoding="utf-8")
    if rendered != committed:
        # first differing line, for a useful failure message
        r_lines, c_lines = rendered.splitlines(), committed.splitlines()
        for i, (r, c) in enumerate(zip(r_lines, c_lines)):
            if r != c:
                return (f"REPORT.md is not the canonical render of its inputs "
                        f"(first diff at line {i + 1}):\n  rendered: {r!r}\n  committed: {c!r}")
        return (f"REPORT.md is not the canonical render of its inputs "
                f"(length differs: rendered {len(r_lines)} lines vs committed {len(c_lines)})")
    return None


def check_mirror_hash(
    mirror_dir: Path = MIRROR,
    upstream_path: Path | None = None,
) -> str | None:
    upstream = upstream_path or (
        REPO_ROOT / "apps/ios/Capability/Core/Recognition/IngredientCatalogResolver.swift"
    )
    mirror_file = mirror_dir / "IngredientCatalogResolver.swift"
    if not upstream.exists():
        return f"production resolver missing at {upstream}"
    if not mirror_file.exists():
        return f"mirrored production copy missing at {mirror_file} — run Scripts/refresh.sh"
    import hashlib

    def sha(p: Path) -> str:
        return hashlib.sha256(p.read_bytes()).hexdigest()

    # parse the generated manifest (it is Swift, not JSON)
    text = (mirror_dir / "SourceManifest.swift").read_text(encoding="utf-8")
    pinned_hash = None
    for line in text.splitlines():
        stripped = line.strip()
        if stripped.startswith('"IngredientCatalogResolver.swift"'):
            pinned_hash = stripped.split('"')[3]
    if pinned_hash is None:
        return "SourceManifest.swift: pinned hash not found"
    if sha(upstream) != pinned_hash:
        return (f"pinned hash {pinned_hash} != production sha256 {sha(upstream)} — "
                f"mirror stale relative to the repository file, rerun Scripts/refresh.sh")
    if sha(mirror_file) != pinned_hash:
        return "committed mirror copy differs from the pinned hash"
    return None


def check_grdb_python_side(diff_dir: Path = DIFF_DIR) -> list[str]:
    """Port answers regenerate byte-identically; differential is zero."""
    problems: list[str] = []
    sys.path.insert(0, str(diff_dir))
    import grdb_diff

    fresh = grdb_diff.port_rows()
    fresh_text = "".join(json.dumps(r, sort_keys=True) + "\n" for r in fresh)
    committed_text = (diff_dir / "python_catalog_results.jsonl").read_text(encoding="utf-8")
    if fresh_text != committed_text:
        problems.append("python_catalog_results.jsonl does not match a fresh port run")
    replay = [json.loads(line) for line in
              (diff_dir / "grdb_replay_results.jsonl").read_text(encoding="utf-8").splitlines()]
    probes = [json.loads(line) for line in
              (diff_dir / "probes.jsonl").read_text(encoding="utf-8").splitlines()]
    if [(r["kind"], r["input"]) for r in replay] != [(p["kind"], p["input"]) for p in probes]:
        problems.append("grdb_replay_results.jsonl does not answer probes.jsonl in order")
    n_diff = 0
    for i, (mine, theirs) in enumerate(zip(fresh, replay)):
        for key in sorted(set(mine) - {"kind", "input"}):
            if mine.get(key) != theirs.get(key):
                n_diff += 1
                problems.append(f"GRDB/port diff row {i} ({theirs['kind']}:{theirs['input']!r}) {key}: "
                                f"grdb={theirs.get(key)!r} python={mine.get(key)!r}")
    if n_diff:
        problems.append(f"GRDB replay differs from the Python port in {n_diff} fields")
    return problems


def check_grdb_swift(swift_bin: str) -> list[str]:
    """Re-execute the Swift replay and byte-compare against committed outputs."""
    problems: list[str] = []
    with tempfile.TemporaryDirectory() as tmp:
        out = Path(tmp) / "grdb_replay_results.jsonl"
        meta = Path(tmp) / "grdb_replay_meta.json"
        proc = subprocess.run(
            [swift_bin, "run", "--package-path", str(PACKAGE), "CatalogResolverReplay",
             "--db", str(REPO_ROOT / "apps/ios/Resources/usda_ingredient_catalog.sqlite"),
             "--probes", str(DIFF_DIR / "probes.jsonl"),
             "--out", str(out), "--meta", str(meta)],
            capture_output=True, text=True,
        )
        if proc.returncode != 0:
            problems.append(f"swift replay failed: {proc.stderr[-400:]}")
            return problems
        if out.read_text(encoding="utf-8") != (DIFF_DIR / "grdb_replay_results.jsonl").read_text(encoding="utf-8"):
            problems.append("grdb_replay_results.jsonl does not match a fresh Swift replay run")
        committed_meta = json.loads((DIFF_DIR / "grdb_replay_meta.json").read_text())
        fresh_meta = json.loads(meta.read_text())
        if fresh_meta != committed_meta:
            problems.append("grdb_replay_meta.json does not match a fresh Swift replay run")
    return problems


def check_probes_current() -> str | None:
    proc = subprocess.run(
        [sys.executable, str(DIFF_DIR / "extract_probes.py"), "--check"],
        capture_output=True, text=True,
    )
    if proc.returncode != 0:
        return f"probes.jsonl is stale vs main.swift: {proc.stdout} {proc.stderr}"
    return None


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--skip-swift", action="store_true",
                        help="skip re-executing the Swift replay (Python-side checks still run; "
                             "verification is then NOT complete without the Swift check)")
    parser.add_argument("--swift-bin", default="swift")
    args = parser.parse_args()

    problems: list[str] = []

    with tempfile.TemporaryDirectory() as td:
        problems.extend(check_rescoring(Path(td)))

    for name, check in [
        ("report regeneration", check_report_bytes),
        ("mirror hash", check_mirror_hash),
        ("probes currency", check_probes_current),
    ]:
        result = check()
        if result:
            problems.append(result)
    problems.extend(check_grdb_python_side())
    if args.skip_swift:
        print("NOTE: --skip-swift: the Swift GRDB replay was NOT re-executed; "
              "verification is incomplete without it")
    else:
        problems.extend(check_grdb_swift(args.swift_bin))

    if problems:
        print("FAILED:")
        for p in problems:
            print(" -", p)
        raise SystemExit(1)
    if args.skip_swift:
        print("VERIFIED (partially — rerun without --skip-swift): rescoring deterministic, "
              "full report regenerates byte-for-byte, port answers and probe list current")
    else:
        print("VERIFIED: rescoring deterministic; REPORT.md regenerates byte-for-byte; "
              "GRDB replay re-executed with zero diffs; mirror and probe hashes intact")


if __name__ == "__main__":
    main()
