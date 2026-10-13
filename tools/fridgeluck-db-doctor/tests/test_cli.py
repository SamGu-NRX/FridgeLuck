"""CLI tests: real subprocess runs, declared exits, sentinels, immutability. Owner: integrator."""
from __future__ import annotations

import json
import shutil
import sqlite3

from conftest import SENTINEL, make_healthy_db, sha256_and_listing


def _report(proc):
    return json.loads(proc.stdout)


def test_exit_0_healthy(cli, healthy_db):
    before = sha256_and_listing(healthy_db)
    proc = cli("--input", str(healthy_db))
    after = sha256_and_listing(healthy_db)
    assert proc.returncode == 0, proc.stdout + proc.stderr
    report = _report(proc)
    assert report["verdict"] == "restorable_candidate"
    assert report["input"]["basename"] == "healthy.sqlite"
    assert report["input"]["size_bytes"] > 0
    assert len(report["input"]["sha256_16"]) == 16
    assert before == after  # bytes AND directory contents unchanged


def test_exit_2_missing_not_created(cli, tmp_path):
    missing = tmp_path / "missing.sqlite"
    proc = cli("--input", str(missing))
    assert proc.returncode == 2
    report = _report(proc)
    assert report["refused"]["code"] == "INPUT_MISSING"
    assert report["verdict"] == "not_readable"
    assert not missing.exists()


def test_exit_2_non_sqlite(cli, tmp_path):
    p = tmp_path / "text.sqlite"
    p.write_text("this is not a database at all")
    proc = cli("--input", str(p))
    assert proc.returncode == 2
    assert _report(proc)["refused"]["code"] == "INPUT_NOT_SQLITE"


def test_exit_2_directory_input(cli, tmp_path):
    proc = cli("--input", str(tmp_path))
    assert proc.returncode == 2
    assert _report(proc)["refused"]["code"] == "INPUT_NOT_REGULAR_FILE"


def test_exit_2_symlink(cli, tmp_path, healthy_db):
    link = tmp_path / "link.sqlite"
    import os

    os.symlink(healthy_db, link)
    proc = cli("--input", str(link))
    assert proc.returncode == 2
    assert _report(proc)["refused"]["code"] == "INPUT_SYMLINK"


def test_exit_2_sidecars(cli, tmp_path, healthy_db):
    for suffix in ("-wal", "-shm", "-journal"):
        sidecar = tmp_path / ("healthy.sqlite" + suffix)
        sidecar.write_bytes(b"pending" * 8)
        proc = cli("--input", str(healthy_db))
        assert proc.returncode == 2
        assert _report(proc)["refused"]["code"] == "INPUT_SIDECAR_PRESENT"
        assert sidecar.exists()  # untouched
        sidecar.unlink()


def test_exit_1_broken_fk(cli, tmp_path):
    p = tmp_path / "bad-fk.sqlite"
    con = sqlite3.connect(str(p))
    con.execute("CREATE TABLE recipes (id INTEGER PRIMARY KEY)")
    con.execute(
        "CREATE TABLE cooking_history (id INTEGER PRIMARY KEY,"
        " recipe_id INTEGER NOT NULL REFERENCES recipes(id))"
    )
    con.execute("INSERT INTO recipes VALUES (1)")
    con.execute("PRAGMA foreign_keys=OFF")
    con.execute("INSERT INTO cooking_history VALUES (1, 999)")
    con.commit()
    con.close()
    before = sha256_and_listing(p)
    proc = cli("--input", str(p))
    after = sha256_and_listing(p)
    assert proc.returncode == 1
    report = _report(proc)
    assert report["verdict"] == "readable_with_issues"
    assert any(i["code"] == "FOREIGN_KEY_VIOLATIONS" for i in report["issues"])
    assert before == after


def test_exit_1_or_2_truncated(cli, tmp_path, healthy_db):
    raw = healthy_db.read_bytes()
    truncated = tmp_path / "truncated.sqlite"
    truncated.write_bytes(raw[: len(raw) // 2])
    proc = cli("--input", str(truncated))
    assert proc.returncode in (1, 2)
    report = _report(proc)
    assert report["verdict"] in ("not_readable", "readable_with_issues")
    assert report["verdict"] != "restorable_candidate"


def test_exit_3_budget_limited(cli, tmp_path):
    p = tmp_path / "big.sqlite"
    con = sqlite3.connect(str(p))
    con.execute("CREATE TABLE recipes (id INTEGER PRIMARY KEY, name TEXT NOT NULL)")
    con.executemany("INSERT INTO recipes VALUES (?, 'r')", [(i,) for i in range(3000)])
    con.commit()
    con.close()
    proc = cli("--input", str(p), "--max-steps", "1")
    assert proc.returncode == 3
    report = _report(proc)
    assert report["verdict"] != "restorable_candidate"
    limits = report["limits"]
    assert limits["cancelled"] or limits["truncated"] or limits["deadline_hit"]


def test_sentinel_never_appears_in_output(cli, tmp_path, healthy_db):
    proc = cli("--input", str(healthy_db))
    assert SENTINEL not in proc.stdout and SENTINEL not in proc.stderr

    # plant the sentinel mid-file to corrupt a data page; run again
    raw = bytearray(healthy_db.read_bytes())
    pos = len(raw) // 2
    raw[pos : pos + len(SENTINEL)] = SENTINEL.encode()
    corrupt = tmp_path / "corrupt.sqlite"
    corrupt.write_bytes(bytes(raw))
    proc2 = cli("--input", str(corrupt))
    assert SENTINEL not in proc2.stdout and SENTINEL not in proc2.stderr


def test_hostile_filenames(cli, tmp_path, healthy_db):
    for name in (
        'weird "quoted" & spaced.sqlite',
        "-leading-dash.sqlite",
        "unicode-é中文.sqlite",
        "tab\tname.sqlite",
    ):
        target = tmp_path / name
        shutil.copy(healthy_db, target)
        proc = cli("--input=" + str(target))  # = form survives leading dashes
        assert proc.returncode == 0, f"{name}: {proc.stdout} {proc.stderr}"
        assert _report(proc)["input"]["basename"] == name
        assert sha256_and_listing(target)[0] == sha256_and_listing(healthy_db)[0]


def test_stderr_clean_on_success(cli, healthy_db):
    proc = cli("--input", str(healthy_db))
    assert proc.returncode == 0
    assert proc.stderr == ""


def test_directory_contents_unchanged_after_all_refusals(cli, tmp_path):
    before = sha256_and_listing(tmp_path)
    cli("--input", str(tmp_path / "nope.sqlite"))
    cli("--input", str(tmp_path))
    after = sha256_and_listing(tmp_path)
    assert before == after
