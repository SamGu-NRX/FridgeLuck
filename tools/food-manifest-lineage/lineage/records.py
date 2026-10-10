"""Lineage record schema for the FridgeLuck manifest source-reuse audit.

Core contract ("unknown stays unknown"): a lineage key that a manifest does
not declare is kept as the literal ``unknown`` sentinel and never inferred
from display names, paths, categories, or other heuristics. Unknown keys
never join two records together.

Only four identity keys drive the lineage graph:

- ``content_hash``  exact sha256 hex of the underlying bytes, when the
  manifest declares it, or when the bytes are committed in this repository
  and can be hashed read-only (provenance records which of the two).
- ``source_id``     the upstream identifier the manifest declares for the
  item, scoped by ``origin`` (the upstream dataset family).
- ``product_revision`` the upstream edition/revision the manifest declares
  for the item, when it declares one.
- ``declared_group`` the group label exactly as the manifest declares it.

Anything else is descriptive, not identity.
"""

from __future__ import annotations

import hashlib
from dataclasses import dataclass, replace
from typing import Optional

UNKNOWN = "unknown"
KINDS = ("image", "product", "plate")
HASH_PROVENANCES = ("declared", "computed", UNKNOWN)


def norm(value) -> str:
    """Normalize a declared value; missing or blank becomes UNKNOWN."""
    if value is None:
        return UNKNOWN
    text = str(value).strip()
    return text if text else UNKNOWN


def sha256_hex(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def canonical_dhash(value) -> Optional[str]:
    """Canonical 16-hex-digit form for a declared 64-bit dHash value.

    dish-ambiguity manifests store the value as a large unsigned integer,
    multiplate as a 16-char hex string. This accepts both. Returns None
    when absent/blank. Perceptual hashes are approximate: they are never
    used as join keys and never treated as proof of duplication.
    """
    if value is None:
        return None
    if isinstance(value, str):
        text = value.strip()
        return text.lower() or None
    try:
        return format(int(value) & 0xFFFFFFFFFFFFFFFF, "016x")
    except (TypeError, ValueError):
        return None


@dataclass(frozen=True)
class LineageRecord:
    """One lineage-bearing item from one manifest."""

    manifest: str
    item_id: str
    kind: str
    origin: str = UNKNOWN
    source_id: str = UNKNOWN
    content_hash: str = UNKNOWN
    hash_provenance: str = UNKNOWN
    product_revision: str = UNKNOWN
    declared_group: str = UNKNOWN
    location: str = UNKNOWN
    label: str = UNKNOWN
    declared_dhash: Optional[str] = None

    def __post_init__(self):
        if self.kind not in KINDS:
            raise ValueError(f"kind must be one of {KINDS}, got {self.kind!r}")
        if not norm(self.manifest) or not norm(self.item_id):
            raise ValueError("manifest and item_id are required")
        if self.hash_provenance not in HASH_PROVENANCES:
            raise ValueError(f"hash_provenance must be one of {HASH_PROVENANCES}")

    @property
    def item_ref(self) -> str:
        return f"{self.manifest}:{self.item_id}"

    def with_manifest(self, manifest: str) -> "LineageRecord":
        return replace(self, manifest=manifest)

    def source_key(self):
        """Join key for upstream source identity, or None when undeclared."""
        if self.origin != UNKNOWN and self.source_id != UNKNOWN:
            return ("source", self.origin, self.source_id)
        return None

    def hash_key(self):
        """Join key for exact byte identity, or None when hash unknown."""
        if self.content_hash != UNKNOWN:
            return ("hash", self.content_hash)
        return None

    def to_json(self) -> dict:
        out = {
            "manifest": self.manifest,
            "item_id": self.item_id,
            "kind": self.kind,
            "origin": self.origin,
            "source_id": self.source_id,
            "content_hash": self.content_hash,
            "hash_provenance": self.hash_provenance,
            "product_revision": self.product_revision,
            "declared_group": self.declared_group,
            "location": self.location,
            "label": self.label,
            "declared_dhash": self.declared_dhash,
        }
        return out
