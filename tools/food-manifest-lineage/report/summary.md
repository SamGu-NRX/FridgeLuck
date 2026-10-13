# Lineage report (compact)

Audit head: `148c6e7a4ee63d4b8c31433a74c643001c1e04b6` on branch `obv/fl-l3-source-reuse-audit`.

| manifest | records | images | products | distinct src ids | distinct groups | unknown src | unknown hash |
|---|---|---|---|---|---|---|---|
| apps/ios/Resources/benchmark_manifest.json | 4 | 4 | 0 | 4 | 4 | 0 | 0 |
| apps/ios/Resources/usda_ingredient_nutrition_compact.json | 50 | 0 | 50 | 49 | 0 | 1 | 50 |
| scripts/data/catalog/usda_curated_ingredients.json | 800 | 0 | 800 | 800 | 9 | 0 | 800 |
| scripts/data/review_batches/manual_batch_001.json | 50 | 0 | 50 | 50 | 4 | 0 | 50 |
| scripts/data/review_batches/manual_batch_002.json | 10 | 0 | 10 | 10 | 3 | 0 | 10 |
| scripts/data/review_batches/manual_batch_003.json | 50 | 0 | 50 | 50 | 5 | 0 | 50 |
| scripts/data/review_batches/manual_batch_004.json | 50 | 0 | 50 | 50 | 4 | 0 | 50 |
| scripts/data/review_batches/manual_batch_005.json | 50 | 0 | 50 | 50 | 4 | 0 | 50 |
| scripts/data/review_batches/manual_batch_006.json | 50 | 0 | 50 | 50 | 4 | 0 | 50 |
| scripts/data/review_batches/manual_batch_007.json | 50 | 0 | 50 | 50 | 4 | 0 | 50 |
| scripts/data/review_batches/manual_batch_008.json | 50 | 0 | 50 | 50 | 4 | 0 | 50 |
| scripts/data/review_batches/manual_batch_009.json | 50 | 0 | 50 | 50 | 3 | 0 | 50 |
| scripts/data/review_batches/manual_batch_010.json | 50 | 0 | 50 | 50 | 4 | 0 | 50 |
| scripts/data/review_batches/manual_batch_011.json | 50 | 0 | 50 | 50 | 6 | 0 | 50 |
| scripts/data/review_batches/manual_batch_012.json | 50 | 0 | 50 | 50 | 7 | 0 | 50 |
| scripts/data/review_batches/manual_batch_013.json | 50 | 0 | 50 | 50 | 8 | 0 | 50 |
| scripts/data/review_batches/manual_batch_014.json | 50 | 0 | 50 | 50 | 7 | 0 | 50 |
| scripts/data/review_batches/manual_batch_015.json | 50 | 0 | 50 | 50 | 6 | 0 | 50 |
| scripts/data/review_batches/manual_batch_016.json | 50 | 0 | 50 | 50 | 7 | 0 | 50 |
| scripts/data/review_batches/manual_batch_017.json | 50 | 0 | 50 | 50 | 5 | 0 | 50 |
| scripts/data/review_batches/manual_batch_018.json | 50 | 0 | 50 | 50 | 7 | 0 | 50 |
| scripts/data/review_batches/manual_batch_019.json | 50 | 0 | 50 | 50 | 9 | 0 | 50 |
| scripts/data/review_batches/manual_batch_020.json | 50 | 0 | 50 | 50 | 5 | 0 | 50 |
| scripts/data/review_batches/manual_batch_021.json | 30 | 0 | 30 | 30 | 7 | 0 | 30 |
| scripts/data/usda_manual_overrides.json | 148 | 0 | 148 | 148 | 0 | 0 | 148 |

Totals: 25 manifests, 1992 records, 801 reuse clusters, 64 singletons.

## Proposed repairs (informational — nothing is modified)

### align_group — 138 candidate(s)

same upstream product declared under different groups; canonical group is the catalog's when present.

```json
[
  {
    "cluster_id": "cl-00e2c64dc24f",
    "canonical_group": [
      "nut_seed"
    ],
    "declared_groups": [
      "nut_seed",
      "other"
    ],
    "conflicts": [
      {
        "manifest": "scripts/data/review_batches/manual_batch_008.json",
        "item_id": "batch8-rec-000041",
        "declared_group": "other"
      }
    ],
    "conflict_count": 1
  },
  {
    "cluster_id": "cl-01677013d38d",
    "canonical_group": [
      "dairy_egg"
    ],
    "declared_groups": [
      "dairy_egg",
      "other"
    ],
    "conflicts": [
      {
        "manifest": "scripts/data/review_batches/manual_batch_005.json",
        "item_id": "batch5-rec-000045",
        "declared_group": "other"
      }
    ],
    "conflict_count": 1
  },
  {
    "cluster_id": "cl-0411c89ec2c3",
    "canonical_group": [
      "oil_fat"
    ],
    "declared_groups": [
      "oil_fat",
      "protein"
    ],
    "conflicts": [
      {
        "manifest": "scripts/data/review_batches/manual_batch_011.json",
        "item_id": "batch11-rec-000044",
        "declared_group": "protein"
      }
    ],
    "conflict_count": 1
  },
  {
    "cluster_id": "cl-0435e988eefd",
    "canonical_group": [
      "dairy_egg"
    ],
    "declared_groups": [
      "dairy_egg",
      "other"
    ],
    "conflicts": [
      {
        "manifest": "scripts/data/review_batches/manual_batch_005.json",
        "item_id": "batch5-rec-000049",
        "declared_group": "other"
      }
    ],
    "conflict_count": 1
  },
  {
    "cluster_id": "cl-07d84b94ff63",
    "canonical_group": [
      "grain_legume"
    ],
    "declared_groups": [
      "grain_legume",
      "other"
    ],
    "conflicts": [
      {
        "manifest": "scripts/data/review_batches/manual_batch_001.json",
        "item_id": "batch1-rec-000039",
        "declared_group": "other"
      }
    ],
    "conflict_count": 1
  }
]
```

### within_manifest_duplicate — 0 candidate(s)

same source id appears on multiple rows inside one manifest; candidate for upsert-style dedupe.

No candidates.

### orphan_source — 64 candidate(s)

source ids referenced outside the catalog but absent from it; add to the catalog or drop the reference.

```json
[
  {
    "source_id": "167535",
    "first_manifest": "apps/ios/Resources/usda_ingredient_nutrition_compact.json",
    "labels": [
      "tortilla"
    ]
  },
  {
    "source_id": "167614",
    "first_manifest": "apps/ios/Resources/usda_ingredient_nutrition_compact.json",
    "labels": [
      "canned tuna"
    ]
  },
  {
    "source_id": "167647",
    "first_manifest": "apps/ios/Resources/usda_ingredient_nutrition_compact.json",
    "labels": [
      "salmon"
    ]
  },
  {
    "source_id": "167943",
    "first_manifest": "apps/ios/Resources/usda_ingredient_nutrition_compact.json",
    "labels": [
      "bread"
    ]
  },
  {
    "source_id": "168218",
    "first_manifest": "scripts/data/usda_manual_overrides.json",
    "labels": []
  }
]
```

### label_drift — 166 candidate(s)

same source id declared under multiple labels; pick a canonical display name.

```json
[
  {
    "source_id": "167722",
    "labels": [
      "Tofu Yogurt",
      "tofu"
    ]
  },
  {
    "source_id": "167737",
    "labels": [
      "Corn-Peanut-Olive Oil Blend",
      "olive oil"
    ]
  },
  {
    "source_id": "167746",
    "labels": [
      "Lemons (Without Peel, Raw)",
      "lemon"
    ]
  },
  {
    "source_id": "167764",
    "labels": [
      "Tropical Fruit Salad (Heavy Syrup)",
      "banana"
    ]
  },
  {
    "source_id": "167782",
    "labels": [
      "Abiyuch Fruit",
      "Abiyuch Fruit (Raw)"
    ]
  }
]
```

Unobserved lineage: records with unknown source ids or hashes are counted but never joined, so they generate no repairs.
