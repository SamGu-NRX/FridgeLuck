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
| Shell | **F + system** | Native iOS 26 TabView representation: Liquid Glass floating platter, four tabs — Tonight, Kitchen, Explore, Cookbook — with Scan as the separated trailing search-role tab (`Tab("Scan", systemImage: "viewfinder", role: .search)`); Table moved inside Explore behind the beta flag; profile inside Progress | F's calm density at the system's own fidelity; Sam's call. The hand-rolled orb is retired to the ALTERNATE shell (shell S, two tabs + orb). |
| Photo treatment | **P** | Warm linen placeholder with hatch and a working caption (`photo: overhead, daylight, 3:2 crop`); 3:2 aspect capped at 40% of screen height (≈340 px) | P's warmth kept the placeholder from reading as broken; the 3:2 cap keeps Tonight's decision and Recipe's ingredients on the first screen. |
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

| ink on warm chip fill | 13.72 | 4.5 | | ink on warm chip fill | 12.37 | 4.5 | | ink on warm chip fill | 12.25 | 4.5 |
| ink-2 on warm chip fill | 5.53 | 4.5 | | ink-2 on warm chip fill | 6.78 | 4.5 | | ink-2 on warm chip fill | 6.18 | 4.5 |
| chip stroke on chip fill | 3.39 | 3 | | chip stroke on chip fill | 3.68 | 3 | | chip stroke on chip fill | 3.10 | 3 |
| accent-ink on bar fill (active tab) | 7.89 | 4.5 | | accent-ink on bar fill | 8.13 | 4.5 | | accent-ink on bar fill | 7.55 | 4.5 |
| ink-2 on bar fill (inactive tabs) | 6.01 | 4.5 | | ink-2 on bar fill | 7.80 | 4.5 | | ink-2 on bar fill | 6.41 | 4.5 |

All 57 pairs pass (`node tools/contrast.mjs` exits 0). Accent digits appear only at ≥24 px (large-text rule). The chip stroke carries its own token (`--chipstroke`) because the shared rule-2 stroke failed on the lighter chip fill in dark mode (2.57); `#8B7F6C` passes at 3.68.

## Revision 2 — Sam's four fixes (applied to every affected frame)

1. **Photos 3:2, capped.** The shared photo block renders at 3:2 with a 40%-of-screen-height cap (≈340 px; all three Tonight frames measure 230 px, Recipe 235 px). This pulled "Cook this" above the bar on Tonight and the ingredients above the dock on Recipe — verified per rendered frame by `probe2.mjs`, not by eye: button bottom 738 vs bar top 802 at default text size (light and dark), and Recipe's first ingredient rows start at 649 with four rows above the dock. The deciding note's gap above the primary action moves 48 → 16 px on Tonight only; the bar itself supplies the fold's separation. At XXL the pick scrolls — reported, not hidden.
2. **Native tab bar everywhere.** The hand-made dock (content bled through it on every screen) is replaced on all tab-bearing frames by a faithful iOS 26 TabView representation: floating Liquid Glass platter (left/right 12 pt, bottom 22 pt, 34 pt radius, system bottom insets), four tab items, no central orb, no bleed — pixel-verified (`ghost-check.mjs`: platter-interior luminance spread 0–3 of 255 on Tonight, Kitchen, Explore, Table, light and dark). While fixing this, a real bug surfaced and was fixed: the bar markup had been a sibling of the phone frame, outside the theme-token scope, so `--barbg` resolved to nothing and the platter painted transparent on every screen; the bar is now inside the frame and the fill is effectively opaque (0.99 + 40 px blur), which also keeps captures honest in renderers that skip backdrop-filter.
3. **Four-tab default shell.** Default configuration is Tonight · Kitchen · Explore · Cookbook with Scan as the separated trailing search-role tab (`Tab("Scan", systemImage: "viewfinder", role: .search)` — custom label and icon on a search-role tab are documented as supported; the system may present it as search/expand on activation). Table left the bar and lives inside Explore behind the beta flag: Explore gains a "Community tables — Beta" entry row (More section), and the Table frames render with Explore active and a state note explaining the entry point. The shell-s mocks (two tabs + central orb, Profile inside Progress) remain in the set relabeled **ALTERNATE configuration**, with a state note saying so.
4. **Warm pills in Kitchen.** "Still open / Gone / Confirm" and the other uncertain-item pills are retinted from cool grey to H's warm linen fill family (`--chipfill` with a dedicated `--chipstroke`); contrast re-run and every pair passes (ink 13.72/12.37/12.25, ink-2 5.53/6.78/6.18, stroke 3.39/3.68/3.10 across light/dark/cook).

### Search-role verification note

The scan's bar control is specified as `Tab("Scan", systemImage: "viewfinder", role: .search)`. This is written from Apple's documented SwiftUI API (iOS 18+ `role:` parameter, custom label and `systemImage` supported) — it has **not** been verified in a live iOS 26 build this round. Documented behavior to verify on device: a search-role tab renders separated at the trailing edge and may open the system search/expansion presentation on activation rather than a custom screen. **Fallback if native verification disagrees:** Scan as a prominent action on Tonight and Kitchen (the orb's press affordance, minus the bar orb), keeping the four content tabs.

## Files

26 mocks in this directory (`<screen>.html` + `-dark`; `cook-lechef` in cook palette, `tonight-xxl` light-only at 428 pt) · 26 captures in `renders/` (393×852 @2x, after 450 ms) · generators in `tools/` (`make_html.py` builds; `shoot.mjs` captures; `contrast.mjs` computes). Reviewed through three fix iterations (round 1: button rings, full-width glass bar, dock stacking, photo heights, Explore row columns, chip rows; round 2: Quests stat band, Tour frame fit, Tonight bar clearance, shell chips rule, nowrap quantities; round 3: Sam's four fixes below). Verification: `tools/probe2.mjs` (43 measured checks: Tonight "Cook this" above the bar at 738 < 802 at default text size in light and dark, 3:2 photos at ≤340 px, Recipe's primary inside its dock with four ingredient rows above it, no horizontal overflow on all 26 frames) and `tools/ghost-check.mjs` (pixel luminance spread inside the platter ≤ 3 of 255 — no content reads through the glass). XXL is informational: at 428 pt the pick scrolls and "Cook this" falls below the bar (912 > 802), which the first-paint rule does not cover. Known chrome quirk: the status pill sits flush to the frame's left edge — uniform across all screens, presentation-only.
