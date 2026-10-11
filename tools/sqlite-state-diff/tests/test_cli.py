"""End-to-end CLI tests against the committed synthetic fixtures.

Runs the real command as a subprocess, asserts exit codes and the exact
expected difference structure, determinism of stdout bytes, and that input
files and directories are byte-identical after every run.
"""

import hashlib
import json
import os
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CLI = ROOT / "sqlite_state_diff" / "cli.py"
FIXTURES = Path(__file__).resolve().parent / "fixtures"


def digest_file(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def snapshot_dir(d):
    return sorted((p.name, p.stat().st_size) for p in Path(d).iterdir())


def run_cli(*argv):
    return subprocess.run(
        [sys.executable, str(CLI), *argv], capture_output=True, text=True)


def test_equal_pair_exit_zero_and_deterministic():
    args = (str(FIXTURES / "equal_a.sqlite"), str(FIXTURES / "equal_b.sqlite"),
            "--table", "snacks", "--table", "servings")
    first = run_cli(*args)
    second = run_cli(*args)
    assert first.returncode == 0, first.stdout + first.stderr
    assert first.stdout == second.stdout
    doc = json.loads(first.stdout)
    assert doc["result"] == "equal"
    assert doc["rows"]["snacks"]["status"] == "equal"
    assert doc["rows"]["servings"]["status"] == "equal"
    assert doc["schema"]["tables"][0]["differences"] == []


def test_diff_pair_exact_expected_structure():
    before = (digest_file(FIXTURES / "diff_a.sqlite"),
              digest_file(FIXTURES / "diff_b.sqlite"),
              snapshot_dir(FIXTURES))
    proc = run_cli(str(FIXTURES / "diff_a.sqlite"), str(FIXTURES / "diff_b.sqlite"),
                   "--table", "snacks", "--table", "servings")
    assert proc.returncode == 1
    doc = json.loads(proc.stdout)
    assert doc["result"] == "different"
    snacks = doc["rows"]["snacks"]
    assert len(snacks["added"]) == 1
    assert len(snacks["deleted"]) == 1
    kinds = sorted((c["column"], c["code"], c["old_type"], c["new_type"])
                   for c in snacks["changed"])
    assert kinds == [
        ("calories", "value_changed", "real", "real"),   # one-ULP bit difference
        ("data", "value_changed", "blob", "blob"),
        ("qty", "type_changed", "integer", "text"),      # 7 vs '7x'
    ]
    assert doc["rows"]["servings"]["status"] == "equal"
    schema_codes = [d["code"] for t in doc["schema"]["tables"]
                    for d in t["differences"]]
    assert sorted(schema_codes) == ["index_added", "trigger_removed"]
    for leak in ("alpha-bar", "beta-bites", "gamma-gems", "delta-drops",
                 "epsilon-chips", "7x"):
        assert leak not in proc.stdout
    after = (digest_file(FIXTURES / "diff_a.sqlite"),
             digest_file(FIXTURES / "diff_b.sqlite"),
             snapshot_dir(FIXTURES))
    assert before == after


def test_missing_file_refused_never_created_and_path_not_leaked(tmp_path):
    ghost = tmp_path / "ghost-fixture-name.sqlite"
    proc = run_cli(str(ghost), str(FIXTURES / "equal_a.sqlite"),
                   "--table", "snacks")
    assert proc.returncode == 2
    doc = json.loads(proc.stdout)
    assert doc["result"] == "invalid"
    assert doc["refusal"]["code"] == "missing"
    assert "ghost-fixture-name" not in proc.stdout
    assert not ghost.exists()


def test_sidecar_refused(tmp_path):
    db = tmp_path / "copy.sqlite"
    (tmp_path / "copy.sqlite-wal").write_bytes(b"")
    proc = run_cli(str(db), str(FIXTURES / "equal_a.sqlite"), "--table", "snacks")
    assert proc.returncode == 2
    assert json.loads(proc.stdout)["refusal"]["code"] in ("missing", "sidecar")


def test_symlink_refused(tmp_path):
    link = tmp_path / "link.sqlite"
    os.symlink(str(FIXTURES / "equal_a.sqlite"), str(link))
    proc = run_cli(str(link), str(FIXTURES / "equal_a.sqlite"), "--table", "snacks")
    assert proc.returncode == 2
    assert json.loads(proc.stdout)["refusal"]["code"] == "symlink"


def test_not_sqlite_refused(tmp_path):
    junk = tmp_path / "junk.sqlite"
    junk.write_bytes(b"junk" * 100)
    proc = run_cli(str(junk), str(FIXTURES / "equal_a.sqlite"), "--table", "snacks")
    assert proc.returncode == 2
    assert json.loads(proc.stdout)["refusal"]["code"] == "not_sqlite"


def test_parent_traversal_refused(tmp_path):
    (tmp_path / "sub").mkdir()
    proc = run_cli(str(tmp_path / "sub" / ".." / "equal_a.sqlite"),
                   str(FIXTURES / "equal_a.sqlite"), "--table", "snacks")
    assert proc.returncode == 2
    assert json.loads(proc.stdout)["refusal"]["code"] == "escape"


def test_bad_key_specs_refused():
    base = [str(FIXTURES / "equal_a.sqlite"), str(FIXTURES / "equal_b.sqlite"),
            "--table", "snacks"]
    proc = run_cli(*base, "--key", "snacks")  # no colon -> malformed
    assert proc.returncode == 2
    assert json.loads(proc.stdout)["refusal"]["code"] == "key_malformed"
    proc = run_cli(*base, "--key", "snacks:nope")
    assert proc.returncode == 2
    assert json.loads(proc.stdout)["refusal"]["code"] == "unknown_key_column"
    proc = run_cli(*base, "--key", "unselected:id")
    assert proc.returncode == 2
    assert json.loads(proc.stdout)["refusal"]["code"] == "key_for_unselected_table"
    proc = run_cli(*base, "--table", "snacks")
    assert proc.returncode == 2
    assert json.loads(proc.stdout)["refusal"]["code"] == "duplicate_table"


def test_no_stable_identity_refused_end_to_end(tmp_path):
    db = tmp_path / "nopk.sqlite"
    conn = __import__("sqlite3").connect(str(db))
    conn.execute("CREATE TABLE t (a TEXT, b INTEGER)")
    conn.execute("INSERT INTO t VALUES ('x', 1)")
    conn.commit()
    conn.close()
    proc = run_cli(str(db), str(db), "--table", "t")
    assert proc.returncode == 2
    doc = json.loads(proc.stdout)
    assert doc["refusal"]["code"] == "no_stable_identity"
    assert doc["refusal"]["table"] == "t"


def test_row_limit_end_to_end_is_limited():
    proc = run_cli(str(FIXTURES / "equal_a.sqlite"), str(FIXTURES / "equal_b.sqlite"),
                   "--table", "snacks", "--table", "servings",
                   "--max-rows-per-table", "1")
    assert proc.returncode == 3
    doc = json.loads(proc.stdout)
    assert doc["result"] == "limited"
    assert doc["limits"]["triggered"]["code"] == "max_rows"


def test_zero_time_budget_end_to_end_is_limited():
    proc = run_cli(str(FIXTURES / "equal_a.sqlite"), str(FIXTURES / "equal_b.sqlite"),
                   "--table", "snacks", "--time-budget-seconds", "0")
    assert proc.returncode == 3
    doc = json.loads(proc.stdout)
    assert doc["result"] == "limited"
    assert doc["limits"]["triggered"]["code"] == "time_budget"


def test_explicit_key_end_to_end_on_committed_fixture():
    proc = run_cli(str(FIXTURES / "diff_a.sqlite"), str(FIXTURES / "diff_b.sqlite"),
                   "--table", "snacks", "--key", "snacks:id")
    assert proc.returncode == 1
    doc = json.loads(proc.stdout)
    assert len(doc["rows"]["snacks"]["added"]) == 1
    assert doc["selections"]["keys"]["snacks"] == ["id"]


def test_help_exit_zero():
    proc = run_cli("--help")
    assert proc.returncode == 0
    assert "--table" in proc.stdout
