# Regeneration proof (from capsule-stored outputs)

The food-study table below was regenerated **purely from capsule-stored
outputs** — no owner file was read for the table, no owner code was run,
and no live endpoint was contacted. Provenance for this table is the
capsule binding digests (capsule `usda-curation-catalog`, output
`usda_curated_ingredients.json`, sha256 `363bfad9ff10341b0258571f60b31741b8d18dcf2b3eff80d1acd6dd7e0fd7dc`),
not the repository, not HEAD, and not any run.

## Digest stability

- rebuilt twice from the same capsule bytes: identical (yes)
- volatile-content scan of the regenerated table: clean (the origin artifact's volatile `generated_at_utc` field is deliberately
  not carried into regenerated table content)

## Cross-capsule count checks (labeled)


- DIFFERENCE [cross-capsule]: Swift export ingredientCount (50, internally consistent with its 50 embedded records) differs from the capsule catalog record count (800): the two owner artifacts cover different record sets; no equality claim is made

## Provenance identities (capsule bindings)

Actual binding identities behind this table — capsule id, binding digest,
toolchain, producer evidence, and every declared source digest with its
current same/different/UNKNOWN status. These identities are the provenance;
numerical agreement with any other table is not (R7).


- capsule `usda-curation-catalog` — binding schema `1`, binding digest `21d8dbd4cca277d5...`

-   toolchain: python 3.13.14; dependencies: orjson, typer, pydantic, httpx, filelock, tenacity

-   producer evidence: none bound — producer context explicitly unknown

-   source `scripts/data/usda.py` (declared sha256 `8508f57a28f8154f...`) — same

-   source `scripts/data/usda_core/__init__.py` (declared sha256 `e3b0c44298fc1c14...`) — same

-   source `scripts/data/usda_core/batches.py` (declared sha256 `2552c6ad16fb38b5...`) — same

-   source `scripts/data/usda_core/build_sqlite.py` (declared sha256 `b1706c41c5ba79d6...`) — same

-   source `scripts/data/usda_core/cache_store.py` (declared sha256 `542d9af117eef511...`) — same

-   source `scripts/data/usda_core/candidates.py` (declared sha256 `3262cd5b62dfd422...`) — same

-   source `scripts/data/usda_core/client_async.py` (declared sha256 `8679e64455a78ad2...`) — same

-   source `scripts/data/usda_core/config.py` (declared sha256 `fa347086803f65ac...`) — same

-   source `scripts/data/usda_core/io.py` (declared sha256 `047fefa6cb9b34e1...`) — same

-   source `scripts/data/usda_core/migrate.py` (declared sha256 `f296aad28eb3dcbb...`) — same

-   source `scripts/data/usda_core/promote.py` (declared sha256 `a42929512ce6fcc1...`) — same

-   source `scripts/data/usda_core/report.py` (declared sha256 `93e80b0442301f2f...`) — same

-   source `scripts/data/usda_core/schema.py` (declared sha256 `b485765ee5ca0ff7...`) — same

-   source `scripts/data/usda_core/sprite_rules.py` (declared sha256 `0119b87ced6daa74...`) — same

-   source `scripts/data/usda_core/utils.py` (declared sha256 `810b95f77edbc215...`) — same

-   source `scripts/data/usda_core/validate.py` (declared sha256 `c2bddbc882ec617b...`) — same

-   source `scripts/data/usda_manual_overrides.json` (declared sha256 `d313885cee4b3e20...`) — same

- capsule `usda-swift-static-export` — binding schema `1`, binding digest `decfa195527df014...`

-   toolchain: python 3.13.14; dependencies: none declared

-   producer evidence: none bound — producer context explicitly unknown

-   source `scripts/data/generate_usda_ingredient_swift_static.py` (declared sha256 `54b79dcf3990f993...`) — same

-   source `apps/ios/Resources/usda_ingredient_nutrition_compact.json` (declared sha256 `7c80f8e909318f96...`) — same

## Comparison against the current origin files (labeled)

origin file: `scripts/data/catalog/usda_curated_ingredients.json` (current sha256 `363bfad9ff10341b...`)


- AGREEMENT (numerical): every row of the capsule-derived table matches the origin-derived table numerically. This is numerical agreement, NOT identical provenance: the capsule table's provenance is the packed output digests, not the origin file or any run that produced it.

## Coverage gaps

Dynamic imports that cannot be statically resolved remain **declared
coverage gaps** in the capsule. Regeneration does not guess them closed:
the capsule declares exactly what was verified, and nothing else.

## Trust limits

Digests bind content, not intent. This proof detects drift and
inconsistent rewrites; it cannot detect a consistent malicious rewrite
absent an external root of trust. Numerical agreement between the
capsule-derived table and any other table is agreement of numbers only —
it is never identical provenance.

## Regenerated table (tsv)

```tsv
category	ingredients	macro_complete	macro_complete_share
condiment	27	27	1.0000
dairy_egg	45	45	1.0000
fruit	149	149	1.0000
grain_legume	107	107	1.0000
herb_spice	27	27	1.0000
nut_seed	69	69	1.0000
oil_fat	27	27	1.0000
protein	95	95	1.0000
vegetable	254	254	1.0000
TOTAL	800	800	1.0000
```
