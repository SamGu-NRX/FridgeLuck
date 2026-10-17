# Copy guide — food-safety phrasing for LeChef and the UI

Every rule in this guide is enforced or sourced by `data/food-safety/rules.json` (cited to USDA FSIS, FDA, FoodSafety.gov or CDC) and, for recipe text, enforced by the `StepLinter` in `packages/FLFoodSafety`. When this guide and the linter disagree, fix one of them in the same commit — the never-say list below mirrors the linter's patterns one for one, and suite C's corpus linter (`rs.py`) uses the same phrases.

## The one rule

Doneness is a food thermometer at a safe minimum internal temperature. Colour, time, juices, firmness and browning never establish safety or doneness (FSIS, "Doneness Versus Safety": "Appearance and color are not reliable indicators of safety or doneness").

## What to say

Cooking and reheating copy names the thermometer test, the placement and the temperature, then hands the timer its real job: telling the cook when to check.

| Class | Minimum | Copy template |
| --- | --- | --- |
| Poultry (all cuts, ground poultry, stuffing) | 165 °F / 74 °C | "Cook until a food thermometer in the innermost part of the thigh and wing and the thickest part of the breast reads 74 °C (165 °F) — the timer only tells you when to check." |
| Ground meat (beef, pork, lamb, veal) | 160 °F / 71 °C | "…a food thermometer in the centre of the patty or the thickest part of the ground-meat portion reads 71 °C (160 °F)…" |
| Ground poultry | 165 °F / 74 °C | "…reads 74 °C (165 °F). Ground poultry keeps the poultry minimum." |
| Whole cuts, pork, ham (uncooked) | 145 °F / 63 °C + 3 min rest | "…reads 63 °C (145 °F), then rest 3 minutes…" |
| Fish | 145 °F / 63 °C | "…in the thickest part of the fillet or the centre of the portion…" |
| Shellfish | 145 °F / 63 °C | "…in the centre of the thickest piece…" |
| Egg dishes | 160 °F / 71 °C | "…in the centre of the egg dish or the yolk…" |
| Leftovers and casseroles | 165 °F / 74 °C | "Reheat until a food thermometer in several places (microwave: cover, rotate and check more than one spot) reads 74 °C (165 °F)…" |
| Fully cooked ham (reheat only) | 140 °F / 60 °C | "…reads 60 °C (140 °F) before serving." |

Handling copy has its own templates:

- **Thawing** — "Thaw in the refrigerator, in cold water (leak-proof bag, water changed every 30 minutes), or in the microwave — and cook immediately after cold-water or microwave thawing." Never suggest the counter, hot water, the sun, or "outside" (FSIS, "The Big Thaw").
- **Leftovers out of the fridge** — "Refrigerate or freeze within 2 hours — within 1 hour above 32 °C (90 °F)." Leftovers keep 3–4 days in the fridge; that window is below.
- **Raw or lightly cooked eggs** — name the dish's risk and the fix: "Use pasteurized eggs for this raw-egg dish, or cook the egg component to 71 °C (160 °F)." Any copy mentioning caesar, tiramisu, mayonnaise, eggnog, hollandaise, ice cream, mousse or cookie dough with raw egg carries this warning.
- **Washing** — never tell anyone to wash raw chicken; say "pat dry with paper towel" if drying matters (CDC, "Chicken and Food Poisoning"). Hand-washing copy says "20 seconds, soap and water".
- **High-risk groups** — when copy addresses pregnant, immunocompromised, young or older cooks, point to the risk plainly: "If you are pregnant or cooking for someone at higher risk, cook eggs until both yolk and white are firm."

## What never to say

Each entry names the `StepLinter` flag that fires on it. These phrases are forbidden in recipe steps, LeChef messages and UI strings about protein, egg or leftover steps:

| Never say | Why | Flag |
| --- | --- | --- |
| "until golden", "golden brown" (as doneness — both match the linter's "golden" pattern) | colour is not doneness | `appearanceDoneness` |
| "until no longer pink", "no pink", "not pink" | colour is not doneness | `appearanceDoneness` |
| "until the juices run clear", "clear juices" | FSIS rejects juice colour separately | `appearanceDoneness` |
| "until cooked through", "browned through" | appearance phrasing | `appearanceDoneness` |
| "until no longer translucent", "until opaque" | appearance phrasing | `appearanceDoneness` |
| "until firm to the touch" | appearance phrasing | `appearanceDoneness` |
| "Roast the chicken for 45 minutes." (any protein or leftover step with a duration and no thermometer mention) | time alone never establishes doneness | `timeOnlyCooking` |
| "Thaw on the counter", "at room temperature", "in hot water" | unsafe thawing method | `ambientThawing` |
| "Leave the leftovers out", "cool to room temperature overnight", "on the counter" (leftovers) | exceeds the 2-hour window | `leftoversHeldOut` |
| "Reheat for 2 minutes", "warm through", "microwave 1 min" (no thermometer) | leftovers must reach 74 °C (165 °F) | `reheatingWithoutThermometer` |

A step that already carries a thermometer mention, an internal temperature ("74 °C", "165 degrees F") or "reaches temperature" is a true negative — the linter lets it pass. So are handling durations ("rest 5 minutes", "marinate overnight", "chill 1 hour"): they are not cooking times.

## What a camera look may claim

LeChef's camera look describes what a picture can actually show. It may report:

- **Browning** — "the surface is golden" (an observation, not a verdict).
- **Size and shape** — "the patties have shrunk to the pan's width".
- **Consistency** — "the sauce coats the spoon".

It may never:

- state or imply doneness ("this looks done", "ready to eat", "cooked through");
- give a safety verdict ("safe", "no bacteria risk", "fine to leave out");
- endorse a colour cue as a temperature substitute — a camera look never replaces a thermometer reading, and its wording never points at one as if it did.

When the cook asks "is it done?", the camera look hands back the thermometer test: "I can see browning, but doneness needs a thermometer — check the thickest part reads 74 °C (165 °F)."

## Time changes when quantities change

Rescaling changes stated times only when a reviewed rule supports the change. The reviewed factors: **thickness of the piece, pan size and crowding, and the quantity in the pan**. Everything else keeps the original time and says to check:

- Supported: "This makes four servings instead of two — the thicker stack needs about 5 more minutes; check with a thermometer."
- Not supported: "Double the recipe, double the time." Roasts do not scale linearly with weight, and copy never implies they do.
- When no reviewed rule covers the change, the copy says: "The timer may not fit the new quantity — check rather than trust the timer, and confirm with a thermometer."

## Shelf-life copy

Shelf-life numbers come from the USDA FoodKeeper data and FridgeLuck's own guidance (`SHELF-LIFE.md`); the UI presents them as **quality guidance, never a safety certificate**. Required phrasing for every shelf-life display:

- Lead with the quality framing: "Best within ~3–4 days for peak quality."
- Carry the standing disclaimer: "Storage times are quality guidance, not a safety guarantee. When in doubt, throw it out."
- Never write "safe until", "still good on", or "expires" for a FoodKeeper-derived date. The app does not certify that food is safe.
- A food-safety rule may shorten a quality window (the 3–4-day leftovers rule wins over a FoodKeeper quality row), never lengthen it.

## Spoilage and use-it-up policy

This section is the binding spec for use-it-up tips, salvage advice and any
copy that judges food past its prime. The `CopyLint`
(`packages/FLFoodSafety/Sources/FLFoodSafety/CopyLint/`) enforces it, with its
pattern data in `data/food-safety/copy-lint-patterns.json`. When this section
and the linter disagree, fix one of them in the same commit.

### What advice may say

- **Use food before its quality window passes.** Quality-window language comes
  from `SHELF-LIFE.md` and FoodKeeper: "Best within ~3–4 days — use spinach
  within 3 days of purchase."
- **Frame a passed window as a quality loss, not a verdict.** FSIS
  ("Refrigeration and Food Safety"): "Food that has been stored too long in the
  refrigerator or freezer may be of lessened quality, but most likely would not
  make anyone sick." Copy that uses this line carries the Listeria caveat:
  some bacteria "thrive at cold temperatures" and multiply in the fridge over
  time. A food-safety rule that shortens the window always wins.
- **Tell the reader to discard spoiled food.** FDA ("Are You Storing Food
  Safely?"): "Be alert for spoiled food. Anything that looks or smells
  suspicious should be thrown out."
- **Trim under a cited carve-out.** FDA ("Selecting and Serving Produce
  Safely"): "Cut away any damaged or bruised areas on fresh fruits and
  vegetables before preparing and/or eating." FSIS ("Molds on Food: Are They
  Dangerous?") allows trimming mold on FIRM, low-moisture produce; SOFT,
  high-moisture produce is discarded ("can be contaminated below the
  surface").
- **Carry the standing disclaimer.** "When in doubt, throw it out." (FDA:
  "If you're not sure or if the food looks questionable, throw it out.")

### What never to say

Five banned patterns. Each names the `CopyLint` pattern id and the exact
replacement copy; the linter pairs the rewrite with the policy citation
automatically.

| Pattern id | Never say | Why | Replace with |
| --- | --- | --- | --- |
| `salvage-spoiled` | "It's still fine even though it's slimy", "just cook it, it's probably fine", any advice to use food that has spoiled | Food that has spoiled is not rescued by cooking or hiding it in another dish. FDA: food "can make you very sick even when it doesn't look, smell, or taste spoiled." | "Do not use food that has spoiled — gone slimy, moldy, decayed or off-smelling. Discard it, and plan to buy less next time. When in doubt, throw it out." |
| `leafy-greens-too-far-gone` | Use-it-up copy that uses spinach or other leafy greens that are slimy, mushy or "too far gone" | Spoilage on leafy greens cannot be washed, trimmed or cooked away; the spinach rule (3–7 days, `SHELF-LIFE.md`) is a quality window, not a spoilage override. | "Leafy greens that are slimy, mushy or too far gone go in the bin — spoilage cannot be washed, trimmed or cooked away. Use greens within their quality window (spinach keeps 3–7 days refrigerated) and freeze what you cannot use in time. When in doubt, throw it out." |
| `cook-decayed-or-sprouted` | "Roast the sprouted potatoes after removing the sprouts", cooking decaying or rotten produce | Cooking does not make spoiled produce safe; FDA says to discard produce that looks rotten. | "Discard produce that is rotten, decaying or has sprouted — cooking does not make spoiled produce safe. Use produce before its quality window instead. When in doubt, throw it out." |
| `fish-curing-rescue` | "Rescue" raw fish by curing, marinating, or "the lime juice cooks the fish" | FDA names one mitigation for raw-fish parasites — prior freezing — and cooking as the safest route; acid and salt are not on that list. | "Raw fish is not made safe by curing, marinating or citrus juice. Use fish that was previously frozen — freezing kills parasites — or cook it to 63 °C (145 °F) on a food thermometer." |
| `smell-safety-test` | "If it smells fine, it's safe", "it doesn't smell bad, so it's still good", any smell-as-safety-test | Smells fine is not safe: pathogens "do not generally affect the taste, smell, or appearance of a food", so "one cannot tell that a pathogen is present" (FSIS). | "Smell is not a safety test: bacteria that cause food poisoning do not change how food smells or looks. Judge by time and temperature instead — the 2-hour rule and the storage window — and discard what has passed them. When in doubt, throw it out." |

True negatives (the linter passes them clean): "Use spinach within 3 days of
purchase." · "Discard the greens if they are slimy or off-smelling." · "When in
doubt, throw it out." · "Best within 2 days for peak quality." · "Sprouted
grain bread is made from sprouted wheat." (an ingredient name, not salvage
advice) · "Marinate the salmon overnight in the refrigerator." · "Freezing
kills parasites that may be present in fish."

### The sprouted-produce exception that is not there

The canon looked for a federal primary-source line (FDA, USDA FSIS,
FoodSafety.gov) permitting one named sprouted food under stated conditions —
the usual candidate is a firm sprouted potato with the sprouts removed. No such
line was fetchable on 2026-10-11: the FDA Bad Bug Book (second edition) carries
no solanine or chaconine chapter, and no FSIS or FoodSafety.gov page granting
the exception could be fetched. Land-grant extension services do publish that
guidance, but the canon cites federal primary sources, so the policy ships with
**no sprouted exception**: `CopyLint` flags every salvage of sprouted produce.
The "sprouted grain bread" true negative above is a precision guard for
ingredient names of intentionally sprouted foods, not a salvage exception. If
Sam wants the exception, the work is: fetch a federal page granting it, add the
verbatim quote to `copy-lint-patterns.json`, and narrow the pattern then.

## Where enforcement lives

- `packages/FLFoodSafety` — `StepLinter` (recipe steps), `CopyLint` (spoilage and use-it-up phrasing in recipe steps, use-it-up tips, LeChef lines and UI copy; pattern data in `data/food-safety/copy-lint-patterns.json`), `DonenessLookup` (class and check for an ingredient or step), `Rulebook` (schema and citation validation).
- `data/food-safety/rules.json` — the reviewed rulebook; every rule cites a primary source with URL, verbatim quote and retrieval date.
- Suite C's corpus linter (`evaluation/suites/recipes/rs.py`) uses the same colour/time phrase list and FSIS class minimums; corpus steps may only satisfy it with `{"safety": {"class": …, "temp_f": ≥ class minimum, "method": "thermometer", "source": …}}`.

Regenerate the audit after changing any rule: see `data/food-safety/BUNDLED-RECIPE-AUDIT.md` and `packages/FLFoodSafety/README.md`.

## Provenance of the spoilage-policy quotes

All quotes above were verified on **2026-10-11** against the live pages by
fetching each URL and reading the rendered text. `fsis.usda.gov` sits behind an
Akamai bot filter (direct curl returns 403); those two pages were fetched
through the r.jina.ai text proxy of the same live URL, which returns the page
content verbatim. The proxy renders italics as `_underscores_` and tables as
pipe rows; those markup characters are stripped in the quoted text and no words
change. Every quote is taken verbatim from the fetched text; the copy-lint
pattern file carries the same quotes in machine-readable form.

| Source | URL | Route | Quotes used |
| --- | --- | --- | --- |
| USDA FSIS, "Refrigeration and Food Safety" | <https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/refrigeration> | r.jina.ai (direct: 403) | "Pathogenic bacteria can grow rapidly in the \"Danger Zone,\" the temperature range between 40 and 140 °F, but they do not generally affect the taste, smell, or appearance of a food. In other words, one cannot tell that a pathogen is present." · "Food that has been left too long on the counter may be dangerous to eat, but could look fine." · "Food that has been stored too long in the refrigerator or freezer may be of lessened quality, but most likely would not make anyone sick." |
| FDA, "Are You Storing Food Safely?" | <https://www.fda.gov/consumers/consumer-updates/are-you-storing-food-safely> | direct fetch (200) | "Be aware that food can make you very sick even when it doesn't look, smell, or taste spoiled. That's because foodborne illnesses are caused by pathogenic bacteria, which are different from the spoilage bacteria that make foods \"go bad.\"" · "Be alert for spoiled food. Anything that looks or smells suspicious should be thrown out." · "The safest practice is to discard food that is moldy." · "If you're not sure or if the food looks questionable, throw it out." |
| FDA, "Fresh and Frozen Seafood: Selecting and Serving It Safely" | <https://www.fda.gov/food/buy-store-serve-safe-food/fresh-and-frozen-seafood-selecting-and-serving-it-safely> | direct fetch (200) | "It's always best to cook seafood thoroughly to minimize the risk of foodborne illness. However, if you choose to eat raw fish anyway, one rule of thumb is to eat fish that has been previously frozen. Some species of fish can contain parasites, and freezing will kill any parasites that may be present. However, be aware that freezing doesn't kill all harmful germs. That's why the safest route is to cook your seafood." |
| USDA FSIS, "Molds on Food: Are They Dangerous?" | <https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/molds-food-are-they-dangerous> | r.jina.ai (direct: 403) | "Small mold spots can be cut off FIRM fruits and vegetables with low moisture content. It's difficult for mold to penetrate dense foods." · "SOFT fruits and vegetables with high moisture content can be contaminated below the surface." |
| FDA, "Selecting and Serving Produce Safely" | <https://www.fda.gov/food/buy-store-serve-safe-food/selecting-and-serving-produce-safely> | direct fetch (200) | "Cut away any damaged or bruised areas on fresh fruits and vegetables before preparing and/or eating. Throw away any produce that looks rotten." |

Searched and rejected for the sprouted exception: the FDA Bad Bug Book, second
edition (<https://www.fda.gov/files/food/published/Bad-Bug-Book-2nd-Edition-(PDF).pdf>,
direct fetch, 2026-10-11) contains no solanine, chaconine or glycoalkaloid
chapter, and no FSIS or FoodSafety.gov page permitting a named sprouted food
could be fetched. University-extension guidance exists (for example Michigan
State University Extension on potato sprouts) but is not a federal primary
source, so the canon ships without the sprouted exception.
