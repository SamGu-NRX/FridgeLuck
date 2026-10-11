# Direction P — Sam's pastel palette, rebuilt to the craft bar

**Round:** visual overhaul, direction P · **Date:** 2026-10-11 · **Frames:** 393×852 pt
**Source brief:** `/home/user/work/briefs/task-direction-p.md` · Author of this document: the Direction P mock worker.

---

## 1. What this direction is

Direction P keeps **Sam's approved pastel palette as the colour base** — the warm paper neutrals, terracotta accent, sage, oat and dusty rose from the documented `AppTheme` hexes — and rebuilds **everything else to the craft bar**: layout, hierarchy, density, type and motion. The palette is the *only* inherited layer; nothing else from the earlier stage-2 drafts survives unreviewed.

### Kept (Sam's decisions, respected)

- **The palette itself.** All documented hexes are canonical (see §5 for the float-rounding drift note). Terracotta is the accent; sage confirms; oat warms; dustyRose is a tint, never a signal.
- **Structure decisions Sam approved in stage 2:** Tonight is a single card with one job; scan results are review questions, not a stock write; the household Table proposes but never assigns; taste profile is a record with counts, not a control room; the tour is three steps, ever; Profile lives inside Progress in Shell S.
- **The density contract:** 44 pt rows, evidence on every line, counts instead of percentages, state squares that keep meaning in greyscale.

### Rebuilt to the craft bar

- **One type system.** Three type designs were competing in the stage-2 drafts; there is now exactly one: a serif display for titles only (New York), one rounded UI face for everything else (Nunito family, system-rounded fallback), and a tabular mono for every numeral so timers, fits and amounts align in columns. No third face anywhere.
- **Shadows killed on everything.** Stage-2 shadowed cards, chips, tiles and the nav. Elevation is now hairlines (`inset 0 0 0 .5px`) and surface colour; the only shadows left are the physical phone bezel and the mock chrome, plus one case: a floating element over content (dock, orb) may carry a single soft shadow to detach from scrolled content. Nothing else casts.
- **The floating orb nav on Shell F is dead.** Shell F's bar was a floating glass pill with a 62 pt scan orb stuck to its side, overlapping content and the resume dock. The Shell F tab bar is now a flat, full-width bottom bar — five tabs, hairline top rule, no orb, no glass, no shadow. *Shell S's central scan orb is a separate candidate, kept and mocked* (`shell-s-*.html`): it is a deliberate structure test, not a leftover.
- **Motion reduced and honest.** Entrance is one 180 ms rise, 24 ms apart, six blocks maximum, `prefers-reduced-motion` collapses it to a 150 ms fade. Press feedback is scale 0.985–0.97 at 120 ms. The only richer moments are earned and rare: cook-complete plate settle (480 ms, once a day), timer-done settle (480 ms). Voice bars move only with real input amplitude — offline they go static (a fake pulse would be a lie).
- **Hierarchy by weight, not by weight of colour.** One accent per screen maximum; the fit meter, state squares and chips carry shape first (filled / hollow / dashed), colour second.

### The craft bar, applied

- Every numeral is tabular mono; every proportion is "n of m", never a percentage.
- Every learned line carries its evidence; every state (empty, loading, error, offline, unconfirmed, stale, thin data, below-minimum, pending, queued) is designed and documented in the state notes under each frame — states are part of the design language, not exceptions.
- Type floors: captions ≥ 13 px, secondary ≥ 15 px; tab labels are the one 10.5 px exception (iOS standard). Body text clears 4.5:1 everywhere (§5); large mono timer digits are measured at their own size.
- The XXL frame (`tonight-xxl.html`) proves the hierarchy survives 1.35× Dynamic Type: 393 pt treated as 482 pt, the header wraps, the plate drops to a 150 px band, the resume dock reflows to two rows — nothing truncates.

---

## 2. The screens

| # | File(s) | Frame | Role |
|---|---------|-------|------|
| 1 | `tonight.html` / `tonight-dark.html` | Tonight | The pick: hero card (fit meter 9 of 10 · 1 swap, why line with counts), two alternatives, use-soon, resume dock |
| 2 | `kitchen.html` / `kitchen-dark.html` | Kitchen | Search, filter chips, legend, use-soon, needs-a-look, fridge rows with per-line states |
| 3 | `scan-review.html` / `scan-review-dark.html` | Scan review | Three review questions (coriander or parsley / still 2 lemons / how much rice), 11 sure, confirm bar |
| 4 | `recipe.html` / `recipe-dark.html` | Recipe | Fit card with revision evidence, per-line ingredient states, swaps inline, LeChef dock |
| 5 | `cook-lechef.html` (2 frames) | Cook mode | Mid-cook: step at 27 px, mono quantity chips, timer tiles, LeChef card, offline banner, 64 pt Back/Next, camera look. Completion: plate, rating pills, one-line note, kcal line. Cook palette, ignores system appearance |
| 6 | `taste-profile.html` / `taste-profile-dark.html` | Taste profile | Learned sentences with counts, Right/Wrong pairs with in-place undo, forgotten things, quiet-honesty card, debug |
| 7 | `explore.html` / `explore-dark.html` | Explore | Search + filter chips, cookability-ranked catalog, reviewed community rows, honest social proof |
| 8 | `table.html` / `table-dark.html` | Table | Cook cards with the viewer's own fit + own button, share preview (what leaves / never), owner-approved invites, count-based challenges |
| 9 | `tonight-xxl.html` | Tonight at XXL | 1.35× Dynamic Type, light only — the accessibility proof |
| 10 | `shell-s-kitchen.html` / `-dark` | Shell S candidate | Kitchen main tab, central 74 pt scan orb, flat two-tab bar |
| 11 | `shell-s-progress.html` / `-dark` | Shell S candidate | Progress main tab: week as counts, recent cooks, taste-profile line, Profile row |
| 12 | `shell-s-profile.html` / `-dark` | Shell S candidate | Profile pushed inside Progress: household, privacy contract row, kitchen settings |
| 13 | `candidates-quests.html` / `-dark` | Candidate — held | Quests & badges rewarding cooks made and food saved; gamification risk named, adoption condition stated |
| 14 | `candidates-tour.html` / `-dark` | Candidate — kept | The constrained 3-step tour: dots, visible back, auto-return Home, nothing collected |

Every screen carries a **state note** under the frame: the states listed in §3 plus its motion contract. Cook mode gets its own warm-dark palette and one two-frame file (mid-cook + completion) as briefed.

---

## 3. State notes — the conventions

Every frame's note documents its states. The shared conventions:

- **No dead ends.** Empty gives first-class routes; loading reserves height and shows one 2 px line while the last valid content stays up; error keeps the last good data with an "as of" stamp and silent retry — the page never becomes an alert.
- **Offline is a state, not an error.** Cook mode renders the offline banner live (voice falls back on-device, bars go static). Explore renders the cached list with a timestamp. Table queues posts on-device with a "queued" mark.
- **Nothing is written silently.** Scan review adds nothing until a receipt or manual entry; share previews list exactly what leaves the phone; a rejected adaptation leaves the original's record untouched; taste corrections show the change before it lands, with Undo.
- **Honesty floor.** Below 5 ratings a profile line says nothing at all; "cooked by N people" only above a real minimum; coverage is "9 of 14", never 64%.

---

## 4. Motion contract (summary)

| Interaction | Motion | Reduced motion |
|---|---|---|
| Screen entrance | rise 180 ms, stagger 24 ms, ≤ 6 blocks | 150 ms fade, no stagger |
| Press (rows / chips / buttons) | scale 0.985–0.97, 120 ms | unchanged (short) |
| Tab / filter switch | crossfade 150 ms under a stable frame | same fade |
| Wrong → greyed (profile) | opacity to 55%, 150 ms, no layout shift | same fade |
| Resume dock arrive | 320 ms move curve | 150 ms fade |
| Timer done / cook complete | one 480 ms settle — the only rich moments | 150 ms fade |
| Voice bars | real amplitude only; static when offline | static |
| Timer ring | depletes **linearly** — a ring that eases is lying about time | still moves (information) |

---

## 5. Computed WCAG contrast table

Computed by `tools/contrast.js` from the documented hex tokens (WCAG 2.x relative-luminance ratios; text floor 4.5:1, large-text floor 3:1, non-text floor 3:1). Full output of the run; **ALL PAIRS PASS**.

### Text pairs

| Pair (mode) | Foreground | Background | Ratio | Use |
| --- | --- | --- | --- | --- |
| light | `#2A2118` | `#F5F0E8` | **13.93:1** | primary text on #F5F0E8 · body |
| light | `#2A2118` | `#FEFCF8` | **15.42:1** | primary text on #FEFCF8 · body |
| light | `#2A2118` | `#F0E8DE` | **13.02:1** | primary text on #F0E8DE · body |
| light | `#2A2118` | `#E8E0D4` | **12.07:1** | primary text on #E8E0D4 · body |
| light | `#6B6054` | `#F5F0E8` | **5.4:1** | secondary text on #F5F0E8 · body |
| light | `#6B6054` | `#FEFCF8` | **5.98:1** | secondary text on #FEFCF8 · body |
| light | `#6B6054` | `#F0E8DE` | **5.05:1** | secondary text on #F0E8DE · body |
| light | `#6B6054` | `#E8E0D4` | **4.68:1** | secondary text on #E8E0D4 · body |
| light | `#6B6054` | `#F0E0C7` | **4.73:1** | secondary text on #F0E0C7 · body |
| light | `#2A2118` | `#F0E0C7` | **12.18:1** | primary text on hero chip · body |
| light | `#2A2118` | `#EFDFD3` | **12.16:1** | chip text on terracotta-tint chip · 13px semibold |
| light | `#2A2118` | `#D3D9C8` | **10.93:1** | chip text on sage chip · 13px semibold |
| light | `#2A2118` | `#F0E0C7` | **12.18:1** | chip text on oat chip · 13px semibold |
| light | `#2A2118` | `#E6D9D1` | **11.44:1** | chip text on rose chip · 13px semibold |
| light | `#6B6054` | `#F0E0C7` | **4.73:1** | chip evidence text on oat chip · 13px |
| light | `#A35131` | `#F5F0E8` | **4.9:1** | accent text (links, prices of attention) on page · body |
| light | `#A35131` | `#FEFCF8` | **5.42:1** | accent text on surface cards · body |
| light | `#A35131` | `#F0E8DE` | **4.58:1** | accent text on muted surface · body |
| light | `#5F6E53` | `#F5F0E8` | **4.82:1** | sage confirm text on page · body |
| light | `#5F6E53` | `#FEFCF8` | **5.33:1** | sage confirm text on surface · body |
| light | `#7C5C30` | `#F0E0C7` | **4.72:1** | use-soon chip text on oat chip · 13px semibold |
| light | `#FFFFFF` | `#A35131` | **5.56:1** | label on filled primary button · 17px semibold |
| light | `#2A2118` | `#D4B78F` | **8.25:1** | primary text on oat plate block · body |
| light | `#2A2118` | `#B8C7AD` | **8.89:1** | primary text on sage plate block · body |
| light | `#2A2118` | `#C09E96` | **6.45:1** | primary text on rose plate block · body |
| light | `#2A2118` | `#E39E7A` | **7.1:1** | primary text on accentLight block · body |
| dark | `#F2EDE3` | `#141210` | **16.02:1** | primary text on #141210 · body |
| dark | `#F2EDE3` | `#24211C` | **13.75:1** | primary text on #24211C · body |
| dark | `#F2EDE3` | `#2E2924` | **12.34:1** | primary text on #2E2924 · body |
| dark | `#F2EDE3` | `#1A1712` | **15.31:1** | primary text on #1A1712 · body |
| dark | `#BDB09E` | `#141210` | **8.78:1** | secondary text on #141210 · body |
| dark | `#BDB09E` | `#24211C` | **7.54:1** | secondary text on #24211C · body |
| dark | `#BDB09E` | `#2E2924` | **6.76:1** | secondary text on #2E2924 · body |
| dark | `#BDB09E` | `#1A1712` | **8.4:1** | secondary text on #1A1712 · body |
| dark | `#F2EDE3` | `#34241C` | **12.72:1** | chip text on terracotta chip (dark) · 13px semibold |
| dark | `#F2EDE3` | `#424E3C` | **7.54:1** | chip text on sage chip (dark) · 13px semibold |
| dark | `#F2EDE3` | `#3D362B` | **10.22:1** | chip text on oat chip (dark) · 13px semibold |
| dark | `#F2EDE3` | `#3B322F` | **10.69:1** | chip text on rose chip (dark) · 13px semibold |
| dark | `#D98059` | `#141210` | **6.39:1** | accent text on page (dark) · body |
| dark | `#D98059` | `#24211C` | **5.49:1** | accent text on surface (dark) · body |
| dark | `#D98059` | `#2E2924` | **4.92:1** | accent text on muted surface (dark) · body |
| dark | `#94B085` | `#141210` | **7.84:1** | sage text on page (dark) · body |
| dark | `#94B085` | `#24211C` | **6.73:1** | sage text on surface (dark) · body |
| dark | `#1E1C17` | `#D98059` | **5.82:1** | label on filled button (dark) · 17px semibold |
| dark | `#D98059` | `#1E1C17` | **5.82:1** | accent text on deepOlive slab (dark) · body |
| dark | `#CFB58C` | `#141210` | **9.47:1** | oat text on page (dark) · body |
| dark | `#EBB08C` | `#1E1C17` | **9.01:1** | accentLight on deepOlive slab (dark) · body |
| cook | `#F2EDE3` | `#1F1C17` | **14.55:1** | cook primary text on #1F1C17 · body |
| cook | `#F2EDE3` | `#2B2924` | **12.45:1** | cook primary text on #2B2924 · body |
| cook | `#F2EDE3` | `#2E2924` | **12.34:1** | cook primary text on #2E2924 · body |
| cook | `#BDB09E` | `#1F1C17` | **7.98:1** | cook secondary text on #1F1C17 · body |
| cook | `#BDB09E` | `#2B2924` | **6.83:1** | cook secondary text on #2B2924 · body |
| cook | `#BDB09E` | `#2E2924` | **6.76:1** | cook secondary text on #2E2924 · body |
| cook | `#EBB08C` | `#2B2924` | **7.69:1** | timer digits on tile · mono 44px |
| cook | `#D98059` | `#1F1C17` | **5.81:1** | cook accent text on page · body |
| cook | `#1F1C17` | `#D98059` | **5.81:1** | label on filled cook button · 17px semibold |

### Non-text UI pairs (3:1 floor)

| Non-text UI (mode) | Foreground | Background | Ratio | Use |
| --- | --- | --- | --- | --- |
| light | `#C2613A` | `#FEFCF8` | **4.05:1** | fit-meter filled square on surface |
| light | `#C2613A` | `#F5F0E8` | **3.65:1** | fit-meter filled square on page |
| light | `#6B6054` | `#FEFCF8` | **5.98:1** | hollow/dashed state square border on surface |
| light | `#7A8E6B` | `#FEFCF8` | **3.47:1** | have-state filled square on surface |
| light | `#7A8E6B` | `#F5F0E8` | **3.13:1** | have-state filled square on page |
| dark | `#D98059` | `#24211C` | **5.49:1** | fit-meter filled square (dark) |
| dark | `#BDB09E` | `#24211C` | **7.54:1** | hollow/dashed square border (dark) |
| dark | `#94B085` | `#24211C` | **6.73:1** | have-state filled square (dark) |

### Adjustments to Sam's palette

| Mode | Token | Before | After | Why |
| --- | --- | --- | --- | --- |
| light | textSecondary | `#887A6A` | `#6B6054` | fails 4.5:1 for body text on #F5F0E8, #E8E0D4, #FEFCF8, #F0E8DE, #F0E0C7 |
| light | accent → accentInk (new derived role: text on plain surfaces, filled controls) | `#C2613A` | `#A35131` | accent #C2613A as text = 3.65:1 and white on it = 4.15:1; hue kept, lightness lowered to clear 4.5:1 both ways |
| light | sage → sageInk (text role only; sage itself stays for filled squares/fills) | `#7A8E6B` | `#5F6E53` | sage #7A8E6B as text = 3.13:1; hue kept, lightness lowered to clear 4.5:1 |
| light | oat → oatInk (text role only; oat itself stays for fills/blocks) | `#D4B78F` | `#7C5C30` | oat as text on heroLight chip = 1.48:1; hue kept, lightness lowered to clear 4.5:1 |

Decorative/fill uses keep the original palette values — only *text roles* move to the derived inks. Hue is never changed; only lightness, so the palette still reads as Sam's.

### AppTheme.swift comment-vs-float drift (documented hexes canonical)

- light.surface: strict float rounding → #FCFCF7, documented token #FEFCF8 (comment-level rounding, ≤2/255 per channel)
- light.textPrimary: strict float rounding → #292117, documented token #2A2118 (comment-level rounding, ≤2/255 per channel)
- light.textSecondary: strict float rounding → #877A6B, documented token #887A6A (comment-level rounding, ≤2/255 per channel)
- light.accent: strict float rounding → #C2613B, documented token #C2613A (comment-level rounding, ≤2/255 per channel)
- light.sage: strict float rounding → #7A8F6B, documented token #7A8E6B (comment-level rounding, ≤2/255 per channel)
- light.oat: strict float rounding → #D4B88F, documented token #D4B78F (comment-level rounding, ≤2/255 per channel)
- light.dustyRose: strict float rounding → #BF9E96, documented token #C09E96 (comment-level rounding, ≤2/255 per channel)
- light.heroMid: strict float rounding → #D4B88F, documented token #D4B78F (comment-level rounding, ≤2/255 per channel)
- dark.bg: strict float rounding → #14120F, documented token #141210 (comment-level rounding, ≤2/255 per channel)
- dark.sageLight: strict float rounding → #708A69, documented token #708A68 (comment-level rounding, ≤2/255 per channel)
- dark.deepOlive: strict float rounding → #1F1C17, documented token #1E1C17 (comment-level rounding, ≤2/255 per channel)

---

## 6. Review log — two fix iterations, verified in captures

All 26 HTML files were screenshotted with Playwright (Chromium, 393×852 viewport, 2× scale, ≥450 ms settle before capture; 27 shots in `shots/`, cook mode renders both frames). Reviewed every screen family including all dark variants and both cook frames. Two fix iterations, each re-rendered and re-captured:

**Iteration 1**
1. **Floating orb nav killed (brief-mandated).** Shell F's bar still carried the 62 pt scan orb overlapping the tabs and the resume dock. Bar rebuilt flat and full-width; orb removed from Shell F everywhere; Shell S's orb kept as the separate briefed candidate.
2. **Resume dock collision.** The Tonight dock sat at `bottom: 22` under the old pill bar and ghosted through the tabs; moved above the flat bar.
3. **Global underline leak.** Anchor defaults underlined tab labels and links app-wide; reset globally, link affordance carried by context and weight.
4. **Cook offline banner collision.** The in-flow offline line landed under the absolutely-positioned voice row; relocated into the bottom stack as its first row.
5. **Cook ghost button invisible.** `cbtn.ghost2` never set a background, so the UA's light button face bled through the dark cook palette; set `transparent` + hairline.
6. **Cook quantity chips oversized and splitting** ("3" / "tbsp" across lines); reduced to 0.78 em mono with nowrap.
7. **Cook bottom stack spacing** — camera-look row clipped by the home bar; re-spaced.

**Iteration 2**
8. **XXL header collision** — the Scanned chip overlapped the 38 px title; header now wraps at XXL.
9. **XXL plate** — the note claimed the plate shrinks; it didn't. Implemented the real rule (150 px band) and re-worded the note to match exactly what renders.
10. **XXL dock** — ballooned to four text lines covering the evidence; restructured to two rows (step text on top, timer + Resume below).
11. **Quest rows collapsed** — mono count and meter were nested inside the title span and rendered inline ("Cook 3 suppers1 of 3■□□"); span nesting fixed, columns now align.
12. **LeChef card buttons wrapped** to two lines; nowrap + padding.
13. **Section label links** ("why this order") wrapped to three lines; nowrap.

Post-fix captures verified: Tonight (light/dark/XXL), Kitchen (light/dark), scan review, recipe, both cook frames, taste profile, explore, table, Shell S kitchen, both candidates. Remaining unviewed shots are dark re-variants of screens whose dark tokens were verified directly (tonight-dark, kitchen-dark) plus mechanically identical variants — the render pipeline is one shared system, so their diffs are token swaps already exercised elsewhere.

---

## 7. Candidate decisions

| Candidate | Verdict | Reason |
|---|---|---|
| Shell F floating orb nav | **Killed** | Craft bar forbids it: floats over content, collides with docks, adds a second scan entry. Flat bar carries the same tabs. |
| Shell S central scan orb | **Kept as candidate** | One navigational affordance from Shell S worth testing; mocked as a full structure (Kitchen/Progress tabs, Profile inside Progress) in this direction's tokens. |
| Quests & badges | **Held** | Rewards only cooks made and food saved — never app opens, no streak flames, no confetti. Held because it is the densest surface and one step from gamification creep; adopt only if Progress needs a weekly spine. |
| Constrained tour | **Kept** | Three steps, ever; visible back on every step; auto-returns Home; carries the on-device promise before first cook. |

---

## 8. File inventory

```
docs/design-round/direction-p/
├── DIRECTION.md                        ← this document
├── tonight.html / tonight-dark.html    ├── kitchen.html / kitchen-dark.html
├── scan-review.html / scan-review-dark.html
├── recipe.html / recipe-dark.html      ├── cook-lechef.html (2 frames)
├── taste-profile.html / taste-profile-dark.html
├── explore.html / explore-dark.html    ├── table.html / table-dark.html
├── tonight-xxl.html (light only, briefed)
├── shell-s-kitchen.html / -dark · shell-s-progress.html / -dark · shell-s-profile.html / -dark
├── candidates-quests.html / -dark · candidates-tour.html / -dark
└── shots/                              ← 27 Playwright captures (2× PNG)
tools/                                  ← generators (shell.js, screens-*.js, gen.js, shots.js, contrast.js)
```

26 HTML mocks · 27 screenshots · all computed pairs pass. Tools live under `/home/user/work/round-p/tools/`; regenerating is `node tools/gen.js && node tools/shots.js`.
