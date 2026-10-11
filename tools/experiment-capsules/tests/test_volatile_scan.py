"""Volatile-content scanner tests, with literal expected values."""

from volatile_scan import scan_text

SHA256_EXAMPLE = (
    "44136fa355b3678a1146ad16f7e8649e94fb4fc21fe77e8310c060f61caaff8a"
)
GIT_SHA_EXAMPLE = "2fd0dfea1a86eb9d341e43a339e368ff3088c64d"


def patterns(hits):
    return sorted(h.pattern for h in hits)


def test_clean_table_content_has_no_hits():
    text = "food_group\tdishes\tkcal_total\ngrains\t1\t180\n"
    assert scan_text(text) == []


def test_64hex_sha256_is_not_volatile():
    # Capsule digests legitimately appear in reports; they must not match.
    assert scan_text(f"binding sha256: {SHA256_EXAMPLE}\n") == []


def test_40hex_git_sha_is_flagged():
    hits = scan_text(f"built at {GIT_SHA_EXAMPLE}\n")
    assert patterns(hits) == ["git-sha-like"]
    assert hits[0].line == 1


def test_iso_datetime_is_flagged():
    hits = scan_text("run 2026-10-11T14:03:07Z finished\n")
    assert patterns(hits) == ["iso-datetime"]


def test_space_separated_datetime_is_flagged():
    hits = scan_text("run 2026-10-11 14:03 finished\n")
    assert patterns(hits) == ["iso-datetime"]


def test_epoch_seconds_are_flagged():
    hits = scan_text("finished at 1760000000 exactly\n")
    assert patterns(hits) == ["unix-epoch-seconds"]


def test_plain_date_and_run_ids_are_content():
    text = "window: 2026-03-02\nrun_id: r1\nversion: 10\n"
    assert scan_text(text) == []


def test_line_numbers_are_reported():
    hits = scan_text("clean\n" * 3 + f"sha {GIT_SHA_EXAMPLE}\n")
    assert hits[0].line == 4
