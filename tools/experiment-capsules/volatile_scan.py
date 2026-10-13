#!/usr/bin/env python3
"""Volatile-content scanning: wall-clock and VCS values in table content.

Regenerated table content must be digest-stable, so wall-clock time and
the HEAD commit sha must never enter it. This module scans text for the
volatile shapes that would break that guarantee:

- git-sha-like tokens (40 hex chars, boundary-guarded so 64-hex sha256
  digests do NOT match),
- ISO datetimes (``2026-10-11T14:03``, ``2026-10-11 14:03:07Z``, ...),
- unix epoch seconds (10-digit 1xxxxxxxxx, boundary-guarded).

Plain dates that are study data (``2026-03-02`` week labels, ``r1`` run
ids) are content, not volatility, and are deliberately not flagged.
"""

from __future__ import annotations

import re
from dataclasses import dataclass

# 40-hex with non-hex guards: a 40-char window inside a 64-hex sha256 run
# always has a hex neighbour on one side, so sha256 digests never match.
_GIT_SHA_RE = re.compile(r"(?<![0-9a-fA-F])[0-9a-fA-F]{40}(?![0-9a-fA-F])")
_ISO_DATETIME_RE = re.compile(
    r"\d{4}-\d{2}-\d{2}[Tt ]\d{2}:\d{2}(:\d{2}(\.\d+)?)?([Zz]|[+-]\d{2}:?\d{2})?"
)
_EPOCH_RE = re.compile(r"(?<![\d.])1[0-9]{9}(?![\d.])")

PATTERNS: tuple[tuple[str, re.Pattern], ...] = (
    ("git-sha-like", _GIT_SHA_RE),
    ("iso-datetime", _ISO_DATETIME_RE),
    ("unix-epoch-seconds", _EPOCH_RE),
)


@dataclass(frozen=True)
class VolatileHit:
    pattern: str
    line: int
    snippet: str

    def to_dict(self) -> dict:
        return {"pattern": self.pattern, "line": self.line, "snippet": self.snippet}


def scan_text(text: str) -> list[VolatileHit]:
    """Return every volatile hit, ordered by line then pattern."""
    hits: list[VolatileHit] = []
    for lineno, line in enumerate(text.splitlines(), start=1):
        for name, pattern in PATTERNS:
            for match in pattern.finditer(line):
                snippet = match.group(0)
                start = max(0, match.start() - 20)
                end = min(len(line), match.end() + 20)
                context = line[start:end].strip()
                hits.append(VolatileHit(pattern=name, line=lineno, snippet=context))
    hits.sort(key=lambda h: (h.line, h.pattern, h.snippet))
    return hits


def scan_bytes(data: bytes) -> list[VolatileHit]:
    return scan_text(data.decode("utf-8", errors="replace"))
