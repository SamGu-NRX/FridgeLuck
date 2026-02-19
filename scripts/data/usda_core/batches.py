from __future__ import annotations

from typing import Iterable

from .schema import BatchPayload, BatchRow, CanonicalCatalog, CuratedIngredientRow
from .utils import canonical


def quality_score(row: CuratedIngredientRow) -> int:
    score = 0
    source = canonical(row.source_description)
    if "," in row.source_description:
        score += 1
    if len(canonical(row.display_name).split(" ")) <= 1:
        score += 2
    if len(row.alt_names) < 2:
        score += 2
    if not row.description or len(row.description) < 20:
        score += 2
    suspicious = ("composite", "carcass", "retail cuts", "variety meats", "by-products")
    if any(t in source for t in suspicious):
        score += 3
    return score


def export_batch(
    catalog: CanonicalCatalog,
    *,
    batch_id: int,
    batch_size: int,
    candidates: Iterable[CuratedIngredientRow] | None = None,
) -> BatchPayload:
    existing_ids = {row.fdc_id for row in catalog.records}
    selected: list[BatchRow] = []

    if candidates:
        for row in candidates:
            if row.fdc_id in existing_ids:
                continue
            selected.append(BatchRow(action="upsert", row=row, review_notes="new candidate from USDA"))
            if len(selected) >= batch_size:
                return BatchPayload(batch_id=batch_id, batch_size=len(selected), records=selected)

    ranked = sorted(catalog.records, key=lambda row: (-quality_score(row), canonical(row.display_name), row.fdc_id))
    start = max(0, (batch_id - 1) * max(1, batch_size))
    for row in ranked[start : start + max(1, batch_size - len(selected))]:
        selected.append(BatchRow(action="upsert", row=row, review_notes="review metadata quality"))

    return BatchPayload(batch_id=batch_id, batch_size=len(selected), records=selected)
