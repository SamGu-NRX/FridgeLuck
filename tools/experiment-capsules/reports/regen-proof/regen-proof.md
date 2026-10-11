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
