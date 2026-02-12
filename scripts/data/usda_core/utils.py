from __future__ import annotations

import hashlib
import os
import re
import tempfile
from datetime import datetime, timezone
from pathlib import Path
from typing import Iterable, Iterator, Sequence, TypeVar

from filelock import FileLock

T = TypeVar("T")

MILLIGRAM_UNITS = {"mg", "milligram", "milligrams"}
MICROGRAM_UNITS = {"mcg", "ug", "µg", "microgram", "micrograms"}


def utc_now_iso() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def canonical(text: str) -> str:
    text = text.strip().lower().replace("_", " ")
    text = re.sub(r"[^a-z0-9%\s\-]", " ", text)
    return re.sub(r"\s+", " ", text).strip()


def title_case(text: str) -> str:
    text = re.sub(r"\s+", " ", text.strip())
    if not text:
        return ""
    return " ".join([w if w.isupper() else w.capitalize() for w in text.split(" ")])


def dedupe_keep_order(values: Sequence[str]) -> list[str]:
    seen: set[str] = set()
    out: list[str] = []
    for value in values:
        normalized = canonical(value)
        if not normalized or normalized in seen:
            continue
        seen.add(normalized)
        out.append(normalized)
    return out


def chunked(values: Sequence[T], size: int) -> Iterator[list[T]]:
    step = max(1, int(size))
    for idx in range(0, len(values), step):
        yield list(values[idx : idx + step])


def stable_json_hash(raw: bytes) -> str:
    return hashlib.sha256(raw).hexdigest()


def atomic_write_bytes(path: Path, payload: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    lock = FileLock(str(path) + ".lock")
    with lock:
        with tempfile.NamedTemporaryFile(dir=str(path.parent), delete=False) as tmp:
            tmp.write(payload)
            tmp.flush()
            os.fsync(tmp.fileno())
            temp_name = tmp.name
        os.replace(temp_name, path)


def parse_parenthetical_aliases(description: str) -> list[str]:
    aliases: list[str] = []
    text = description
    for _ in range(6):
        matches = re.findall(r"\(([^()]{2,90})\)", text)
        if not matches:
            break
        for match in matches:
            for part in re.split(r"[/;]| or |,", match):
                candidate = canonical(part)
                if candidate and candidate not in {"raw", "cooked"}:
                    aliases.append(candidate)
        text = re.sub(r"\([^()]{2,90}\)", " ", text)
    return dedupe_keep_order(aliases)
