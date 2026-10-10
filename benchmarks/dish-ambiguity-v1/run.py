#!/usr/bin/env python3
"""Run the pinned Food-101 classifiers over a dish-ambiguity manifest (CPU).

Usage:
    python3 benchmarks/dish-ambiguity-v1/run.py \
        --manifest benchmarks/dish-ambiguity-v1/manifest.json \
        --dataset-root /path/to/food-101 \
        --out benchmarks/dish-ambiguity-v1/results

Runs both pinned models (revisions + weight sha256 frozen below) over every
manifest image, on CPU. Per-image failures are recorded and retained, never
silently dropped. Writes one predictions file per model plus run-metadata.json
with versions, revisions, weight hashes, dataset tarball sha256, actual latency
and peak memory.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import platform
import time
from pathlib import Path

import numpy as np
import torch
import transformers
from PIL import Image

BENCH_DIR = Path(__file__).resolve().parent
REPO_ROOT = BENCH_DIR.parents[1]


def canonical_path(p: Path) -> str:
    """Repo-relative path when inside the checkout; bare name otherwise."""
    try:
        return str(p.resolve().relative_to(REPO_ROOT))
    except ValueError:
        return p.name

MODELS = {
    "vit-base-food101": {
        "repo": "nateraw/vit-base-food101",
        "revision": "55859a2a13495f714060e34f150031e616fce549",
        "weights_sha256": "61f707d9d423461b8d1b8fc5cfc2500d0cc34675c19d3e91ae97b282fc925a95",
    },
    "mobilenet-v2-food101": {
        "repo": "rajkr/mobilenet-v2-food101",
        "revision": "0dea82e70d00f786f2029d8487d845a5cfc2d64a",
        "weights_sha256": "4f972e3ea524f678eb42e41498cf76539a567d086cd9ac12b86fa6d9f4ca0eef",
    },
}


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def verify_weight(repo: str, revision: str, expected: str) -> str:
    """Download pinned weights and verify the sha256 before loading them."""
    from huggingface_hub import hf_hub_download
    local = Path(hf_hub_download(repo, "model.safetensors", revision=revision))
    actual = sha256_file(local)
    if actual != expected:
        raise SystemExit(f"weight hash mismatch for {repo}: expected {expected}, got {actual}")
    return actual


def load_model(tag: str, device: str):
    from transformers import AutoImageProcessor, AutoModelForImageClassification
    m = MODELS[tag]
    verify_weight(m["repo"], m["revision"], m["weights_sha256"])
    proc = AutoImageProcessor.from_pretrained(m["repo"], revision=m["revision"])
    model = AutoModelForImageClassification.from_pretrained(m["repo"], revision=m["revision"])
    model.to(device).eval()
    return proc, model


def run_model(tag: str, images: list[dict], dataset_root: Path, device: str) -> dict:
    proc, model = load_model(tag, device)
    id2label = {int(i): lbl for i, lbl in model.config.id2label.items()}

    preds, failures = [], []
    latencies = []
    with torch.no_grad():
        for img in images:
            path = dataset_root / img["path"]
            try:
                t0 = time.perf_counter()
                with Image.open(path) as im:
                    inputs = proc(im, return_tensors="pt").to(device)
                logits = model(**inputs).logits[0]
                probs = torch.softmax(logits, dim=-1).cpu().numpy()
                dt = time.perf_counter() - t0
            except Exception as exc:  # failures retained, never dropped
                failures.append({"path": img["path"], "class": img["class"],
                                 "error": f"{type(exc).__name__}: {exc}"})
                continue
            latencies.append(dt)
            top = np.argsort(probs)[::-1][:5]
            preds.append({
                "path": img["path"],
                "class": img["class"],
                "top1Label": id2label[int(top[0])],
                "top1Prob": float(probs[top[0]]),
                "top5": [{"label": id2label[int(i)], "prob": float(probs[i])} for i in top],
                "latencyMs": round(dt * 1000, 3),
            })

    # model-level sanitation: empty runs are a failure, not a pass
    if not preds and not failures:
        raise SystemExit(f"run: model {tag} produced no predictions and no failures")

    return {"predictions": preds, "failures": failures, "latencies": latencies}


def main() -> int:
    import resource

    ap = argparse.ArgumentParser()
    ap.add_argument("--manifests", nargs="+",
                    default=[str(BENCH_DIR / "manifest.json"), str(BENCH_DIR / "dev_manifest.json")])
    ap.add_argument("--dataset-root", required=True)
    ap.add_argument("--out", default=str(BENCH_DIR / "results"))
    ap.add_argument("--models", nargs="*", default=sorted(MODELS))
    ap.add_argument("--device", default="cpu")
    args = ap.parse_args()

    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    dataset_root = Path(args.dataset_root)

    manifests = {}
    for mp in args.manifests:
        path = Path(mp)
        manifests[path.stem if path.stem != "manifest" else "test"] = {
            "path": canonical_path(path),
            "sha256": sha256_file(path),
        }

    tarball = dataset_root.parent / "food-101.tar.gz"
    tarball_sha = sha256_file(tarball) if tarball.exists() else None

    started = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    rss0 = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss

    for tag in args.models:
        if tag not in MODELS:
            raise SystemExit(f"run: unknown model tag {tag!r}")
        for stem, minfo in sorted(manifests.items()):
            mdata = json.loads(Path(minfo["path"]).read_text())
            result = run_model(tag, mdata["images"], dataset_root, args.device)
            (out / f"predictions-{stem}-{tag}.json").write_text(json.dumps({
                "schemaVersion": "dish-ambiguity-predictions-v1",
                "model": tag, **MODELS[tag],
                "manifest": minfo["path"],
                "manifestSha256": minfo["sha256"],
                "device": args.device,
                "numImages": len(mdata["images"]),
                "numPredictions": len(result["predictions"]),
                "numFailures": len(result["failures"]),
                "predictions": result["predictions"],
                "failures": result["failures"],
            }, indent=1))
            lat = result["latencies"]
            print(f"run: {stem}/{tag}: {len(result['predictions'])} predictions, "
                  f"{len(result['failures'])} failures, "
                  f"latency mean {np.mean(lat)*1000:.1f} ms / median {np.median(lat)*1000:.1f} ms / p95 "
                  f"{np.percentile(lat, 95)*1000:.1f} ms", flush=True)

    meta = {
        "schemaVersion": "dish-ambiguity-run-metadata-v1",
        "startedUtc": started,
        "finishedUtc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "device": args.device,
        "python": platform.python_version(),
        "torch": torch.__version__,
        "transformers": transformers.__version__,
        "numpy": np.__version__,
        "torchNumThreads": torch.get_num_threads(),
        "datasetTarball": {"path": canonical_path(tarball) if tarball.exists() else None,
                            "sha256": tarball_sha},
        "models": MODELS,
        "peakRssKb": max(resource.getrusage(resource.RUSAGE_SELF).ru_maxrss, rss0),
        "manifests": manifests,
    }
    (out / "run-metadata.json").write_text(json.dumps(meta, indent=1))
    print(f"run: metadata written (peak RSS {meta['peakRssKb'] / 1e6:.2f} GB, "
          f"tarball sha256 {'recorded' if tarball_sha else 'NOT RECORDED - tarball missing'})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
