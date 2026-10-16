"""Rights records for suite C: per-recipe evidence, and the bundled-catalog audit.

SPEC 3.5: "Ship only recipes the app has the right to ship. For each recipe
the corpus records separately whether text, images, modification, attribution,
caching and offline use are permitted. Unknown rights means quarantine."

Two jobs live here:

1. `validate_manifest` — the corpus rights manifest (`rights_manifest.json`)
   maps every recipe's `source_ref` to a rights record. A record is
   *complete* (rights-clear) only when source, license, access date, origin
   and all six permission fields are present. Anything less is quarantine.

2. `audit_bundled_catalog` — decode the bundled catalog (positional arrays:
   apps/ios/Resources/data.json today, assets/recipes.json in the task brief)
   and write a per-recipe rights record from the evidence *in the data*: a
   bbcgoodfood.com source URL with no licence is quarantine ("no licence
   evidence", SPEC 10); no source at all is quarantine ("rights unknown").
   The auditor never upgrades a recipe the data cannot evidence.
"""

from __future__ import annotations

import json
import re
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

PERMISSION_FIELDS = ("text", "images", "modification", "attribution",
                     "caching", "offline_use")

REQUIRED_RECORD_FIELDS = ("source_id", "source_type", "origin", "license",
                          "access_date")

BUNDLED_CANDIDATES = (
    "assets/recipes.json",              # named by the suite C brief
    "apps/ios/Resources/data.json",     # the bundled catalog on eval branches
)

_BBC = re.compile(r"bbcgoodfood\.com", re.IGNORECASE)


def complete_record(rec: Any) -> bool:
    """True when every SPEC 3.5 rights field is present with evidence."""
    if not isinstance(rec, dict):
        return False
    if any(not rec.get(f) for f in REQUIRED_RECORD_FIELDS):
        return False
    perms = rec.get("permissions")
    if not isinstance(perms, dict) or not all(isinstance(perms.get(p), bool)
                                              for p in PERMISSION_FIELDS):
        return False
    # license evidence: a license string plus where the license evidence lives
    if not rec.get("license_evidence"):
        return False
    # access date must parse
    try:
        datetime.strptime(str(rec["access_date"]), "%Y-%m-%d")
    except (ValueError, TypeError):
        return False
    return True


def record_status(rec: Any) -> tuple[str, str]:
    """Return (status, reason) for one rights record; quarantine fail-closes."""
    if complete_record(rec):
        return "clear", "complete rights evidence in manifest"
    if not isinstance(rec, dict):
        return "quarantined", "malformed rights record"
    if _BBC.search(str(rec.get("source_id", ""))) and not rec.get("license"):
        return "quarantined", "source is bbcgoodfood.com with no licence evidence (SPEC 10)"
    if not rec.get("license"):
        return "quarantined", "no license recorded"
    if not rec.get("access_date"):
        return "quarantined", "no access date recorded"
    if not rec.get("license_evidence"):
        return "quarantined", "no license evidence recorded"
    return "quarantined", "rights record incomplete (SPEC 3.5: unknown rights means quarantine)"


def validate_manifest(manifest: dict[str, Any]) -> dict[str, dict[str, str]]:
    """Validate every record; return {source_ref: {status, reason}}."""
    statuses: dict[str, dict[str, str]] = {}
    records = manifest.get("records", manifest) if isinstance(manifest, dict) else {}
    if not isinstance(records, dict):
        raise ValueError("rights manifest must map source_ref -> record")
    for ref, rec in records.items():
        status, reason = record_status(rec)
        statuses[ref] = {"status": status, "reason": reason}
    return statuses


# ---------------------------------------------------------------------------
# bundled catalog audit
# ---------------------------------------------------------------------------


def find_bundled_catalog(repo_root: Path) -> Path | None:
    for rel in BUNDLED_CANDIDATES:
        p = repo_root / rel
        if p.is_file():
            return p
    return None


def decode_bundled_catalog(raw: dict[str, Any]) -> list[dict[str, Any]]:
    """Decode positional records: [id, title, minutes, servings,
    [[ingredient_id, grams], ...], [[tag_id, seconds], ...], instructions_text,
    source_url?]."""
    out: list[dict[str, Any]] = []
    for rec in raw.get("recipes", []):
        if not isinstance(rec, list) or len(rec) < 7:
            continue
        rid, title, minutes, servings, ingredient_refs, tag_refs, steps_text = rec[:7]
        source_url = rec[7] if len(rec) > 7 and isinstance(rec[7], str) else None
        out.append({
            "bundled_id": rid,
            "title": title,
            "minutes": minutes,
            "servings": servings,
            "ingredient_lines": len(ingredient_refs or []),
            "tag_refs": tag_refs or [],
            "instructions_chars": len(steps_text or ""),
            "source_url": source_url,
        })
    return out


def audit_bundled_catalog(repo_root: Path, out_dir: Path) -> dict[str, Any]:
    """Write the per-recipe rights audit of the bundled catalog.

    Returns the audit summary: counts by status and the audited path. Every
    recipe without complete in-data licence evidence is quarantined; none of
    them is counted toward the rights-clear corpus.
    """
    path = find_bundled_catalog(repo_root)
    today = datetime.now(timezone.utc).strftime("%Y-%m-%d")
    if path is None:
        return {
            "audited": False,
            "reason": ("no bundled catalog found at any of: "
                       + ", ".join(BUNDLED_CANDIDATES)),
            "recipes_audited": 0,
            "quarantined": 0,
            "rights_clear": 0,
        }
    raw = json.loads(path.read_text())
    recipes = decode_bundled_catalog(raw)
    per_recipe = []
    counts = {"clear": 0, "quarantined": 0}
    for rec in recipes:
        url = rec.get("source_url")
        if url and _BBC.search(url):
            status, reason = "quarantined", (
                "bbcgoodfood.com source URL with no licence evidence (SPEC 10)")
        elif url:
            status, reason = "quarantined", (
                f"source {url!r} recorded but no licence evidence in data")
        else:
            status, reason = "quarantined", (
                "no source recorded; rights unknown (SPEC 3.5: unknown rights means quarantine)")
        counts[status] += 1
        per_recipe.append({
            "bundled_id": rec["bundled_id"],
            "title": rec["title"],
            "source_url": url,
            "status": status,
            "reason": reason,
            "access_date": today,
        })
    summary = {
        "audited": True,
        "catalog_path": str(path.relative_to(repo_root)),
        "recipes_audited": len(recipes),
        "quarantined": counts["quarantined"],
        "rights_clear": counts["clear"],
        "note": ("audited against in-data evidence only; SPEC 10 default is "
                 "rewrite-as-original or remove. Recipes quarantined here are "
                 "NOT counted toward the rights-clear bar."),
    }
    out_dir.mkdir(parents=True, exist_ok=True)
    (out_dir / "audit_bundled_catalog.json").write_text(
        json.dumps({"summary": summary, "recipes": per_recipe}, indent=2) + "\n")
    return summary
