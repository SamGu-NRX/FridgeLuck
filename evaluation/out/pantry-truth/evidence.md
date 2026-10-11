# Suite A (pantry-truth) — audit evidence

Run: 2026-10-11T23:34:29Z · seed 20261011 · corpus apps/ios/Resources/data.json (sha256 62d9ed0ae769…)

## Grounding

- Recipe corpus of record: `apps/ios/Resources/data.json` — the production bundled corpus the app loads (BundledDataLoader). The task brief named `assets/recipes.json`; no such file exists on any branch of this repository.
- USDA grounding (`scripts/data/catalog/usda_curated_ingredients.json`): 36 of 50 catalog ingredients matched against 800 USDA records (name-based, recorded only).
- Production fit subset compiled verbatim (13 files, SHA256s in results.json); replayed through the real RecipeRepository/RecommendationPolicy calls on GRDB. Replicated boundary (cannot compile on Linux): `AppDependencies.swift:137-139` — availableIds come from inventory lots only.
- No LLM arm: the programme plan's suite A is property tests + the 200-pair deterministic audit; none designed, none left unexecuted.

## Metric 1 — stock counted twice (bar == 0)

Findings: **37** of 62 plans. A finding is production calling both dinners makeable from one shared lot that cannot cover both (quantities are dropped at the AppDependencies boundary; the fit matches by ingredient-ID membership). First 10 of 37 shown:
- `PLAN-C1` (curated_scarce_shared_lot): shared lot 125.0 g vs combined demand 150.0 g — production: both makeable.
- `PLAN-R001` (random_shared_lot): shared lot 60.9 g vs combined demand 110.0 g — production: both makeable.
- `PLAN-R002` (random_shared_lot): shared lot 6.5 g vs combined demand 10.0 g — production: both makeable.
- `PLAN-R004` (random_shared_lot): shared lot 7.2 g vs combined demand 10.0 g — production: both makeable.
- `PLAN-R005` (random_shared_lot): shared lot 4.7 g vs combined demand 11.0 g — production: both makeable.
- `PLAN-R006` (random_shared_lot): shared lot 4.6 g vs combined demand 11.0 g — production: both makeable.
- `PLAN-R008` (random_shared_lot): shared lot 102.2 g vs combined demand 220.0 g — production: both makeable.
- `PLAN-R009` (random_shared_lot): shared lot 201.3 g vs combined demand 275.0 g — production: both makeable.
- `PLAN-R011` (random_shared_lot): shared lot 6.4 g vs combined demand 14.0 g — production: both makeable.
- `PLAN-R012` (random_shared_lot): shared lot 6.5 g vs combined demand 12.0 g — production: both makeable.

Anomalies (production missed something the ledger covers):
- `PLAN-R045`: production did not render one or both dinners although the ledger covers every line; the baseline ranks exact matches and surfaces 20, so fully-covered dinners can miss the ranked window (a coverage-visibility gap, not a double count)
- `PLAN-R046`: production did not render one or both dinners although the ledger covers every line; the baseline ranks exact matches and surfaces 20, so fully-covered dinners can miss the ranked window (a coverage-visibility gap, not a double count)
- `PLAN-R055`: production did not render one or both dinners although the ledger covers every line; the baseline ranks exact matches and surfaces 20, so fully-covered dinners can miss the ranked window (a coverage-visibility gap, not a double count)

## Metric 2 — sufficient claimed without quantity evidence (bar == 0)

Offending line-instances across the 200 pairs: **209** (production counts matched; ledger state short/quantity_unknown/needs_reconfirming/assumed_staple/missing). True counts by class: {"short_by_quantity": 77, "observed_unknown": 54, "estimated_quantity": 39, "stale_evidence": 39}. Examples (capped at 12 per class, 209 shown): {"short_by_quantity": ["P001:9:short", "P001:6:short", "P004:22:short", "P004:6:short", "P007:21:short", "P007:6:short", "P021:28:short", "P021:12:short", "P031:19:short", "P031:21:short", "P032:21:short", "P032:6:short"], "observed_unknown": ["P008:21:quantity_unknown", "P008:39:quantity_unknown", "P009:22:quantity_unknown", "P009:3:quantity_unknown", "P010:22:quantity_unknown", "P010:25:quantity_unknown", "P018:22:quantity_unknown", "P018:21:quantity_unknown", "P028:17:quantity_unknown", "P028:21:quantity_unknown", "P033:6:quantity_unknown", "P033:22:quantity_unknown"], "estimated_quantity": ["P013:1:quantity_unknown", "P013:3:quantity_unknown", "P017:4:quantity_unknown", "P017:22:quantity_unknown", "P019:41:quantity_unknown", "P019:42:quantity_unknown", "P024:4:quantity_unknown", "P024:29:quantity_unknown", "P036:6:quantity_unknown", "P036:35:quantity_unknown", "P057:41:quantity_unknown", "P057:6:quantity_unknown"], "stale_evidence": ["P027:21:needs_reconfirming", "P027:6:needs_reconfirming", "P030:38:needs_reconfirming", "P030:7:needs_reconfirming", "P040:6:needs_reconfirming", "P040:2:needs_reconfirming", "P041:6:needs_reconfirming", "P041:14:needs_reconfirming", "P046:4:needs_reconfirming", "P046:5:needs_reconfirming", "P054:17:needs_reconfirming", "P054:16:needs_reconfirming"]}

## Metric 3 — fit-line text correct (bar == 200 of 200)

Correct pairs: **55** of 200. Correct = the rendered fit surface states exactly the ledger's sufficiency count, never overclaims a complete match, and never shows a percentage. Pairs production renders nothing for are incorrect (the fit truth is owed on every card).

| pair | class | ledger states | sufficient | production renders | expected (SPEC shape) | correct |
|---|---|---|---|---|---|---|
| P001 | short_by_quantity | short,short,sufficient,sufficient | 2/4 | 4/4 required · Complete match | 2 recorded · check pasta, garlic | NO |
| P002 | assumed_staple | sufficient,assumed_stap,assumed_stap | 1/3 | <no card rendered> | 1 recorded · check green_onion, garlic | NO |
| P003 | full_coverage | sufficient,sufficient | 2/2 | 2/2 required · Complete match | 2 of 2 | yes |
| P004 | short_by_quantity | sufficient,short,short,sufficient | 2/4 | 4/4 required · Complete match | 2 recorded · check sesame_oil, garlic | NO |
| P005 | assumed_staple | sufficient,assumed_stap,assumed_stap | 1/3 | <no card rendered> | 1 recorded · check green_onion, garlic | NO |
| P006 | assumed_staple | assumed_stap,sufficient,assumed_stap | 1/3 | 1/3 required · Missing 2 | 1 recorded · check sesame_oil, green_onion | yes |
| P007 | short_by_quantity | sufficient,short,sufficient,short | 2/4 | 4/4 required · Complete match | 2 recorded · check green_onion, garlic | NO |
| P008 | observed_unknown | quantity_unk,sufficient,sufficient,quantity_unk,sufficient | 3/5 | 5/5 required · Complete match | 3 recorded · check green_onion, lettuce | NO |
| P009 | observed_unknown | quantity_unk,sufficient,quantity_unk | 1/3 | 3/3 required · Complete match | 1 recorded · check sesame_oil, soy_sauce | NO |
| P010 | observed_unknown | quantity_unk,sufficient,quantity_unk | 1/3 | 3/3 required · Complete match | 1 recorded · check sesame_oil, cucumber | NO |
| P011 | full_coverage | sufficient,sufficient,sufficient,sufficient,sufficient,sufficient,sufficient | 7/7 | 7/7 required · Complete match | 7 of 7 | yes |
| P012 | full_coverage | sufficient,sufficient,sufficient | 3/3 | 3/3 required · Complete match | 3 of 3 | yes |
| P013 | estimated_quantity | quantity_unk,sufficient,quantity_unk | 1/3 | 3/3 required · Complete match | 1 recorded · check egg, soy_sauce | NO |
| P014 | assumed_staple | sufficient,sufficient,sufficient,sufficient,assumed_stap,sufficient,assumed_stap | 5/7 | <no card rendered> | 5 recorded · check rice, green_onion | NO |
| P015 | full_coverage_swap | covered_by_s,sufficient,sufficient,sufficient,sufficient | 5/5 | 4/5 required · Missing 1 | 5 of 5 · 1 swap | NO |
| P016 | full_coverage | sufficient,sufficient,sufficient,sufficient,sufficient | 5/5 | 5/5 required · Complete match | 5 of 5 | yes |
| P017 | estimated_quantity | sufficient,quantity_unk,quantity_unk | 1/3 | 3/3 required · Complete match | 1 recorded · check chicken_breast, sesame_oil | NO |
| P018 | observed_unknown | quantity_unk,quantity_unk,sufficient,sufficient,sufficient | 3/5 | 5/5 required · Complete match | 3 recorded · check sesame_oil, green_onion | NO |
| P019 | estimated_quantity | sufficient,sufficient,quantity_unk,sufficient,quantity_unk | 3/5 | 5/5 required · Complete match | 3 recorded · check peanut_butter, frozen_peas | NO |
| P020 | full_coverage | sufficient,sufficient,sufficient,sufficient | 4/4 | 4/4 required · Complete match | 4 of 4 | yes |
| P021 | short_by_quantity | short,sufficient,sufficient,short,sufficient | 3/5 | 5/5 required · Complete match | 3 recorded · check tortilla, cheese | NO |
| P022 | full_coverage | sufficient,sufficient,sufficient,sufficient,sufficient,sufficient,sufficient,sufficient | 8/8 | 8/8 required · Complete match | 8 of 8 | yes |
| P023 | full_coverage | sufficient,sufficient,sufficient | 3/3 | 3/3 required · Complete match | 3 of 3 | yes |
| P024 | estimated_quantity | quantity_unk,sufficient,quantity_unk,sufficient | 2/4 | 4/4 required · Complete match | 2 recorded · check chicken_breast, lime | NO |
| P025 | full_coverage | sufficient,sufficient,sufficient,sufficient,sufficient,sufficient,sufficient | 7/7 | 7/7 required · Complete match | 7 of 7 | yes |
| P026 | full_coverage_swap | sufficient,covered_by_s | 2/2 | 1/2 required · Missing 1 | 2 of 2 · 1 swap | NO |
| P027 | stale_evidence | needs_reconf,needs_reconf,sufficient | 1/3 | 3/3 required · Complete match | 1 recorded · check green_onion, garlic | NO |
| P028 | observed_unknown | sufficient,quantity_unk,quantity_unk | 1/3 | 3/3 required · Complete match | 1 recorded · check lemon, green_onion | NO |
| P029 | assumed_staple | assumed_stap,sufficient,sufficient,assumed_stap | 2/4 | <no card rendered> | 2 recorded · check sesame_oil, bread | NO |
| P030 | stale_evidence | needs_reconf,sufficient,sufficient,sufficient,sufficient,needs_reconf | 4/6 | 6/6 required · Complete match | 4 recorded · check ground_beef, tomato | NO |
| P031 | short_by_quantity | short,sufficient,short | 1/3 | 3/3 required · Complete match | 1 recorded · check spinach, green_onion | NO |
| P032 | short_by_quantity | short,short,sufficient,sufficient,sufficient,sufficient | 4/6 | 6/6 required · Complete match | 4 recorded · check green_onion, garlic | NO |
| P033 | observed_unknown | sufficient,quantity_unk,quantity_unk | 1/3 | 3/3 required · Complete match | 1 recorded · check garlic, sesame_oil | NO |
| P034 | full_coverage | sufficient,sufficient,sufficient | 3/3 | 3/3 required · Complete match | 3 of 3 | yes |
| P035 | assumed_staple | sufficient,assumed_stap,assumed_stap,sufficient | 2/4 | <no card rendered> | 2 recorded · check garlic, frozen_peas | NO |
| P036 | estimated_quantity | sufficient,sufficient,quantity_unk,quantity_unk,sufficient | 3/5 | 5/5 required · Complete match | 3 recorded · check garlic, chickpea | NO |
| P037 | full_coverage | sufficient,sufficient,sufficient,sufficient | 4/4 | 4/4 required · Complete match | 4 of 4 | yes |
| P038 | full_coverage | sufficient,sufficient,sufficient | 3/3 | 3/3 required · Complete match | 3 of 3 | yes |
| P039 | full_coverage | sufficient,sufficient,sufficient,sufficient,sufficient | 5/5 | 5/5 required · Complete match | 5 of 5 | yes |
| P040 | stale_evidence | sufficient,sufficient,needs_reconf,needs_reconf,sufficient | 3/5 | 5/5 required · Complete match | 3 recorded · check garlic, rice | NO |
| P041 | stale_evidence | sufficient,needs_reconf,needs_reconf,sufficient | 2/4 | 4/4 required · Complete match | 2 recorded · check garlic, butter | NO |
| P042 | full_coverage | sufficient,sufficient,sufficient | 3/3 | 3/3 required · Complete match | 3 of 3 | yes |
| P043 | full_coverage | sufficient,sufficient,sufficient | 3/3 | 3/3 required · Complete match | 3 of 3 | yes |
| P044 | full_coverage_swap | sufficient,sufficient,covered_by_s | 3/3 | 2/3 required · Missing 1 | 3 of 3 · 1 swap | NO |
| P045 | full_coverage_swap | sufficient,sufficient,covered_by_s,sufficient,sufficient,sufficient,sufficient | 7/7 | 6/7 required · Missing 1 | 7 of 7 · 1 swap | NO |
| P046 | stale_evidence | needs_reconf,sufficient,needs_reconf,sufficient,sufficient | 3/5 | 5/5 required · Complete match | 3 recorded · check chicken_breast, onion | NO |
| P047 | full_coverage | sufficient,sufficient,sufficient,sufficient,sufficient,sufficient | 6/6 | 6/6 required · Complete match | 6 of 6 | yes |
| P048 | observed_unknown | sufficient,quantity_unk,quantity_unk | 1/3 | 3/3 required · Complete match | 1 recorded · check egg, soy_sauce | NO |
| P049 | assumed_staple | assumed_stap,sufficient,assumed_stap,sufficient | 2/4 | 2/4 required · Missing 2 | 2 recorded · check canned_tuna, onion | yes |
| P050 | observed_unknown | quantity_unk,quantity_unk,sufficient,sufficient | 2/4 | 4/4 required · Complete match | 2 recorded · check sesame_oil, green_onion | NO |
| P051 | short_by_quantity | short,sufficient,sufficient,short,sufficient | 3/5 | 5/5 required · Complete match | 3 recorded · check sesame_oil, black_beans | NO |
| P052 | full_coverage | sufficient,sufficient,sufficient | 3/3 | 3/3 required · Complete match | 3 of 3 | yes |
| P053 | short_by_quantity | short,short,sufficient | 1/3 | 3/3 required · Complete match | 1 recorded · check sesame_oil, mushroom | NO |
| P054 | stale_evidence | sufficient,sufficient,needs_reconf,needs_reconf,sufficient | 3/5 | 5/5 required · Complete match | 3 recorded · check lemon, olive_oil | NO |
| P055 | stale_evidence | needs_reconf,sufficient,sufficient,needs_reconf | 2/4 | 4/4 required · Complete match | 2 recorded · check chicken_breast, olive_oil | NO |
| P056 | stale_evidence | sufficient,needs_reconf,needs_reconf | 1/3 | 3/3 required · Complete match | 1 recorded · check soy_sauce, sesame_oil | NO |
| P057 | estimated_quantity | quantity_unk,quantity_unk,sufficient | 1/3 | 3/3 required · Complete match | 1 recorded · check peanut_butter, garlic | NO |
| P058 | observed_unknown | quantity_unk,sufficient,quantity_unk,sufficient | 2/4 | 4/4 required · Complete match | 2 recorded · check sesame_oil, coconut_milk | NO |
| P059 | full_coverage | sufficient,sufficient,sufficient,sufficient | 4/4 | 4/4 required · Complete match | 4 of 4 | yes |
| P060 | observed_unknown | sufficient,quantity_unk,quantity_unk,sufficient | 2/4 | 4/4 required · Complete match | 2 recorded · check garlic, ginger | NO |
| P061 | short_by_quantity | sufficient,sufficient,short,sufficient,short,sufficient,sufficient | 5/7 | 7/7 required · Complete match | 5 recorded · check garlic, black_beans | NO |
| P062 | estimated_quantity | quantity_unk,quantity_unk,sufficient | 1/3 | 3/3 required · Complete match | 1 recorded · check sesame_oil, green_onion | NO |
| P063 | assumed_staple | sufficient,assumed_stap,assumed_stap | 1/3 | <no card rendered> | 1 recorded · check garlic, lemon | NO |
| P064 | observed_unknown | sufficient,quantity_unk,quantity_unk | 1/3 | 3/3 required · Complete match | 1 recorded · check frozen_peas, cucumber | NO |
| P065 | assumed_staple | sufficient,assumed_stap | 1/2 | 1/2 required · Missing 1 | 1 recorded · check green_onion | yes |
| P066 | estimated_quantity | sufficient,sufficient,quantity_unk,sufficient,quantity_unk | 3/5 | 5/5 required · Complete match | 3 recorded · check zucchini, chicken_breast | NO |
| P067 | observed_unknown | sufficient,quantity_unk,quantity_unk | 1/3 | 3/3 required · Complete match | 1 recorded · check green_onion, garlic | NO |
| P068 | full_coverage | sufficient,sufficient,sufficient,sufficient | 4/4 | 4/4 required · Complete match | 4 of 4 | yes |
| P069 | stale_evidence | needs_reconf,sufficient,sufficient,needs_reconf | 2/4 | 4/4 required · Complete match | 2 recorded · check chicken_breast, garlic | NO |
| P070 | estimated_quantity | sufficient,sufficient,quantity_unk,quantity_unk,sufficient,sufficient,sufficient | 5/7 | 7/7 required · Complete match | 5 recorded · check green_onion, bell_pepper | NO |
| P071 | full_coverage_swap | sufficient,sufficient,covered_by_s | 3/3 | 2/3 required · Missing 1 | 3 of 3 · 1 swap | NO |
| P072 | full_coverage_swap | sufficient,sufficient,sufficient,sufficient,sufficient,covered_by_s | 6/6 | 5/6 required · Missing 1 | 6 of 6 · 1 swap | NO |
| P073 | empty_pantry | missing,missing | 0/2 | <no card rendered> | 0 recorded · check sesame_oil, green_onion | NO |
| P074 | full_coverage_swap | sufficient,covered_by_s,sufficient | 3/3 | 2/3 required · Missing 1 | 3 of 3 · 1 swap | NO |
| P075 | short_by_quantity | short,sufficient | 1/2 | 2/2 required · Complete match | 1 recorded · check cucumber | NO |
| P076 | assumed_staple | assumed_stap,assumed_stap,sufficient | 1/3 | <no card rendered> | 1 recorded · check sesame_oil, lemon | NO |
| P077 | short_by_quantity | short,short,sufficient | 1/3 | 3/3 required · Complete match | 1 recorded · check sesame_oil, garlic | NO |
| P078 | short_by_quantity | sufficient,short,sufficient,sufficient,sufficient,short,sufficient | 5/7 | 7/7 required · Complete match | 5 recorded · check green_onion, spinach | NO |
| P079 | observed_unknown | quantity_unk,sufficient | 1/2 | 2/2 required · Complete match | 1 recorded · check honey | NO |
| P080 | full_coverage | sufficient,sufficient | 2/2 | 2/2 required · Complete match | 2 of 2 | yes |
| P081 | stale_evidence | needs_reconf,sufficient,needs_reconf,sufficient,sufficient | 3/5 | 5/5 required · Complete match | 3 recorded · check green_onion, sesame_oil | NO |
| P082 | estimated_quantity | quantity_unk,sufficient,quantity_unk,sufficient | 2/4 | 4/4 required · Complete match | 2 recorded · check sesame_oil, honey | NO |
| P083 | full_coverage | sufficient,sufficient,sufficient,sufficient | 4/4 | 4/4 required · Complete match | 4 of 4 | yes |
| P084 | stale_evidence | needs_reconf,sufficient,sufficient,needs_reconf | 2/4 | 4/4 required · Complete match | 2 recorded · check chicken_breast, green_onion | NO |
| P085 | full_coverage | sufficient,sufficient | 2/2 | 2/2 required · Complete match | 2 of 2 | yes |
| P086 | full_coverage | sufficient,sufficient,sufficient,sufficient,sufficient,sufficient | 6/6 | 6/6 required · Complete match | 6 of 6 | yes |
| P087 | full_coverage_swap | covered_by_s,sufficient,sufficient | 3/3 | 2/3 required · Missing 1 | 3 of 3 · 1 swap | NO |
| P088 | stale_evidence | needs_reconf,needs_reconf,sufficient,sufficient,sufficient | 3/5 | 5/5 required · Complete match | 3 recorded · check sesame_oil, green_onion | NO |
| P089 | full_coverage | sufficient,sufficient,sufficient,sufficient,sufficient | 5/5 | 5/5 required · Complete match | 5 of 5 | yes |
| P090 | full_coverage | sufficient,sufficient,sufficient,sufficient,sufficient,sufficient,sufficient,sufficient | 8/8 | 8/8 required · Complete match | 8 of 8 | yes |
| P091 | full_coverage | sufficient,sufficient,sufficient | 3/3 | 3/3 required · Complete match | 3 of 3 | yes |
| P092 | estimated_quantity | quantity_unk,sufficient,quantity_unk | 1/3 | 3/3 required · Complete match | 1 recorded · check sesame_oil, garlic | NO |
| P093 | stale_evidence | sufficient,needs_reconf,needs_reconf | 1/3 | 3/3 required · Complete match | 1 recorded · check lime, soy_sauce | NO |
| P094 | assumed_staple | assumed_stap,sufficient,sufficient,sufficient,sufficient,assumed_stap,sufficient | 5/7 | <no card rendered> | 5 recorded · check sesame_oil, avocado | NO |
| P095 | short_by_quantity | short,sufficient,short | 1/3 | 3/3 required · Complete match | 1 recorded · check tomato, garlic | NO |
| P096 | short_by_quantity | short,sufficient,sufficient,short,sufficient,sufficient | 4/6 | 6/6 required · Complete match | 4 recorded · check sesame_oil, black_beans | NO |
| P097 | full_coverage | sufficient,sufficient,sufficient,sufficient | 4/4 | 4/4 required · Complete match | 4 of 4 | yes |
| P098 | short_by_quantity | sufficient,short,sufficient,short | 2/4 | 4/4 required · Complete match | 2 recorded · check soy_sauce, green_onion | NO |
| P099 | full_coverage | sufficient,sufficient,sufficient,sufficient,sufficient,sufficient | 6/6 | 6/6 required · Complete match | 6 of 6 | yes |
| P100 | observed_unknown | quantity_unk,sufficient,sufficient,sufficient,sufficient,sufficient,sufficient,sufficient,quantity_unk | 7/9 | 9/9 required · Complete match | 7 recorded · check rice, lime | NO |
| P101 | full_coverage_swap | covered_by_s,sufficient,sufficient,sufficient,sufficient,sufficient,sufficient | 7/7 | 6/7 required · Missing 1 | 7 of 7 · 1 swap | NO |
| P102 | observed_unknown | quantity_unk,sufficient | 1/2 | 2/2 required · Complete match | 1 recorded · check sesame_oil | NO |
| P103 | observed_unknown | quantity_unk,sufficient | 1/2 | 2/2 required · Complete match | 1 recorded · check honey | NO |
| P104 | empty_pantry | missing,missing,missing,missing,missing | 0/5 | <no card rendered> | 0 recorded · check sesame_oil, green_onion, garlic, cumin, spinach | NO |
| P105 | estimated_quantity | sufficient,sufficient,quantity_unk,quantity_unk,sufficient | 3/5 | 5/5 required · Complete match | 3 recorded · check green_onion, cumin | NO |
| P106 | assumed_staple | sufficient,sufficient,sufficient,assumed_stap,sufficient,assumed_stap | 4/6 | <no card rendered> | 4 recorded · check soy_sauce, sesame_oil | NO |
| P107 | full_coverage | sufficient,sufficient,sufficient,sufficient,sufficient,sufficient | 6/6 | 6/6 required · Complete match | 6 of 6 | yes |
| P108 | assumed_staple | sufficient,assumed_stap,assumed_stap,sufficient,sufficient | 3/5 | <no card rendered> | 3 recorded · check bell_pepper, onion | NO |
| P109 | full_coverage | sufficient,sufficient,sufficient,sufficient,sufficient,sufficient | 6/6 | 6/6 required · Complete match | 6 of 6 | yes |
| P110 | empty_pantry | missing,missing,missing,missing | 0/4 | <no card rendered> | 0 recorded · check sesame_oil, green_onion, honey, spinach | NO |
| P111 | short_by_quantity | sufficient,short,short | 1/3 | 3/3 required · Complete match | 1 recorded · check sesame_oil, tortilla | NO |
| P112 | short_by_quantity | sufficient,sufficient,short,short | 2/4 | 4/4 required · Complete match | 2 recorded · check sesame_oil, green_onion | NO |
| P113 | stale_evidence | needs_reconf,sufficient,needs_reconf,sufficient,sufficient,sufficient,sufficient | 5/7 | 7/7 required · Complete match | 5 recorded · check sesame_oil, ginger | NO |
| P114 | estimated_quantity | quantity_unk,sufficient,sufficient,quantity_unk | 2/4 | 4/4 required · Complete match | 2 recorded · check green_onion, cumin | NO |
| P115 | stale_evidence | sufficient,needs_reconf,sufficient,sufficient,needs_reconf,sufficient,sufficient,sufficient | 6/8 | 8/8 required · Complete match | 6 recorded · check green_onion, black_beans | NO |
| P116 | short_by_quantity | sufficient,sufficient,short,sufficient,short | 3/5 | 5/5 required · Complete match | 3 recorded · check avocado, cumin | NO |
| P117 | full_coverage | sufficient,sufficient,sufficient,sufficient,sufficient | 5/5 | 5/5 required · Complete match | 5 of 5 | yes |
| P118 | short_by_quantity | short,sufficient,short,sufficient | 2/4 | 4/4 required · Complete match | 2 recorded · check sesame_oil, garlic | NO |
| P119 | observed_unknown | sufficient,quantity_unk,quantity_unk,sufficient | 2/4 | 4/4 required · Complete match | 2 recorded · check sesame_oil, coconut_milk | NO |
| P120 | short_by_quantity | sufficient,short,sufficient,sufficient,sufficient,sufficient,short | 5/7 | 7/7 required · Complete match | 5 recorded · check green_onion, tortilla | NO |
| P121 | full_coverage | sufficient,sufficient,sufficient | 3/3 | 3/3 required · Complete match | 3 of 3 | yes |
| P122 | empty_pantry | missing,missing,missing,missing,missing | 0/5 | <no card rendered> | 0 recorded · check black_beans, egg, lettuce, garlic, canned_tuna | NO |
| P123 | assumed_staple | sufficient,sufficient,sufficient,assumed_stap,assumed_stap | 3/5 | 3/5 required · Missing 2 | 3 recorded · check garlic, carrot | yes |
| P124 | full_coverage | sufficient,sufficient,sufficient | 3/3 | 3/3 required · Complete match | 3 of 3 | yes |
| P125 | short_by_quantity | sufficient,sufficient,sufficient,short,sufficient,sufficient,short | 5/7 | 7/7 required · Complete match | 5 recorded · check cumin, lime | NO |
| P126 | assumed_staple | assumed_stap,assumed_stap,sufficient | 1/3 | <no card rendered> | 1 recorded · check black_beans, sesame_oil | NO |
| P127 | estimated_quantity | quantity_unk,sufficient,sufficient,quantity_unk,sufficient | 3/5 | 5/5 required · Complete match | 3 recorded · check green_onion, lettuce | NO |
| P128 | observed_unknown | quantity_unk,sufficient,quantity_unk | 1/3 | 3/3 required · Complete match | 1 recorded · check black_beans, green_onion | NO |
| P129 | observed_unknown | sufficient,quantity_unk | 1/2 | 2/2 required · Complete match | 1 recorded · check garlic | NO |
| P130 | estimated_quantity | quantity_unk,quantity_unk,sufficient | 1/3 | 3/3 required · Complete match | 1 recorded · check spinach, avocado | NO |
| P131 | short_by_quantity | short,short,sufficient | 1/3 | 3/3 required · Complete match | 1 recorded · check sesame_oil, green_onion | NO |
| P132 | assumed_staple | assumed_stap,assumed_stap,sufficient,sufficient | 2/4 | <no card rendered> | 2 recorded · check sesame_oil, green_onion | NO |
| P133 | short_by_quantity | sufficient,short | 1/2 | 2/2 required · Complete match | 1 recorded · check garlic | NO |
| P134 | short_by_quantity | short,sufficient,sufficient,sufficient,short,sufficient | 4/6 | 6/6 required · Complete match | 4 recorded · check sesame_oil, ginger | NO |
| P135 | short_by_quantity | short,short,sufficient | 1/3 | 3/3 required · Complete match | 1 recorded · check green_onion, lemon | NO |
| P136 | stale_evidence | needs_reconf,sufficient,sufficient,needs_reconf | 2/4 | 4/4 required · Complete match | 2 recorded · check pasta, lemon | NO |
| P137 | short_by_quantity | sufficient,sufficient,short,sufficient,short | 3/5 | 5/5 required · Complete match | 3 recorded · check lettuce, canned_tuna | NO |
| P138 | full_coverage | sufficient,sufficient | 2/2 | 2/2 required · Complete match | 2 of 2 | yes |
| P139 | short_by_quantity | sufficient,sufficient,sufficient,sufficient,short,short | 4/6 | 6/6 required · Complete match | 4 recorded · check spinach, yogurt | NO |
| P140 | full_coverage_swap | covered_by_s,sufficient,sufficient | 3/3 | 2/3 required · Missing 1 | 3 of 3 · 1 swap | NO |
| P141 | observed_unknown | sufficient,quantity_unk,quantity_unk,sufficient,sufficient,sufficient,sufficient | 5/7 | 7/7 required · Complete match | 5 recorded · check sesame_oil, garlic | NO |
| P142 | full_coverage | sufficient,sufficient,sufficient | 3/3 | 3/3 required · Complete match | 3 of 3 | yes |
| P143 | assumed_staple | sufficient,assumed_stap,assumed_stap | 1/3 | 1/3 required · Missing 2 | 1 recorded · check cheese, butter | yes |
| P144 | estimated_quantity | sufficient,quantity_unk,sufficient,sufficient,sufficient,quantity_unk | 4/6 | 6/6 required · Complete match | 4 recorded · check green_onion, yogurt | NO |
| P145 | full_coverage | sufficient,sufficient,sufficient,sufficient,sufficient,sufficient | 6/6 | 6/6 required · Complete match | 6 of 6 | yes |
| P146 | full_coverage | sufficient,sufficient,sufficient,sufficient,sufficient,sufficient,sufficient | 7/7 | 7/7 required · Complete match | 7 of 7 | yes |
| P147 | estimated_quantity | sufficient,quantity_unk | 1/2 | 2/2 required · Complete match | 1 recorded · check garlic | NO |
| P148 | stale_evidence | sufficient,needs_reconf,needs_reconf | 1/3 | 3/3 required · Complete match | 1 recorded · check garlic, green_onion | NO |
| P149 | observed_unknown | quantity_unk,sufficient | 1/2 | 2/2 required · Complete match | 1 recorded · check honey | NO |
| P150 | short_by_quantity | sufficient,short,short,sufficient,sufficient,sufficient | 4/6 | 6/6 required · Complete match | 4 recorded · check ground_beef, mushroom | NO |
| P151 | short_by_quantity | sufficient,short,short,sufficient | 2/4 | 4/4 required · Complete match | 2 recorded · check celery, onion | NO |
| P152 | short_by_quantity | short,short,sufficient,sufficient | 2/4 | 4/4 required · Complete match | 2 recorded · check green_onion, garlic | NO |
| P153 | estimated_quantity | sufficient,quantity_unk,sufficient,quantity_unk,sufficient,sufficient | 4/6 | 6/6 required · Complete match | 4 recorded · check mushroom, garlic | NO |
| P154 | short_by_quantity | sufficient,sufficient,short,sufficient,sufficient,short | 4/6 | 6/6 required · Complete match | 4 recorded · check cumin, soy_sauce | NO |
| P155 | observed_unknown | quantity_unk,sufficient,sufficient,sufficient,quantity_unk | 3/5 | 5/5 required · Complete match | 3 recorded · check green_onion, frozen_peas | NO |
| P156 | full_coverage | sufficient,sufficient,sufficient | 3/3 | 3/3 required · Complete match | 3 of 3 | yes |
| P157 | observed_unknown | quantity_unk,sufficient,sufficient,sufficient,sufficient,quantity_unk | 4/6 | 6/6 required · Complete match | 4 recorded · check sesame_oil, soy_sauce | NO |
| P158 | full_coverage | sufficient,sufficient,sufficient | 3/3 | 3/3 required · Complete match | 3 of 3 | yes |
| P159 | full_coverage | sufficient,sufficient,sufficient,sufficient | 4/4 | 4/4 required · Complete match | 4 of 4 | yes |
| P160 | observed_unknown | sufficient,quantity_unk,sufficient,quantity_unk | 2/4 | 4/4 required · Complete match | 2 recorded · check green_onion, yogurt | NO |
| P161 | assumed_staple | sufficient,sufficient,sufficient,sufficient,assumed_stap,assumed_stap | 4/6 | <no card rendered> | 4 recorded · check black_beans, lemon | NO |
| P162 | full_coverage_swap | covered_by_s,sufficient,sufficient | 3/3 | 2/3 required · Missing 1 | 3 of 3 · 1 swap | NO |
| P163 | short_by_quantity | sufficient,short,sufficient,sufficient,sufficient,sufficient,sufficient,short | 6/8 | 8/8 required · Complete match | 6 recorded · check green_onion, cucumber | NO |
| P164 | full_coverage_swap | sufficient,covered_by_s,sufficient | 3/3 | 2/3 required · Missing 1 | 3 of 3 · 1 swap | NO |
| P165 | short_by_quantity | sufficient,sufficient,short,sufficient,short,sufficient | 4/6 | 6/6 required · Complete match | 4 recorded · check cumin, bell_pepper | NO |
| P166 | observed_unknown | quantity_unk,sufficient,quantity_unk | 1/3 | 3/3 required · Complete match | 1 recorded · check green_onion, cucumber | NO |
| P167 | short_by_quantity | short,sufficient,sufficient,short,sufficient | 3/5 | 5/5 required · Complete match | 3 recorded · check lime, sesame_oil | NO |
| P168 | full_coverage | sufficient,sufficient,sufficient,sufficient,sufficient,sufficient,sufficient | 7/7 | 7/7 required · Complete match | 7 of 7 | yes |
| P169 | full_coverage | sufficient,sufficient,sufficient,sufficient,sufficient,sufficient | 6/6 | 6/6 required · Complete match | 6 of 6 | yes |
| P170 | short_by_quantity | sufficient,short,short | 1/3 | 3/3 required · Complete match | 1 recorded · check sesame_oil, tortilla | NO |
| P171 | stale_evidence | sufficient,needs_reconf | 1/2 | 2/2 required · Complete match | 1 recorded · check garlic | NO |
| P172 | observed_unknown | sufficient,sufficient,quantity_unk,quantity_unk,sufficient,sufficient | 4/6 | 6/6 required · Complete match | 4 recorded · check chicken_breast, black_beans | NO |
| P173 | short_by_quantity | sufficient,sufficient,short,sufficient,short | 3/5 | 5/5 required · Complete match | 3 recorded · check tomato, olive_oil | NO |
| P174 | full_coverage | sufficient,sufficient,sufficient | 3/3 | 3/3 required · Complete match | 3 of 3 | yes |
| P175 | full_coverage | sufficient,sufficient,sufficient | 3/3 | 3/3 required · Complete match | 3 of 3 | yes |
| P176 | full_coverage_swap | sufficient,covered_by_s | 2/2 | 1/2 required · Missing 1 | 2 of 2 · 1 swap | NO |
| P177 | full_coverage_swap | sufficient,covered_by_s,sufficient,sufficient | 4/4 | 3/4 required · Missing 1 | 4 of 4 · 1 swap | NO |
| P178 | full_coverage | sufficient,sufficient,sufficient,sufficient | 4/4 | 4/4 required · Complete match | 4 of 4 | yes |
| P179 | full_coverage | sufficient,sufficient,sufficient,sufficient | 4/4 | 4/4 required · Complete match | 4 of 4 | yes |
| P180 | observed_unknown | quantity_unk,sufficient,quantity_unk | 1/3 | 3/3 required · Complete match | 1 recorded · check sesame_oil, pasta | NO |
| P181 | full_coverage | sufficient,sufficient,sufficient,sufficient | 4/4 | 4/4 required · Complete match | 4 of 4 | yes |
| P182 | estimated_quantity | sufficient,quantity_unk,quantity_unk,sufficient | 2/4 | 4/4 required · Complete match | 2 recorded · check ginger, lettuce | NO |
| P183 | estimated_quantity | quantity_unk,sufficient,sufficient,sufficient,quantity_unk | 3/5 | 5/5 required · Complete match | 3 recorded · check sesame_oil, chickpea | NO |
| P184 | stale_evidence | needs_reconf,needs_reconf,sufficient,sufficient | 2/4 | 4/4 required · Complete match | 2 recorded · check green_onion, garlic | NO |
| P185 | full_coverage_swap | sufficient,sufficient,covered_by_s,sufficient | 4/4 | 3/4 required · Missing 1 | 4 of 4 · 1 swap | NO |
| P186 | empty_pantry | missing,missing,missing | 0/3 | <no card rendered> | 0 recorded · check banana, oats, egg | NO |
| P187 | stale_evidence | sufficient,sufficient,needs_reconf,sufficient,needs_reconf | 3/5 | 5/5 required · Complete match | 3 recorded · check garlic, lime | NO |
| P188 | assumed_staple | sufficient,assumed_stap,assumed_stap,sufficient,sufficient,sufficient | 4/6 | <no card rendered> | 4 recorded · check cumin, green_onion | NO |
| P189 | full_coverage | sufficient,sufficient,sufficient | 3/3 | 3/3 required · Complete match | 3 of 3 | yes |
| P190 | assumed_staple | assumed_stap,sufficient,assumed_stap,sufficient | 2/4 | <no card rendered> | 2 recorded · check sesame_oil, frozen_peas | NO |
| P191 | full_coverage | sufficient,sufficient,sufficient,sufficient,sufficient | 5/5 | 5/5 required · Complete match | 5 of 5 | yes |
| P192 | observed_unknown | quantity_unk,sufficient | 1/2 | 2/2 required · Complete match | 1 recorded · check cucumber | NO |
| P193 | short_by_quantity | short,sufficient,short,sufficient | 2/4 | 4/4 required · Complete match | 2 recorded · check sesame_oil, honey | NO |
| P194 | full_coverage | sufficient,sufficient,sufficient,sufficient,sufficient | 5/5 | 5/5 required · Complete match | 5 of 5 | yes |
| P195 | full_coverage | sufficient,sufficient,sufficient,sufficient | 4/4 | 4/4 required · Complete match | 4 of 4 | yes |
| P196 | short_by_quantity | short,sufficient | 1/2 | 2/2 required · Complete match | 1 recorded · check garlic | NO |
| P197 | short_by_quantity | sufficient,short,sufficient,short | 2/4 | 4/4 required · Complete match | 2 recorded · check tortilla, lime | NO |
| P198 | observed_unknown | sufficient,quantity_unk,quantity_unk,sufficient,sufficient | 3/5 | 5/5 required · Complete match | 3 recorded · check black_beans, garlic | NO |
| P199 | short_by_quantity | sufficient,short,short | 1/3 | 3/3 required · Complete match | 1 recorded · check egg, soy_sauce | NO |
| P200 | observed_unknown | sufficient,quantity_unk,quantity_unk,sufficient,sufficient | 3/5 | 5/5 required · Complete match | 3 recorded · check bell_pepper, sesame_oil | NO |

Pair verdict rules: (1) claimed count == ledger sufficient count (swap-covered lines count — SPEC: "across lines, swaps, or several dinners"); (2) no complete-match claim while any line lacks quantity evidence; (3) no percentage. All three must hold.

Full per-pair records: `pairs_200.json`; machine results: `results.json`.
