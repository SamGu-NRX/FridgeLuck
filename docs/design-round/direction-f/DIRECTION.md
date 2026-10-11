# Direction F — the prep list · round set

Evolution of the eight first-draft mocks into the full round set for the prep-list direction.
Everything here is generated: 26 self-contained 393×852 HTML mocks (light + dark per screen,
plus the XXL and candidate extras), screenshotted with Playwright Chromium at 2× and reviewed
through two fix iterations. Contrast ratios are computed, not transcribed — script:
`tools/contrast.js`.

**State of this round:** every listed file exists, every render has been reviewed and fixed
through two passes, all contrast claims below come from the run recorded at the end of this
session.

---

## Contents

- `tonight.html` / `tonight-dark.html` — the recommendation. Hero photo plate (3:2), fit pips,
  the one-line swap, the Why line (evidence, not a score), Cook this / Something else.
- `recipe.html` / `recipe-dark.html` — the dish page. Fit block ("9 of 10 · 1 swap" +
  "Fit to your kitchen"), ingredients with mono grams and a servings stepper, per-ingredient
  presence marks, steps preview, floating dock (Just the steps / Cook with LeChef).
- `kitchen.html` / `kitchen-dark.html` — the pantry ledger. Use soon / Needs a look / Fridge
  groups, yolk-colored use-by chips, mono quantities, Yes/Gone confirm chips for scan
  hypotheses, scan orb.
- `scan-review.html` / `scan-review-dark.html` — the post-scan review. Photo-squares per
  hypothesis, chip choices ("Leafy, pale stems, top shelf"), Add 14 to kitchen.
- `cook-lechef.html` — cook mode (hob palette). Yellow step numbers, oversized timer,
  LeChef card, voice hint, Next dock.
- `explore.html` / `explore-dark.html` — the catalog + community feed. Search, filter chips,
  "Can cook now" cards: thumb, name, source, fit pips, caption + CTA on a full-width row.
- `table.html` / `table-dark.html` — the Table feed + share preview (second frame below):
  cook cards with quotes, ratings, fit lines, Cook tonight / Cook with swap.
- `taste-profile.html` / `taste-profile-dark.html` — learned taste: what you noticed, rated
  pairs, skippables, eaten-late patterns — "1 of 3" confirm chips, no percentages.
- `shell-s-*.html` (+dark) — Shell S: the flat-header information shell (Kitchen, Progress,
  Profile) as a competing structure to the floating-glass shell used elsewhere.
- `tonight-xxl.html` — the accessibility variant of Tonight at XXL type scale.
- `candidates-quests*.html` — candidate: weekly quests framed as gentle rituals (counters,
  no streaks, no confetti).
- `candidates-tour*.html` — candidate: the 3-step shelf tour (Back / Step 1 of 3 / Skip,
  Open camera, returns to Tonight between steps).

Renders (`renders/`): one full-page PNG per mock at deviceScaleFactor 2 (786 px wide phone
frame, state note below), plus three contact sheets (`_sheet1..3.png`) used for the review
passes.

---

## Token definitions

### Shared (all palettes except hob)

`--mono` = ui-monospace stack. `--pip` marks are currentColor squares (10 pips, filled = fit).

| token | light | dark | role |
|---|---|---|---|
| paper | `#F7F8F6` | `#191A18` | screen background |
| ink | `#131313` | `#F1F1ED` | primary text, filled marks, primary button bg |
| ink-2 | `#5E5E59` | `#999993` | secondary text, quotes, captions |
| ink-3 | `#8A8A84` | `#6A6A64` | tertiary/meta text, photo credits, idle tab labels |
| rule | `#E4E5E0` | `#2A2B28` | hairline separators |
| rule-2 | `#CFD0CA` | `#43443F` | stronger hairlines, chip outlines |
| yolk | `#F5C400` | `#F5C400` | the accent: eyebrows, pips-eyebrow, use-by chips, hob numerals |
| yolk-soft | `#FFF3B8` | `#2A2300` | yolk chip/sel backgrounds |
| yolk-ink | `#6A5300` | `#F5C400` | text on yolk-soft |
| err | `#C8321E` | `#FF6B57` | destructive / past-due |
| btn-ink | `#FFFFFF` | `#161715` | icon/text on ink-filled and on yolk-filled controls |
| bar | `rgba(250,250,247,.92)` | `rgba(28,29,27,.93)` | tab glass capsule |
| barline | `rgba(0,0,0,.09)` | `rgba(255,255,255,.14)` | glass inner hairline |
| barshadow | `rgba(0,0,0,.22)` | `rgba(0,0,0,.5)` | glass drop shadow |
| card | `#FBFBF9` | `#1F201D` | card surfaces |
| cardline | `rgba(0,0,0,.12)` | `rgba(255,255,255,.12)` | card hairline |
| photo-bg | `#E9EAE4` | `#20211E` | photo plate placeholder |

### Hob (cook mode)

`#0C0C0C` background; ink `#F1F1ED`, ink-2 `#8E8E88`, ink-3 `#5A5A55`, rule `#252525`,
rule-2 `#3A3A36`, yolk `#F5C400`, yolk-soft `#2A2300`, yolk-ink `#F5C400`,
err `#FF6B57`, btn-ink `#0C0C0C`, bar `rgba(22,22,22,.93)`, card `#161616`,
photo-bg `#1A1A18`. Cook mode is its own warm-dark, darker than system dark on purpose.

---

## Computed WCAG ratios

`tools/contrast.js` (WCAG 2.x relative luminance) — run this session against the final tokens.

### Light (paper `#F7F8F6`)

| pair | ratio | verdict |
|---|---|---|
| ink / paper | **17.44:1** | AAA (doc claims "17" — this is the exact value) |
| ink-2 / paper | **6.12:1** | AA text |
| ink-3 / paper | **3.26:1** | AA large-text / decorative meta |
| ink / yolk (on-yolk text) | **11.31:1** | AAA |
| yolk-ink / yolk-soft | **6.58:1** | AA text |
| err / paper | **5.01:1** | AA text |
| yolk / paper | 1.54:1 | shape/accent only — never text |

### Dark (system dark `#191A18`)

| pair | ratio | verdict |
|---|---|---|
| ink / dark bg | **15.42:1** | AAA |
| ink-2 / dark bg | **6.10:1** | AA text |
| ink-3 / dark bg | **3.21:1** | AA large-text / decorative meta |
| yolk / dark bg | **10.63:1** | AAA |
| yolk-ink / yolk-soft (dark) | **9.54:1** | AAA |
| err / dark bg | **6.23:1** | AA text |

### Hob (cook mode `#0C0C0C`)

| pair | ratio | verdict |
|---|---|---|
| ink / hob | **17.27:1** | AAA |
| ink-2 / hob | **5.94:1** | AA text |
| ink-3 / hob | **2.82:1** | decorative only (see limits) |
| yolk / hob | **11.90:1** | AAA — the cook-mode numeral color |
| yolk-ink / yolk-soft (hob) | **9.54:1** | AAA |
| err / hob | **6.98:1** | AA text |

### Surface separation

| surfaces | ratio | note |
|---|---|---|
| dark bg vs hob bg | **1.12:1** | intentionally close — cook mode must read as the same family, just deeper |
| dark bg vs paper | **16.40:1** | full flip |
| card vs paper | ~1.06:1 | separation carried by the hairline, not fill |

Known limits (accepted, by design):
- ink-3 is a *decorative* tier: photo credits, idle tab labels, timestamps. It clears 3:1 on
  light and dark but sits at 2.82:1 on hob. Nothing instructional is set in ink-3 on hob.
- yolk/paper at 1.54:1 is fine for eyebrow squares, pip fills and chip borders — never text.

---

## Dark appearance decisions

- The dark paper is a green-tinged near-black (`#191A18`), not neutral `#000`, to keep the
  food context warm; cook mode (`#0C0C0C`) sits below it and is reserved for cooking.
- Yolk stays `#F5C400` in all three palettes. On dark, yolk-soft inverts to a dark olive
  (`#2A2300`) with yolk-ink lifted to pure yolk so chips invert instead of vanishing.
- err lifts to `#FF6B57` on dark/hob (red on near-black needs the lift to hold 4.5:1).
- Photo plates darken to `#20211E` / `#1A1A18` with stripes at white-alpha instead of
  black-alpha; credit text stays ink-3.
- The tab glass goes to 93% opacity dark (`rgba(28,29,27,.93)`). Static mock renders show a
  faint content whisper behind the capsule — deliberate, matching the floating-bar behavior
  without depending on backdrop blur.

---

## Review record

Two review/fix iterations were run over the full render set (contact sheets in `renders/`):

**Iteration 1 fixes** (found in the first full screenshot pass):
- Tonight/Recipe hero plates moved 4:5 → **3:2**; Tonight's whole hierarchy (pick, fit pips,
  swap line, Why line, both CTAs) now fits above the tab bar in the initial frame.
- Taste profile and Shell S Profile headers: explanatory paragraphs wrap **below** the title
  instead of truncating beside it (`.head` gained `flex-wrap:wrap`).
- Explore cards compacted to thumb-and-text rows; search placeholder clipped to one line.
- Table CTAs ("Cook with swap(s)") made non-shrinking/nowrap so they hold one line.
- Dark tab glass raised from .78 → .93 opacity (background text read through it in renders).
- Scan orb icon color fixed to `--btn-ink` (was hard-coded white: invisible icon on the dark
  ink-filled orb).

**Iteration 2 fixes** (verified iteration 1, then):
- Explore card action rows restructured: fit pips live under the text, caption + CTA share a
  full-width bottom row of the card (the caption column was squeezed into mid-phrase wraps,
  and a nowrap CTA overflowed the card).
- Swap/swap-count phrases wrapped in nowrap spans in Table, Explore and XXL Tonight so counts
  never split ("… · 1 / swap").
- The bar's `backdrop-filter` was proven a no-op in headless Chromium renders (probe with and
  without: identical pixels) and caused a full-page-screenshot stitching artifact (ghost text
  over the glass at full strength). Removed; the glass look now comes from the .92/.93 fill,
  inner hairline and shadow, which render identically everywhere.

---

## Candidate trade-offs (what the two candidate screens argue)

- **Quests, not streaks.** Weekly quests are framed as rituals ("Cook 3 dinners", "Use it up:
  cook the spinach") with counters that do not reset on a missed day. The state note spells
  out the refusal: no streaks, no flames, no confetti; the score is the fit line, never a
  gamified number. Risk: less daily-open pull than a streak loop would buy. Accepted —
  the product's promise is remembering what worked, not daily habit pressure.
- **Tour, not tutorial.** Three steps, each anchored to the real camera flow with the real
  promise (return to Tonight between steps, ends after three). Skippable from step one.
  Risk: users who skip never see the pantry trick. Accepted — the Kitchen screen's own
  "Needs a look" flow teaches the same trick on first use.

## How to regenerate

```bash
node tools/build.js     # emits 26 HTML mocks into docs/design-round/direction-f/
node tools/shot.js      # Playwright Chromium, 393×852 @2×, 450ms+ settle, full-page PNGs
node tools/contrast.js  # prints the tables above
```
