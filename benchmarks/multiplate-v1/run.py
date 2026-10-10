#!/usr/bin/env python3
"""Multi-plate benchmark runner: does a detector see which dish is where,
while whole-image classification cannot?

Arms (per image, all offline CPU, deterministic, pinned):

  detector        DETR-ResNet-50 (facebook/detr-resnet-50, HF revision pinned
                  below), CPU eval mode. COCO classes mapped to the manifest's
                  Open Images eval classes with a documented table. Sees boxes.
  proposals       Whole-image classification (the app-shaped pipeline) plus
                  AUTOMATIC region proposals: Felzenszwalb segments + a
                  multi-scale grid, classified zero-shot with pinned CLIP
                  ViT-B-32 (laion2b_s34b_b79k, same checkpoint as
                  experiments/ingredient-recognition). Automatic predictions
                  NEVER see ground-truth boxes.
  oracle-crops    SEPARATELY-LABELLED UPPER BOUND: the same classifier on the
                  ground-truth boxes. Oracle crops see target boxes by
                  construction; never compared head-to-head with automatic
                  predictions as if fair.

Metrics (computed by score.py): IoU 0.5 matching (optimal assignment), missed
small regions, duplicate detections, category confusion, region-count error.

NOTE: GT food boxes count food categories, not servings or plates; no
plate/serving ground truth exists in this dataset and none is claimed.

Usage (from repo root):
  python3 benchmarks/multiplate-v1/run.py --manifest benchmarks/multiplate-v1/manifest.json \
      --out benchmarks/multiplate-v1/results
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import time
import traceback
from collections import defaultdict
from pathlib import Path

# force offline: all weights must come from the local cache
os.environ.setdefault("HF_HUB_OFFLINE", "1")
os.environ.setdefault("TRANSFORMERS_OFFLINE", "1")

HERE = Path(__file__).resolve().parent
POOL_DIR = Path("/home/user/work/bench/multiplate-images")

# ---- pinned configuration (recorded verbatim into results/run_config.json) ----
PINNED = {
    "detector": {
        "model": "facebook/detr-resnet-50",
        "revision": "1d5f47bd3bdd2c4bbfa585418ffe6da5028b4c0b",
        "score_threshold": 0.30,
        "device": "cpu",
    },
    "classifier": {
        "model": "ViT-B-32",
        "pretrained": "laion2b_s34b_b79k",
        "food_prob_threshold": 0.20,
        "absorber_margin": 0.0,
        "nms_class_iou": 0.5,
        "nms_cross_iou": 0.7,
        "prompts": "a photo of {name}",
    },
    "proposals": {
        "felzenszwalb": {"scale": 100, "sigma": 0.8, "min_size": 200},
        "min_segment_area_frac": 0.005,
        "grid_scales": [0.35, 0.55, 0.8],
        "grid_positions": 3,
        "max_proposals": 120,
    },
    "absorber_prompts": [
        "a photo of a kitchen counter",
        "a photo of a wooden table",
        "a photo of an empty plate",
        "a photo of a person",
        "a photo of a restaurant interior",
    ],
    # COCO -> Open Images eval class; absent keys are dropped (documented
    # limitation: the detector covers only these classes)
    "detector_class_map": {
        "banana": "Fruit",
        "apple": "Apple",
        "orange": "Orange",
        "sandwich": "Sandwich",
        "broccoli": "Vegetable",
        "carrot": "Vegetable",
        "hot dog": "Fast food",
        "pizza": "Pizza",
        "donut": "Dessert",
        "cake": "Cake",
    },
    "libs": {},
}

SMALL_REGION_FRAC = 0.04  # "small region" = GT box < 4% of image area


def lib_versions() -> dict:
    import numpy
    import open_clip
    import PIL
    import scipy
    import skimage
    import torch
    import torchvision
    import transformers

    return {
        "numpy": numpy.__version__,
        "pillow": PIL.__version__,
        "scipy": scipy.__version__,
        "scikit-image": skimage.__version__,
        "torch": torch.__version__,
        "torchvision": torchvision.__version__,
        "transformers": transformers.__version__,
        "open_clip": open_clip.__version__,
    }


# ---------------------------------------------------------------------------
# Arms
# ---------------------------------------------------------------------------


class DetectorArm:
    """Pinned DETR on CPU, COCO classes mapped to eval classes."""

    arm = "detector"

    def __init__(self, eval_classes: set[str]):
        from transformers import AutoImageProcessor, DetrForObjectDetection

        self.processor = AutoImageProcessor.from_pretrained(
            PINNED["detector"]["model"], revision=PINNED["detector"]["revision"]
        )
        self.model = DetrForObjectDetection.from_pretrained(
            PINNED["detector"]["model"], revision=PINNED["detector"]["revision"]
        )
        self.model.eval()
        self.id2label = self.model.config.id2label
        self.class_map = PINNED["detector_class_map"]
        self.threshold = PINNED["detector"]["score_threshold"]
        self.eval_classes = eval_classes

    def run(self, img) -> list[dict]:
        import torch

        inputs = self.processor(images=img, return_tensors="pt")
        with torch.inference_mode():
            outputs = self.model(**inputs)
        target_sizes = torch.tensor([[img.height, img.width]])
        results = self.processor.post_process_object_detection(
            outputs, threshold=self.threshold, target_sizes=target_sizes
        )[0]
        dets = []
        for score, label, box in zip(results["scores"], results["labels"], results["boxes"]):
            coco_name = self.id2label[int(label)]
            mapped = self.class_map.get(coco_name)
            if mapped is None or mapped not in self.eval_classes:
                continue
            x0, y0, x1, y1 = box.tolist()
            dets.append(
                {
                    "label": mapped,
                    "coco_label": coco_name,
                    "box": [x0 / img.width, y0 / img.height, x1 / img.width, y1 / img.height],
                    "confidence": float(score),
                }
            )
        return dets


class ClipClassifier:
    """Pinned CLIP ViT-B-32 zero-shot over the eval classes + absorbers."""

    def __init__(self, eval_names: list[str]):
        import open_clip
        import torch

        self.torch = torch
        self.model, _, self.preprocess = open_clip.create_model_and_transforms(
            "ViT-B-32", pretrained="laion2b_s34b_b79k"
        )
        self.model.eval()
        self.tokenizer = open_clip.get_tokenizer("ViT-B-32")
        self.class_names = list(eval_names)
        prompts = [f"a photo of {n}" for n in self.class_names] + PINNED["absorber_prompts"]
        with torch.inference_mode():
            text = self.tokenizer(prompts)
            self.text_emb = self.model.encode_text(text)
            self.text_emb = self.text_emb / self.text_emb.norm(dim=-1, keepdim=True)
        self.n_food = len(self.class_names)

    def probs(self, crops: list) -> list[tuple[int | None, float]]:
        """Returns [(best_food_class_index or None, best_food_prob)] per crop."""
        import torch

        if not crops:
            return []
        batch = torch.stack([self.preprocess(c) for c in crops])
        out = []
        with torch.inference_mode():
            for i in range(0, len(batch), 64):
                chunk = batch[i : i + 64]
                emb = self.model.encode_image(chunk)
                emb = emb / emb.norm(dim=-1, keepdim=True)
                logits = (100.0 * emb @ self.text_emb.T).softmax(dim=-1)
                food_probs = logits[:, : self.n_food]
                absorber_probs = logits[:, self.n_food :]
                best_conf, best_idx = food_probs.max(dim=-1)
                best_abs = absorber_probs.max(dim=-1).values
                for conf, idx, ab in zip(best_conf, best_idx, best_abs):
                    threshold = PINNED["classifier"]["food_prob_threshold"]
                    margin = PINNED["classifier"]["absorber_margin"]
                    if float(conf) >= threshold and float(conf) > float(ab) + margin:
                        out.append((int(idx), float(conf)))
                    else:
                        out.append((None, float(conf)))
        return out


class ProposalsArm:
    """Whole-image classification + automatic region proposals (no GT access)."""

    arm = "proposals"

    def __init__(self, eval_names: list[str]):
        self.clf = ClipClassifier(eval_names)

    def propose(self, img) -> list[tuple[int, int, int, int]]:
        import numpy as np
        from skimage.segmentation import felzenszwalb

        cfg = PINNED["proposals"]
        arr = np.asarray(img.convert("RGB"))
        h, w = arr.shape[:2]
        boxes = [(0, 0, w, h)]
        seg = felzenszwalb(
            arr,
            scale=cfg["felzenszwalb"]["scale"],
            sigma=cfg["felzenszwalb"]["sigma"],
            min_size=cfg["felzenszwalb"]["min_size"],
        )
        min_area = cfg["min_segment_area_frac"] * h * w
        for label_id in np.unique(seg):
            ys, xs = np.where(seg == label_id)
            if len(ys) < min_area:
                continue
            boxes.append((int(xs.min()), int(ys.min()), int(xs.max()) + 1, int(ys.max()) + 1))
        for s in cfg["grid_scales"]:
            wh, hh = int(w * s), int(h * s)
            for gy in range(cfg["grid_positions"]):
                for gx in range(cfg["grid_positions"]):
                    x0 = int(gx * (w - wh) / (cfg["grid_positions"] - 1))
                    y0 = int(gy * (h - hh) / (cfg["grid_positions"] - 1))
                    boxes.append((x0, y0, x0 + wh, y0 + hh))
        kept: list[tuple[int, int, int, int]] = []
        for b in boxes:
            area_b = max(1, (b[2] - b[0]) * (b[3] - b[1]))
            dup = False
            for k in kept:
                inter = max(0, min(b[2], k[2]) - max(b[0], k[0])) * max(
                    0, min(b[3], k[3]) - max(b[1], k[1])
                )
                union = area_b + max(1, (k[2] - k[0]) * (k[3] - k[1])) - inter
                if union > 0 and inter / union > 0.95:
                    dup = True
                    break
            if not dup:
                kept.append(b)
        return kept[: cfg["max_proposals"]]

    def run(self, img) -> list[dict]:
        import torch
        from torchvision.ops import nms

        w, h = img.size
        boxes = self.propose(img)
        crops = [img.crop(b) for b in boxes]
        preds = self.clf.probs(crops)
        kept = []
        for (fx, fy, fxx, fyy), (cls_idx, conf) in zip(boxes, preds):
            if cls_idx is None:
                continue
            kept.append(
                {
                    "label": self.clf.class_names[cls_idx],
                    "box": [fx / w, fy / h, fxx / w, fyy / h],
                    "confidence": conf,
                }
            )
        if not kept:
            return []
        boxes_t = torch.tensor([d["box"] for d in kept])
        scores_t = torch.tensor([d["confidence"] for d in kept])
        labels = [d["label"] for d in kept]
        keep_global = []
        for cls in sorted(set(labels)):
            idx = [i for i, l in enumerate(labels) if l == cls]
            keep = nms(boxes_t[idx], scores_t[idx], PINNED["classifier"]["nms_class_iou"])
            keep_global.extend(idx[i] for i in keep.tolist())
        sub = [kept[i] for i in sorted(keep_global)]
        boxes_t = torch.tensor([d["box"] for d in sub])
        scores_t = torch.tensor([d["confidence"] for d in sub])
        keep = nms(boxes_t, scores_t, PINNED["classifier"]["nms_cross_iou"])
        return [sub[i] for i in sorted(keep.tolist())]


class OracleArm:
    """UPPER BOUND ONLY: classifier on ground-truth boxes (sees target boxes)."""

    arm = "oracle-crops"

    def __init__(self, eval_names: list[str]):
        self.clf = ClipClassifier(eval_names)

    def run(self, img, boxes: list[dict]) -> list[dict]:
        w, h = img.size
        crops = []
        for b in boxes:
            x0, y0 = int(b["xmin"] * w), int(b["ymin"] * h)
            x1, y1 = int(b["xmax"] * w), int(b["ymax"] * h)
            crops.append(img.crop((x0, y0, max(x1, x0 + 1), max(y1, y0 + 1))))
        preds = self.clf.probs(crops)
        out = []
        for b, (cls_idx, conf) in zip(boxes, preds):
            if cls_idx is None:
                continue
            out.append(
                {
                    "label": self.clf.class_names[cls_idx],
                    "gt_label": b["label_name"],
                    "gt_box": [b["xmin"], b["ymin"], b["xmax"], b["ymax"]],
                    "box": [b["xmin"], b["ymin"], b["xmax"], b["ymax"]],
                    "confidence": conf,
                }
            )
        return out


# ---------------------------------------------------------------------------


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--manifest", type=Path, required=True)
    ap.add_argument("--out", type=Path, required=True)
    ap.add_argument("--arms", default="detector,proposals,oracle-crops")
    ap.add_argument("--limit", type=int, default=0, help="debug: first N images")
    args = ap.parse_args()

    manifest = json.loads(args.manifest.read_text())
    eval_names = [c["name"] for c in manifest["classes"]]
    eval_classes = set(eval_names)
    args.out.mkdir(parents=True, exist_ok=True)
    PINNED["libs"] = lib_versions()

    images = manifest["images"]
    if args.limit:
        images = images[: args.limit]

    arms = args.arms.split(",")
    instances = {}
    if "detector" in arms:
        instances["detector"] = DetectorArm(eval_classes)
    if "proposals" in arms:
        instances["proposals"] = ProposalsArm(eval_names)
    if "oracle-crops" in arms:
        instances["oracle-crops"] = OracleArm(eval_names)

    (args.out / "run_config.json").write_text(
        json.dumps(
            {
                "pinned": PINNED,
                "manifest_sha256": hashlib.sha256(args.manifest.read_bytes()).hexdigest(),
                "images": len(images),
                "small_region_frac": SMALL_REGION_FRAC,
                "note": "oracle-crops sees target boxes; upper bound only. "
                "GT food boxes count categories, not servings or plates.",
            },
            indent=1,
        )
    )

    # Resume support: reopen existing outputs in append mode and skip
    # image/arm pairs already recorded. A resumed run's host timing covers
    # only newly processed images.
    done: dict[str, set] = {a: set() for a in instances}
    for a in instances:
        p = args.out / f"predictions_{a}.jsonl"
        if p.exists():
            for line in p.read_text().splitlines():
                try:
                    done[a].add(json.loads(line)["image_id"])
                except Exception:  # noqa: BLE001
                    pass

    outs = {a: open(args.out / f"predictions_{a}.jsonl", "a") for a in instances}  # noqa: SIM115
    failures = open(args.out / "failures.jsonl", "a")  # noqa: SIM115
    timing = {a: [] for a in instances}
    error_counts: dict[str, int] = defaultdict(int)

    try:
        from PIL import Image

        for n, im in enumerate(images):
            if all(im["image_id"] in done[a] for a in instances):
                continue
            try:
                img = Image.open(POOL_DIR / f"{im['image_id']}.jpg").convert("RGB")
            except Exception as exc:  # noqa: BLE001
                failures.write(
                    json.dumps({"image_id": im["image_id"], "arm": "decode", "error": str(exc)}) + "\n"
                )
                continue

            for arm, inst in instances.items():
                if im["image_id"] in done[arm]:
                    continue
                t0 = time.perf_counter()
                try:
                    if arm == "oracle-crops":
                        dets = inst.run(img, im["boxes"])
                    else:
                        dets = inst.run(img)
                    elapsed = (time.perf_counter() - t0) * 1000.0
                    timing[arm].append(elapsed)
                    outs[arm].write(
                        json.dumps(
                            {
                                "image_id": im["image_id"],
                                "role": im["role"],
                                "detections": dets,
                                "elapsed_ms": round(elapsed, 2),
                            }
                        )
                        + "\n"
                    )
                    outs[arm].flush()
                except Exception as exc:  # noqa: BLE001
                    elapsed = (time.perf_counter() - t0) * 1000.0
                    error_counts[arm] += 1
                    failures.write(
                        json.dumps(
                            {
                                "image_id": im["image_id"],
                                "arm": arm,
                                "error": str(exc),
                                "trace": traceback.format_exc(limit=3)[-400:],
                                "elapsed_ms": round(elapsed, 2),
                            }
                        )
                        + "\n"
                    )
            if (n + 1) % 25 == 0:
                for f in outs.values():
                    f.flush()
                failures.flush()
                print(f"  {n + 1}/{len(images)} images done", flush=True)
    finally:
        for f in list(outs.values()) + [failures]:
            f.close()

    timing_summary = {}
    for arm, values in timing.items():
        if values:
            values_sorted = sorted(values)
            timing_summary[arm] = {
                "images": len(values),
                "mean_ms": round(sum(values) / len(values), 2),
                "median_ms": round(values_sorted[len(values_sorted) // 2], 2),
                "p90_ms": round(values_sorted[int(len(values_sorted) * 0.9)], 2),
                "max_ms": round(values_sorted[-1], 2),
                "errors": error_counts.get(arm, 0),
            }
    (args.out / "host_timing.json").write_text(json.dumps(timing_summary, indent=1))
    print(json.dumps(timing_summary, indent=1))


if __name__ == "__main__":
    main()
