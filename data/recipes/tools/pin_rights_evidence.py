#!/usr/bin/env python3
"""Write data/recipes/evidence/rights.json: the rights evidence the gate checks.

A rights record names its evidence ("record fl-original-0001 at 607ef99", a
licence URL). rights_evidence.py accepts a record only when that evidence is
pinned here and agrees with it, so a well-spelled citation of a record that
does not exist, or of terms that do not grant the use, fails.

Originals: read from git at ORIGINALS_COMMIT (branch overhaul/original-recipes,
owned by fl-original-recipes-f1; this tool only reads it). For each record:
the authoring task's rights record fields, the recipe's title and a SHA-256
of its ingredient names, so the gate can tell the corpus recipe is the one
the record covers. The blob ids of the two source files are kept so a test
can re-derive the file from git.

Sources: the terms each external source was checked against on
SOURCES_CHECKED_ON, with the page hashes and the quoted sentences that
decide the verdict. Only "verified" sources clear a recipe.

    python3 -I data/recipes/tools/pin_rights_evidence.py [--check]
"""

from __future__ import annotations

import argparse
import hashlib
import json
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import corpus_io  # noqa: E402

ORIGINALS_COMMIT = "607ef996e685ed250c0c0036690736587fddf728"
ORIGINALS_MANIFEST = "data/recipes/originals/rights_manifest.json"
ORIGINALS_RECIPES = "data/recipes/originals/originals.jsonl"
EVIDENCE = corpus_io.REPO_ROOT / "data/recipes/evidence/rights.json"
SOURCES_CHECKED_ON = "2026-10-11"

# Fetched 2026-10-11 with curl (HTTP 200). The recipe pages link the
# Healthier Families terms in their footer; those terms, not the general
# nhs.uk OGL release, govern the pages.
SOURCES = {
    "nhs_website": {
        "verdict": "refused",
        "reason": ("NHS Healthier Families recipe pages link their own Terms of Website "
                   "Use, which reserve all rights, allow personal use only and require a "
                   "licence for commercial use. The records cite the general nhs.uk OGL "
                   "release (terms 3.3). The two terms conflict, and until the NHS or legal "
                   "review settles which governs, the app's text, modification, caching and "
                   "offline-use permissions are unknown."),
        "pages": {
            "https://www.nhs.uk/healthier-families/terms-and-conditions/": {
                "sha256": "0d7ca9feaae589787770d59eb019a4d3534144df819307d4afbc6b40e6ac434a",
                "quotes": [
                    "We are the owner or the licensee of all intellectual property rights in "
                    "the Site, and in the material published on it. Those works are protected "
                    "by copyright laws and treaties around the world. All such rights are "
                    "reserved.",
                    "You must not use any part of the content on the Site for commercial "
                    "purposes without obtaining a licence to do so from us or our licensors.",
                ],
            },
            "https://www.nhs.uk/our-policies/terms-and-conditions/": {
                "sha256": "f57f154192f1cf59c68dddd97687f216e014e7900c8093ee2b4affd99b7bc009",
                "quotes": [
                    "3.3 Copyright and database rights in NHS Website Content are released "
                    "free-of-charge under the current version of the Open Government Licence "
                    "(\"OGL\"), except where specified, either in these terms and conditions, "
                    "elsewhere on this website or in the OGL terms.",
                ],
            },
            "https://www.nhs.uk/healthier-families/recipes/greek-yoghurt-and-raspberry-chill/": {
                "sha256": "665a58ee4f25709e2726d0b01b60ee58c5638ce58cdd90f7f2ac921c6377fb2b",
                "quotes": ["footer link: /healthier-families/terms-and-conditions/"],
            },
            "https://www.nhs.uk/healthier-families/recipes/porridge-with-yoghurt-and-berries/": {
                "sha256": "dac6470534edc9e3721b38aba9a87f6d9ce5cc76d582a306f2bc8e16c6872d65",
                "quotes": ["footer link: /healthier-families/terms-and-conditions/"],
            },
        },
    },
}


def git(*args: str) -> str:
    out = subprocess.run(["git", "-C", str(corpus_io.REPO_ROOT), *args],
                         capture_output=True, text=True)
    if out.returncode:
        raise SystemExit(f"git {' '.join(args)}: {out.stderr.strip()} "
                         "(fetch origin overhaul/original-recipes)")
    return out.stdout


def ingredients_sha256(names: list[str]) -> str:
    return hashlib.sha256(json.dumps(names, ensure_ascii=False).encode("utf-8")).hexdigest()


def build() -> dict:
    manifest = json.loads(git("show", f"{ORIGINALS_COMMIT}:{ORIGINALS_MANIFEST}"))
    records = manifest.get("records", manifest)
    recipes = {r["id"]: r for r in map(json.loads,
               git("show", f"{ORIGINALS_COMMIT}:{ORIGINALS_RECIPES}").splitlines()) }
    pinned = {}
    for rid, rec in sorted(records.items()):
        recipe = recipes.get(rid)
        if recipe is None:
            raise SystemExit(f"{rid}: rights record without a recipe at {ORIGINALS_COMMIT}")
        pinned[rid] = {
            "source_type": rec["source_type"],
            "license": rec["license"],
            "license_evidence": rec["license_evidence"],
            "permissions": rec["permissions"],
            "title": recipe["title"],
            "ingredients_sha256": ingredients_sha256([i["name"] for i in recipe["ingredients"]]),
        }
    return {
        "originals": {
            "branch": "overhaul/original-recipes",
            "commit": ORIGINALS_COMMIT,
            "manifest_blob": git("rev-parse", f"{ORIGINALS_COMMIT}:{ORIGINALS_MANIFEST}").strip(),
            "recipes_blob": git("rev-parse", f"{ORIGINALS_COMMIT}:{ORIGINALS_RECIPES}").strip(),
            "records": pinned,
        },
        "sources": {"checked_on": SOURCES_CHECKED_ON, **SOURCES},
    }


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--check", action="store_true",
                    help="exit 1 if the committed file differs from a fresh build")
    args = ap.parse_args()
    text = json.dumps(build(), ensure_ascii=False, indent=1, sort_keys=True) + "\n"
    if args.check:
        same = EVIDENCE.exists() and EVIDENCE.read_text(encoding="utf-8") == text
        print("evidence matches git" if same else "evidence differs from git")
        return 0 if same else 1
    EVIDENCE.parent.mkdir(parents=True, exist_ok=True)
    EVIDENCE.write_text(text, encoding="utf-8")
    print(f"wrote {EVIDENCE}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
