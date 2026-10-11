# Direction H — the hybrid

Per element, from P's written palette (AppTheme.swift) and F's written structure (design-direction.md). One rule held throughout: it must still look like one app — warm paper, ink data, one terracotta accent, everything else hairlines.

## The borrow table

| Element | Taken from | Decision | Why |
| --- | --- | --- | --- |
| Light background | **P** | Warm linen `#F5F0E8`, surface `#FEFCF8` | P's linen is the hybrid's warmth carrier; F's paper-white alone read cold next to the walnut ink. |
| Ink & neutrals | **F** | Walnut ink `#2A2118`, three-step warm greys, no blue-grey anywhere | F's neutrals keep data honest; P's brown-tinted greys muddied mono numerals. |
| Dark mode | **P** | Twilight Warmth: `#141210` bg, cream ink, lifted terracotta `#D98059` | P's dark palette is the more resolved half; F's was cooler and flatter. |
| Accent | **P** | Terracotta `#C2613A` (light) / `#D98059` (dark), accent-soft fill family | P's hue with F's discipline: exactly one accent, markers and digits only — sage/oat/dusty-rose cut. |
| Serif display | **P** | New York-style serif for dish names and promises only | P's voice; F used it more widely, which competed with data. |
| Type scale | **F** | 17/24 body, 13 captions, tabular mono for every numeral | F's scale survived contact with real content; P's floated. |
| Structure | **F** | Flat hairline rows, 44 pt targets, dense 24 px sections, no card chrome | F's deciding-screen density is the product's engine. |
| Motion | **F** | Five tokens: 220 ms rise, 40 ms stagger, 150 ms crossfade, 120 ms press, snap easing; reduced-motion = fades | Borrowed whole; re-deriving a sixth token would break the system. |
| Shell | **F** | Two tabs + central scan orb; Explore/Cookbook/LeChef as header links; profile inside Progress | Fitts-safe, calm; five tabs read as clutter. |
| Photo treatment | **P** | Warm linen placeholder with hatch and a working caption (`photo: overhead, daylight, 4:5 crop`) | P's warmth kept the placeholder from reading as broken. |
| Fit meter | **new** | Filled walnut squares + one hollow terracotta square — the gap is the story, never a percentage | Neither direction had a shape for "9 of 10 · 1 swap" that fits a row. |
| Cook-mode palette | **new** | Twilight hob: darker than dark, ember accent `#E08B62`, cream 26 px step text | Cook mode happens in a dark kitchen; both source palettes were too bright for it. |
| State squares | **new** | F's filled/hollow extended: dashed = unconfirmed, grey ring = assumed staple (always captioned) | The pantry-truth contract needed two more honest states than F drew. |
| Evidence sentences | **new** | Profile claims as counts in mono ("18 of 23") with Right/Wrong | The taste contract's deciding UI, in the hybrid's own register. |
| State notes | **new** | Every frame ships with a side note listing states, motion and rules | Neither direction documented states per frame; the handoff needs it. |

## What the hybrid does well and badly

**Well:** one voice across the full set — warmth in the ground, honesty in the data; the fit meter tells the swap story at a glance; dark and cook modes feel continuous with light, not inverted.

**Badly:** warm linen flattens hairlines — rules sit close to the ground colour and long lists lose structure (kept surface-white rows where lists run long). One accent means no secondary semantic colour: sync and info states must stay ink. Terracotta on linen sits at 3.65:1 — legal for markers, too low for small text, so accent text always rides accent-soft. The serif/mono pairing leaves body text voiceless — it leans on weight steps.

## Craft check (computed, `node tools/contrast.mjs`; full tables in `contrast-table.md`)

| Pair (light) | Ratio | Min | | Pair (dark) | Ratio | Min | | Pair (cook) | Ratio | Min |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| ink on bg | 13.93 | 4.5 | | ink on bg | 16.02 | 4.5 | | ink on bg | 14.59 | 4.5 |
| ink-2 on bg | 5.62 | 4.5 | | ink-2 on bg | 8.78 | 4.5 | | ink-2 on bg | 7.36 | 4.5 |
| accent-ink on accent-soft | 6.42 | 4.5 | | accent-ink on accent-soft | 7.40 | 4.5 | | accent-ink on accent-soft | 7.53 | 4.5 |
| accent-ink on bg (links) | 7.37 | 4.5 | | accent-ink on bg (links) | 9.14 | 4.5 | | accent-ink on bg (links) | 8.66 | 4.5 |
| text on primary button | 15.80 | 4.5 | | text on primary button | 14.59 | 4.5 | | text on primary button | 14.59 | 4.5 |
| error on bg | 5.20 | 4.5 | | error on bg | 6.67 | 4.5 | | error on bg | 6.07 | 4.5 |
| accent marker on bg | 3.65 | 3 | | accent marker on bg | 6.39 | 3 | | accent marker on bg | 6.52 | 3 |
| hollow stroke on bg | 3.44 | 3 | | hollow stroke on bg | 3.32 | 3 | | hollow stroke on bg | 3.69 | 3 |

All 53 text pairs and 8 non-text pairs pass. Accent digits appear only at ≥24 px (large-text rule).

## Files

26 mocks in this directory (`<screen>.html` + `-dark`; `cook-lechef` in cook palette, `tonight-xxl` light-only at 428 pt) · 26 captures in `renders/` (393×852 @2x, after 450 ms) · generators in `tools/` (`make_html.py` builds; `shoot.mjs` captures; `contrast.mjs` computes). Reviewed through two fix iterations (round 1: button rings, full-width glass bar, dock stacking, photo heights, Explore row columns, chip rows; round 2: Quests stat band, Tour frame fit, Tonight bar clearance, shell chips rule, nowrap quantities); layout probe confirms uniform 393×852 frames, no horizontal overflow. Known chrome quirk: the status pill sits flush to the frame's left edge — uniform across all screens, presentation-only.
