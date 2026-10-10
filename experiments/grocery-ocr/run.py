#!/usr/bin/env python3
"""Run the grocery label OCR study end to end.

    python3 experiments/grocery-ocr/run.py \
        --manifest experiments/grocery-ocr/manifest.json \
        --out experiments/grocery-ocr/results

Stages (each resumable, outputs land under the experiment dir):
  1. acquire (skipped when the manifest already exists)
       sample_products.py  -> data/manifest.csv + universe_counts.csv
       fetch_images.py     -> imgcache/ + data/image_hashes.csv
       ocr_baseline.py     -> data/ocr_lines.jsonl
       build_manifest.py   -> manifest.json (alignment classes, license, revision)
  2. check_manifest.py  — aborts the run on any manifest problem
  3. prepare inputs     — prepare_inputs.py -> results/inputs/*.jsonl
  4. swift replay       — builds the harness package against the REAL production
       recognition sources and records the exact commands; runs
       targets / ocr_front / ocr_ingredients / ocr_nutrition / reference arms
  5. score              — acquisition/score.py -> results/scores.json + per-product traces

If the Swift harness cannot build or run, stage 4 records catalog execution as
unavailable (results/catalog_availability.json), stages 1-3 and 5 still produce the
optical baseline, and scoring proceeds with empty harness arms. The Python side never
reimplements the production mapper — a missing Swift arm stays a missing arm.
"""
import argparse
import json
import os
import shutil
import subprocess
import sys
import time

ROOT = os.path.dirname(os.path.abspath(__file__))
ACQ = os.path.join(ROOT, "acquisition")
HARNESS = os.path.join(ROOT, "harness")
DATA = os.path.join(ROOT, "data")
CACHE = os.path.join(ROOT, "imgcache")


def run_cmd(cmd, env=None, capture=False):
    print("+", " ".join(cmd), flush=True)
    e = dict(os.environ)
    e.setdefault("PATH", os.environ["PATH"])
    if env:
        e.update(env)
    if capture:
        p = subprocess.run(cmd, env=e, capture_output=True, text=True)
        return p.returncode, p.stdout, p.stderr
    return subprocess.call(cmd, env=e)


def stage_acquire(manifest_path):
    if os.path.exists(manifest_path):
        print("stage acquire: manifest exists, skipping")
        return 0
    os.makedirs(DATA, exist_ok=True)
    rc = run_cmd(["python3", os.path.join(ACQ, "sample_products.py"), "--out-dir", DATA])
    if rc:
        return rc
    rc = run_cmd(["python3", os.path.join(ACQ, "fetch_images.py"),
                  "--manifest", os.path.join(DATA, "manifest.csv"),
                  "--cache", CACHE, "--out", os.path.join(DATA, "image_hashes.csv")])
    if rc:
        return rc
    rc = run_cmd(["python3", os.path.join(ACQ, "ocr_baseline.py"),
                  "--manifest", os.path.join(DATA, "manifest.csv"),
                  "--cache", CACHE, "--hashes", os.path.join(DATA, "image_hashes.csv"),
                  "--out", os.path.join(DATA, "ocr_lines.jsonl")])
    if rc:
        return rc
    return run_cmd(["python3", os.path.join(ROOT, "build_manifest.py"),
                    "--data-dir", DATA, "--out", manifest_path])


def stage_check(manifest_path):
    return run_cmd(["python3", os.path.join(ROOT, "check_manifest.py"),
                    "--manifest", manifest_path, "--cache", CACHE])


def stage_prepare(manifest_path, out):
    inputs = os.path.join(out, "inputs")
    os.makedirs(inputs, exist_ok=True)
    cmd = ["python3", os.path.join(ACQ, "prepare_inputs.py"), "--manifest", manifest_path,
           "--out-dir", inputs]
    traces = os.path.join(DATA, "ocr_lines.jsonl")
    if os.path.exists(traces):
        cmd += ["--ocr-traces", traces]
    return run_cmd(cmd)


def stage_swift(out, catalog):
    """Build + run the harness; record commands. Returns (ok, commands, log)."""
    env = {"PATH": f"{os.path.expanduser('~')}/.local/share/swiftly/bin:{os.environ.get('PATH', '')}",
           "LD_LIBRARY_PATH": "/usr/local/lib"}
    rc, _, err = run_cmd(["swift", "build"], env=env, capture=True)
    commands = []
    if rc != 0:
        with open(os.path.join(out, "swift_build_error.log"), "w") as f:
            f.write(err)
        return False, commands, err[-4000:]

    bin_ = os.path.join(HARNESS, ".build", "debug", "GroceryOCRHarness")
    arms = [
        ("targets", "targets_input.jsonl", "targets_output.jsonl", "targets"),
        ("reference", "reference_input.jsonl", "reference_output.jsonl", "reference"),
    ]
    for role in ("front", "ingredients", "nutrition"):
        src = f"harness_ocr_input_{role}.jsonl"
        if os.path.exists(os.path.join(out, "inputs", src)):
            arms.append((f"ocr_{role}", src, f"ocr_{role}_output.jsonl", "ocr"))

    harness_out = os.path.join(out, "harness")
    os.makedirs(harness_out, exist_ok=True)
    log = []
    for name, src, dst, mode in arms:
        cmd = ["swift", "run", "GroceryOCRHarness",
               "--catalog", catalog,
               "--input", os.path.join(out, "inputs", src),
               "--output", os.path.join(harness_out, dst),
               "--mode", mode]
        commands.append({"arm": name, "cmd": " ".join(cmd)})
        rc, stdout, stderr = run_cmd(cmd, env=env, capture=True)
        log.append(f"### {name} rc={rc}\n{stderr[-2000:]}")
        if rc != 0:
            with open(os.path.join(out, "swift_run_error.log"), "w") as f:
                f.write("\n".join(log))
            return False, commands, "\n".join(log)
    with open(os.path.join(out, "swift_replay_commands.txt"), "w") as f:
        for c in commands:
            f.write(c["cmd"] + "\n")
    return True, commands, "\n".join(log)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--manifest", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--catalog", default=os.path.join(ROOT, "..", "apps", "ios", "Resources",
                                                      "usda_ingredient_catalog.sqlite"))
    ap.add_argument("--skip-swift", action="store_true")
    args = ap.parse_args()

    os.makedirs(args.out, exist_ok=True)
    t0 = time.time()
    meta = {"stages": {}, "timings_note": "wall-clock seconds per stage"}

    rc = stage_acquire(args.manifest)
    meta["stages"]["acquire"] = rc
    if rc:
        print("acquisition failed", file=sys.stderr)
        return rc
    meta["stages"]["check"] = stage_check(args.manifest)
    if meta["stages"]["check"]:
        print("manifest check failed", file=sys.stderr)
        return meta["stages"]["check"]
    meta["stages"]["prepare"] = stage_prepare(args.manifest, args.out)
    if meta["stages"]["prepare"]:
        return meta["stages"]["prepare"]

    catalog_ok = os.path.exists(args.catalog)
    if args.skip_swift or not catalog_ok:
        with open(os.path.join(args.out, "catalog_availability.json"), "w") as f:
            json.dump({"available": False,
                       "reason": ("ingredient catalog not found at " + args.catalog) if not catalog_ok
                       else "--skip-swift requested"}, f, indent=1)
        meta["stages"]["swift"] = "skipped"
    else:
        ok, cmds, log = stage_swift(args.out, os.path.abspath(args.catalog))
        meta["stages"]["swift"] = "ok" if ok else "failed"
        meta["swift_commands"] = cmds
        if not ok:
            with open(os.path.join(args.out, "catalog_availability.json"), "w") as f:
                json.dump({"available": False,
                           "reason": "swift harness build/run failed — see swift_*_error.log; "
                                     "optical (tesseract line-extraction) numbers stand alone"}, f, indent=1)

    inputs = os.path.join(args.out, "inputs")
    harness_out = os.path.join(args.out, "harness")
    score_cmd = ["python3", os.path.join(ACQ, "score.py"),
                 "--manifest", os.path.join(DATA, "manifest.csv"),
                 "--targets", os.path.join(harness_out, "targets_output.jsonl"),
                 "--ocr", os.path.join(harness_out, "ocr_front_output.jsonl"),
                 "--reference", os.path.join(harness_out, "reference_output.jsonl"),
                 "--out-dir", args.out]
    meta["stages"]["score"] = run_cmd(score_cmd)

    meta["wall_seconds"] = round(time.time() - t0, 1)
    with open(os.path.join(args.out, "meta.json"), "w") as f:
        json.dump(meta, f, indent=1)
    print("run complete:", json.dumps(meta["stages"]))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
