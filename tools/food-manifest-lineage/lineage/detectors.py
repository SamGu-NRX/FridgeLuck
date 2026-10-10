"""Detection categories over lineage clusters.

Categories (per the audit brief):
- ``exact-duplicate``   >= 2 members share an exact content hash.
- ``renamed-url``       a cluster contains >= 2 distinct declared locations
                        (paths/URLs) for the same underlying content/source:
                        the same item under different names.
- ``source-reuse``      >= 2 members join by upstream source identity; the
                        cluster is ``transitive`` when no single join key
                        instance spans every member (A~B by source, B~C by
                        hash, A and C sharing nothing directly).

Spans are additional context, not separate detections:
- ``cross-manifest``    members come from >= 2 audited manifests.
- ``cross-group``       members carry >= 2 distinct declared_group values
                        (including split labels embedded in those groups).
"""

from __future__ import annotations

import json
from dataclasses import dataclass
from typing import List

from .graph import Cluster, cluster_id
from .records import UNKNOWN, LineageRecord

EXACT_DUPLICATE = "exact-duplicate"
RENAMED_URL = "renamed-url"
SOURCE_REUSE = "source-reuse"
CATEGORY_KEYS = (EXACT_DUPLICATE, RENAMED_URL, SOURCE_REUSE)


@dataclass
class Finding:
    cluster_id: str
    size: int
    categories: List[str]
    transitive: bool
    cross_manifest: bool
    cross_group: bool
    manifests: List[str]
    declared_groups: List[str]
    kinds: List[str]
    join_key_types: List[str]
    member_refs: List[str]
    examples: List[dict]

    def to_json(self) -> dict:
        return {
            "cluster_id": self.cluster_id,
            "size": self.size,
            "categories": self.categories,
            "transitive": self.transitive,
            "cross_manifest": self.cross_manifest,
            "cross_group": self.cross_group,
            "manifests": self.manifests,
            "declared_groups": self.declared_groups,
            "kinds": self.kinds,
            "join_key_types": self.join_key_types,
            "member_refs": self.member_refs,
            "examples": self.examples,
        }


def _member_example(rec: LineageRecord) -> dict:
    return {
        "ref": rec.item_ref,
        "origin": rec.origin,
        "source_id": rec.source_id,
        "content_hash": rec.content_hash,
        "product_revision": rec.product_revision,
        "declared_group": rec.declared_group,
        "location": rec.location,
        "label": rec.label,
    }


def classify(cluster: Cluster) -> Finding:
    members = cluster.members
    categories: List[str] = []
    if "hash" in cluster.key_types:
        categories.append(EXACT_DUPLICATE)
    known_locations = sorted(
        {m.location for m in members if m.location != UNKNOWN}
    )
    if len(known_locations) >= 2:
        categories.append(RENAMED_URL)
    if "source" in cluster.key_types:
        categories.append(SOURCE_REUSE)

    manifests = sorted({m.manifest for m in members})
    groups = sorted({m.declared_group for m in members})
    kinds = sorted({m.kind for m in members})
    return Finding(
        cluster_id=cluster_id(cluster),
        size=len(members),
        categories=categories,
        transitive=not cluster.has_spanning_key,
        cross_manifest=len(manifests) >= 2,
        cross_group=len(groups) >= 2,
        manifests=manifests,
        declared_groups=groups,
        kinds=kinds,
        join_key_types=sorted(cluster.key_types),
        member_refs=[m.item_ref for m in members],
        examples=[_member_example(m) for m in members[:5]],
    )


@dataclass
class AnalysisResult:
    total_records: int
    singletons: int
    multi_member_clusters: int
    findings: List[Finding]
    counts: dict
    cross_manifest_clusters: int
    cross_group_clusters: int
    unobserved: dict

    def to_json(self) -> dict:
        return {
            "totals": {
                "records": self.total_records,
                "singletons": self.singletons,
                "multi_member_clusters": self.multi_member_clusters,
            },
            "counts": self.counts,
            "cross_manifest_clusters": self.cross_manifest_clusters,
            "cross_group_clusters": self.cross_group_clusters,
            "unobserved": self.unobserved,
            "findings": [f.to_json() for f in self.findings],
        }


def analyze(records: List[LineageRecord]) -> AnalysisResult:
    """Cluster records and classify every multi-member cluster.

    Deterministic: findings and counts are independent of input order.
    """
    from .graph import build_clusters

    clusters = [c for c in build_clusters(records) if c.size >= 2]
    findings = sorted(
        (classify(c) for c in clusters),
        key=lambda f: (not f.transitive, -f.size, f.cluster_id),
    )
    counts = {
        EXACT_DUPLICATE: sum(1 for f in findings if EXACT_DUPLICATE in f.categories),
        RENAMED_URL: sum(1 for f in findings if RENAMED_URL in f.categories),
        SOURCE_REUSE: sum(1 for f in findings if SOURCE_REUSE in f.categories),
        "transitive-source": sum(1 for f in findings if f.transitive),
        "cross-manifest": sum(1 for f in findings if f.cross_manifest),
        "cross-group": sum(1 for f in findings if f.cross_group),
    }
    unobserved = {
        "unknown_content_hash_records": sum(
            1 for r in records if r.content_hash == UNKNOWN
        ),
        "unknown_source_id_records": sum(
            1 for r in records if r.source_id == UNKNOWN
        ),
        "unknown_product_revision_records": sum(
            1 for r in records if r.product_revision == UNKNOWN
        ),
        "unknown_declared_group_records": sum(
            1 for r in records if r.declared_group == UNKNOWN
        ),
        "note": "unknown keys are kept unknown; they never join records and "
        "never produce findings",
    }
    return AnalysisResult(
        total_records=len(records),
        singletons=len(records) - sum(c.size for c in clusters),
        multi_member_clusters=len(clusters),
        findings=findings,
        counts=counts,
        cross_manifest_clusters=counts["cross-manifest"],
        cross_group_clusters=counts["cross-group"],
        unobserved=unobserved,
    )


def findings_to_json(result: AnalysisResult) -> str:
    return json.dumps(result.to_json(), indent=2, sort_keys=True) + "\n"
