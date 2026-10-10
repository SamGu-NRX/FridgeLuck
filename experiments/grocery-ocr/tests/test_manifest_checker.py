"""Manifest checker must reject planted corruptions and accept a clean manifest."""
import check_manifest
from conftest import make_manifest, make_product


def test_clean_manifest_passes(tmp_path):
    failures, counts = check_manifest.validate(make_manifest([make_product()]))
    assert failures == []
    assert counts == {"aligned": 1, "metadata_only": 0, "unresolved": 0}


def test_duplicate_product_groups_fail():
    dup = make_product()
    failures, _ = check_manifest.validate(make_manifest([dup, dict(dup)]))
    assert any("duplicate_groups" in f for f in failures)


def test_unsupported_transcription_claim_fails():
    # claims aligned but has no reference text
    p = make_product(reference_text=None, has_ingredient_reference_text=False)
    failures, _ = check_manifest.validate(make_manifest([p]))
    assert any("alignment_consistent" in f and "reference text" in f for f in failures)


def test_aligned_without_ingredient_image_fails():
    p = make_product()
    p["roles"]["ingredients"] = {"url": "https://img/ingredients.jpg", "fetch_status": "error"}
    failures, _ = check_manifest.validate(make_manifest([p]))
    assert any("aligned without a hashed ingredients image" in f for f in failures)


def test_metadata_only_with_text_and_image_fails():
    p = make_product(alignment="metadata_only")
    failures, _ = check_manifest.validate(make_manifest([p]))
    assert any("marked metadata_only" in f for f in failures)


def test_planted_mismatched_image_hash_fails(tmp_path):
    p = make_product()
    front = p["roles"]["front"]
    cache = tmp_path / "imgcache"
    cache.mkdir()
    img = cache / "3017620422003__front.jpg"
    img.write_bytes(b"not the pinned bytes")
    # pin the hash of DIFFERENT content in the manifest
    import hashlib
    front["sha256"] = hashlib.sha256(b"other bytes entirely").hexdigest()
    failures, _ = check_manifest.validate(make_manifest([p]), cache_dir=str(cache))
    assert any("sha256 mismatch" in f for f in failures)


def test_matching_image_hash_passes(tmp_path):
    import hashlib
    p = make_product()
    cache = tmp_path / "imgcache"
    cache.mkdir()
    for role, entry in p["roles"].items():
        img = cache / f"3017620422003__{role}.jpg"
        img.write_bytes(b"real bytes")
        entry["sha256"] = hashlib.sha256(b"real bytes").hexdigest()
    failures, _ = check_manifest.validate(make_manifest([p]), cache_dir=str(cache))
    assert failures == []


def test_missing_revision_or_license_fails():
    p = make_product(revision={})
    p["source"] = {"database": "Open Food Facts"}
    failures, _ = check_manifest.validate(make_manifest([p]))
    assert any("missing product revision" in f for f in failures)
    assert any("missing permission/attribution" in f for f in failures)
