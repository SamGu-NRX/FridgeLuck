from __future__ import annotations

from typing import Iterable

from .schema import BatchPayload, CanonicalCatalog, CuratedIngredientRow, existing_macro_map, macros_equal
from .sprite_rules import infer_sprite_group, infer_sprite_key
from .utils import utc_now_iso


class PromoteError(RuntimeError):
    pass


def _assert_usda_provenance(row: CuratedIngredientRow) -> None:
    source = row.source_meta.verification_source.strip().lower()
    if "usda" not in source:
        raise PromoteError(f"fdc_id={row.fdc_id} missing USDA verification_source")


def promote_batch(catalog: CanonicalCatalog, batch: BatchPayload) -> CanonicalCatalog:
    by_id: dict[int, CuratedIngredientRow] = {row.fdc_id: row for row in catalog.records}
    previous_macros = existing_macro_map(catalog)

    for record in batch.records:
        row = record.row
        if not row.sprite_group or (row.sprite_group == "other" and row.category_label != "other"):
            row.sprite_group = infer_sprite_group(row.category_label)
        if not row.sprite_key:
            row.sprite_key = infer_sprite_key(row.display_name, row.source_description)
        _assert_usda_provenance(row)

        if record.action == "drop":
            by_id.pop(row.fdc_id, None)
            continue

        existing = by_id.get(row.fdc_id)
        if existing is not None:
            prev = previous_macros[row.fdc_id]
            if not macros_equal(prev, row.macros):
                raise PromoteError(
                    f"Macro freeze violation for existing fdc_id={row.fdc_id}; USDA-verified macro values are immutable"
                )
        by_id[row.fdc_id] = row

    merged = sorted(by_id.values(), key=lambda value: value.fdc_id)
    return CanonicalCatalog(schema_version="v2", generated_at_utc=utc_now_iso(), records=merged)
