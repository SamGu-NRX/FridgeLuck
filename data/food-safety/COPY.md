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

## Where enforcement lives

- `packages/FLFoodSafety` — `StepLinter` (recipe steps), `DonenessLookup` (class and check for an ingredient or step), `Rulebook` (schema and citation validation).
- `data/food-safety/rules.json` — the reviewed rulebook; every rule cites a primary source with URL, verbatim quote and retrieval date.
- Suite C's corpus linter (`evaluation/suites/recipes/rs.py`) uses the same colour/time phrase list and FSIS class minimums; corpus steps may only satisfy it with `{"safety": {"class": …, "temp_f": ≥ class minimum, "method": "thermometer", "source": …}}`.

Regenerate the audit after changing any rule: see `data/food-safety/BUNDLED-RECIPE-AUDIT.md` and `packages/FLFoodSafety/README.md`.
