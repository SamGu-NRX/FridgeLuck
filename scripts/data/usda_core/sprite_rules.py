from __future__ import annotations

from .config import CATEGORY_TO_SPRITE_GROUP, DISTINCT_SPRITE_KEYS
from .utils import canonical


def infer_sprite_group(category_label: str) -> str:
    normalized = canonical(category_label).replace(" ", "_")
    return CATEGORY_TO_SPRITE_GROUP.get(normalized, "other")


def infer_sprite_key(display_name: str, source_description: str) -> str:
    text = f"{display_name} | {source_description}"
    norm = canonical(text)
    for token, key in DISTINCT_SPRITE_KEYS.items():
        if token in norm:
            return key
    return ""
