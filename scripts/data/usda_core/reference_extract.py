"""Extract FDC reference evidence for the curated catalog.

Reads the public FoodData Central bulk JSON releases (public domain, no API
key, no rate-limited endpoints — one static download per dataset edition),
keeps the nutrient observations the catalog's macros depend on for exactly the
curated fdc_ids, and writes:

- a byte-stable, self-contained extract JSON (committed to the repo), and
- a MANIFEST.json recording the source archives (URL, edition, sha256, size)
  and the extract file's own sha256.

The extract is deterministic: same archives + same canonical fdc_ids produce
byte-identical output, so the committed sha256 stays a reproducible reference.
"""

from __future__ import annotations

import hashlib
import zipfile
from dataclasses import dataclass
from pathlib import Path
from typing import Any

import orjson

from .nutrients import MACRO_SPECS, ENERGY_KCAL_PRECEDENCE, ENERGY_KJ_IDS
from .utils import utc_now_iso

# Every nutrient id the canonical macros can legally come from.
TARGET_NUTRIENT_IDS: frozenset[int] = frozenset(
    int(i) for pair in (*ENERGY_KCAL_PRECEDENCE, *ENERGY_KJ_IDS) for i in (pair[0], int(pair[1]))
) | {int(i) for spec in MACRO_SPECS.values() for i in spec.ids}

EXTRACT_FILENAME = "fdc_reference_extracts.json"
MANIFEST_FILENAME = "MANIFEST.json"


@dataclass(frozen=True)
class ReferenceSource:
    dataset: str
    edition: str
    url: str
    path: Path
    sha256: str
    bytes: int

    def to_json(self) -> dict[str, Any]:
        return {
            "dataset": self.dataset,
            "edition": self.edition,
            "url": self.url,
            "filename": self.path.name,
            "sha256": self.sha256,
            "bytes": self.bytes,
        }


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _load_dataset_items(zip_path: Path, top_key: str) -> list[dict[str, Any]]:
    with zipfile.ZipFile(zip_path) as bundle:
        names = [n for n in bundle.namelist() if n.endswith(".json")]
        if not names:
            raise RuntimeError(f"No JSON payload inside {zip_path}")
        with bundle.open(names[0]) as handle:
            payload = orjson.loads(handle.read())
    items = payload.get(top_key)
    if not isinstance(items, list):
        raise RuntimeError(f"{zip_path} is missing the {top_key} array")
    return items


def _food_category(value: Any) -> str:
    if isinstance(value, dict):
        return str(value.get("description") or value.get("name") or "")
    return str(value or "")


def _compact_nutrients(food: dict[str, Any]) -> list[dict[str, Any]]:
    out: list[dict[str, Any]] = []
    for entry in food.get("foodNutrients") or []:
        nested = entry.get("nutrient") if isinstance(entry.get("nutrient"), dict) else {}
        nutrient_id = entry.get("nutrientId") or entry.get("nutrient_id") or nested.get("id")
        try:
            nutrient_id = int(nutrient_id)
        except (TypeError, ValueError):
            continue
        if nutrient_id not in TARGET_NUTRIENT_IDS:
            continue
        amount = entry.get("amount", entry.get("value"))
        out.append(
            {
                "id": nutrient_id,
                "number": str(nested.get("number") or entry.get("nutrientNumber") or ""),
                "name": str(nested.get("name") or entry.get("nutrientName") or ""),
                "unit": str(nested.get("unitName") or entry.get("unitName") or ""),
                "amount": None if amount is None else float(amount),
                "data_points": entry.get("dataPoints"),
                "derivation_code": str(
                    entry.get("foodNutrientDerivation")
                    or entry.get("derivationCode")
                    or ""
                ),
            }
        )
    return sorted(out, key=lambda n: n["id"])


def build_reference_extract(
    canonical_records: list[dict[str, Any]],
    sources: list[ReferenceSource],
) -> dict[str, Any]:
    """Collect compact evidence records for the curated fdc_ids."""

    wanted = {int(r["fdc_id"]) for r in canonical_records}
    found: dict[int, dict[str, Any]] = {}

    dataset_keys = {"sr_legacy": "SRLegacyFoods", "foundation": "FoundationFoods"}
    for source in sources:
        top_key = dataset_keys[source.dataset]
        for food in _load_dataset_items(source.path, top_key):
            fdc_id = food.get("fdcId")
            if fdc_id is None or int(fdc_id) not in wanted:
                continue
            data_type = str(food.get("dataType") or "")
            record = {
                "fdc_id": int(fdc_id),
                "data_type": data_type,
                "food_class": str(food.get("foodClass") or ""),
                "description": str(food.get("description") or ""),
                "food_category": _food_category(food.get("foodCategory")),
                "publication_date": str(food.get("publicationDate") or ""),
                "ndb_number": food.get("ndbNumber"),
                "basis": "per_100g",
                "source_dataset": source.dataset,
                "source_edition": source.edition,
                "nutrients": _compact_nutrients(food),
            }
            found[int(fdc_id)] = record

    missing = sorted(wanted - set(found))
    return {
        "schema_version": "v1",
        "sources": [s.to_json() for s in sources],
        "records": [found[f] for f in sorted(found)],
        "missing_fdc_ids": missing,
    }


def write_reference_bundle(
    out_dir: Path,
    canonical_records: list[dict[str, Any]],
    sources: list[ReferenceSource],
) -> dict[str, Any]:
    out_dir.mkdir(parents=True, exist_ok=True)

    # The extract itself carries its source metadata so it is self-contained;
    # timestamps stay out so the bytes are reproducible.
    extract = build_reference_extract(canonical_records, sources)
    extract_bytes = orjson.dumps(extract, option=orjson.OPT_SORT_KEYS)
    extract_path = out_dir / EXTRACT_FILENAME
    extract_path.write_bytes(extract_bytes + b"\n")

    manifest = {
        "generated_at_utc": utc_now_iso(),
        "extract_file": EXTRACT_FILENAME,
        "extract_sha256": hashlib.sha256(extract_bytes).hexdigest(),
        "extract_record_count": len(extract["records"]),
        "missing_fdc_ids": extract["missing_fdc_ids"],
        "sources": [s.to_json() for s in sources],
        "license": "USDA FoodData Central bulk releases are public domain (no API key required).",
    }
    manifest_path = out_dir / MANIFEST_FILENAME
    manifest_path.write_bytes(orjson.dumps(manifest, option=orjson.OPT_SORT_KEYS | orjson.OPT_INDENT_2) + b"\n")
    return manifest
