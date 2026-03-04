from __future__ import annotations

from pathlib import Path
from typing import Any

import orjson

from .schema import CanonicalCatalog, CuratedIngredientRow, MacroSet, SourceMeta
from .sprite_rules import infer_sprite_group, infer_sprite_key
from .utils import canonical, dedupe_keep_order, utc_now_iso


def migrate_from_clean_json(path: Path) -> CanonicalCatalog:
    payload = orjson.loads(path.read_bytes())
    records = payload.get("records", [])
    out: list[CuratedIngredientRow] = []

    for raw in records:
        if not isinstance(raw, dict):
            continue
        try:
            fdc_id = int(raw.get("fdc_id"))
        except (ValueError, TypeError):
            continue
        display_name = str(raw.get("display_name", "") or "").strip()
        if not display_name:
            continue
        category_label = str(raw.get("category_label", "other") or "other")
        source_description = str(raw.get("source_description", "") or "").strip()
        description = str(raw.get("clarification", "") or "").strip()
        if not description:
            description = f"{display_name} ingredient entry sourced from USDA FoodData Central."

        alt_names = raw.get("alt_names", [])
        if not isinstance(alt_names, list):
            alt_names = []
        alt_names = dedupe_keep_order([str(v) for v in alt_names if isinstance(v, str)])

        sprite_group = infer_sprite_group(category_label)
        sprite_key = infer_sprite_key(display_name, source_description)

        row = CuratedIngredientRow(
            fdc_id=fdc_id,
            display_name=display_name,
            alt_names=alt_names,
            category_label=category_label,
            sprite_group=sprite_group,
            sprite_key=sprite_key,
            description=description,
            source_description=source_description,
            source_meta=SourceMeta(
                data_type=str(raw.get("data_type", "") or ""),
                food_category=str(raw.get("food_category", "") or ""),
                verified_at_utc=utc_now_iso(),
                verification_source="USDA FoodData Central API",
            ),
            macros=MacroSet(
                calories=float(raw.get("calories", 0.0) or 0.0),
                protein_g=float(raw.get("protein_g", 0.0) or 0.0),
                carbs_g=float(raw.get("carbs_g", 0.0) or 0.0),
                fat_g=float(raw.get("fat_g", 0.0) or 0.0),
                fiber_g=float(raw.get("fiber_g", 0.0) or 0.0),
                sugar_g=float(raw.get("sugar_g", 0.0) or 0.0),
                sodium_g=float(raw.get("sodium_g", 0.0) or 0.0),
            ),
        )
        out.append(row)

    out = sorted(out, key=lambda r: r.fdc_id)
    return CanonicalCatalog(schema_version="v2", generated_at_utc=utc_now_iso(), records=out)
