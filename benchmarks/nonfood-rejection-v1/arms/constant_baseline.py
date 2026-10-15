#!/usr/bin/env python3
"""Baseline arm: constant score, never produces.

A non-model floor: every image gets the same mid-range food score and no
food label is ever produced. Shows what the policy does with a signal that
carries no information but at least never adds phantom food.
"""
ARM_NAME = "constant-0.5"
ARM_VERSION = "baseline:constant-0.5"


def evaluate(image_path, record):
    return {"food_score": 0.5, "produced_food": False, "food_labels": []}
