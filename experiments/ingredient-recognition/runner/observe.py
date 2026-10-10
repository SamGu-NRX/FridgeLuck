#!/usr/bin/env python3
"""Open-model observation runner: substitutes the app's on-device classifier
(VNClassifyImageRequest) with CLIP zero-shot, and replays everything around it
with the ported app pipeline (crop schedule + label resolution + dedup).

App pipeline being mirrored (VisionService.scan + ScanImagePreprocessor):
  1. prepare: normalize orientation, downscale to max side <= 1600
  2. deterministicCrops: full, center square (Int(minSide*0.70)), 4 half-size
     quadrants, each >= 64x64
  3. per crop: classifier labels with confidence > 0.1
  4. each label -> IngredientIdentityResolution.resolveLabel
     (userCorrection -> curated lexicon -> catalog exact)
  5. per image: keep best-confidence classification per ingredient id
  6. detections sorted by confidence desc

Substitution is at step 3 only. The OCR path is NOT exercised (FoodSeg103
photos contain no packaging text); OCR resolution functions are ported and
unit-tested in resolution/app_resolution.py but idle here.

Experiment variables (recorded in observations):
  --label-space curated     CLIP classes = 52 curated display names
  --label-space curated+usda  ... plus the 800 USDA catalog display names
  --absorbers on|off        extra CLIP classes ("kitchen counter", ...) that
                            fail resolution. ON mirrors the app, whose classifier
                            can emit non-food labels that then fail resolution.
Prompt: "a photo of {name}" (parentheticals like "(Raw)" stripped for the
prompt only; resolution still uses the exact catalog name).

Outputs (per split):
  observations JSONL: {"split","image_id","crops":[{"id","labels":[{"name","prob",
    "resolved_id"}]}],"detections":[{"ingredient_id","confidence","original_label",
    "crop_id"}]}
  plus the image-embedding cache (npy) keyed (split, model_id) so re-scoring
  with different thresholds/label spaces is a cheap re-softmax.

Embedding caches live outside the repo (/home/user/work/bench/embeddings/).
"""

from __future__ import annotations

import argparse
import gzip
import io
import json
import sys
import time
from pathlib import Path

import numpy as np
import pyarrow.parquet as pq
import torch
from PIL import Image

EXPERIMENT_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(EXPERIMENT_ROOT / "resolution"))
from app_resolution import (  # noqa: E402
    IngredientCatalogResolver,
    IngredientLexicon,
    resolve_label,
)

PARQUET_DIR = Path("/home/user/work/bench/dataset")
EMBED_DIR = Path("/home/user/work/bench/embeddings")
ABSORBERS = [
    "a messy kitchen counter",
    "a wooden table",
    "kitchen utensils",
    "a person",
    "a prepared dish on a plate",
]


# --------------------------------------------------------------------------
# Port of ScanImagePreprocessor (geometry documented in the Swift source)
# --------------------------------------------------------------------------
def prepare(image: Image.Image, max_dimension: int = 1600) -> Image.Image:
    largest = max(image.width, image.height)
    if largest <= max_dimension:
        return image
    ratio = max_dimension / largest
    new_size = (int(image.width * ratio), int(image.height * ratio))
    return image.resize(new_size, Image.LANCZOS)


def deterministic_crops(image: Image.Image) -> list[tuple[str, Image.Image]]:
    width, height = image.size
    if width <= 0 or height <= 0:
        return [("full", image)]
    crops = [("full", image)]

    min_side = min(width, height)
    center_size = int(min_side * 0.70)  # Swift Int(Double) truncation
    center_x = max(0, (width - center_size) // 2)
    center_y = max(0, (height - center_size) // 2)
    if center_size >= 64:
        crops.append(("center", image.crop((center_x, center_y, center_x + center_size, center_y + center_size))))

    half_w = max(1, width // 2)
    half_h = max(1, height // 2)
    quadrant_defs = [
        ("topLeft", 0, 0),
        ("topRight", max(0, width - half_w), 0),
        ("bottomLeft", 0, max(0, height - half_h)),
        ("bottomRight", max(0, width - half_w), max(0, height - half_h)),
    ]
    for crop_id, x, y in quadrant_defs:
        if half_w >= 64 and half_h >= 64:
            crops.append((crop_id, image.crop((x, y, x + half_w, y + half_h))))
    return crops


# --------------------------------------------------------------------------
# Classifier substitution
# --------------------------------------------------------------------------
def build_label_space(label_space: str, lexicon: IngredientLexicon, catalog: IngredientCatalogResolver) -> list[dict]:
    """Returns [{name, raw, prompt}]. `raw` is the exact string fed to the app's
    resolver: curated entries use the lexicon label (e.g. "bell_pepper"); USDA
    entries use the catalog name stripped of prep parentheticals ("Green Beans"),
    which is what a real classifier emits and what the resolver can match."""
    entries: dict[str, dict] = {}
    for label in sorted(lexicon.label_to_id):
        display = lexicon.display_names.get(lexicon.label_to_id[label], label.replace("_", " "))
        prompt_name = display.split(" (")[0]
        entries[display] = {"name": display, "raw": label, "prompt": f"a photo of {prompt_name}"}
    if label_space == "curated+usda":
        for row in catalog._conn.execute("SELECT id, name FROM ingredients ORDER BY id"):
            display = IngredientCatalogResolver.make_display_name(row[1])
            if display in entries:
                continue  # curated entry wins on collision
            prompt_name = display.split(" (")[0]
            entries[display] = {"name": display, "raw": prompt_name, "prompt": f"a photo of {prompt_name}"}
    return list(entries.values())


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--split", choices=["validation", "train"], required=True)
    ap.add_argument("--model", default="ViT-B-32")
    ap.add_argument("--pretrained", default="laion2b_s34b_b79k")
    ap.add_argument("--label-space", choices=["curated", "curated+usda"], default="curated")
    ap.add_argument("--absorbers", choices=["on", "off"], default="on")
    ap.add_argument("--limit", type=int, default=0, help="cap rows (0 = all); for smoke runs only")
    ap.add_argument("--out", default="")
    args = ap.parse_args()

    lex = IngredientLexicon()
    catalog = IngredientCatalogResolver()
    labels = build_label_space(args.label_space, lex, catalog)
    if args.absorbers == "on":
        labels = labels + [{"name": a, "raw": a, "prompt": f"a photo of {a}"} for a in ABSORBERS]
    print(f"label space: {len(labels)} classes")

    import open_clip

    model_id = f"{args.model}-{args.pretrained.replace('/', '_')}"
    EMBED_DIR.mkdir(parents=True, exist_ok=True)
    embed_path = EMBED_DIR / f"{args.split}-{model_id}.npy"
    ids_path = EMBED_DIR / f"{args.split}-{model_id}-ids.json"

    device = "cpu"
    model, _, preprocess = open_clip.create_model_and_transforms(args.model, pretrained=args.pretrained)
    model = model.to(device).eval()
    tokenizer = open_clip.get_tokenizer(args.model)

    # ---- image embeddings (cached)
    geom_path = EMBED_DIR / f"{args.split}-{model_id}-geoms.json"
    meta_path = EMBED_DIR / f"{args.split}-{model_id}-meta.json"
    cache_complete = False
    if meta_path.exists():
        try:
            cache_complete = json.loads(meta_path.read_text()).get("complete", False)
        except json.JSONDecodeError:
            cache_complete = False
    if embed_path.exists() and ids_path.exists() and geom_path.exists() and cache_complete:
        embeddings = np.load(embed_path)
        with ids_path.open() as f:
            image_ids = json.load(f)
        with geom_path.open() as f:
            crop_geoms = json.load(f)
        print(f"loaded cached embeddings {embed_path} ({embeddings.shape})")
    else:
        parquets = sorted(PARQUET_DIR.glob(f"{args.split}-*.parquet"))
        image_ids: list[int] = []
        crop_geoms: list[str] = []
        feats: list[np.ndarray] = []
        t0 = time.time()
        batch_imgs: list[torch.Tensor] = []
        images_done = 0

        def flush() -> None:
            if not batch_imgs:
                return
            with torch.no_grad():
                x = torch.stack(batch_imgs).to(device)
                f_emb = model.encode_image(x)
                f_emb = f_emb / f_emb.norm(dim=-1, keepdim=True)
            feats.append(f_emb.cpu().numpy())
            batch_imgs.clear()

        outer: bool = False
        for shard in parquets:
            table = pq.read_table(shard, columns=["image", "id"])
            for i in range(table.num_rows):
                payload = table.column("image")[i].as_py()
                img_id = table.column("id")[i].as_py()
                img = prepare(Image.open(io.BytesIO(payload["bytes"])).convert("RGB"))
                for crop_id, crop in deterministic_crops(img):
                    batch_imgs.append(preprocess(crop))
                    image_ids.append(img_id)
                    crop_geoms.append(crop_id)
                    if len(batch_imgs) >= 256:
                        flush()
                        if len(feats) % 8 == 0:
                            print(f"  embedded {sum(f.shape[0] for f in feats)} crops ({time.time()-t0:.0f}s)")
                images_done += 1
                if args.limit and images_done >= args.limit:
                    outer = True
                    break
            if outer:
                break
        flush()
        embeddings = np.concatenate(feats)
        np.save(embed_path, embeddings)
        with ids_path.open("w") as f:
            json.dump(image_ids, f)
        with geom_path.open("w") as f:
            json.dump(crop_geoms, f)
        meta_path.write_text(json.dumps({"complete": args.limit == 0, "images": images_done, "crops": int(embeddings.shape[0])}))
        print(f"embedded {embeddings.shape[0]} crops of {images_done} images in {time.time()-t0:.0f}s -> {embed_path}")
    # image_ids/crop_geoms are per-crop lists aligned with embedding rows

    # ---- text embeddings
    prompts = [l["prompt"] for l in labels]
    with torch.no_grad():
        text_feats = []
        for chunk_start in range(0, len(prompts), 256):
            toks = tokenizer(prompts[chunk_start : chunk_start + 256]).to(device)
            t = model.encode_text(toks)
            t = t / t.norm(dim=-1, keepdim=True)
            text_feats.append(t.cpu().numpy())
        text_feats = np.concatenate(text_feats)
    logit_scale = model.logit_scale.exp().item()

    # ---- per-crop labels -> app resolution path
    probs = (torch.from_numpy(embeddings) @ torch.from_numpy(text_feats.T)) * logit_scale
    probs = torch.softmax(probs.float(), dim=-1).numpy()

    out_path = Path(args.out) if args.out else EXPERIMENT_ROOT / "observations" / f"openmodel_{args.split}_{args.label_space.replace('+','_')}_absorbers{args.absorbers}.jsonl.gz"
    out_path.parent.mkdir(parents=True, exist_ok=True)

    rows_by_id: dict[int, dict] = {}
    for crop_index in range(embeddings.shape[0]):
        img_id = image_ids[crop_index]
        crop_geom = crop_geoms[crop_index]
        crop_row = probs[crop_index]
        top = np.argsort(-crop_row)[:8]
        record_labels = []
        kept = []
        for cls_idx in top:
            prob = float(crop_row[cls_idx])
            if prob <= 0.1:  # app threshold: confidence > 0.1 only continues
                continue
            label = labels[int(cls_idx)]
            resolved = resolve_label(label["raw"], lex, catalog)
            entry = {
                "name": label["name"],
                "prob": round(prob, 6),
                "resolved_id": resolved.ingredient_id if resolved else None,
                "provenance": resolved.provenance if resolved else None,
                "is_absorber": label["name"] in ABSORBERS,
            }
            record_labels.append(entry)
            if resolved is not None:
                kept.append((prob, resolved.ingredient_id, label["name"], resolved.provenance))
        rows_by_id.setdefault(img_id, {"crops": []})
        crop_pos = len(rows_by_id[img_id]["crops"])
        rows_by_id[img_id]["crops"].append(
            {"id": crop_geom, "labels": record_labels}
        )
        # app dedup: best confidence per ingredient across crops (ties: first wins)
        best: dict[int, tuple] = {}
        for prob, ing_id, name, prov in kept:
            if ing_id not in best or prob > best[ing_id][0]:
                best[ing_id] = (prob, name, prov)
        detections = sorted(
            (
                {
                    "ingredient_id": ing_id,
                    "confidence": round(b[0], 6),
                    "original_label": b[1],
                    "provenance": b[2],
                }
                for ing_id, b in best.items()
            ),
            key=lambda d: -d["confidence"],
        )
        rows_by_id[img_id]["detections"] = detections

    with gzip.open(out_path, "wt") as f:
        for img_id in sorted(rows_by_id):
            rec = {"split": args.split, "image_id": img_id}
            rec.update(rows_by_id[img_id])
            f.write(json.dumps(rec) + "\n")
    n_det = sum(len(r["detections"]) for r in rows_by_id.values())
    print(f"wrote {out_path}: {len(rows_by_id)} images, {n_det} detections")


if __name__ == "__main__":
    main()
