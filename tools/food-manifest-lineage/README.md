# Food-manifest lineage scanner

Static, offline lineage analysis for FridgeLuck's public dataset manifests. It
answers three questions about the manifests the repo already publishes — the
dish-ambiguity sampling manifests, the nonfood-rejection manifest, the multiplate
manifest, the FoodSeg103-style CSV, the FridgeLuck catalogue tables and review
batches, the preparation-state fixture, the Nutrition5k experiment artifacts,
and the bundled demo manifest — without fetching anything:

1. which items are the same bytes (exact duplicates) or the same upstream
   source object reused under different declared identities,
2. which of those relationships only become visible transitively (no single
   key spans the cluster), and
3. which relationships cross manifest boundaries and declared group
   boundaries.

**Core policy: unknown provenance stays unknown.** A record with no declared
source id, no declared upstream revision, or no declared content hash keeps
those values as `unknown` and is never joined on them. Unknown never joins
unknown, so manifests that only describe experiment outputs (for example the
Nutrition5k summary) contribute records that are counted but never clustered.
This is the tool-side mirror of the data rule the repo's evidence work already
follows: nothing is inferred to fill a missing key.

## Layout

```
lineage/records.py    LineageRecord + normalization (kind, hashes, dhash, id/revision)
lineage/adapters.py   Manifest-shape adapters (one per family) + run_adapter
lineage/graph.py      Union-find clustering over composite (origin, key-type, key) nodes
lineage/detectors.py  Per-cluster categories: exact-duplicate, renamed-url,
                      source-reuse, transitive-source, cross-manifest, cross-group
check.py              Contract-fixture check (expectations + false-positive controls)
report.py             Compact census + proposed repairs; --verify-report checks
                      byte-identical regeneration
audit/                Pinned inputs.json + read-only audit runner + committed results
fixtures/             Synthetic contracts: 11 manifests, 32 records, 15 controls
tests/                pytest suite (adapters, engine semantics, check integration,
                      harness mutation tests)
```

### Record schema

Every manifest row becomes a `LineageRecord`:

| field | meaning |
|---|---|
| `manifest`, `item_id` | which manifest and which row (composite identity; item ids are manifest-scoped) |
| `kind` | `image` \| `product` \| `plate` |
| `origin` | upstream source family, e.g. `food-101`, `openimages`, `foodseg103`, `usda-fdc`, `fixture-app` |
| `source_id` | stable upstream object id (path, image id, FDC id, dish id) — join key `source` |
| `content_hash` | sha256 of bytes — declared, or computed via a blob resolver — join key `sha256` |
| `declared_dhash` | declared perceptual hash, canonicalized but **not** a join key |
| `product_revision` | declared upstream edition/revision (e.g. `SR Legacy`, a descriptor) |
| `declared_group` | the group the manifest declares (class/split, subset/role, dup group, plate cluster, sprite group) |
| `location` | known URL/path for the object — feeds `renamed-url` |

### Join keys

- `sha256:<hash>` — exact bytes. Declared hashes join immediately; undeclared
  hashes are computed only if a blob resolver is supplied (demo assets).
- `source:<origin>/<id>` — same upstream object. Scoped by origin so the same
  numeric id under two different source families never joins.

### Detector categories (per cluster of ≥2 records)

- **exact-duplicate** — members joined by an identical content hash.
- **renamed-url** — same source object at ≥2 distinct known locations.
- **source-reuse** — members joined by source identity (distinct or shared
  locations).
- **transitive-source** — no single key spans the whole cluster; the
  relationship is only visible through union-find.
- **cross-manifest** — members come from ≥2 manifests.
- **cross-group** — members carry ≥2 distinct declared groups.

Order-independent and id-independent: shuffling input records or renaming
manifests/items does not change any count (`tests/test_engine.py` proves both).

## Families: audited here vs. modeled by contract

Two tiers, kept explicit so neither borrows evidence from the other:

- **Real, audited by the pinned audit** (`audit/audit.py` over
  `audit/inputs.json`): the bundled demo benchmark manifest (whose referenced
  images are committed and hashed read-only), the USDA catalogue
  (`usda_curated_ingredients.json`), the 21 USDA review batches, the manual
  overrides, and the compact nutrition map. These are files committed in this
  repository at the audit head.
- **Modeled shapes, validated only by the synthetic contract** (`check.py`):
  Food-101-style dish-ambiguity manifests, the Open Images-style nonfood
  rejection manifest, the multiplate manifest, the FoodSeg103-style CSV,
  preparation-state groups, and Nutrition5k experiment artifacts. None of
  those manifests are committed to this repository at the audit head, so the
  audit says nothing about them; their adapters are exercised purely by the
  synthetic fixture (all ids, hashes, and hosts in it are synthetic).

## Usage

```bash
# Contract check (expectations + false-positive controls), exit code 0 on pass
python3 tools/food-manifest-lineage/check.py \
    --fixture tools/food-manifest-lineage/fixtures/contracts.json

# Tests
python3 -m pytest tools/food-manifest-lineage/tests -q

# Pinned read-only audit of the repository's committed manifests
# (verifies audit/inputs.json pins, writes audit/results.json)
python3 tools/food-manifest-lineage/audit/audit.py

# Compact report with proposed (never applied) repairs
python3 tools/food-manifest-lineage/report.py

# Verify the committed report still regenerates byte-identically
python3 tools/food-manifest-lineage/report.py --verify-report
```

### Contract fixtures

`fixtures/contracts.json` drives `check.py`. Each entry names an adapter, a
kind, the data file, and an optional declared revision; `expectations` pins the
exact counts the scanner must produce; `controls.quiet_item_refs` lists items
that share only surface features with planted positives (same class, same
sprite group, same subdirectory, blank or unknown keys) and must produce **no**
finding. All fixture ids, hashes, and URLs are synthetic (`fixture.invalid`
hosts, `aa…`-pattern sha256 placeholders).

Planted relationships in the fixtures:

- exact duplicate across dev/test splits with a renamed path (dish manifests)
- same Open Images id at two URLs, one also reused as a nonfood control
- three records chained only through a shared hash + shared source id
  (transitive — no spanning key)
- FoodSeg103 rows sharing bytes across splits; two rows with blank hashes that
  must stay singletons
- FDC rows reused across the catalogue, a review batch, and preparation-state
  members (including a null descriptor → unknown revision)

## Design notes

- **Declared ≠ computed.** A declared dhash labels the record; only exact
  sha256 joins clusters. Perceptual similarity is intentionally out of scope
  for this static pass — it cannot be verified without fetching pixels, which
  this tool never does.
- **Split-scoped ids.** Some real manifests recycle numeric ids across splits
  (FoodSeg103's `7`/`77`); the source id is scoped by the split the manifest
  declares so two different rows never collide, while cross-split byte
  identity is still caught by the hash key.
- **Manifests without per-item lineage.** The Nutrition5k summary contributes
  one record with unknown keys; it exists so the checker can prove such
  manifests stay quiet rather than vanish.

## Audit milestone

`audit/inputs.json` pins every permitted manifest committed at the audit head
(path, git blob SHA, file sha256, byte count, last-modifying commit) and
`audit/audit.py` verifies each pin before scanning — a drifted pin is a hard
failure, not a warning. It writes `audit/results.json` (per-manifest census,
cluster counts, example findings with item ids, approximate-dHash flags kept
separate) and `audit/summary.md` interprets it. The audit is read-only and
offline: it hashes committed files, fetches nothing, and never treats a
declared perceptual hash as evidence of duplication.

## Report milestone

`report.py` runs the same pinned scan and writes `report/report.json` plus a
deterministic `report/summary.md`: a compact per-manifest census and four
repair categories derived mechanically from the findings — align-group
conflicts (catalog group as canonical), within-manifest duplicate rows,
orphan source references, and label drift. Proposals are informational; the
tool never modifies a manifest or dataset. `--verify-report` regenerates
both files and requires a byte-identical match, so a committed report acts
as a regression gate.

Mutation tests (`tests/test_mutation.py`) run check.py as a subprocess on
mutated fixture copies and prove the harness catches violations: a dropped
expectation, a broken planted duplicate, a newly planted duplicate or
source-reuse relationship on a quiet control all fail the check, while
record-order permutation (content-derived ids) and group-label similarity
still pass.

## Known limitation

`audit.py` (pinned read-only audit) and `report.py` (compact census with
proposed repairs) are implemented over the repository's real committed
manifests; results are committed under `audit/` and `report/`. The dataset
families not committed to this repository remain out of scope for the audit
even though their adapter shapes are contract-tested.
