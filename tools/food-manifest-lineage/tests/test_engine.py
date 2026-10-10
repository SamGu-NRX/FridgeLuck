"""Engine tests: clustering semantics, unknown handling, and determinism."""

import random

from lineage.detectors import EXACT_DUPLICATE, RENAMED_URL, SOURCE_REUSE, analyze
from lineage.records import UNKNOWN, LineageRecord


def rec(manifest, item_id, *, origin=UNKNOWN, source_id=UNKNOWN, content_hash=UNKNOWN,
        declared_group=UNKNOWN, location=UNKNOWN, kind="image", **kw):
    return LineageRecord(
        manifest=manifest,
        item_id=item_id,
        kind=kind,
        origin=origin,
        source_id=source_id,
        content_hash=content_hash,
        declared_group=declared_group,
        location=location,
        **kw,
    )


def test_transitive_cluster_without_spanning_key():
    records = [
        # A ~ B by source identity (same Open Images id, different bytes),
        # B ~ C by exact hash; A and C share nothing directly.
        rec("m1", "a", origin="openimages", source_id="X", content_hash="h10",
            location="u1", declared_group="g1"),
        rec("m2", "b", origin="openimages", source_id="X", content_hash="h11",
            location="u2", declared_group="g2"),
        rec("m2", "c", origin="openimages", source_id="Y", content_hash="h11",
            location="u3", declared_group="g3"),
    ]
    result = analyze(records)
    assert result.multi_member_clusters == 1
    finding = result.findings[0]
    assert finding.size == 3
    assert finding.transitive is True
    assert EXACT_DUPLICATE in finding.categories
    assert SOURCE_REUSE in finding.categories
    assert result.counts["transitive-source"] == 1


def test_direct_cluster_with_spanning_key_is_not_transitive():
    records = [
        rec("m1", "a", origin="usda-fdc", source_id="1", declared_group="g1"),
        rec("m2", "b", origin="usda-fdc", source_id="1", declared_group="g1"),
    ]
    result = analyze(records)
    assert result.multi_member_clusters == 1
    assert result.findings[0].transitive is False


def test_unknown_never_joins_unknown():
    records = [
        rec("m1", "a"),
        rec("m1", "b"),
        rec("m2", "c", origin="food-101"),
    ]
    result = analyze(records)
    assert result.multi_member_clusters == 0
    assert result.singletons == 3
    assert result.unobserved["unknown_content_hash_records"] == 3
    assert result.unobserved["unknown_source_id_records"] == 3


def test_cross_origin_same_source_id_does_not_join():
    records = [
        rec("m1", "a", origin="food-101", source_id="img/1.jpg"),
        rec("m2", "b", origin="foodseg103", source_id="img/1.jpg"),
    ]
    result = analyze(records)
    assert result.multi_member_clusters == 0


def test_exact_hash_joins_across_origins():
    records = [
        rec("m1", "a", origin="food-101", source_id="p1", content_hash="same"),
        rec("m2", "b", origin="foodseg103", source_id="p2", content_hash="same"),
    ]
    result = analyze(records)
    assert result.multi_member_clusters == 1
    finding = result.findings[0]
    assert EXACT_DUPLICATE in finding.categories
    assert finding.cross_manifest is True


def test_renamed_url_requires_two_known_locations():
    joined = [
        rec("m1", "a", origin="openimages", source_id="X", content_hash="h1", location="u1"),
        rec("m2", "b", origin="openimages", source_id="X", content_hash="h1", location="u2"),
    ]
    result = analyze(joined)
    assert result.counts["renamed-url"] == 1

    same_location = [
        joined[0],
        rec("m2", "b", origin="openimages", source_id="X", content_hash="h1", location="u1"),
    ]
    result2 = analyze(same_location)
    assert result2.counts["renamed-url"] == 0
    assert EXACT_DUPLICATE in result2.findings[0].categories


def test_order_independence():
    records = [
        rec("m1", "a", origin="openimages", source_id="X", content_hash="h10", location="u1"),
        rec("m2", "b", origin="openimages", source_id="X", content_hash="h11", location="u2"),
        rec("m2", "c", origin="openimages", source_id="Y", content_hash="h11", location="u3"),
        rec("m3", "d", origin="food-101", source_id="z", content_hash="h12", location="u4"),
    ]
    baseline = analyze(records).to_json()
    shuffled = list(records)
    random.Random(7).shuffle(shuffled)
    assert analyze(shuffled).to_json() == baseline


def test_relabelled_ids_keep_structure():
    """Independence: renaming manifests/items must not change detection counts."""

    def build(tag):
        return [
            rec(f"{tag}-m1", f"{tag}-a", origin="openimages", source_id="X",
                content_hash="h10", location="u1", declared_group="g1"),
            rec(f"{tag}-m2", f"{tag}-b", origin="openimages", source_id="X",
                content_hash="h11", location="u2", declared_group="g2"),
            rec(f"{tag}-m2", f"{tag}-c", origin="openimages", source_id="Y",
                content_hash="h11", location="u3", declared_group="g3"),
        ]

    first = analyze(build("one"))
    second = analyze(build("two"))
    assert first.counts == second.counts
    assert first.multi_member_clusters == second.multi_member_clusters == 1
    assert RENAMED_URL in first.findings[0].categories
