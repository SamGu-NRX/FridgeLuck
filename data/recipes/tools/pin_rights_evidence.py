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
import fl_revisions  # noqa: E402

ORIGINALS_COMMIT = "607ef996e685ed250c0c0036690736587fddf728"
ORIGINALS_MANIFEST = "data/recipes/originals/rights_manifest.json"
ORIGINALS_RECIPES = "data/recipes/originals/originals.jsonl"
EVIDENCE = corpus_io.REPO_ROOT / "data/recipes/evidence/rights.json"
SOURCES_CHECKED_ON = "2026-10-11"

# The 2026-10 originals packets (branches owned by the packet PRs; this tool
# only reads them). Each packet's own evidence, read at the commit the ingest
# map pins, is copied here so the gate can verify a packet citation against
# what the packet actually recorded. World packet records carry no per-record
# license/permissions — the packet manifest records authorship, and the
# corpus-side rights record carries the license and the app's permission grant.
# The everyday packet ships two recipe files; its rights.json has one records
# block per file. `key` says whether a block's records are keyed by the
# packet recipe id or by the packet's source_ref slug.
PACKETS = {
    "obv/burst5-fridgeluck-rcp-originals-world": {
        "commit": "1733f5f7a8dda145d7e70fd8b2e245692d9301a2",
        "dir": "data/recipe-sources/world-2026-10",
        "manifest": "evidence/originals-rights-manifest.json",
        "blocks": [{
            "recipes": "originals.jsonl", "key": "source_ref",
        }],
    },
    "obv/burst5-fridgeluck-rcp-originals-everyday": {
        "commit": "68c164de1893a3f659584bad438f92dd693a16b6",
        "dir": "data/recipe-sources/everyday-2026-10",
        "manifest": "evidence/rights.json",
        "blocks": [
            {"manifest_inner": "everyday-originals", "recipes": "originals.jsonl",
             "key": "id"},
            {"manifest_inner": "everyday-144", "recipes": "converted-144.jsonl",
             "key": "id"},
        ],
    },
}

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


def packet_section(branch: str, cfg: dict) -> dict:
    """Pin one packet's own evidence at its pinned commit: per-record rights
    fields where the packet records them, plus each recipe's title and
    ingredient-name hash from the packet's recipes file, so the gate can tell
    the corpus recipe is the one the packet record covers."""
    commit = cfg["commit"]
    manifest_text = git("show", f"{commit}:{cfg['dir']}/{cfg['manifest']}")
    manifest = json.loads(manifest_text)
    records: dict[str, dict] = {}
    files: dict[str, dict] = {}
    for block in cfg["blocks"]:
        recipes_text = git("show", f"{commit}:{cfg['dir']}/{block['recipes']}")
        sha = hashlib.sha256(recipes_text.encode("utf-8")).hexdigest()
        files[block["recipes"]] = {
            "blob": git("rev-parse",
                        f"{commit}:{cfg['dir']}/{block['recipes']}").strip(),
            "sha256": sha,
        }
        if block.get("manifest_inner"):
            inner = manifest[block["manifest_inner"]]
            declared = inner.get("recipes_sha256")
            if declared is not None and declared != sha:
                raise SystemExit(
                    f"{branch}: block {block['manifest_inner']} declares recipes "
                    f"sha256 {declared}, which does not match the pinned file {sha}")
            entries = inner["records"]
        else:
            entries = manifest
        recipes = {r["id"]: r for r in map(json.loads, recipes_text.splitlines()) if r}
        for ref, entry in sorted(entries.items()):
            if block["key"] == "source_ref":
                recipe = next((r for r in recipes.values()
                               if r.get("source_ref") == ref), None)
            else:
                recipe = recipes.get(ref)
            if recipe is None:
                raise SystemExit(f"{branch}: packet record {ref!r} has no recipe "
                                 f"in {block['recipes']} at {commit[:12]}")
            rec = {
                "title": recipe["title"],
                "ingredients_sha256": ingredients_sha256(
                    [i["name"] for i in recipe["ingredients"]]),
            }
            if recipe.get("source_ref"):
                # 144-era rewrites in the corpus cite this row slug; the
                # citation resolves through it (see rights_evidence).
                rec["source_ref"] = recipe["source_ref"]
            for field in ("rights_status", "license", "source_type", "permissions"):
                if entry.get(field) is not None:
                    rec[field] = entry[field]
            if ref in records:
                raise SystemExit(f"{branch}: duplicate packet record {ref!r}")
            records[ref] = rec
    primary = next(b["recipes"] for b in cfg["blocks"]
                   if b["recipes"] == "originals.jsonl") \
        if any(b["recipes"] == "originals.jsonl" for b in cfg["blocks"]) \
        else cfg["blocks"][0]["recipes"]
    return {
        "commit": commit,
        "manifest_blob": git("rev-parse",
                             f"{commit}:{cfg['dir']}/{cfg['manifest']}").strip(),
        "recipes_sha256": files[primary]["sha256"],
        "files": files,
        "records": records,
    }


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
        "packets": {branch: packet_section(branch, cfg)
                    for branch, cfg in sorted(PACKETS.items())},
        "sources": {"checked_on": SOURCES_CHECKED_ON, **SOURCES},
        # FridgeLuck's own revisions of its LicenseRef-FL-Original recipes,
        # derived from the committed corpus-fixes packets (changes_rights_pin).
        # Derived from working-tree fix files, which are committed inputs — the
        # section is reproducible on any checkout carrying them.
        "fl_revisions": fl_revisions.derive(),
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
