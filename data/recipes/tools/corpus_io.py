"""Read and write the corpus files without rewriting records nobody changed.

corpus.jsonl lines were written by several tools, some with ASCII escapes
(the seed converter) and some without. Re-serialising every line would put
unrelated byte changes in the diff, so `write_corpus` writes an unchanged
record's original line back as it was.
"""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any

REPO_ROOT = Path(__file__).resolve().parents[3]
CORPUS = REPO_ROOT / "data/recipes/corpus.jsonl"
MANIFEST = REPO_ROOT / "data/recipes/rights_manifest.json"
QUARANTINE = REPO_ROOT / "data/recipes/quarantine.jsonl"


class Line:
    """One corpus record plus the exact line it was read from."""

    def __init__(self, raw: str | None, obj: dict[str, Any]) -> None:
        self.raw = raw
        self.obj = obj

    def dumps(self) -> str:
        if self.raw is not None and json.loads(self.raw) == self.obj:
            return self.raw
        return json.dumps(self.obj, ensure_ascii=False)


def read_jsonl(path: Path) -> list[Line]:
    if not path.exists():
        return []
    out = []
    for n, raw in enumerate(path.read_text(encoding="utf-8").split("\n"), start=1):
        if not raw.strip():
            continue
        try:
            out.append(Line(raw, json.loads(raw)))
        except json.JSONDecodeError as exc:
            raise SystemExit(f"{path.name} line {n}: {exc}") from exc
    return out


def write_jsonl(path: Path, lines: list[Line]) -> None:
    with path.open("w", encoding="utf-8", newline="\n") as f:
        for line in lines:
            f.write(line.dumps() + "\n")


def read_manifest(path: Path = MANIFEST) -> dict[str, Any]:
    return json.loads(path.read_text(encoding="utf-8"))


def write_manifest(manifest: dict[str, Any], path: Path = MANIFEST) -> None:
    path.write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n",
                    encoding="utf-8")
