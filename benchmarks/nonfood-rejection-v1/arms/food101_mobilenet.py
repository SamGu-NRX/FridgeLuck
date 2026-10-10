#!/usr/bin/env python3
"""Pinned CPU arm: MobileNetV2 fine-tuned on Food-101.

Maps onto the run.py interface as:
  food_score     max softmax probability over the 101 Food-101 classes
  produced_food  True if the model produced any prediction at all (it is a
                 food-only classifier, so every argmax resolves to a food
                 class — the same semantics as a pipeline whose base resolver
                 accepts any predicted food label)
  food_labels    [predicted class]

Pinned to revision 0dea82e70d00f786f2029d8487d845a5cfc2d64a of
rajkr/mobilenet-v2-food101; loaded offline from the local hub cache.
Deterministic on CPU with fixed eval mode and no augmentation.
"""
from __future__ import annotations

import functools

import torch
from PIL import Image
from transformers import AutoModelForImageClassification, AutoImageProcessor

REPO = "rajkr/mobilenet-v2-food101"
REVISION = "0dea82e70d00f786f2029d8487d845a5cfc2d64a"

ARM_NAME = "food101-mobilenet"
ARM_VERSION = f"{REPO}@{REVISION}"


@functools.lru_cache(maxsize=1)
def _load():
    processor = AutoImageProcessor.from_pretrained(REPO, revision=REVISION, local_files_only=True)
    model = AutoModelForImageClassification.from_pretrained(REPO, revision=REVISION, local_files_only=True)
    model.eval()
    return processor, model


@torch.no_grad()
def evaluate(image_path, record):
    processor, model = _load()
    img = Image.open(image_path).convert("RGB")
    inputs = processor(images=img, return_tensors="pt")
    logits = model(**inputs).logits[0]
    probs = torch.softmax(logits, dim=-1)
    score, idx = torch.max(probs, dim=-1)
    label = model.config.id2label[int(idx)]
    return {
        "food_score": float(score),
        "produced_food": True,  # food-only classifier: every argmax is a food class
        "food_labels": [label],
    }
