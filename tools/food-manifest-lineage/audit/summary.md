# Pinned read-only manifest lineage audit

Run at audit head `148c6e7a4ee6` on branch `obv/fl-l3-source-reuse-audit`.
Every input is a file already committed in this repository, pinned in
[`inputs.json`](inputs.json) by git blob SHA, file sha256, byte count, and
last-modifying commit; `audit.py` refuses to run when any pin drifts.

**Scope:** offline, read-only. No image acquisition, no recognition, no
network access, datasets untouched.

## Results

| total | value |
|---|---|
| pinned manifests | 25 |
| records | 1992 |
| multi-member reuse clusters | 801 (1928 records) |
| singletons | 64 |
| — exact-duplicate (byte-identical) | 0 |
| — renamed-url | 0 |
| — source-reuse (same FDC id across manifests) | 801 |
| — transitive (no spanning key) | 0 |
| cross-manifest spans | 801 |
| cross-group spans | 249 |
| unknown content-hash records | 1988 |
| unknown source-id records | 1 |
| declared dHash records / approximate flags | 0 / 0 |

Cluster sizes: 492 pairs, 293 triples, 15 quads, 1 quint.

## What the findings mean

1. **Product-level source reuse is pervasive by design, not by accident.**
   All 990 review-batch rows reference FDC products that already exist in
   `usda_curated_ingredients.json` (798 distinct ids over 21 batches), and
   148 manual-override entries target 104 of those same catalog rows. The
   801 clusters are the same upstream product referenced by two to five
   manifests under slightly different labels — the audit surfaces them with
   both declared labels so curation can resolve drift (see examples below).

2. **Declared-group conflicts are real and quantified: 249 clusters.** The
   same FDC id is declared under different sprite groups in different
   manifests. Examples:
   - `fdc-170932` Red Pepper (Cayenne / Flakes): `herb_spice` in the catalog
     and batch 21, but `other` in batch 11.
   - `fdc-168324` Rendered Bacon Fat: `oil_fat` in the catalog and batch 18,
     but `protein` in batch 11.

3. **No byte-level duplication exists in the bundled demo assets.** The four
   images referenced by `benchmark_manifest.json` were hashed read-only from
   the repo (`hash_provenance: computed`); all four are distinct.

4. **Unknown stays unknown.** 1988 of 1992 records have no declared content
   hash (they are text product rows; the 4 exceptions are the computed demo
   image hashes). 1 record (one compact-nutrition ingredient with no match)
   has no source id. None of these were joined on their missing keys, and no
   declared dHash exists in any pinned manifest — the approximate-dHash flag
   section is empty and reported as such, never merged into duplicates.

## Interpretation limits

- Product manifests declare identity (FDC ids) but not bytes; the zero
  exact-duplicate count is evidence only about the four hashed demo images,
  not about the 1984 product rows.
- Dataset diversity judgments ("is reuse too high?") are downstream of this
  census — the audit quantifies reuse; it does not rank it.
- Food-101, Open Images, FoodSeg103, Nutrition5k, and preparation-state
  families are not committed to this repository at the audit head, so they
  are out of scope here. The scanner's adapters for those shapes are
  validated by the synthetic contract fixture (`check.py`), not by this
  audit.

Reproduce:

```bash
python3 tools/food-manifest-lineage/audit/audit.py
```

Full machine-readable output: [`results.json`](results.json).
