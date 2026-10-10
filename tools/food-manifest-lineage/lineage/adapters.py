"""Adapters for FridgeLuck's existing public food image/product/plate manifests.

Every adapter consumes only the fields its manifest actually declares and
maps them onto the four lineage keys (exact hash, source ID, product
revision, declared group). A key a manifest does not declare stays
``unknown`` — adapters never infer identity from display names, labels,
categories, or any other heuristic, and never fetch, decode, or recognize
images.

Adapters are registered by name in ``ADAPTERS`` and used by both the
contract-fixture check (``check.py``) and the pinned audit (``audit.py``).
An optional ``blob_resolver(repo_path) -> bytes`` lets the audit compute
exact hashes for assets committed to this repository (read-only, from the
pinned git tree); fixture runs pass ``None`` and hashes stay unknown.
"""

from __future__ import annotations

import csv
import io
import json
from dataclasses import dataclass
from typing import Callable, Dict, List, Optional

from .records import (
    UNKNOWN,
    LineageRecord,
    canonical_dhash,
    norm,
    sha256_hex,
)

BlobResolver = Callable[[str], bytes]

FOOD101 = "food-101"
OPENIMAGES = "openimages"
FOODSEG103 = "foodseg103"
NUTRITION5K = "nutrition5k"
USDA_FDC = "usda-fdc"
BUNDLED_DEMO = "bundled-demo-assets"


@dataclass
class AdapterInput:
    name: str
    kind: str
    adapter: str
    declared_revision: str = UNKNOWN
    options: Optional[dict] = None


@dataclass
class ManifestData:
    raw_bytes: bytes
    text: str

    def json(self) -> dict:
        return json.loads(self.text)


# ---------------------------------------------------------------------------
# image manifests
# ---------------------------------------------------------------------------

def adapt_dish_ambiguity(inp: AdapterInput, data: ManifestData, ctx) -> List[LineageRecord]:
    """benchmarks/dish-ambiguity-v1/{manifest,dev_manifest}.json (Food-101).

    Declares: path, class, split, sha256, dhash (int). Food-101 declares no
    separate image id, so the dataset path is the upstream identity; exact
    duplicates renamed to a different path therefore join by hash only.
    """
    doc = data.json()
    out: List[LineageRecord] = []
    for i, img in enumerate(doc["images"]):
        path = norm(img.get("path"))
        out.append(
            LineageRecord(
                manifest=inp.name,
                item_id=img.get("id") or f"img-{i:06d}",
                kind=inp.kind,
                origin=FOOD101,
                source_id=path,
                content_hash=norm(img.get("sha256")),
                hash_provenance="declared" if norm(img.get("sha256")) != UNKNOWN else UNKNOWN,
                product_revision=inp.declared_revision,
                declared_group=norm(f'{norm(img.get("class"))}/{norm(img.get("split"))}'
                                    if norm(img.get("class")) != UNKNOWN and norm(img.get("split")) != UNKNOWN
                                    else None),
                location=path,
                label=norm(img.get("class")),
                declared_dhash=canonical_dhash(img.get("dhash")),
            )
        )
    return out


def adapt_nonfood_rejection(inp: AdapterInput, data: ManifestData, ctx) -> List[LineageRecord]:
    """benchmarks/nonfood-rejection-v1/manifest.json (Open Images).

    Declares: image_id, subset, s3_url, sha256, split, role, stratum,
    match_key, photographer group_id/series_id. The upstream revision of
    Open Images is not declared as a single version key, so product_revision
    stays unknown; group is the declared split/role pair.
    """
    doc = data.json()
    out: List[LineageRecord] = []
    for i, img in enumerate(doc["images"]):
        split, role = norm(img.get("split")), norm(img.get("role"))
        group = "/".join(part for part in (split, role) if part != UNKNOWN) or UNKNOWN
        sha = norm(img.get("sha256"))
        out.append(
            LineageRecord(
                manifest=inp.name,
                item_id=img.get("id") or f"img-{i:06d}",
                kind=inp.kind,
                origin=OPENIMAGES,
                source_id=norm(img.get("image_id")),
                content_hash=sha,
                hash_provenance="declared" if sha != UNKNOWN else UNKNOWN,
                product_revision=inp.declared_revision,
                declared_group=group,
                location=norm(img.get("s3_url")),
                label=norm(img.get("match_key")),
            )
        )
    return out


def adapt_multiplate(inp: AdapterInput, data: ManifestData, ctx) -> List[LineageRecord]:
    """benchmarks/multiplate-v1/manifest.json (Open Images validation boxes).

    Declares: image_id, role, series_group, sha256, source_url, dhash (hex),
    and the dataset block declares the upstream snapshot (2018_04).
    """
    doc = data.json()
    out: List[LineageRecord] = []
    for i, img in enumerate(doc["images"]):
        sha = norm(img.get("sha256"))
        out.append(
            LineageRecord(
                manifest=inp.name,
                item_id=img.get("id") or f"img-{i:06d}",
                kind=inp.kind,
                origin=OPENIMAGES,
                source_id=norm(img.get("image_id")),
                content_hash=sha,
                hash_provenance="declared" if sha != UNKNOWN else UNKNOWN,
                product_revision=inp.declared_revision,
                declared_group=norm(img.get("role")),
                location=norm(img.get("source_url")),
                label=norm(img.get("series_group")),
                declared_dhash=canonical_dhash(img.get("dhash")),
            )
        )
    return out


def adapt_foodseg_csv(inp: AdapterInput, data: ManifestData, ctx) -> List[LineageRecord]:
    """experiments/ingredient-recognition/scoring/dataset/foodseg103_manifest.csv.

    Declares: split, image_id, sha256, dup_group. The manifest's own
    dup_group values are split-scoped (va-7 / te-7), so image ids are
    treated as split-scoped too: source_id = "<split>/<image_id>".
    """
    out: List[LineageRecord] = []
    reader = csv.DictReader(io.StringIO(data.text))
    for i, row in enumerate(reader):
        split = norm(row.get("split"))
        image_id = norm(row.get("image_id"))
        sha = norm(row.get("sha256"))
        out.append(
            LineageRecord(
                manifest=inp.name,
                item_id=row.get("id") or f"row-{i:06d}",
                kind=inp.kind,
                origin=FOODSEG103,
                source_id=norm(f"{split}/{image_id}" if image_id != UNKNOWN else None),
                content_hash=sha,
                hash_provenance="declared" if sha != UNKNOWN else UNKNOWN,
                product_revision=inp.declared_revision,
                declared_group=norm(
                    f"{split}/{norm(row.get('dup_group'))}"
                    if split != UNKNOWN and norm(row.get("dup_group")) != UNKNOWN
                    else None
                ),
                location=norm(row.get("path") or row.get("url")),
                label=norm(row.get("classes_on_image")),
            )
        )
    return out


def adapt_bundled_demo(inp: AdapterInput, data: ManifestData, ctx) -> List[LineageRecord]:
    """apps/ios/Resources/benchmark_manifest.json (bundled app demo scans).

    Declares: id, resourceName, resourceSubdirectory, resourceExtension,
    scenarioTags. No hash is declared in the manifest; when the referenced
    asset is committed to the repository, the audit computes its exact
    sha256 read-only from the pinned tree and marks provenance "computed".
    Without a resolver the hash stays unknown.
    """
    doc = data.json()
    opts = inp.options or {}
    asset_root = opts.get("asset_root", "").rstrip("/")
    out: List[LineageRecord] = []
    for i, img in enumerate(doc.get("images", [])):
        sub, name, ext = (
            norm(img.get("resourceSubdirectory")),
            norm(img.get("resourceName")),
            norm(img.get("resourceExtension")),
        )
        rel = "/".join(part for part in (sub, name) if part != UNKNOWN)
        rel = f"{rel}.{ext}" if rel != UNKNOWN and ext != UNKNOWN else rel
        repo_path = f"{asset_root}/{rel}" if asset_root and rel != UNKNOWN else UNKNOWN
        content_hash, provenance = UNKNOWN, UNKNOWN
        if repo_path != UNKNOWN and ctx is not None:
            try:
                blob = ctx(repo_path)
            except FileNotFoundError:
                blob = None
            if blob is not None:
                content_hash, provenance = sha256_hex(blob), "computed"
        tags = img.get("scenarioTags") or []
        group = ",".join(str(t) for t in tags) if tags else UNKNOWN
        out.append(
            LineageRecord(
                manifest=inp.name,
                item_id=norm(img.get("id")) or f"img-{i:06d}",
                kind=inp.kind,
                origin=BUNDLED_DEMO,
                source_id=norm(rel),
                content_hash=content_hash,
                hash_provenance=provenance,
                product_revision=inp.declared_revision,
                declared_group=group,
                location=repo_path,
                label=norm(img.get("id")),
            )
        )
    return out


# ---------------------------------------------------------------------------
# plate manifests
# ---------------------------------------------------------------------------

def adapt_nutrition5k_summary(inp: AdapterInput, data: ManifestData, ctx) -> List[LineageRecord]:
    """experiments/nutrition5k-portion/MANIFEST.json (Nutrition5k plates).

    Summary-level only: per-file sha256 values were recorded at fetch time
    in a (uncommitted) imagery_manifest.jsonl, so every lineage key except
    the origin stays unknown here. That is the honest census: the manifest
    proves the fetch, not per-image lineage.
    """
    doc = data.json()
    return [
        LineageRecord(
            manifest=inp.name,
            item_id="manifest-summary",
            kind=inp.kind,
            origin=NUTRITION5K,
            product_revision=inp.declared_revision,
        )
    ]


def adapt_nutrition5k_dishes(inp: AdapterInput, data: ManifestData, ctx) -> List[LineageRecord]:
    """experiments/nutrition5k-portion/data/dish_targets.csv (plate rows).

    Declares: dish_id, cafe, scan_ts, official_rgb_split, official_depth_split,
    plate_cluster, my_split. Image bytes are not committed and no per-image
    hash is declared, so content_hash stays unknown; dish_id is the upstream
    plate identity and plate_cluster is the declared group.
    """
    out: List[LineageRecord] = []
    reader = csv.DictReader(io.StringIO(data.text))
    for i, row in enumerate(reader):
        dish = norm(row.get("dish_id"))
        my_split = norm(row.get("my_split"))
        cluster = norm(row.get("plate_cluster"))
        out.append(
            LineageRecord(
                manifest=inp.name,
                item_id=row.get("id") or f"row-{i:06d}",
                kind=inp.kind,
                origin=NUTRITION5K,
                source_id=dish,
                content_hash=norm(row.get("sha256")),
                hash_provenance="declared" if norm(row.get("sha256")) != UNKNOWN else UNKNOWN,
                product_revision=inp.declared_revision,
                declared_group=norm(
                    f"{my_split}/{cluster}"
                    if my_split != UNKNOWN and cluster != UNKNOWN
                    else None
                ),
                label=norm(row.get("ingredient_names")),
            )
        )
    return out


# ---------------------------------------------------------------------------
# product manifests
# ---------------------------------------------------------------------------

def _usda_record(inp: AdapterInput, row: dict, item_id: str) -> LineageRecord:
    meta = row.get("source_meta") or {}
    sprite = norm(row.get("sprite_group"))
    group = sprite if sprite != UNKNOWN else norm(row.get("category_label"))
    data_type = norm(meta.get("data_type"))
    return LineageRecord(
        manifest=inp.name,
        item_id=item_id,
        kind=inp.kind,
        origin=USDA_FDC,
        source_id=norm(row.get("fdc_id")),
        content_hash=norm(row.get("sha256")),
        hash_provenance="declared" if norm(row.get("sha256")) != UNKNOWN else UNKNOWN,
        product_revision=data_type if data_type != UNKNOWN else inp.declared_revision,
        declared_group=group,
        location=norm(row.get("url")),
        label=norm(row.get("display_name")),
    )


def adapt_usda_catalog(inp: AdapterInput, data: ManifestData, ctx) -> List[LineageRecord]:
    """scripts/data/catalog/usda_curated_ingredients.json (USDA product rows).

    Declares: fdc_id, display_name, sprite_group, category_label,
    source_meta.data_type. No bytes/hash: text nutrition records.
    """
    doc = data.json()
    return [
        _usda_record(
            inp,
            rec,
            f"rec-{i:06d}" if norm(rec.get("fdc_id")) == UNKNOWN else f"fdc-{norm(rec.get('fdc_id'))}",
        )
        for i, rec in enumerate(doc.get("records", []))
    ]


def adapt_usda_review_batches(inp: AdapterInput, data: ManifestData, ctx) -> List[LineageRecord]:
    """scripts/data/review_batches/manual_batch_*.json (USDA review rows).

    Declares: batch_id, records[].action, records[].row (same USDA row
    shape). Rows upsert existing catalog products: the same fdc_id in the
    canonical catalog and a review batch is a real cross-manifest product
    relationship, reported with both declared labels.
    """
    doc = data.json()
    batch = norm(doc.get("batch_id"))
    out: List[LineageRecord] = []
    for i, entry in enumerate(doc.get("records", [])):
        row = entry.get("row") or {}
        item_id = f"batch{batch}-rec-{i:06d}"
        out.append(_usda_record(inp, row, item_id))
    return out


def adapt_preparation_state(inp: AdapterInput, data: ManifestData, ctx) -> List[LineageRecord]:
    """benchmarks/preparation-state-v1/manifest.json groups (USDA-derived).

    Declares: groups[].group_id, members[].catalog_id (fdc id), name,
    descriptor, states, and provenance.catalog_sha256 pinning the exact
    catalog snapshot. Product identity is the fdc catalog id; the group is
    the declared base-name group.
    """
    doc = data.json()
    out: List[LineageRecord] = []
    for g_i, group in enumerate(doc.get("groups", [])):
        group_id = norm(group.get("group_id"))
        for m_i, member in enumerate(group.get("members", [])):
            out.append(
                LineageRecord(
                    manifest=inp.name,
                    item_id=f"group-{g_i:05d}-member-{m_i:05d}",
                    kind=inp.kind,
                    origin=USDA_FDC,
                    source_id=norm(member.get("catalog_id")),
                    content_hash=norm(member.get("sha256")),
                    hash_provenance="declared" if norm(member.get("sha256")) != UNKNOWN else UNKNOWN,
                    product_revision=norm(member.get("descriptor")) or UNKNOWN,
                    declared_group=group_id,
                    label=norm(member.get("name")),
                )
            )
    return out


def adapt_fdc_reference(inp: AdapterInput, data: ManifestData, ctx) -> List[LineageRecord]:
    """scripts/data/reference/MANIFEST.json (USDA FoodData Central sources).

    Declares: sources[].dataset/edition/filename/sha256/url plus the
    extract file and its sha256. Source-file identity is the bulk dataset
    + edition; the extract is pinned by its own sha256.
    """
    doc = data.json()
    out: List[LineageRecord] = []
    for i, src in enumerate(doc.get("sources", [])):
        dataset = norm(src.get("dataset"))
        out.append(
            LineageRecord(
                manifest=inp.name,
                item_id=f"source-{dataset}" if dataset != UNKNOWN else f"source-{i:05d}",
                kind=inp.kind,
                origin=USDA_FDC,
                source_id=norm(f"fdc-bulk:{dataset}" if dataset != UNKNOWN else None),
                content_hash=norm(src.get("sha256")),
                hash_provenance="declared" if norm(src.get("sha256")) != UNKNOWN else UNKNOWN,
                product_revision=norm(src.get("edition")),
                declared_group=dataset,
                location=norm(src.get("url")),
                label=norm(src.get("filename")),
            )
        )
    extract_name = norm(doc.get("extract_file"))
    extract_sha = norm(doc.get("extract_sha256"))
    if extract_name != UNKNOWN:
        out.append(
            LineageRecord(
                manifest=inp.name,
                item_id="extract",
                kind=inp.kind,
                origin=USDA_FDC,
                source_id=f"fdc-extract:{extract_name}",
                content_hash=extract_sha,
                hash_provenance="declared" if extract_sha != UNKNOWN else UNKNOWN,
                product_revision=norm(doc.get("generated_at_utc")),
                declared_group=norm(doc.get("extract_file")),
                label=extract_name,
            )
        )
    return out


def adapt_usda_manual_overrides(inp: AdapterInput, data: ManifestData, ctx) -> List[LineageRecord]:
    """scripts/data/usda_manual_overrides.json — curation overrides keyed by FDC id.

    Each override targets an upstream FDC product (source identity) but
    declares no group, revision, or hash of its own; only a curated label.
    """
    doc = data.json()
    out: List[LineageRecord] = []
    for i, (fdc_id, entry) in enumerate(
        sorted(doc.get("overrides", {}).items(), key=lambda kv: str(kv[0]))
    ):
        if not isinstance(entry, dict):
            continue
        out.append(
            LineageRecord(
                manifest=inp.name,
                item_id=f"override-{i:06d}",
                kind=inp.kind,
                origin=USDA_FDC,
                source_id=norm(fdc_id),
                product_revision=UNKNOWN,
                declared_group=UNKNOWN,
                content_hash=UNKNOWN,
                label=norm(entry.get("display_name")),
            )
        )
    return out


def adapt_nutrition_compact(inp: AdapterInput, data: ManifestData, ctx) -> List[LineageRecord]:
    """apps/ios/Resources/usda_ingredient_nutrition_compact.json — ingredient map.

    Declares, per app ingredient: ingredient_key/name and the matched FDC
    product (matched_fdc_id) with its upstream data type. Source identity is
    the matched fdc_id; no bytes/hash are available.
    """
    doc = data.json()
    out: List[LineageRecord] = []
    for i, row in enumerate(doc.get("records", [])):
        if not isinstance(row, dict):
            continue
        out.append(
            LineageRecord(
                manifest=inp.name,
                item_id=norm(row.get("ingredient_key")) or f"ing-{i:06d}",
                kind=inp.kind,
                origin=USDA_FDC,
                source_id=norm(row.get("matched_fdc_id")),
                product_revision=norm(row.get("matched_data_type")),
                declared_group=UNKNOWN,
                content_hash=UNKNOWN,
                label=norm(row.get("ingredient_name")),
            )
        )
    return out


ADAPTERS: Dict[str, Callable[[AdapterInput, ManifestData, object], List[LineageRecord]]] = {
    "dish-ambiguity": adapt_dish_ambiguity,
    "nonfood-rejection": adapt_nonfood_rejection,
    "multiplate": adapt_multiplate,
    "foodseg-csv": adapt_foodseg_csv,
    "bundled-demo": adapt_bundled_demo,
    "nutrition5k-summary": adapt_nutrition5k_summary,
    "nutrition5k-dishes": adapt_nutrition5k_dishes,
    "usda-catalog": adapt_usda_catalog,
    "usda-review-batches": adapt_usda_review_batches,
    "usda-manual-overrides": adapt_usda_manual_overrides,
    "nutrition-compact": adapt_nutrition_compact,
    "preparation-state": adapt_preparation_state,
    "fdc-reference": adapt_fdc_reference,
}


def run_adapter(
    inp: AdapterInput,
    raw_bytes: bytes,
    blob_resolver: Optional[BlobResolver] = None,
) -> List[LineageRecord]:
    if inp.adapter not in ADAPTERS:
        raise KeyError(f"unknown adapter {inp.adapter!r}; known: {sorted(ADAPTERS)}")
    data = ManifestData(raw_bytes=raw_bytes, text=raw_bytes.decode("utf-8"))
    return ADAPTERS[inp.adapter](inp, data, blob_resolver)
