# FridgeLuck visual and motion direction

For whoever rebuilds `apps/ios/DesignSystem` and the feature screens. Answers: what the app looks and moves like, with values you can type into `AppTheme` and `AppMotion`, and what to refuse. The mocks in `../mocks/` are the reference renderings.

## Direction

**A prep list, not a magazine.** White like the inside of a fridge, ink, and one colour. Numbers are the loudest thing on screen because, in a kitchen, the number is what you read from arm's length: 300 g, 8 min, 9 of 10. Deciding happens on paper (light); cooking happens on the hob (dark). The switch between them is the moment you commit.

Why the current look fails. `AppTheme.swift` is warm linen (#F5F0E8) plus terracotta (#C2613A) plus a serif display face. That combination is the first of the four AI-default looks the frontend-design skill lists, and it is the look of every 2025 "AI wellness" app. On top of it sit dark olive slabs (`deepOlive` panels on the linen page), three type designs (serif, rounded, default), an amber hero gradient, a floating orb nav, confetti, and a shimmer. Nothing is wrong with any one of these. Together they say nobody chose.

The one aesthetic risk: egg-yolk yellow as the only chromatic colour, used for exactly one meaning (attention here, now). Tonight's pick, a running timer, a use-soon item, a selected chip. It is kitchen-native (yolk, butter, a Post-it on the fridge door), it reads at 11:1 against both paper and the hob, and it is not terracotta, not acid green, not violet. The risk is that yellow reads as "warning" to some people. It is cheap to swap for tomato red (#D7301F) if the test in product-direction says so; nothing else in the system moves.

## Type

SF Pro for words, SF Mono for numbers. No serif. No rounded. Two faces, each with one job, and the contrast between them is the typographic identity.

| Role | Face | Size / line | Weight | Tracking | Notes |
| --- | --- | --- | --- | --- | --- |
| Dish title | SF Pro Display | 32 / 34 | 700 | -0.02 em | Wraps to 3 lines max, then truncates |
| Screen title | SF Pro Display | 28 / 32 | 700 | -0.015 em | Inline, not the large-title collapse |
| Cook-mode step | SF Pro Display | 26 / 32 | 600 | -0.01 em | On hob black; this is the largest body text in the app |
| Body | SF Pro Text | 17 / 24 | 400 | 0 | |
| Secondary | SF Pro Text | 15 / 20 | 400 | 0 | ink-2 |
| Section label | SF Pro Text | 13 / 16 | 600 | 0 | Sentence case. Never uppercase, never tracked |
| Caption | SF Pro Text | 13 / 16 | 400 | 0 | ink-2 |
| Timer | SF Mono | 56 / 56 | 500 | -0.02 em | Tabular. Yolk on hob |
| Fit count, totals | SF Mono | 17 / 22 | 500 | -0.01 em | Tabular |
| Quantity, time, kcal | SF Mono | 15 / 20 | 400 | -0.01 em | Tabular, right-aligned in rows |
| Evidence count | SF Mono | 13 / 16 | 400 | 0 | ink-2 |

Rules. Every numeral with a unit is mono. Units are set in the same mono at the same size, separated by a thin space (300 g, 8 min). Mixed runs ("9 of 10") are mono throughout. Dynamic Type applies everywhere via text styles; mono comes from `.monospaced()` on the system font so it scales. Minimum size anywhere: 13.

## Colour

Light (paper) and cook mode (hob) are two palettes, not light and dark mode. The app also has a system dark mode, which is the paper palette inverted; cook mode is its own thing and ignores the system setting.

| Token | Paper | Hob | Use |
| --- | --- | --- | --- |
| bg | #F7F8F6 | #0C0C0C | Page |
| ink | #131313 | #F1F1ED | Text, primary buttons, filled states |
| ink-2 | #5E5E59 | #8E8E88 | Secondary text (6.1:1 on paper) |
| ink-3 | #8A8A84 | #5A5A55 | Tertiary, placeholders, inactive tab (3.2:1; never body-size text) |
| rule | #E4E5E0 | #252525 | Hairlines, 0.5 pt on 3x screens |
| rule-2 | #CFD0CA | #3A3A36 | Hollow states (missing ingredient, unconfirmed item) |
| yolk | #F5C400 | #F5C400 | Attention: tonight's pick marker, running timers, use-soon, selection |
| yolk-soft | #FFF3B8 | #2A2300 | Yolk as a background behind text |
| yolk-ink | #6A5300 | #F5C400 | Text on yolk-soft (6.6:1) |
| error | #C8321E | #FF6B57 | Errors only. Never for "missing" or "expiring" |

Contrast checks (computed, not estimated): ink on paper 17:1, ink-2 on paper 6.1:1, ink on yolk 11.3:1, yolk on hob 11.9:1, yolk-ink on yolk-soft 6.6:1, error on paper 5.0:1.

Semantics are shape before colour. Have = filled square. Missing = hollow square. Unconfirmed = dashed outline. Sure (scan) = solid row; needs you = row with two chips. Yolk never carries a meaning on its own; it always sits next to a word.

What is gone: sage, oat, dusty rose, accentLight, the amber hero pair, the olive slabs, the per-macro chart colours. Macros are three ink bars of different lengths with mono labels.

## Materials and depth

- Content is flat. Separation is hairline and whitespace, not shadow. The only shadow in the app is under the floating cook bar on recipe detail, and the system draws it.
- iOS 26 Liquid Glass is used where the system puts it: tab bar, navigation bar, the floating "Cook with LeChef" bar (a `glassEffect` capsule over scrolling content). No glass panels inside content. No custom blur. No glass in cook mode at all; the hob is matte.
- Cards exist only when the thing is a card: a cook from your table, a timer tile. Lists are rows with hairlines. The recipe is a document, not a stack of cards.
- Radii: 10 (buttons, chips), 14 (photos, cook cards, timer tiles), 0 (rows), 36 (sheets, system). Nothing between 16 and 36.
- Photos get a 0.5 pt ink stroke at 8% opacity so a white plate never bleeds into the page.

## Density

Two spacing systems, chosen by what the screen is for.

- Deciding (Tonight hero, cook-mode step, cook-complete): generous. 24 side margin, 32 between blocks, 48 above the primary action. One thing per screenful.
- Everything else (Kitchen, scan review, ingredient lists, taste profile, table): dense. 20 side margin, 44 pt rows, 12 within a row, 8 between chips, 24 between sections. The eye should be able to scan 12 rows without scrolling.

The current `AppTheme.Space.page = 24` everywhere is one reason lists feel padded and the hero feels cramped at once.

## Iconography

SF Symbols only, regular weight, matched to the adjacent text size (20 pt in rows, 24 pt in the tab bar), monochrome ink. No multicolor symbols, no custom icon pack, no ingredient sprites in lists (text is faster to scan than 50 tiny line drawings of vegetables; `FLIcon` sprite resolution stops being used in UI). No sparkle glyph anywhere near LeChef; its mark is the word "LeChef" in the section-label style.

## Imagery

- Recipe photos: overhead, hard daylight, matte, no props, 4:5 on Tonight and recipe detail, 1:1 on cook cards and lists. One crop ratio per context so a scroll of cards lines up.
- Text never sits on a photo. No bottom gradient scrim. Captions go below.
- No photo is not an error. The title at display size on paper is the fallback, and it should look designed, not missing. No grey placeholder illustration.
- User photos from cook-complete: shown as taken, 1:1 crop, same 0.5 pt stroke, no filter.
- Never: stock photos with hands, AI-rendered dishes with that wet sheen, illustrated food.

## Motion

Five tokens replace `AppMotion.swift`. Any animation that needs a sixth is probably decoration.

| Token | SwiftUI | Web mock | Use |
| --- | --- | --- | --- |
| snap | `.spring(duration: 0.22, bounce: 0)` | 200 ms `cubic-bezier(.23,1,.32,1)` | Selection, chip toggle, row check, segment move, step change by voice |
| move | `.spring(duration: 0.34, bounce: 0.12)` | 320 ms `cubic-bezier(.32,.72,0,1)` | Sheet detents, push to recipe, cook card expand, timer tile add |
| settle | `.spring(duration: 0.50, bounce: 0.22)` | 480 ms spring approximation | Drag release only: sheet flick, swipe-to-remove, timer-done ring |
| fade | `.easeOut(duration: 0.15)` | 150 ms `ease` | Colour and opacity crossfades, content swap under a stable frame |
| none | `.none` | none | Tab switch, keyboard, anything a user does more than 20 times a session |

Principles, with where they come from.

- Frequency decides first (emil-design-eng). "Next step" happens 8 to 12 times per cook with wet hands: snap, no slower. Tab switches: none. Cook-complete happens once a day: it may take 500 ms and have one bounce.
- Enter with ease-out, exit faster than enter. Sheets in at 320, out at 240. Rows in with 200, out with 150.
- Press feedback on every pressable: scale 0.97 over 120 ms, back with snap. Rows included.
- Nothing scales from 0. Enter from scale 0.96 and opacity 0.
- Stagger 40 ms, capped at 6 items, never blocking input. Beyond 6, items simply appear.
- Transitions over keyframes for anything that can be interrupted (sheet detents, chip reflow).
- Only transform and opacity animate. Heights animate via a container that clips a transform.
- Timers are linear. A ring that eases is lying about time.
- The voice indicator is driven by real input amplitude. If there is no amplitude (muted, offline), it is a static shape, not a fake pulse.
- No counting-up numbers except once, on cook-complete, for kcal.
- Reduced motion: transforms become opacity-only fades at 150 ms; stagger goes to 0; the timer ring still moves because it is information; press scale stays (it is 120 ms and confirms the tap).
- Haptics pair with motion: light on confirm row and chip, medium on "Add to kitchen" and cook-complete, rigid on timer done.

## Components that carry the identity

Build these first; the rest of the system follows from them.

1. **Fit meter.** m small squares, n filled ink, the rest hollow with rule-2, plus a mono "9 of 10" and a secondary "1 swap". Appears on Tonight, recipe detail, cook cards, and the Table. It is the one glyph that makes the app's promise visible.
2. **Quantity row.** Name left in body, quantity right in mono, state square at the leading edge, 44 pt, hairline. Used in scan review, recipe detail, Kitchen.
3. **Timer tile.** 14 radius, hob surface, label in caption, digits in mono 56 yolk, a thin ring that depletes linearly. Tap pauses, long-press removes.
4. **Cook card.** Photo 1:1 or none, name in body semibold, who and when in caption, the one-line note in body as a quote, the viewer's own fit meter, one button.
5. **Taste sentence.** A sentence in body, evidence count in mono caption, Right / Wrong as two small secondary buttons; on Wrong the row greys and reads "Won't use this" with Undo.

## Avoid

The presence of any item here is a bug.

- Cream background with terracotta and a serif (the current look).
- Glass cards, frosted panels, or custom blur inside content.
- Mesh or linear gradients behind heroes, on buttons, or as text fills.
- An orb nav, a floating centre button that lifts above the bar, or a bar with a notch.
- Confetti, streak flames, trophies, badges.
- A sparkle icon, "AI" as a label, the word "magic".
- Greeting copy ("Good evening, Sam") and motivational copy ("You've got this").
- More than two typefaces. Rounded design on numerals.
- Radius above 16 on anything inside content.
- Pill tags in several colours; colour-coded macro rings.
- Skeleton shimmer loops. Loading is a static layout plus one thin indeterminate line.
- Numbered eyebrows (01, 02, 03) on anything that is not a sequence. Cook-mode steps are a sequence and are numbered; nothing else is.
- Photo cards with a gradient scrim and white text.
- Illustrated mascots or an avatar for LeChef.
- Percentages for fit, confidence, or taste.
- Emoji as icons.

## Where the skills were applied

**frontend-design.** Direction stated in one line and carried across light and hob so no two screens could belong to different apps. One risk (yolk, mono numerals as the typographic voice) with the rest kept quiet. Type chosen for the subject (what you read from arm's length), not from the default menu. Copy written as verbs the user controls: "Cook this", "Add 14 to kitchen", "Something else", "Won't use this". Structural devices encode something true: step numbers only in cook mode, counts only when real.

**emil-design-eng.** The frequency table drove every duration (next-step at 200, tab switch at 0, cook-complete at 500). Ease-out enters, faster exits, 0.97 press on all pressables, no scale-from-zero, 40 ms stagger capped at six, transitions over keyframes for interruptible UI, transform-and-opacity only, origin-aware popovers (the substitution popover on recipe detail grows from its row, not screen centre), tooltips skipped, reduced motion as fewer and gentler rather than none.

**holistic-ux.** Iceberg: "ugly" is the event; the pattern is five competing blocks on Home; the structure is three products in one shell; the mental model was "track everything", replaced with "decide tonight". Jobs per destination, one question each. Hick's law on Tonight: one pick, two alternatives, not a grid. Fitts's law in cook mode: 64 pt targets because hands are wet. Miller's law in scan review: the three uncertain rows come first and alone; the eleven sure rows are a list you skim. Peak-end: the peak is the timer going off at the right moment; the end is the cook-complete screen, kept quiet and short. Backstage mapped for the places trust is won or lost: timers on device, step state persisted, Live session drop handled in one line, counts hidden under ten. Empty, loading and error states written as directions, in the interface's voice, on every mock.
