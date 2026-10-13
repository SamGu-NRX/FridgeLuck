"""Food-manifest lineage: adapters, union-find graph, and detectors."""

from .records import (
    UNKNOWN,
    KINDS,
    LineageRecord,
    canonical_dhash,
    norm,
    sha256_hex,
)
from .adapters import ADAPTERS, AdapterInput, ManifestData, run_adapter
from .graph import Cluster, build_clusters, cluster_id
from .detectors import (
    EXACT_DUPLICATE,
    RENAMED_URL,
    SOURCE_REUSE,
    CATEGORY_KEYS,
    AnalysisResult,
    Finding,
    analyze,
    findings_to_json,
)

__all__ = [
    "UNKNOWN",
    "KINDS",
    "LineageRecord",
    "canonical_dhash",
    "norm",
    "sha256_hex",
    "ADAPTERS",
    "AdapterInput",
    "ManifestData",
    "run_adapter",
    "Cluster",
    "build_clusters",
    "cluster_id",
    "EXACT_DUPLICATE",
    "RENAMED_URL",
    "SOURCE_REUSE",
    "CATEGORY_KEYS",
    "AnalysisResult",
    "Finding",
    "analyze",
    "findings_to_json",
]
