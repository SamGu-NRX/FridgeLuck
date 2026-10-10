"""Faithful port of the app's label-to-ingredient resolution, for benchmark use off-device.

This module mirrors, step by step, three Swift sources (do not "improve" them here —
any intentional divergence must be a flagged experiment variable, never a silent fix):

- apps/ios/Capability/Core/Recognition/IngredientLexicon.swift
  (tables come from lexicon_snapshot.json, generated from the Swift source by
  extract_lexicon.py — not re-typed here)
- apps/ios/Capability/Core/Recognition/IngredientCatalogResolver.swift
  (SQL strings are reproduced verbatim in CATALOG_SQL and tested against the
  same SQLite file the app ships: apps/ios/Resources/usda_ingredient_catalog.sqlite)
- apps/ios/Capability/Core/Recognition/IngredientIdentityResolution.swift
  (resolution precedence: userCorrection -> curated -> catalog-exact; and the
  OCR text fallback with unsupported-phrase masking)

Divergences (all unavoidable, all documented):
- Swift `lowercased()` vs Python `lower()`: identical for ASCII food vocabulary.
- Swift CharacterSet.alphanumerics vs Python isalnum(): identical for ASCII.
- SQLite LIKE is case-insensitive for ASCII; the port lowercases both sides.
"""

from __future__ import annotations

import json
import re
import sqlite3
from dataclasses import dataclass, field
from pathlib import Path

EXPERIMENT_ROOT = Path(__file__).resolve().parent.parent
REPO_ROOT = EXPERIMENT_ROOT.parents[1]
USDA_DB = REPO_ROOT / "apps" / "ios" / "Resources" / "usda_ingredient_catalog.sqlite"
LEXICON_SNAPSHOT = EXPERIMENT_ROOT / "resolution" / "lexicon_snapshot.json"


# --------------------------------------------------------------------------
# Verbatim SQL from IngredientCatalogResolver.swift (for the golden test and
# documentation; the port below implements exactly these queries).
# --------------------------------------------------------------------------
CATALOG_SQL = {
    "uniqueExactMatch": """
        SELECT id FROM ingredients WHERE lower(name) IN ({placeholders})
        UNION
        SELECT i.id FROM ingredients i
        JOIN ingredient_aliases a ON a.ingredient_id = i.id
        WHERE lower(a.alias) IN ({placeholders})
        LIMIT 2
    """,
    "uniqueNameMatch": """
        SELECT id
        FROM ingredients
        WHERE lower(name) = ?
        LIMIT 2
    """,
    "uniqueAliasMatch": """
        SELECT DISTINCT i.id
        FROM ingredients i
        JOIN ingredient_aliases a ON a.ingredient_id = i.id
        WHERE lower(a.alias) = ?
        LIMIT 2
    """,
    "uniquePrefixNameMatch": """
        SELECT id
        FROM ingredients
        WHERE lower(name) LIKE ?
        LIMIT 2
    """,
    "uniquePrefixAliasMatch": """
        SELECT DISTINCT i.id
        FROM ingredients i
        JOIN ingredient_aliases a ON a.ingredient_id = i.id
        WHERE lower(a.alias) LIKE ?
        LIMIT 2
    """,
}


# --------------------------------------------------------------------------
# IngredientLexicon port
# --------------------------------------------------------------------------
class IngredientLexicon:
    def __init__(self, snapshot_path: Path = LEXICON_SNAPSHOT) -> None:
        snap = json.loads(snapshot_path.read_text())
        self.label_to_id: dict[str, int] = snap["labelToId"]
        self.synonyms: dict[str, str] = snap["synonyms"]
        self.unsupported_food_phrases: list[str] = snap["unsupportedFoodPhrases"]
        self.display_names: dict[int, str] = {
            int(k): v for k, v in snap["displayNames"].items()
        }
        # Mirror Swift's sort: longest first, ties broken lexicographically.
        self._synonym_candidates = sorted(
            self.synonyms.keys(), key=lambda s: (-len(s), s)
        )
        self._label_candidates = sorted(self.label_to_id.keys(), key=lambda s: (-len(s), s))
        self._phrase_tokens = [p.split(" ") for p in self.unsupported_food_phrases]

    # -- normalize(_: String) — lower + non-alnum split + rejoin + trim
    @staticmethod
    def normalize(text: str) -> str:
        lowered = text.lower()
        parts = re.split(r"[^0-9A-Za-z\u00c0-\uffef]+", lowered)
        parts = [p for p in parts if p]
        return " ".join(parts).strip()

    # -- resolve(_: String) -> Int64?
    def resolve(self, label: str) -> int | None:
        normalized = label.lower().strip()
        underscored = normalized.replace(" ", "_")
        if underscored in self.label_to_id:
            return self.label_to_id[underscored]
        if normalized in self.label_to_id:
            return self.label_to_id[normalized]
        if normalized in self.synonyms:
            canonical = self.synonyms[normalized]
            if canonical in self.label_to_id:
                return self.label_to_id[canonical]
        # de-pluralization
        if normalized.endswith("ies") and len(normalized) > 3:
            singular = normalized[:-3] + "y"
        elif normalized.endswith("es") and len(normalized) > 2:
            singular = normalized[:-2]
        elif normalized.endswith("s") and len(normalized) > 0:
            singular = normalized[:-1]
        else:
            singular = normalized
        if singular != normalized:
            singular_underscored = singular.replace(" ", "_")
            if singular_underscored in self.label_to_id:
                return self.label_to_id[singular_underscored]
            if singular in self.label_to_id:
                return self.label_to_id[singular]
        return None

    # -- scanUnsupportedPhrases — token-based masking with plural tail match
    def _scan_unsupported(self, text: str) -> tuple[list[str], list[str]]:
        tokens = self.normalize(text).split(" ") if self.normalize(text) else []
        found: list[str] = []
        kept: list[str] = []
        index = 0
        while index < len(tokens):
            match: list[str] | None = None
            for phrase in self._phrase_tokens:
                if index + len(phrase) <= len(tokens):
                    ok = True
                    for offset, word in enumerate(phrase):
                        token = tokens[index + offset]
                        is_last = offset == len(phrase) - 1
                        if token == word or (
                            is_last and token in (word + "s", word + "es")
                        ):
                            continue
                        ok = False
                        break
                    if ok:
                        match = phrase
                        break
            if match is not None:
                found.append(" ".join(match))
                index += len(match)
            else:
                kept.append(tokens[index])
                index += 1
        return kept, found

    def unsupported_food_phrases_in(self, text: str) -> list[str]:
        return self._scan_unsupported(text)[1]

    def masking_unsupported_food_phrases(self, text: str) -> str:
        return " ".join(self._scan_unsupported(text)[0])

    @staticmethod
    def _contains_whole_phrase(normalized_text: str, phrase: str) -> bool:
        normalized_phrase = IngredientLexicon.normalize(phrase)
        if not normalized_phrase:
            return False
        return f" {normalized_text} ".find(f" {normalized_phrase} ") != -1

    # -- resolveFromTextDetailed(_: String) -> OCRTextMatch?
    def resolve_from_text_detailed(self, ocr_text: str) -> "OCRTextMatch | None":
        normalized_text = self.masking_unsupported_food_phrases(ocr_text)
        if not normalized_text:
            return None
        for phrase in self._synonym_candidates:
            if self._contains_whole_phrase(normalized_text, phrase):
                canonical = self.synonyms[phrase]
                if canonical in self.label_to_id:
                    return OCRTextMatch(
                        ingredient_id=self.label_to_id[canonical],
                        kind="exact",
                        matched_token=phrase,
                    )
        for label in self._label_candidates:
            readable = label.replace("_", " ")
            if self._contains_whole_phrase(normalized_text, readable):
                return OCRTextMatch(
                    ingredient_id=self.label_to_id[label],
                    kind="exact",
                    matched_token=readable,
                )
        tokens = normalized_text.split(" ")
        for token in tokens:
            if len(token) >= 4:
                resolved = self.resolve(token)
                if resolved is not None:
                    return OCRTextMatch(
                        ingredient_id=resolved, kind="fuzzy", matched_token=token
                    )
        return None

    def resolve_from_text(self, ocr_text: str) -> int | None:
        m = self.resolve_from_text_detailed(ocr_text)
        return m.ingredient_id if m else None


@dataclass
class OCRTextMatch:
    ingredient_id: int
    kind: str  # "exact" | "fuzzy"
    matched_token: str


# --------------------------------------------------------------------------
# IngredientCatalogResolver port (against the shipped SQLite catalog)
# --------------------------------------------------------------------------
@dataclass
class CatalogMatch:
    ingredient_id: int
    stage: str  # which Swift stage produced it: exact|name|alias|prefixName|prefixAlias


class IngredientCatalogResolver:
    def __init__(self, db_path: Path = USDA_DB) -> None:
        if not db_path.exists():
            raise FileNotFoundError(f"USDA catalog not found at {db_path}")
        self._conn = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True)
        self._conn.execute("PRAGMA case_sensitive_like = OFF")

    @staticmethod
    def normalize(raw: str) -> str:
        lower = raw.lower().replace("_", " ")
        parts = [p for p in re.split(r"[^0-9A-Za-z\u00c0-\uffef]+", lower) if p]
        return " ".join(parts).strip()

    @staticmethod
    def normalized_candidates(raw: str) -> list[str]:
        base = IngredientCatalogResolver.normalize(raw)
        if not base:
            return []
        candidates = [base]
        if base.endswith("ies") and len(base) > 4:
            candidates.append(base[:-3] + "y")
        elif base.endswith("es") and len(base) > 3:
            candidates.append(base[:-2])
        elif base.endswith("s") and len(base) > 2:
            candidates.append(base[:-1])
        trimmed = re.sub(r"^(fresh|raw|cooked|frozen|dried)\s+", "", base).strip()
        if trimmed and trimmed != base:
            candidates.append(trimmed)
        deduped: list[str] = []
        seen: set[str] = set()
        for c in candidates:
            if c not in seen:
                seen.add(c)
                deduped.append(c)
        return deduped

    def _unique(self, rows: list[int]) -> int | None:
        return rows[0] if len(rows) == 1 else None

    def resolve(self, raw_value: str, matching: str = "exact") -> int | None:
        """Port of IngredientCatalogResolver.resolve(_:matching:)."""
        candidates = self.normalized_candidates(raw_value)
        if not candidates:
            return None
        if matching == "exact":
            ph = ",".join("?" * len(candidates))
            sql = CATALOG_SQL["uniqueExactMatch"].replace("{placeholders}", ph)
            rows = self._conn.execute(sql, candidates + candidates).fetchall()
            return self._unique([r[0] for r in rows])
        # allowPrefix — stage order per Swift source
        for candidate in candidates:
            rows = self._conn.execute(
                "SELECT id FROM ingredients WHERE lower(name) = ? LIMIT 2", (candidate,)
            ).fetchall()
            m = self._unique([r[0] for r in rows])
            if m is not None:
                return m
        for candidate in candidates:
            rows = self._conn.execute(
                """SELECT DISTINCT i.id FROM ingredients i
                   JOIN ingredient_aliases a ON a.ingredient_id = i.id
                   WHERE lower(a.alias) = ? LIMIT 2""",
                (candidate,),
            ).fetchall()
            m = self._unique([r[0] for r in rows])
            if m is not None:
                return m
        for candidate in candidates:
            if len(candidate) >= 5:
                rows = self._conn.execute(
                    "SELECT id FROM ingredients WHERE lower(name) LIKE ? LIMIT 2",
                    (candidate + "%",),
                ).fetchall()
                m = self._unique([r[0] for r in rows])
                if m is not None:
                    return m
        for candidate in candidates:
            if len(candidate) >= 5:
                rows = self._conn.execute(
                    """SELECT DISTINCT i.id FROM ingredients i
                       JOIN ingredient_aliases a ON a.ingredient_id = i.id
                       WHERE lower(a.alias) LIKE ? LIMIT 2""",
                    (candidate + "%",),
                ).fetchall()
                m = self._unique([r[0] for r in rows])
                if m is not None:
                    return m
        return None

    def resolve_from_text(self, raw_text: str) -> int | None:
        """Port of resolveFromText — sliding windows, longest first, allowPrefix."""
        normalized = self.normalize(raw_text)
        if not normalized:
            return None
        tokens = normalized.split(" ")
        if not tokens:
            return None
        max_window = min(3, len(tokens))
        for window in range(max_window, 0, -1):
            for start in range(0, len(tokens) - window + 1):
                phrase = " ".join(tokens[start : start + window])
                resolved = self.resolve(phrase, matching="allowPrefix")
                if resolved is not None:
                    return resolved
        return None

    def display_name(self, ingredient_id: int) -> str | None:
        row = self._conn.execute(
            "SELECT name FROM ingredients WHERE id = ?", (ingredient_id,)
        ).fetchone()
        if row is None:
            return None
        return IngredientCatalogResolver.make_display_name(row[0])

    @staticmethod
    def make_display_name(raw_name: str) -> str:
        normalized = raw_name.replace("_", " ")
        if normalized == normalized.lower():
            return normalized.capitalize()
        return normalized


# --------------------------------------------------------------------------
# IngredientIdentityResolution port
# --------------------------------------------------------------------------
@dataclass
class ResolvedLabel:
    ingredient_id: int
    provenance: str  # "userCorrection" | "curated" | "catalog"
    catalog_matching: str | None = None


def resolve_label(
    label: str,
    lexicon: IngredientLexicon,
    catalog: IngredientCatalogResolver,
    user_correction=None,
) -> ResolvedLabel | None:
    """Port of IngredientIdentityResolution.resolveLabel — curated wins over catalog."""
    if user_correction is not None:
        corrected = user_correction(label)
        if corrected is not None:
            return ResolvedLabel(corrected, "userCorrection")
    curated = lexicon.resolve(label)
    if curated is not None:
        return ResolvedLabel(curated, "curated")
    catalog_id = catalog.resolve(label, matching="exact")
    if catalog_id is not None:
        return ResolvedLabel(catalog_id, "catalog", catalog_matching="exact")
    return None


def resolve_text_from_catalog(
    text: str, lexicon: IngredientLexicon, catalog: IngredientCatalogResolver
) -> int | None:
    """Port of IngredientIdentityResolution.resolveTextFromCatalog."""
    for phrase in lexicon.unsupported_food_phrases_in(text):
        resolved = catalog.resolve(phrase, matching="allowPrefix")
        if resolved is not None:
            return resolved
    masked = lexicon.masking_unsupported_food_phrases(text)
    if not masked:
        return None
    return catalog.resolve_from_text(masked)
