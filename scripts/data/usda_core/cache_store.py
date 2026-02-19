from __future__ import annotations

import sqlite3
from pathlib import Path
from typing import Any

import orjson

from .utils import utc_now_iso


class CacheStore:
    def __init__(self, path: Path):
        self.path = path
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self._init_db()

    def _connect(self) -> sqlite3.Connection:
        conn = sqlite3.connect(str(self.path))
        conn.execute("PRAGMA journal_mode=WAL")
        conn.execute("PRAGMA synchronous=NORMAL")
        return conn

    def _init_db(self) -> None:
        with self._connect() as conn:
            conn.execute(
                """
                CREATE TABLE IF NOT EXISTS food_cache (
                    fdc_id INTEGER PRIMARY KEY,
                    payload BLOB NOT NULL,
                    updated_at TEXT NOT NULL
                )
                """
            )
            conn.execute(
                """
                CREATE TABLE IF NOT EXISTS search_cache (
                    cache_key TEXT PRIMARY KEY,
                    payload BLOB NOT NULL,
                    updated_at TEXT NOT NULL
                )
                """
            )
            conn.commit()

    def get_food(self, fdc_id: int) -> dict[str, Any] | None:
        with self._connect() as conn:
            row = conn.execute("SELECT payload FROM food_cache WHERE fdc_id = ?", [fdc_id]).fetchone()
        if row is None:
            return None
        return orjson.loads(row[0])

    def put_food(self, fdc_id: int, payload: dict[str, Any]) -> None:
        raw = orjson.dumps(payload)
        with self._connect() as conn:
            conn.execute(
                """
                INSERT INTO food_cache(fdc_id, payload, updated_at)
                VALUES (?, ?, ?)
                ON CONFLICT(fdc_id) DO UPDATE SET payload=excluded.payload, updated_at=excluded.updated_at
                """,
                [fdc_id, raw, utc_now_iso()],
            )
            conn.commit()

    def get_search(self, cache_key: str) -> dict[str, Any] | None:
        with self._connect() as conn:
            row = conn.execute("SELECT payload FROM search_cache WHERE cache_key = ?", [cache_key]).fetchone()
        if row is None:
            return None
        return orjson.loads(row[0])

    def put_search(self, cache_key: str, payload: dict[str, Any]) -> None:
        raw = orjson.dumps(payload)
        with self._connect() as conn:
            conn.execute(
                """
                INSERT INTO search_cache(cache_key, payload, updated_at)
                VALUES (?, ?, ?)
                ON CONFLICT(cache_key) DO UPDATE SET payload=excluded.payload, updated_at=excluded.updated_at
                """,
                [cache_key, raw, utc_now_iso()],
            )
            conn.commit()
