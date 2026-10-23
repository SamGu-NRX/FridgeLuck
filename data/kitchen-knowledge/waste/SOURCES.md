# Sources — waste accounting factors

Every number in `emission_factors.json`, `price_factors.json`, and
`loss_factors.json` traces to one of the sources below. All were retrieved and
read in-session (2026-10-11) before being encoded. Citation ids match the
`citationId` fields in the factor files.

---

## s1 — Greenhouse gas emissions per kilogram of food product

- **Used for:** `emission_factors.json` — all `kgCo2ePerKg` central values (48 ingredient mappings).
- **Title:** "Greenhouse gas emissions per kilogram of food product", grapher CSV `ghg-per-kg-poore`; stage breakdown via grapher CSV `food-emissions-supply-chain`.
- **Data source:** Poore, J. & Nemecek, T. (2018), "Reducing food's environmental impacts through producers and consumers", *Science* 360(6392), 987–992 — global-average cradle-to-retail kg CO2e per kg of food product (land use, farm, animal feed, processing, transport, packaging, retail, retail losses).
- **Publisher:** Our World in Data.
- **URL:** https://ourworldindata.org/grapher/ghg-per-kg-poore.csv?v=1&csvType=full&useColumnShortNames=true (stage breakdown: https://ourworldindata.org/grapher/food-emissions-supply-chain.csv?v=1&csvType=full&useColumnShortNames=true)
- **Retrieved:** 2026-10-11.
- **Licence:** CC BY 4.0 — licence line verified this session on both grapher pages (footer links to https://creativecommons.org/licenses/by/4.0/).
- **How it is used:** OWID publishes a single central value per product (no low/high spread). Per the model's honesty rule, factors are therefore recorded as `low = central = high` with `rangeBasis: "point"`; no range is invented. For the five plant oils the central value is the sum of the published per-stage emissions from the supply-chain CSV (stage sums reproduce the published per-kg totals; the dataset's "Shrimps (prawns)" series is mapped to the `shrimp` key — naming difference, same P&N series).

## s2 — BLS Average Price Data (AP series)

- **Used for:** `price_factors.json` — all `usdPerKg` values (23 priced staples).
- **Title:** BLS Average Price Data, U.S. city average monthly series (`ap.item`, `ap.series`, `ap.data.0.Current`, `ap.data.3.Food`).
- **Publisher:** U.S. Bureau of Labor Statistics.
- **URL:** https://download.bls.gov/pub/time.series/ap/
- **Retrieved:** 2026-10-11, via Wayback Machine snapshots of the unmodified BLS files (2025-04-05/06): https://web.archive.org/web/20250406125820/https://download.bls.gov/pub/time.series/ap/ap.data.0.Current and https://web.archive.org/web/20250405024926/https://download.bls.gov/pub/time.series/ap/ap.data.3.Food. `download.bls.gov` blocks automated retrieval; the snapshots are of the original BLS files.
- **Licence:** Public domain (U.S. federal government work).
- **Data month:** 2025-02 (latest month present in the snapshot for all listed series), U.S. city average. Region recorded in the file as "United States, national average".
- **How it is used:** Per-pound series converted to per-kg with 1 lb = 0.45359237 kg (exact definition), division shown per row in the file's `method`. Egg and milk series quoted in non-mass units were converted with the USDA gram weights of s5.

## s3 — USDA ERS TB-1927 consumer-level loss estimates

- **Used for:** `loss_factors.json` — `consumerLevelLossPct` (38 rows).
- **Title:** Muth, M. K., Karns, S. A., Nielsen, S. J., Buzby, J. C., & Wells, H. F., "Consumer-Level Food Loss Estimates and Their Use in the ERS Loss-Adjusted Food Availability Data", USDA ERS Technical Bulletin TB-1927, January 2011 (tables 3–9, RTI International estimates).
- **Publisher:** USDA Economic Research Service.
- **URL:** https://www.ers.usda.gov/media/8547/tb-1927.pdf
- **Retrieved:** 2026-10-11 (re-verified same day against the re-fetched PDF: both lettuce LAFA commodities — "Fresh head lettuce" and "Fresh romaine and leaf lettuce" — carry previous 20% / proposed 24%, combined per appendix A).
- **Licence:** Public domain (U.S. federal government work).
- **How it is used:** Each row uses the "Proposed consumer loss estimate" where RTI published one, otherwise the "Previous consumer loss estimate" (the assumption carried in the ERS LAFA series); every row's `note` states which column it came from.

## s4 — USDA SR28 refuse percentages

- **Used for:** `loss_factors.json` — `edibleSharePct` (100 − refuse) for the rows citing an NDB number.
- **Title:** USDA National Nutrient Database for Standard Reference, Release 28 (SR28), `FOOD_DES.txt` refuse percentages.
- **Publisher:** USDA Agricultural Research Service, Nutrient Data Laboratory.
- **URL:** https://www.ars.usda.gov/ARSUserFiles/80400525/Data/SR/SR28/dnload/sr28asc.zip (file `FOOD_DES.txt`).
- **Retrieved:** 2026-10-11. The ARS host did not serve the file on re-request this session; the four refuse rows cited by NDB (grapes 09132, spinach 11457, lettuce 11252, peppers 11333) were re-verified the same day against the SR28 ASCII `FOOD_DES.txt` mirrored at https://github.com/maxsu/USDA-SR28 — item descriptions and refuse values (4%, 28%, 5%, 18%) match the shipped rows.
- **Licence:** Public domain (U.S. federal government work).
- **How it is used:** Edible-portion translation (purchased grams → edible grams) and display only; the waste model never multiplies these into waste or savings totals — the inventory event stream already records the observed outcome (`model.md`, section 5).

## s5 — USDA FoodData Central SR Legacy household-measure weights

- **Used for:** unit conversion of two BLS price series quoted in non-mass units.
- **Title:** USDA FoodData Central, SR Legacy, `food.csv` + `food_portion.csv`.
- **Publisher:** USDA Agricultural Research Service, FoodData Central.
- **URL:** https://fdc.nal.usda.gov/fdc-datasets/FoodData_Central_sr_legacy_food_csv_2018-04.zip
- **Retrieved:** 2026-10-11.
- **Licence:** Public domain (U.S. federal government work).
- **How it is used:** Egg, whole, raw, fresh (fdc_id 171287): 1 large egg = 50 g; Milk, whole, 3.25% milkfat (fdc_id 171265): 1 quart = 976 g. Used only to convert the BLS per-unit quotes (per egg, per quart) into per-kg prices.

---

## Unmapped / unpriced keys are the refusal case, not a gap to fill

Where no citable factor exists for an ingredient key — emission factors outside
the P&N coverage mapped honestly, prices outside the BLS-covered staples — the
factor files omit the row and the model reports the grams as
`missingEmissionFactor` / `missingPrice` refusals (data, not errors). No factor
is interpolated, borrowed across a mismatched category, or invented. See
`model.md` (refusal semantics) and `hand_computed_examples.json`
(ex-13–ex-16).
