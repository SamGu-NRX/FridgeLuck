from __future__ import annotations

from collections import Counter

import orjson

from .config import DEFAULT_REQUIRED_TERMS
from .schema import CanonicalCatalog, row_to_search_text
from .utils import canonical, stable_json_hash


class ValidationError(RuntimeError):
    pass


def validate_catalog(catalog: CanonicalCatalog, required_terms: list[str] | None = None) -> dict[str, int]:
    required_terms = required_terms or list(DEFAULT_REQUIRED_TERMS)

    seen_ids: set[int] = set()
    seen_names: set[str] = set()
    alias_counter: Counter[str] = Counter()
    previous_fdc_id = 0

    for row in catalog.records:
        if row.fdc_id <= previous_fdc_id:
            raise ValidationError("Catalog records must be strictly sorted by fdc_id")
        previous_fdc_id = row.fdc_id

        if row.fdc_id in seen_ids:
            raise ValidationError(f"Duplicate fdc_id={row.fdc_id}")
        seen_ids.add(row.fdc_id)

        display_key = canonical(row.display_name)
        if display_key in seen_names:
            raise ValidationError(f"Duplicate display_name={row.display_name}")
        seen_names.add(display_key)

        if "usda" not in row.source_meta.verification_source.lower():
            raise ValidationError(f"fdc_id={row.fdc_id} missing USDA verification source")

        for alias in row.alt_names:
            alias_key = canonical(alias)
            if not alias_key:
                raise ValidationError(f"fdc_id={row.fdc_id} contains empty alias")
            alias_counter[alias_key] += 1

    corpus = "\n".join([row_to_search_text(row) for row in catalog.records])
    missing = [term for term in required_terms if canonical(term) not in canonical(corpus)]
    if missing:
        raise ValidationError("Missing required search terms: " + ", ".join(missing))

    dumped = orjson.dumps(catalog.model_dump(mode="json"), option=orjson.OPT_SORT_KEYS)
    roundtrip = CanonicalCatalog.model_validate(orjson.loads(dumped))
    redumped = orjson.dumps(roundtrip.model_dump(mode="json"), option=orjson.OPT_SORT_KEYS)
    if stable_json_hash(dumped) != stable_json_hash(redumped):
        raise ValidationError("Determinism check failed: canonical JSON is not stable after round-trip serialization")

    return {
        "record_count": len(catalog.records),
        "unique_alias_count": len(alias_counter),
        "required_terms": len(required_terms),
    }
