# Proposed accessibility identifiers — Tonight and Kitchen screens

**Status: PROPOSAL, not an agreement.** The evaluation `CONTRACTS.md` is
absent on alpha, so nothing here has been agreed with the evaluation
side. These are the `fl.`-prefixed identifiers the FLScreens views set
today, offered for confirmation. Nothing should key on them (tests,
automation, XCUITest) until evaluation confirms this file. If evaluation
proposes different names, the views change — the identifiers are
one-line edits by design.

Conventions proposed:

- Prefix `fl.`, then screen (`tonight`, `kitchen`), then element in lower
  camel case.
- Per-item or per-option identifiers append the item's or option's
  stable id (`fl.kitchen.item.milk`), so automation targets a row, not a
  position. Item ids in examples are illustrative — the real ids come
  from the host's pantry records.
- Identifiers name the ELEMENT, never its state or its current label:
  tests assert state by reading traits and values, so a redesign that
  rewords "Cook this" does not silently break automation.

## Tonight (`FLTonight`)

| Identifier | Element | Notes |
|---|---|---|
| `fl.tonight.title` | Screen title ("Tonight") | |
| `fl.tonight.date` | Date line under the title | |
| `fl.tonight.statusLine` | Loading / unknown-kitchen status line | Also covers "Couldn't check the kitchen" reasons |
| `fl.tonight.unknownHeadline` | Unknown-kitchen headline | |
| `fl.tonight.unknownExample` | Unknown-kitchen example line | |
| `fl.tonight.scanKitchen` | "Scan my kitchen" action (unknown state) | |
| `fl.tonight.enterManually` | "Enter it manually" action (unknown state) | |
| `fl.tonight.card` | The hero pick card container | Exactly one when content is a pick |
| `fl.tonight.photo` | The pick's photo area | 3:2, capped at 40% of screen height (`PhotoLayoutRule`) |
| `fl.tonight.why` | The "Why this?" expandable | |
| `fl.tonight.pickAsOf` | The pick-as-of provenance line | |
| `fl.tonight.fit` | The honest fit line | |
| `fl.tonight.meta` | The pick's meta row (time, kcal, difficulty) | |
| `fl.tonight.useSoon.<itemId>` | A use-soon row's swap suggestion | e.g. `fl.tonight.useSoon.eggs` |
| `fl.tonight.youdNeed` | "You'd need:" line (sparse state) | |
| `fl.tonight.nothingFeasible` | "Nothing quite makes it tonight." line | |
| `fl.tonight.cookThis` | **Primary action: "Cook this"** | Must stay visible above the tab bar on first paint |
| `fl.tonight.resumeCook` | "Resume cooking" action (active session) | |
| `fl.tonight.somethingElse` | Secondary action: "Something else" | Rejections never become recorded dislikes |
| `fl.tonight.chooseTomorrow` | Secondary action: "Choose tomorrow" | Always available, never disabled by state |
| `fl.tonight.lateLines` | The late-lines provenance notice | |
| `fl.tonight.servings` | Servings editor container | |
| `fl.tonight.servingsMinus` | Servings − button | |
| `fl.tonight.servingsValue` | Servings value | |
| `fl.tonight.servingsPlus` | Servings + button | |
| `fl.tonight.constraints` | Constraint-offer container (after third "Something else") | |
| `fl.tonight.constraintsQuestion` | The constraint offer's question line | |
| `fl.tonight.constraint.<rawValue>` | One constraint choice | `fl.tonight.constraint.faster`, `.cheaper`, `.lighter`, `.noCook` |
| `fl.tonight.tasteQuestion` | The two-question taste prompt container | |
| `fl.tonight.tasteKeep` | "Keep seeing it" answer | |
| `fl.tonight.tasteStop` | "Stop for a while" answer | |

## Kitchen (`FLKitchen`)

| Identifier | Element | Notes |
|---|---|---|
| `fl.kitchen.title` | Screen title ("Kitchen") | |
| `fl.kitchen.summary` | The count summary ("6 items · 2 need a look") | |
| `fl.kitchen.searchOpen` | Magnifying-glass search button | |
| `fl.kitchen.searchBar` | The search field's container (search mode) | |
| `fl.kitchen.searchField` | The search text field | |
| `fl.kitchen.searchCancel` | Cancel-search button | |
| `fl.kitchen.searchNoMatches` | "Nothing matches '<query>'." line | |
| `fl.kitchen.searchAdd` | "Add '<query>'" action (no matches) | Search ends in manual entry, never a dead end |
| `fl.kitchen.empty` | Empty-kitchen container (never scanned) | |
| `fl.kitchen.emptyHeadline` | Empty-kitchen headline | |
| `fl.kitchen.scanGroceries` | "Scan groceries" (empty state) | |
| `fl.kitchen.addByName` | "Add by name" (empty state) | Ranks equal to scanning |
| `fl.kitchen.staleNotice` | The staleness notice row | A notice, never a write-off |
| `fl.kitchen.scanNow` | "Scan now" (staleness notice) | |
| `fl.kitchen.pillStill.<itemId>` | **"Still there" reconciliation pill** | Warm surface fill (`pillIdle`) |
| `fl.kitchen.pillGone.<itemId>` | **"Gone" reconciliation pill** | Quiet surface fill (`pillGone`) |
| `fl.kitchen.item.<itemId>` | A pantry row (tap expands the edit state) | e.g. `fl.kitchen.item.thighs` |
| `fl.kitchen.edit.<itemId>` | The expanded edit state container | |
| `fl.kitchen.quantityMinus.<itemId>` | Quantity − button | |
| `fl.kitchen.quantity.<itemId>` | Quantity display | |
| `fl.kitchen.quantityPlus.<itemId>` | Quantity + button | |
| `fl.kitchen.usedUp.<itemId>` | "Used up" (deducts and teaches the rate) | |
| `fl.kitchen.remove.<itemId>` | "Remove" | |
| `fl.kitchen.assumed` | The assumed-staples sentence | |
| `fl.kitchen.assumedChange` | "Change" (assumed staples) | |
| `fl.kitchen.backupNote` | The failed-backup quiet line | |
| `fl.kitchen.scanGroceriesBottom` | "Scan groceries" (bottom action) | Same intent as `fl.kitchen.scanGroceries`, different placement |
| `fl.kitchen.newGroceries` | "New groceries" (bottom action) | |

## Open to evaluation

1. The `<itemId>` interpolation: real pantry record ids (host-owned).
   If evaluation needs a fixed fixture vocabulary for tests, say so and
   the fixture ids go into the eval fixtures, not the views.
2. Containers vs leaves: `fl.tonight.card`, `fl.kitchen.edit.<id>` exist
   so automation can scope queries. If evaluation prefers flat trees,
   they can be dropped.
3. Naming style: lower camel case after the screen prefix. If CONTRACTS
   uses kebab-case elsewhere, say so and this file renames before
   anything depends on it.
