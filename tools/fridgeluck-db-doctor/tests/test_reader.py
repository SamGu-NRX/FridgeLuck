"""Reader stream tests: refusals, read-only guarantees, bounded fetch. Owner: integrator."""
from __future__ import annotations

import os
import sqlite3

import codes
import model
import reader

from conftest import sha256_and_listing


def test_missing_refused_and_not_created(tmp_path):
    target = tmp_path / "ghost.sqlite"
    try:
        reader.probe_input(str(target))
        raise AssertionError("expected RefusalError")
    except model.RefusalError as e:
        assert e.code == codes.INPUT_MISSING
    assert not target.exists()


def test_directory_refused(tmp_path):
    try:
        reader.probe_input(str(tmp_path))
        raise AssertionError("expected RefusalError")
    except model.RefusalError as e:
        assert e.code == codes.INPUT_NOT_REGULAR


def test_symlink_refused_not_followed(tmp_path, healthy_db):
    link = tmp_path / "link.sqlite"
    os.symlink(healthy_db, link)
    try:
        reader.probe_input(str(link))
        raise AssertionError("expected RefusalError")
    except model.RefusalError as e:
        assert e.code == codes.INPUT_SYMLINK


def test_non_sqlite_refused(tmp_path):
    p = tmp_path / "plain.txt"
    p.write_bytes(b"hello world, definitely not a database" * 4)
    try:
        reader.probe_input(str(p))
        raise AssertionError("expected RefusalError")
    except model.RefusalError as e:
        assert e.code == codes.INPUT_NOT_SQLITE


def test_tiny_file_refused(tmp_path):
    p = tmp_path / "tiny.bin"
    p.write_bytes(b"\x00\x01\x02")
    try:
        reader.probe_input(str(p))
        raise AssertionError("expected RefusalError")
    except model.RefusalError as e:
        assert e.code == codes.INPUT_NOT_SQLITE


def test_corrupt_header_refused(tmp_path, healthy_db):
    p = tmp_path / "corrupt-header.sqlite"
    p.write_bytes(b"XQLite format 3\x00" + healthy_db.read_bytes()[16:])
    try:
        reader.probe_input(str(p))
        raise AssertionError("expected RefusalError")
    except model.RefusalError as e:
        assert e.code == codes.INPUT_NOT_SQLITE


def test_sidecars_refused(tmp_path, healthy_db):
    for suffix in ("-wal", "-shm", "-journal"):
        sidecar = tmp_path / ("healthy.sqlite" + suffix)
        sidecar.write_bytes(b"pending-state" * 4)
        try:
            reader.probe_input(str(healthy_db))
            raise AssertionError(f"expected RefusalError for {suffix}")
        except model.RefusalError as e:
            assert e.code == codes.INPUT_SIDECAR_PRESENT
        sidecar.unlink()


def test_open_read_only_and_bytes_unchanged(healthy_db):
    before = sha256_and_listing(healthy_db)
    con, info, handle = reader.open_read_only(str(healthy_db), model.Budget())
    try:
        assert info.basename == "healthy.sqlite"
        assert info.size_bytes == healthy_db.stat().st_size
        assert len(info.sha256_16) == 16
        rows, truncated = reader.bounded_fetch(
            con.execute("SELECT COUNT(*) FROM recipes"), model.Budget()
        )
        assert rows[0][0] == 2
        assert truncated is False
    finally:
        con.close()
    assert sha256_and_listing(healthy_db) == before


def test_query_only_rejects_writes(healthy_db):
    con, _info, _handle = reader.open_read_only(str(healthy_db), model.Budget())
    try:
        try:
            con.execute("CREATE TABLE evil(x)")
            raise AssertionError("write unexpectedly allowed")
        except sqlite3.OperationalError:
            pass
    finally:
        con.close()
    assert sha256_and_listing(healthy_db)[0] == sha256_and_listing(healthy_db)[0]


def test_bounded_fetch_truncates(tmp_path):
    p = tmp_path / "many-rows.sqlite"
    con = sqlite3.connect(str(p))
    con.execute("CREATE TABLE t(x INTEGER)")
    con.executemany("INSERT INTO t VALUES (?)", [(i,) for i in range(500)])
    con.commit()
    con.close()
    con2, _info, _handle = reader.open_read_only(str(p), model.Budget())
    try:
        rows, truncated = reader.bounded_fetch(
            con2.execute("SELECT x FROM t"), model.Budget(max_rows=100)
        )
        assert truncated is True
        assert len(rows) <= 100
    finally:
        con2.close()
    assert sha256_and_listing(p)[0] == sha256_and_listing(p)[0]
