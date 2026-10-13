"""Union-find lineage graph over lineage records.

Two records join when they share an exact join key instance. A record with
an unknown key contributes no key, so unknown never joins unknown and
single-declaration data cannot collide with anything.

Join keys (see records.LineageRecord):
- ("hash", content_hash)                  exact byte identity
- ("source", origin, source_id)           upstream source identity
"""

from __future__ import annotations

from collections import defaultdict
from dataclasses import dataclass, field
from typing import Dict, List, Optional, Sequence, Set, Tuple

from .records import LineageRecord

KeyT = Tuple[str, ...]


class _UnionFind:
    def __init__(self, size: int):
        self.parent = list(range(size))
        self.rank = [0] * size

    def find(self, i: int) -> int:
        while self.parent[i] != i:
            self.parent[i] = self.parent[self.parent[i]]
            i = self.parent[i]
        return i

    def union(self, a: int, b: int) -> None:
        ra, rb = self.find(a), self.find(b)
        if ra == rb:
            return
        if self.rank[ra] < self.rank[rb]:
            ra, rb = rb, ra
        self.parent[rb] = ra
        if self.rank[ra] == self.rank[rb]:
            self.rank[ra] += 1


@dataclass
class Cluster:
    """A connected component of the lineage graph with its join evidence."""

    members: List[LineageRecord]
    # Join key instances that connect >= 2 members of this cluster,
    # with the member refs sharing each key.
    key_instances: Dict[KeyT, List[str]] = field(default_factory=dict)

    @property
    def size(self) -> int:
        return len(self.members)

    @property
    def key_types(self) -> Set[str]:
        return {key[0] for key in self.key_instances}

    @property
    def has_spanning_key(self) -> bool:
        """True when one single key instance connects every member."""
        return any(len(refs) == self.size for refs in self.key_instances.values())


def build_clusters(records: Sequence[LineageRecord]) -> List[Cluster]:
    """Cluster records by shared exact keys; unknown keys never join."""
    uf = _UnionFind(len(records))
    key_owner: Dict[KeyT, int] = {}
    for i, rec in enumerate(records):
        for key in (rec.hash_key(), rec.source_key()):
            if key is None:
                continue
            if key in key_owner:
                uf.union(i, key_owner[key])
            else:
                key_owner[key] = i

    by_root: Dict[int, List[int]] = defaultdict(list)
    for i in range(len(records)):
        by_root[uf.find(i)].append(i)

    clusters: List[Cluster] = []
    for indexes in by_root.values():
        members = [records[i] for i in sorted(indexes, key=lambda j: records[j].item_ref)]
        if len(members) < 2:
            continue  # singleton: no reuse evidence, not part of findings
        refs_by_key: Dict[KeyT, List[str]] = defaultdict(list)
        for member in members:
            for key in (member.hash_key(), member.source_key()):
                if key is not None:
                    refs_by_key[key].append(member.item_ref)
        key_instances = {
            key: sorted(refs)
            for key, refs in refs_by_key.items()
            if len(refs) >= 2
        }
        clusters.append(Cluster(members=members, key_instances=key_instances))

    clusters.sort(key=lambda c: c.members[0].item_ref)
    return clusters


def cluster_id(cluster: Cluster) -> str:
    """Deterministic id derived from the cluster's member refs."""
    import hashlib

    joined = "|".join(rec.item_ref for rec in cluster.members)
    return "cl-" + hashlib.sha256(joined.encode("utf-8")).hexdigest()[:12]


def find_key_for(records: Sequence[LineageRecord], key: KeyT) -> Optional[Cluster]:
    """Return the cluster containing the two records joined by ``key`` (tests)."""
    for cluster in build_clusters(records):
        if key in cluster.key_instances:
            return cluster
    return None
