#!/usr/bin/env python3
"""Baseline arm: reject everything.

Never produces a food label and always reports zero food evidence. The
policy will therefore declare every visibly-empty image certainly empty
while missing every food control - the failure mode the benchmark exists
to catch, taken to its limit.
"""
ARM_NAME = "reject-everything"
ARM_VERSION = "baseline:reject-everything"


def evaluate(image_path, record):
    return {"food_score": 0.0, "produced_food": False, "food_labels": []}
