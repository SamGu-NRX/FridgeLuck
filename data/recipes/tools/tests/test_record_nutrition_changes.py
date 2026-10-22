"""Record_nutrition_changes tests: causes are traced honestly, fail closed.

What is asserted:
1. a >40% swing with no resolved key, re-sourced row, or corpus fix behind it
   fails closed (planted untraceable move — the tool must never write an
   unexplained exemption);
2. a key whose per-100g row was RE-SOURCED between revisions is accepted as a
   cause, with the old and new fdc row and kcal in the recorded string;
3. a corpus amount fix (packet file + fix id) is accepted as a cause;
4. the original resolved-key cause still works (a key that GAINED a per-100g
   row between revisions).
All fixtures are planted in tmp_path; nothing here touches the real corpus.
"""
from __future__ import annotations

import json
import subprocess
import sys
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parents[4]
TOOL = REPO / "data/recipes/tools/record_nutrition_changes.py"


def vocab_entry(key: str, kcal: float | None, fdc: int = 1001) -> dict:
    e = {"key": key, "display_name": key, "fdc_id": fdc}
    if kcal is not None:
        e["per_100g"] = {"kcal": kcal, "protein_g": 0.0, "carbs_g": 0.0,
                         "fat_g": 0.0, "fiber_g": 0.0, "sugar_g": 0.0,
                         "sodium_mg": 0.0}
    return e


def write_vocab(path: Path, entries: list[dict]) -> None:
    path.write_text(json.dumps({"entries": entries}, indent=2) + "\n")


def write_bundle(path: Path, kcal_by_rid: dict[str, float]) -> None:
    doc = {"recipes": [
        {"catalog_id": rid,
         "ingredients": [{"key": "test_key", "quantity": {"kind": "unknown"},
                          "required": True, "assumed_staple": False, "note": None}],
         "nutrition_per_serving": {"kcal": kcal}}
        for rid, kcal in kcal_by_rid.items()]}
    path.write_text(json.dumps(doc, indent=2) + "\n")


def run_tool(prev_vocab: Path, cur_vocab: Path, prev_bundle: Path,
             new_bundle: Path, out: Path, fixes_dir: Path | None) -> subprocess.CompletedProcess:
    cmd = [sys.executable, str(TOOL),
           "--new", str(new_bundle),
           "--previous", str(prev_bundle),
           "--previous-vocab", str(prev_vocab),
           "--vocab", str(cur_vocab),
           "--out", str(out),
           "--previous-note", "test fixtures"]
    if fixes_dir is not None:
        cmd += ["--fixes-dir", str(fixes_dir)]
    return subprocess.run(cmd, capture_output=True, text=True)


@pytest.fixture()
def env(tmp_path: Path):
    """A one-recipe world: the 'test_key' line causes every kcal swing."""
    class Env:
        def __init__(self):
            self.prev_vocab = tmp_path / "prev-vocab.json"
            self.cur_vocab = tmp_path / "cur-vocab.json"
            self.prev_bundle = tmp_path / "prev-bundle.json"
            self.new_bundle = tmp_path / "new-bundle.json"
            self.out = tmp_path / "changes.json"
            self.fixes_dir = tmp_path / "fixes"
            self.fixes_dir.mkdir()
            # default: same row in both revisions — nothing traceable
            write_vocab(self.cur_vocab, [vocab_entry("test_key", 300.0)])
            write_bundle(self.prev_bundle, {"rcp-000001": 100.0})

        def set_prev_vocab(self, kcal: float | None, fdc: int = 1001):
            write_vocab(self.prev_vocab, [vocab_entry("test_key", kcal, fdc)])

        def set_cur_vocab(self, kcal: float, fdc: int = 1002):
            write_vocab(self.cur_vocab, [vocab_entry("test_key", kcal, fdc)])

        def set_kcal(self, prev: float, new: float):
            write_bundle(self.prev_bundle, {"rcp-000001": prev})
            write_bundle(self.new_bundle, {"rcp-000001": new})

        def run(self, fixes_dir: Path | None = None):
            return run_tool(self.prev_vocab, self.cur_vocab, self.prev_bundle,
                            self.new_bundle, self.out, fixes_dir)
    return Env()


# ---- 1. planted untraceable move: fail closed --------------------------------

def test_untraceable_move_fails_closed(env):
    env.set_prev_vocab(300.0)   # same row before and after — no re-source
    env.set_cur_vocab(300.0, fdc=1001)
    env.set_kcal(100.0, 55.0)   # -45% with no traceable cause
    proc = env.run()
    assert proc.returncode != 0, proc.stdout
    assert "rcp-000001" in proc.stderr
    assert "investigate before exempting" in proc.stderr
    assert not env.out.exists(), "no exemption file may be written"


# ---- 2. re-sourced per-100g row is a traced cause -----------------------------

def test_resourced_row_is_recorded_with_old_and_new_row(env):
    env.set_prev_vocab(300.0, fdc=1001)
    env.set_cur_vocab(150.0, fdc=2002)
    env.set_kcal(100.0, 55.0)   # -45% — caused by the re-sourced row
    proc = env.run()
    assert proc.returncode == 0, proc.stderr
    doc = json.loads(env.out.read_text())
    assert len(doc["entries"]) == 1
    cause = doc["entries"][0]["vocabulary_change"]
    assert "test_key" in cause
    assert "1001" in cause and "2002" in cause
    assert "300.0" in cause and "150.0" in cause
    assert doc["entries"][0]["old_kcal"] == 100.0
    assert doc["entries"][0]["new_kcal"] == 55.0


# ---- 3. corpus amount fix is a traced cause -----------------------------------

def test_corpus_fix_is_recorded_with_file_and_fix_id(env):
    env.set_prev_vocab(300.0)
    env.set_cur_vocab(300.0, fdc=1001)
    env.set_kcal(100.0, 55.0)   # -45% — caused by the corpus grams fix
    packet = env.fixes_dir / "amounts-test.json"
    packet.write_text(json.dumps({
        "schema": "test", "packet": "amounts-test",
        "fixes": [{"id": "fl-original-0001", "catalog_id": "rcp-000001"}]}) + "\n")
    proc = env.run(fixes_dir=env.fixes_dir)
    assert proc.returncode == 0, proc.stderr
    cause = json.loads(env.out.read_text())["entries"][0]["vocabulary_change"]
    assert "amounts-test.json" in cause
    assert "fl-original-0001" in cause


# ---- 4. resolved-key cause still works ----------------------------------------

def test_resolved_key_cause_still_works(env):
    env.set_prev_vocab(None)     # no per-100g row before
    env.set_cur_vocab(300.0)
    env.set_kcal(100.0, 250.0)   # +150%
    proc = env.run()
    assert proc.returncode == 0, proc.stderr
    cause = json.loads(env.out.read_text())["entries"][0]["vocabulary_change"]
    assert "resolved to per-100g rows" in cause


# ---- 5. small swings still stay unrecorded ------------------------------------

def test_small_swing_writes_no_entry(env):
    env.set_prev_vocab(300.0)
    env.set_cur_vocab(300.0, fdc=1001)
    env.set_kcal(100.0, 90.0)   # -10% — under the gate
    proc = env.run()
    assert proc.returncode == 0, proc.stderr
    doc = json.loads(env.out.read_text())
    assert doc["entries"] == []
