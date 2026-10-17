# Sources — Challenge Packs

All sources in this directory were retrieved on **2026-10-11** during a single working
session. Every price, item list, and USDA identity in `budget_packs.json`,
`food_bank_packs.json`, `seasonal_packs.json`, and `use_it_up_packs.json` resolves to one
of the records below by `citationIds` / `priceSourceId`. Nothing is estimated without the
method being stated; items with no citable source were dropped and the gap is recorded
here and in each file's notes.

| id | title | publisher | url | retrieved | licence |
|----|-------|-----------|-----|-----------|---------|
| s1 | Average Price Data (AP), U.S. city average, August 2026 (series APU0000…) | U.S. Bureau of Labor Statistics | https://download.bls.gov/pub/time.series/ap/ (item list) · https://api.bls.gov/publicAPI/v2/timeseries/data/ (values) | 2026-10-11 | Public domain (U.S. government work) |
| s2 | TEFAP Fact Sheet (page updated August 11, 2026) | USDA Food and Nutrition Service / Food and Nutrition Administration | https://www.fna.usda.gov/tefap/factsheet | 2026-10-11 | Public domain (U.S. government work) |
| s3 | TEFAP Availability of Foods for Fiscal Year 2026 (Federal Register notice, May 19, 2026) | USDA Food and Nutrition Service / Food and Nutrition Administration | https://www.fna.usda.gov/tefap/fr-051926 | 2026-10-11 | Public domain (U.S. government work) |
| s4 | What to donate to a food bank and what to avoid (January 14, 2020) | Feeding America | https://www.feedingamerica.org/hunger-blog/what-donate-food-bank-and-what-avoid | 2026-10-11 | Copyright Feeding America; cited for factual reference only, no text reused |
| s5 | How the Feeding America network provides fresh food (August 1, 2025) | Feeding America | https://www.feedingamerica.org/hunger-blog/how-feeding-america-network-provides-fresh-food | 2026-10-11 | Copyright Feeding America; cited for factual reference only, no text reused |
| s6 | Seasonal Produce List by Region (NANASP/ACL chart) | Administration for Community Living, U.S. Dept. of Health and Human Services | https://acl.gov/sites/default/files/nutrition/SeasonalProduceChartByRegion.pdf | 2026-10-11 | Public domain (publication of a U.S. federal agency) |
| s7 | Typical Availability of Seasonal Fresh Fruits and Vegetables in FDPIR (chart, May 2018) | USDA Food and Nutrition Service | https://fns-prod.azureedge.us/sites/default/files/resource-files/FDPIR%20Seasonal%20Produce%20Chart%20v2-1.pdf | 2026-10-11 | Public domain (U.S. government work) |
| s8 | USDA FoodData Central (SR Legacy) food search API | USDA Agricultural Research Service | https://api.nal.usda.gov/fdc/v1/ | 2026-10-11 | Public domain (U.S. government work) |
| s9 | FridgeLuck food-safety rulebook (data/food-safety, branch `overhaul/food-safety-rules`, PR #97) | FridgeLuck project (internal data) | https://github.com/SamGu-NRX/FridgeLuck/tree/overhaul/food-safety-rules/data/food-safety | 2026-10-11 | Internal project data; see repository LICENSE |

## What each source covered

- **s1 (BLS Average Price Data)** — National-average retail prices for all budget-pack
  items. Series IDs and item names come from the AP series item list
  (`https://download.bls.gov/pub/time.series/ap/ap.item`); dollar values were queried
  through the official BLS public API (`api.bls.gov/publicAPI/v2/timeseries/data/`,
  series `APU0000<item>`, period M08 2026, `latest=true`) so every `priceUsd` is
  reproducible. Region recorded on every pack: "United States, national average",
  price date 2026-08. Series with no data for 2024–2026 (apples, butter, carrots,
  onions, canned tomatoes) were **not** priced or included — no substitutes were
  estimated. Budget-pack `totalCostUsd` is the exact sum of item `priceUsd` and sits
  under each pack's `budgetUsd`.
- **s2 (TEFAP Fact Sheet)** — How TEFAP distributions work (the `distributionNote` on
  `tefap-typical-1`) and the categories of USDA Foods purchased for TEFAP.
- **s3 (TEFAP FY2026 Availability, Federal Register)** — The full FY 2026 USDA Foods
  Available List by category; item source for the TEFAP-typical basket.
- **s4 (Feeding America: what to donate)** — Items food banks most often need (peanut
  butter, canned soup/fruit/vegetables/stew/fish/beans, pasta, rice); item source for
  the shelf-stable staples basket.
- **s5 (Feeding America: fresh food)** — That food banks distribute fresh produce,
  protein, and dairy alongside shelf-stable food via farmer/retailer/producer
  partnerships; basis for the fresh-produce-when-available basket.
- **s6 (ACL Seasonal Produce List by Region)** — Primary source for seasonal packs:
  regional produce lists and the six state groupings mapped to this file's region set
  (see mapping below).
- **s7 (FDPIR seasonal chart, May 2018)** — National month-by-month (Jan–Dec) availability
  table, read visually from the rendered chart; used to cross-check month assignments.
- **s8 (USDA FoodData Central SR Legacy API)** — USDA identities (fdcId + description)
  for pack items that are not present in the bundled 800-row
  `apps/ios/Resources/usda_ingredient_catalog.sqlite`. Ids found only here are recorded
  in `tools/validate.py`'s `unverifiedIds` allowlist with reasons (173744 kidney beans,
  175199 pinto beans, 171287 eggs, 171265 milk, 171722 cranberries, 173944 bananas,
  168877 rice, and others).
- **s9 (food-safety rulebook)** — The in-repo rules (`data/food-safety/rules.json`) that
  use-it-up packs link to via `safetyRuleRefs` instead of restating (leftover rice
  handling/reheating, produce discard decisions).

## Region mapping for seasonal packs

`s6` groups states into nine chart regions. This directory uses six contiguous
CONUS regions; the mapping is verbatim to the chart's groupings:

| regionId | chart grouping (s6) | states covered |
|----------|--------------------|----------------|
| northeast | Northeast and New England | ME, VT, NH, MA, CT, RI, NY, NJ, PA, MD, DE |
| midwest | Great Lakes, Ohio Valley, Midwest | WI, MI, IL, IN, OH, KY |
| north-central | North Central | MT, WY, CO, ND, SD, NE, KS, MN, IA, MO |
| south-central | South Central | NM, OK, TX, AR, LA |
| southeast | Southeast | WV, VA, NC, SC, TN, GA, FL, AL, MS |
| southwest | Southwest | CA, NV, AZ, UT |

The chart's **Northwest**, **Alaska**, and **Hawaii** groupings are omitted (documented
gap) to keep six contiguous CONUS regions. The chart lists produce by **season**; months
follow the meteorological convention (spring Mar–May, summer Jun–Aug, fall Sep–Nov,
winter Dec–Feb). Chart qualifiers are preserved: an "(early)" season item appears only in
that season's first month, "(late)" only in its last month; unqualified items appear in
all three months of the season.

## USDA identity resolution and gaps

- Primary identity source: the bundled catalog sqlite
  (`apps/ios/Resources/usda_ingredient_catalog.sqlite`, 800 rows) — every `usdaFdcId`
  the validator finds there is trusted.
- Identities absent from the catalog were verified through the FDC API (s8, SR Legacy
  search, quoted-description match, retrieved 2026-10-11) and are explicitly allowlisted
  in `tools/validate.py` with reasons.
- **Dropped for lack of a citable plain raw identity (recorded gap, not estimated):**
  horseradish, figs, apricots, fiddleheads, garlic scapes, currants, gooseberries,
  boysenberries, lima beans, almonds, walnuts, pecans, dates, sorghum, paw paws.
  Follow-up FDC API checks for horseradish and figs returned HTTP 429 `OVER_RATE_LIMIT`
  (shared demo key, 2026-10-11), so no identity is claimed for them.
- Seasonal chart **group names** are mapped to single identities and every such item
  carries an explanatory `note` (e.g. "Melons" → cantaloupe; "Chicories" → chicory
  greens; "Sunchokes" → Jerusalem artichoke; "Key limes" → limes; "Vidalia onions" →
  onions).

## Sources consulted but not retrievable as text this session

- **USDA SNAP-Ed Seasonal Produce Guide** (`https://snaped.fns.usda.gov/seasonal-produce-guide`,
  public domain) — pages are JavaScript-rendered and could not be text-retrieved on
  2026-10-11, so it is **not cited by any pack** and is recorded here only as an
  unverified complementary source for future work.
