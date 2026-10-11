# Part 2 delivery: Tonight + Kitchen (provisional Direction H)

Scope, architecture rules and verification plan live in PR #97. This
branch is stacked on `overhaul/design-system` (FLDesignTokens +
FLDesignSystem at `ba95187`). Screen packages land under `packages/`,
consuming theme tokens only — nothing hard-coded.

Shell (fix 3): native iOS 26 `TabView`; default four tabs (Tonight,
Kitchen, Explore, Cookbook) + Scan as search-role trailing tab
(custom label/icon verified supported); Shell S as the alternate
configuration. Photo rule (fix 1): 3:2, capped at 40% height.
