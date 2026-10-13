"""Literal tests for safe read-only input handling.

Each test observes the validator's refusal codes and, critically, that
refused/valid runs never create or mutate anything on disk.
"""

import hashlib
import os
import sqlite3
from pathlib import Path

import pytest

from sqlite_state_diff import readers


def make_db(path):
    conn = sqlite3.connect(str(path))
    conn.execute("CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT)")
    conn.execute("INSERT INTO t VALUES (1, 'x')")
    conn.commit()
    conn.close()


def digest_file(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def snapshot_dir(d):
    return sorted((p.name, p.stat().st_size) for p in Path(d).iterdir())


def test_missing_refused_and_never_created(tmp_path):
    target = tmp_path / "nope.sqlite"
    with pytest.raises(readers.InputRejected) as caught:
        readers.validate_input(str(target))
    assert caught.value.code == "missing"
    assert not target.exists()


def test_directory_refused(tmp_path):
    d = tmp_path / "adir.sqlite"
    d.mkdir()
    with pytest.raises(readers.InputRejected) as caught:
        readers.validate_input(str(d))
    assert caught.value.code == "not_regular"


def test_fifo_refused(tmp_path):
    f = tmp_path / "pipe.sqlite"
    os.mkfifo(str(f))
    with pytest.raises(readers.InputRejected) as caught:
        readers.validate_input(str(f))
    assert caught.value.code == "not_regular"


def test_symlink_refused(tmp_path):
    real = tmp_path / "real.sqlite"
    make_db(real)
    link = tmp_path / "link.sqlite"
    os.symlink(str(real), str(link))
    with pytest.raises(readers.InputRejected) as caught:
        readers.validate_input(str(link))
    assert caught.value.code == "symlink"


def test_parent_traversal_refused(tmp_path):
    real = tmp_path / "real.sqlite"
    make_db(real)
    (tmp_path / "sub").mkdir()
    with pytest.raises(readers.InputRejected) as caught:
        readers.validate_input(str(tmp_path / "sub" / ".." / "real.sqlite"))
    assert caught.value.code == "escape"


@pytest.mark.parametrize("suffix", ["-wal", "-shm", "-journal"])
def test_sidecars_refused(tmp_path, suffix):
    db = tmp_path / "s.sqlite"
    make_db(db)
    (tmp_path / ("s.sqlite" + suffix)).write_bytes(b"")
    with pytest.raises(readers.InputRejected) as caught:
        readers.validate_input(str(db))
    assert caught.value.code == "sidecar"


def test_wal_header_refused_even_without_sidecars(tmp_path):
    db = tmp_path / "w.sqlite"
    conn = sqlite3.connect(str(db))
    conn.execute("PRAGMA journal_mode = WAL")
    conn.execute("CREATE TABLE t (id INTEGER PRIMARY KEY)")
    conn.commit()
    conn.close()
    assert not (tmp_path / "w.sqlite-wal").exists()
    with pytest.raises(readers.InputRejected) as caught:
        readers.validate_input(str(db))
    assert caught.value.code == "wal_mode"


def test_not_sqlite_refused(tmp_path):
    f = tmp_path / "n.sqlite"
    f.write_bytes(b"definitely not a database" * 10)
    with pytest.raises(readers.InputRejected) as caught:
        readers.validate_input(str(f))
    assert caught.value.code == "not_sqlite"


def test_valid_open_and_read(tmp_path):
    db = tmp_path / "ok.sqlite"
    make_db(db)
    conn = readers.open_database_ro(str(db))
    try:
        assert conn.execute("SELECT v FROM t WHERE id = 1").fetchone()[0] == "x"
    finally:
        conn.close()


def test_uri_escaping_hostile_directory(tmp_path):
    d = tmp_path / "weird dir #?%"
    d.mkdir()
    db = d / "db.sqlite"
    make_db(db)
    conn = readers.open_database_ro(str(db))
    try:
        assert conn.execute("SELECT count(*) FROM t").fetchone()[0] == 1
    finally:
        conn.close()


def test_open_leaves_input_and_dir_untouched(tmp_path):
    db = tmp_path / "ok.sqlite"
    make_db(db)
    before_hash = digest_file(db)
    before_dir = snapshot_dir(tmp_path)
    conn = readers.open_database_ro(str(db))
    conn.execute("SELECT count(*) FROM sqlite_master").fetchall()
    conn.close()
    assert digest_file(db) == before_hash
    assert snapshot_dir(tmp_path) == before_dir
