# Part 2 delivery: Tonight + Kitchen (provisional Direction H)

Scope, architecture rules and verification plan live in PR #97. This
branch is stacked on `overhaul/design-system` (FLDesignTokens +
FLDesignSystem at `ba95187`). Screen packages land under `packages/`,
consuming theme tokens only — nothing hard-coded.

Shell (fix 3): native iOS 26 `TabView`; default four tabs (Tonight,
Kitchen, Explore, Cookbook) + Scan as search-role trailing tab
(custom label/icon verified supported); Shell S as the alternate
configuration. Photo rule (fix 1): 3:2, capped at 40% height.

## Addendum: FIX-review corrections (honest claims, same screens)

The FIX review at `f25fe74` found places where the screens claimed more
than their state knew. The fixes change what states assert — not the
layout. (1) A servings change on Tonight no longer edits the displayed
servings while silently keeping the old fit bill: the bill is typed
`Pick.FitStanding` — `.current` or `.pendingRecalc` — and any actual
clamped servings change marks it pending. While pending the sufficiency
line is replaced by recalculation copy, the count meter and the sparse
"You'd need" list are hidden, and the cook primary renders disabled
(`primaryAction == .cookPendingRecalc`); only a host replacement of the
whole pick restores a current bill. (2) Tonight actions now render a
typed decision-state contract (`primaryAction`) instead of keying
"Cook this" off `carriedPick`: an unknown kitchen — whose example pick
was wrongly surfacing as cookable — offers the scan / add-by-name entry
pair with no cook claim; sparse states offer the shopping list;
nothing-feasible offers the swap wording only when the host's swap
coverage covers every shortfall ("Cook with N swaps"); and
"Choose tomorrow" is bound to the state's always-true promise, which the
view now renders in every decision state (the unknown-without-example
state previously broke it). (3) Lesser fixes: Kitchen clears the stale
notice only when a reconciliation settles (Still there / Gone) — a
requested scan no longer clears it, so a cancelled scan cannot leave the
warning falsely gone; TonightFit swap grammar requires validated
per-shortfall coverage (`SwapCoverage(coversLine:)` →
`completingSwapCount`), so two shortages plus one unrelated swap no
longer read "complete with swaps"; and the view's resume bar now reads
the state field that exists (`activeCook`), repairing pre-existing
drift in the unverified native file. Tests: FLScreens 62 (31 Tonight,
16 Kitchen, 12 support, 3 lint) + FLDesignTokens 27, all Linux-swift
verified; the SwiftUI files remain UNVERIFIED-NATIVE (Linux builds them
as an empty module).
