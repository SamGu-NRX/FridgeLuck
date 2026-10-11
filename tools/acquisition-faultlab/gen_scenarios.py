"""Generate tools/acquisition-faultlab/scenarios.json with exact expected records.

Every scenario pins the synthetic payload by (seed, size) and records the
sha256/size of (a) the correct full content and (b) the bytes the fixture
actually puts on the wire. The file is committed; run.py and the tests
re-derive every digest from these fields and refuse to run on mismatch.

Dish IDs are real rows from experiments/nutrition5k-portion/data/dish_targets.csv
(official RGB / depth splits) so the PR41 availability gate accepts them, but
all payloads are synthetic and served from loopback only.
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

from fixture_server import corrupt_bytes, sha256_hex, synthetic_content

RGB_DISHES = ["dish_1550704750", "dish_1550704903", "dish_1550705288", "dish_1550705370"]
DEPTH_DISHES = ["dish_1556572657", "dish_1556573514", "dish_1556575014", "dish_1556575083"]

OUT = Path(__file__).resolve().parent / "scenarios.json"


def scenario(sid: str, fault: str, dish: str, fname: str, seed: str, size: int,
             serve: dict, *, served_bytes: bytes | None = None, preseed: str | None = None) -> dict:
    content = synthetic_content(seed, size)
    rec = {
        "id": sid,
        "fault": fault,
        "dish_id": dish,
        "file": fname,
        "content": {"seed": seed, "size": size},
        "serve": serve,
        "expect": {
            "content_sha256": sha256_hex(content),
            "content_size": size,
            "served_sha256": sha256_hex(served_bytes) if served_bytes is not None else sha256_hex(content),
            "served_size": len(served_bytes) if served_bytes is not None else size,
        },
    }
    if preseed:
        rec["harness"] = {"preseed": preseed}
    return rec


def build() -> list[dict]:
    scenarios = [
        scenario("clean-rgb-control", "clean", RGB_DISHES[0], "rgb.png",
                 "faultlab/clean-rgb-control", 2048, {}),
        scenario("truncation-rgb-clean-eof", "truncation", RGB_DISHES[1], "rgb.png",
                 "faultlab/truncation-rgb", 2048, {"truncate_at_bytes": 1024, "end": "eof"},
                 served_bytes=synthetic_content("faultlab/truncation-rgb", 2048)[:1024]),
        scenario("truncation-depth-clean-eof", "truncation", DEPTH_DISHES[0], "depth_raw.png",
                 "faultlab/truncation-depth", 1536, {"truncate_at_bytes": 614, "end": "eof"},
                 served_bytes=synthetic_content("faultlab/truncation-depth", 1536)[:614]),
        scenario("interrupted-write-rgb-rst", "truncation", RGB_DISHES[2], "rgb.png",
                 "faultlab/interrupted-rgb", 2048, {"truncate_at_bytes": 512, "end": "rst"},
                 served_bytes=synthetic_content("faultlab/interrupted-rgb", 2048)[:512]),
        scenario("wrong-content-length-understated", "wrong_content_length", RGB_DISHES[3], "rgb.png",
                 "faultlab/wcl-under", 2048, {"length_delta": -256}),
        scenario("wrong-content-length-overstated", "wrong_content_length", RGB_DISHES[0], "rgb.png",
                 "faultlab/wcl-over", 1536, {"length_delta": 512}),
        scenario("wrong-content-type-html", "wrong_content_type", RGB_DISHES[1], "rgb.png",
                 "faultlab/wct-html", 2048, {"content_type": "text/html; charset=utf-8"}),
        scenario("wrong-hash-same-size-depth", "wrong_hash", DEPTH_DISHES[1], "depth_raw.png",
                 "faultlab/wrong-hash-depth", 1536, {"corrupt_at_bytes": 1024},
                 served_bytes=corrupt_bytes(synthetic_content("faultlab/wrong-hash-depth", 1536), 1024)),
        scenario("redirect-one-hop", "redirect", RGB_DISHES[2], "rgb.png",
                 "faultlab/redirect-1", 2048, {"hops": 1}),
        scenario("redirect-three-hops", "redirect", RGB_DISHES[3], "rgb.png",
                 "faultlab/redirect-3", 2048, {"hops": 3}),
        scenario("redirect-final-404", "redirect", RGB_DISHES[0], "rgb.png",
                 "faultlab/redirect-404", 1536, {"hops": 1, "final_404": True}),
        scenario("empty-depth-raw", "empty", DEPTH_DISHES[2], "depth_raw.png",
                 "faultlab/empty-depth", 1536, {},
                 served_bytes=b""),
        scenario("transient-503-recovers", "transient_status", RGB_DISHES[1], "rgb.png",
                 "faultlab/transient-503", 2048, {"status": 503, "fail_times": 2}),
        scenario("transient-429-exhausted", "transient_status", RGB_DISHES[2], "rgb.png",
                 "faultlab/transient-429", 1536, {"status": 429, "fail_times": 4}),
        scenario("stale-cache-manifest-skip", "clean", DEPTH_DISHES[3], "depth_raw.png",
                 "faultlab/stale-skip", 2048, {}, preseed="stale_manifest_ok"),
        scenario("stale-cache-partial-overwrite", "clean", DEPTH_DISHES[0], "depth_raw.png",
                 "faultlab/stale-partial", 2048, {}, preseed="partial_file"),
    ]
    return scenarios


def counts(scenarios: list[dict]) -> dict:
    by_fault: dict[str, int] = {}
    for s in scenarios:
        family = "truncation_rst" if s["fault"] == "truncation" and s["serve"].get("end") == "rst" else s["fault"]
        by_fault[family] = by_fault.get(family, 0) + 1
    return {"total": len(scenarios), "by_fault": dict(sorted(by_fault.items()))}


def main() -> None:
    import argparse

    ap = argparse.ArgumentParser(description="Faultlab scenario manifest generator")
    ap.add_argument("--check", action="store_true",
                    help="verify the committed manifest matches the generator; exit 1 on drift")
    args = ap.parse_args()

    scenarios = build()
    payload = {
        "schema": "acquisition-faultlab/scenarios@1",
        "loopback_only": True,
        "description": "Synthetic loopback fault fixtures with exact expected final-byte records",
        "counts": counts(scenarios),
        "scenarios": scenarios,
    }
    if args.check:
        committed = json.loads(OUT.read_text())
        if committed != payload:
            print("manifest drift detected: regenerating would change scenarios.json", file=sys.stderr)
            raise SystemExit(1)
        print(f"manifest up to date: {OUT} ({counts(scenarios)['total']} scenarios)")
        return
    OUT.write_text(json.dumps(payload, indent=2, sort_keys=False) + "\n")
    print(f"wrote {OUT} with {counts(scenarios)}")


if __name__ == "__main__":
    main()
