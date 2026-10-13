# Scraper cache — synthetic fixtures

The JSON files in this directory are **synthetic fixtures**, not scraped
content. They replace BBC Good Food scrape caches that were removed from the
repo because the site's terms required prior written permission for
redistribution and none existed (`data/recipes/RIGHTS-AUDIT.md`, "Bundled-recipe
rights audit", 2026-10-11).

What is here:

- `synthetic_fixtures.json` — 152 fictional records, same record shape as the
  removed scrape cache (`title`, `source_url`, `servings_original`,
  `servings_target`, `ingredients`, `steps`), plus `"synthetic": true` on
  every record.
- `synthetic_fixtures.test.json` — the same shape, 3 records, used as a test
  fixture.

Every title, ingredient line, and step sentence is original fiction written
for FridgeLuck; every URL is a fictional `https://example.com/fixtures/...`
address. No real site's wording, titles, or URLs appear in these files, and
no record points at bbcgoodfood.com.

Regenerate deterministically (byte-identical output, no RNG, offline):

    python3 scripts/recipe_scraper/make_synthetic_fixtures.py

`generate_rights_audit.py` reads these fixtures for its cache cross-checks
(record counts, bbcgoodfood.com URL count, title membership against the 25
seed recipes). The scraper itself (`scrape-recipes run`) still writes its
output wherever `--out` points; if you run it, keep the result out of the
repo unless the rights position for the source has changed.
