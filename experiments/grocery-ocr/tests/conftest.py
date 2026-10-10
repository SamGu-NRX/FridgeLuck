import json
import os
import sys

import pytest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, ROOT)
sys.path.insert(0, os.path.join(ROOT, "acquisition"))

import check_manifest  # noqa: E402


def make_product(**overrides):
    p = {
        "code": "3017620422003",
        "stratum": "short_simple",
        "split": "test",
        "revision": {"rev": 42, "last_modified_t": 1700000000},
        "source": {"database": "Open Food Facts", "license": "ODbL-1.0",
                   "attribution": "Open Food Facts contributors", "url": "https://example/food.parquet"},
        "reference_text": "tomato paste, water, salt",
        "has_ingredient_reference_text": True,
        "alignment": "aligned",
        "roles": {
            "front": {"url": "https://img/front.jpg", "fetch_status": "ok", "sha256": "a" * 64},
            "ingredients": {"url": "https://img/ingredients.jpg", "fetch_status": "ok", "sha256": "b" * 64},
        },
    }
    p.update(overrides)
    return p


def make_manifest(products):
    return {"meta": {"salt": "t", "counts": {}}, "products": products}


check_manifest.make_product = make_product
check_manifest.make_manifest = make_manifest
