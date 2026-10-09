"""Offline, self-contained tour of the usda_core ingredient pipeline.

Run it exactly as a new engineer would:

    cd scripts/data && uv run python usda_core/examples/pipeline_demo.py

The script replays the full lifecycle of the USDA ingredient pipeline inside a
throwaway temporary directory, so it never touches the network, the real
catalog, or any file outside that directory:

1. build a tiny 3-row synthetic canonical catalog and round-trip it through
   disk with ``io.save_canonical`` / ``io.load_canonical``;
2. validate it with ``validate.validate_catalog`` and print its stats;
3. export a review batch with ``batches.export_batch`` — one fresh candidate
   plus the lowest-quality catalog rows — and print the review-notes
   distribution;
4. simulate a human editing the batch JSON (new alias on the green-onion row)
   and merge it back with ``promote.promote_batch``, which must also infer the
   missing ``sprite_key`` values — surfacing the green-onion quirk where
   "green onion" text resolves to the plain ``onion`` sprite key;
5. demonstrate the macro-freeze guard: promoting a batch that edits an
   existing row's macros raises ``promote.PromoteError``;
6. build the app SQLite database with ``build_sqlite.build_sqlite`` and print
   every table with its row count (the iOS app queries ``ingredients`` and
   ``ingredient_aliases``);
7. print the head of a markdown pipeline report from ``report.build_report``.

Every step prints a ``step N:`` line so the run can be asserted on by
``usda_core/tests/p11_test_examples.py``. The process exits 0 on success and
non-zero if an internal guard fails.
"""

from __future__ import annotations

import sqlite3
import sys
import tempfile
from collections import Counter
from pathlib import Path
from typing import Iterable

# Bootstrap so the demo runs as `uv run python usda_core/examples/pipeline_demo.py`
# from scripts/data without installing anything: parents[2] is scripts/data,
# the directory that contains the usda_core package.
sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

from usda_core.batches import export_batch  # noqa: E402
from usda_core.build_sqlite import build_sqlite  # noqa: E402
from usda_core.io import load_batch, load_canonical, save_batch, save_canonical  # noqa: E402
from usda_core.promote import PromoteError, promote_batch  # noqa: E402
from usda_core.report import build_report  # noqa: E402
from usda_core.schema import (  # noqa: E402
    BatchPayload,
    BatchRow,
    CanonicalCatalog,
    CuratedIngredientRow,
    MacroSet,
    SourceMeta,
)
from usda_core.validate import validate_catalog  # noqa: E402

# Fixed fdc_ids for the synthetic rows. Real fdc_ids are USDA-minted positive
# integers; the demo uses a made-up block starting at 171001 so it can never
# collide with the real catalog. The only invariants validate_catalog checks
# are that ids are strictly increasing and unique.
OLIVE_OIL_FDC_ID = 171001
GREEN_ONION_FDC_ID = 171002
BABY_CARROT_FDC_ID = 171003
ROTISSERIE_CHICKEN_FDC_ID = 171004


def _row(
    fdc_id: int,
    display_name: str,
    category_label: str,
    food_category: str,
    alt_names: list[str],
    description: str,
    source_description: str,
    macros: dict[str, float],
) -> CuratedIngredientRow:
    """Build one CuratedIngredientRow with demo-appropriate source metadata."""
    return CuratedIngredientRow(
        fdc_id=fdc_id,
        display_name=display_name,
        alt_names=alt_names,
        category_label=category_label,
        sprite_key="",  # left empty on purpose: promote_batch infers it (see step 4)
        description=description,
        source_description=source_description,
        source_meta=SourceMeta(
            data_type="SR Legacy",
            food_category=food_category,
            verified_at_utc="2026-01-01T00:00:00Z",
            # verification_source defaults to "USDA FoodData Central API",
            # which both validate_catalog and promote_batch require.
        ),
        macros=MacroSet(**macros),
    )


def make_demo_catalog() -> CanonicalCatalog:
    """Build the tiny synthetic canonical catalog the demo starts from.

    Three rows with strictly increasing fdc_ids (``validate_catalog`` rejects
    anything else) and full USDA provenance on every row. ``sprite_key`` is
    left empty on every row so ``promote_batch`` has to infer it later — that
    is what surfaces the green-onion sprite-key quirk in step 4.

    >>> catalog = make_demo_catalog()
    >>> [row.fdc_id for row in catalog.records]
    [171001, 171002, 171003]
    >>> [row.display_name for row in catalog.records]
    ['Olive Oil (Extra Virgin)', 'Green Onions (Scallions)', 'Baby Carrots']
    """
    return CanonicalCatalog(
        # Fixed timestamp instead of utils.utc_now_iso() so doctests and demo
        # output stay deterministic.
        generated_at_utc="2026-01-01T00:00:00Z",
        records=[
            _row(
                fdc_id=OLIVE_OIL_FDC_ID,
                display_name="Olive Oil (Extra Virgin)",
                category_label="oil_fat",
                food_category="Fats and Oils",
                alt_names=["olive oil", "extra virgin olive oil", "evoo"],
                description="Extra virgin olive oil is a fruit-oil fat used for dressing and low-heat cooking.",
                source_description="Oil, olive, extra virgin",
                macros={"calories": 884.0, "fat_g": 100.0, "sodium_g": 0.002},
            ),
            _row(
                fdc_id=GREEN_ONION_FDC_ID,
                display_name="Green Onions (Scallions)",
                category_label="vegetable",
                food_category="Vegetables and Vegetable Products",
                alt_names=["green onion", "scallion"],
                description="Green onions are mild alliums used raw as a garnish or briefly cooked.",
                source_description="Onions, green (scallions), raw",
                macros={"calories": 32.0, "carbs_g": 7.34, "fiber_g": 2.6, "protein_g": 1.83, "sodium_g": 0.016},
            ),
            _row(
                fdc_id=BABY_CARROT_FDC_ID,
                display_name="Baby Carrots",
                category_label="vegetable",
                food_category="Vegetables and Vegetable Products",
                alt_names=["baby carrots", "carrots"],
                description="Baby carrots are small peeled carrots sold ready to eat as a snack vegetable.",
                source_description="Carrots, baby, raw",
                macros={"calories": 35.0, "carbs_g": 8.22, "fiber_g": 2.9, "sugar_g": 4.74, "sodium_g": 0.069},
            ),
        ],
    )


def make_candidate_row() -> CuratedIngredientRow:
    """Build one fresh USDA candidate that is not yet in the catalog.

    ``export_batch`` takes candidates like this one, skips any whose fdc_id
    already exists in the catalog, and emits the rest as ``upsert`` rows with
    the review note "new candidate from USDA".

    >>> make_candidate_row().fdc_id
    171004
    >>> make_candidate_row().display_name
    'Rotisserie Chicken'
    """
    return _row(
        fdc_id=ROTISSERIE_CHICKEN_FDC_ID,
        display_name="Rotisserie Chicken",
        category_label="protein",
        food_category="Poultry Products",
        alt_names=["rotisserie chicken", "store roasted chicken"],
        description="Rotisserie chicken is a cooked store-bought bird, skinned and shredded before use.",
        source_description="Chicken, broilers or fryers, rotisserie, meat only",
        macros={"calories": 190.0, "protein_g": 27.3, "fat_g": 8.6, "sodium_g": 0.37},
    )


def note_distribution(notes: Iterable[str]) -> dict[str, int]:
    """Count review-note strings, most common first, ties in alphabetical order.

    Sorting is explicit (not ``Counter.most_common``) so the demo output is
    byte-stable between runs.

    >>> note_distribution(["review metadata quality", "new candidate from USDA", "review metadata quality"])
    {'review metadata quality': 2, 'new candidate from USDA': 1}
    """
    return dict(sorted(Counter(notes).items(), key=lambda item: (-item[1], item[0])))


def main() -> None:
    """Run the seven demo steps against a throwaway temporary directory."""
    with tempfile.TemporaryDirectory(prefix="usda_core_demo_") as tmp:
        work = Path(tmp)
        catalog_path = work / "canonical.json"

        print("step 1: build a 3-row synthetic canonical catalog and round-trip it through disk")
        catalog = make_demo_catalog()
        save_canonical(catalog_path, catalog)
        catalog = load_canonical(catalog_path)
        print(f"step 1: {len(catalog.records)} rows written to {catalog_path.name} and loaded back")

        print("step 2: validate the catalog")
        # A real validate run uses the 14 default app search terms
        # (config.DEFAULT_REQUIRED_TERMS); a 3-row demo catalog can only
        # contain a few of them, so pass a matching subset. Note that an
        # EMPTY list would silently fall back to the default 14 — only a
        # non-empty custom list is honored.
        stats = validate_catalog(catalog, required_terms=["olive oil", "green onion", "scallion", "carrot"])
        print(f"step 2: stats {stats}")

        print("step 3: export a review batch (one new candidate + lowest-quality catalog rows)")
        batch = export_batch(catalog, batch_id=1, batch_size=4, candidates=[make_candidate_row()])
        notes = note_distribution([record.review_notes for record in batch.records])
        print(f"step 3: batch_id={batch.batch_id} rows={batch.batch_size} review-notes={notes}")

        print("step 4: simulate a human edit, then promote the batch back into the catalog")
        batch_path = work / "manual_batch_1.json"
        save_batch(batch_path, batch)
        batch = load_batch(batch_path)  # the human opens the exported batch file
        for record in batch.records:
            if record.row.fdc_id == GREEN_ONION_FDC_ID:
                # The human review edit: add one alias and note what changed.
                # Macros are left untouched — see the freeze guard in step 5.
                record.row.alt_names.append("spring onion")
                record.review_notes = "added spring onion alias; macros untouched"
        save_batch(batch_path, batch)
        merged = promote_batch(catalog, load_batch(batch_path))
        print(
            f"step 4: row count {len(catalog.records)} -> {len(merged.records)} "
            f"after promoting the edited batch {batch_path.name}"
        )
        green_onion = next(row for row in merged.records if row.fdc_id == GREEN_ONION_FDC_ID)
        print(
            f"step 4: quirk — the green-onion row got sprite_key={green_onion.sprite_key!r}, "
            "not 'green_onion' (DISTINCT_SPRITE_KEYS tests 'onion' before 'green onion')"
        )

        print("step 5: macros are frozen — promoting a changed macro value must fail")
        olive_oil = next(row for row in merged.records if row.fdc_id == OLIVE_OIL_FDC_ID)
        tampered = olive_oil.model_copy(deep=True)
        tampered.macros.calories = 950.0
        tampered_batch = BatchPayload(
            batch_id=2,
            batch_size=1,
            records=[BatchRow(action="upsert", row=tampered, review_notes="macro tamper test")],
        )
        try:
            promote_batch(merged, tampered_batch)
        except PromoteError as exc:
            print(f"step 5: caught expected PromoteError: {exc}")
        else:
            raise SystemExit("step 5 FAILED: macro-freeze guard did not fire")

        print("step 6: build the app SQLite database in the temp dir")
        db_path = work / "usda_ingredient_catalog.sqlite"
        build_sqlite(merged, db_path)
        conn = sqlite3.connect(str(db_path))
        try:
            tables = [
                name
                for (name,) in conn.execute(
                    "SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name"
                )
            ]
            for table in tables:
                count = conn.execute(f"SELECT COUNT(*) FROM {table}").fetchone()[0]
                print(f"step 6: table {table}: {count} rows")
        finally:
            conn.close()

        print("step 7: build a markdown pipeline report")
        report = build_report(merged)
        for line in report.splitlines()[:6]:
            print(f"    {line}".rstrip())

    print("done: temp directory removed; nothing was written outside it")


if __name__ == "__main__":
    main()
