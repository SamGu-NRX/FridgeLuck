#!/usr/bin/env python3
"""Pinned CPU arm: CLIP ViT-B/32 zero-shot food vs empty (OpenCLIP format).

Maps onto the run.py interface as:
  food_score     softmax probability that the image "contains food" under a
                 two-prompt zero-shot classifier
  produced_food  True only when the food prompt wins (score >= 0.5) — a
                 stand-in for a base resolver that accepts the predicted
                 label only when the food evidence wins
  food_labels    ["clip:food"] when produced, else []

Weights: laion/CLIP-ViT-B-32-laion2B-s34B-b79K, OpenCLIP checkpoint
pinned by sha256 below, loaded offline via open_clip 3.3.0 with the
ViT-B-32-quickgelu architecture (the laion2b_s34b_b79k training config).
Calibration (fixed before any benchmark metric was computed): a smoke run
showed the model's native logit-scale softmax (scale ~100) saturates to
~1.0 on both food and empty kitchen photos, so the arm uses temperature-1
softmax over the raw cosine similarities instead - monotone in the same
similarity difference, but not saturated. Deterministic on CPU with fixed
eval mode.
"""
from __future__ import annotations

import functools
import hashlib
import pathlib

import open_clip
import torch
from PIL import Image

CKPT = pathlib.Path(
    "/home/user/.cache/huggingface/hub/models--laion--CLIP-ViT-B-32-laion2B-s34B-b79K"
    "/snapshots/1a25a446712ba5ee05982a381eed697ef9b435cf/open_clip_model.safetensors"
)
CKPT_SHA256 = "ac4f8c4b88af6d963118cbf40ad93176d092abbedfcb752601ae1866352656e6"
ARCH = "ViT-B-32-quickgelu"

ARM_NAME = "clip-zeroshot"
ARM_VERSION = f"openclip:{ARCH}:laion2b_s34b_b79k@{CKPT_SHA256[:12]}"

PROMPTS = [
    "a photo containing food items",
    "a photo of an empty kitchen cabinet or refrigerator with no food",
]


def _sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


@functools.lru_cache(maxsize=1)
def _load():
    actual = _sha256(CKPT)
    if CKPT_SHA256 != "PLACEHOLDER" and actual != CKPT_SHA256:
        raise SystemExit(f"checkpoint hash mismatch: {actual}")
    model, _, preprocess = open_clip.create_model_and_transforms(ARCH, pretrained=str(CKPT))
    tokenizer = open_clip.get_tokenizer(ARCH)
    model.eval()
    return preprocess, tokenizer, model


@torch.no_grad()
def evaluate(image_path, record):
    preprocess, tokenizer, model = _load()
    img = preprocess(Image.open(image_path).convert("RGB")).unsqueeze(0)
    text = tokenizer(PROMPTS)
    with torch.no_grad():
        img_f = model.encode_image(img)
        txt_f = model.encode_text(text)
    img_f = img_f / img_f.norm(dim=-1, keepdim=True)
    txt_f = txt_f / txt_f.norm(dim=-1, keepdim=True)
    cos = img_f @ txt_f.T  # [1, 2] cosine similarities in [-1, 1]
    probs = torch.softmax(cos[0], dim=-1)  # temperature 1, not logit scale
    score = float(probs[0])  # food prompt probability
    produced = score >= 0.5
    return {
        "food_score": score,
        "produced_food": produced,
        "food_labels": ["clip:food"] if produced else [],
    }
