from __future__ import annotations

from pathlib import Path
from typing import Any

import orjson

from .schema import BatchPayload, CanonicalCatalog
from .utils import atomic_write_bytes


def _pretty_dumps(payload: Any) -> bytes:
    return orjson.dumps(payload, option=orjson.OPT_INDENT_2 | orjson.OPT_SORT_KEYS)


def load_canonical(path: Path) -> CanonicalCatalog:
    payload = orjson.loads(path.read_bytes())
    return CanonicalCatalog.model_validate(payload)


def save_canonical(path: Path, catalog: CanonicalCatalog) -> None:
    raw = _pretty_dumps(catalog.model_dump(mode="json")) + b"\n"
    atomic_write_bytes(path, raw)


def load_batch(path: Path) -> BatchPayload:
    payload = orjson.loads(path.read_bytes())
    return BatchPayload.model_validate(payload)


def save_batch(path: Path, batch: BatchPayload) -> None:
    raw = _pretty_dumps(batch.model_dump(mode="json")) + b"\n"
    atomic_write_bytes(path, raw)


def save_json(path: Path, payload: Any) -> None:
    raw = _pretty_dumps(payload) + b"\n"
    atomic_write_bytes(path, raw)
