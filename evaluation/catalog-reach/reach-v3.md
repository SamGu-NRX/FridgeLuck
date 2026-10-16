# Catalog reach v3: the app's own lookup over ten written pantries

Pantry items resolve through a replay of `IngredientRepository.search`
(SQLite substring LIKE over name/description/notes/alias; exact-name, then
name-prefix, then name; first result). A recipe line is in the kitchen only
when its key bridges to the same app ingredient id the first search result
holds. Before: shipped data with the strict-precedence bridge. After: cited
alias/name/row repairs plus the union identity bridge.

## Diet-eligible cookable recipes (median across the 10 pantries)

| diet | before exact | after exact | before near | after near | near delta |
|---|---|---|---|---|---|
| omnivore | 0.5 | 4.5 | 101.0 | 162.5 | +61.5 |
| vegetarian | 0.5 | 1.5 | 54.0 | 93.5 | +39.5 |
| vegan | 0.0 | 0.0 | 22.5 | 29.0 | +6.5 |
| gluten_free | 0.0 | 2.5 | 42.5 | 76.0 | +33.5 |
| dairy_free | 0.0 | 2.0 | 44.5 | 78.0 | +33.5 |

## Lost required lines by class (before-state classification)

| class | lines | distinct recipes hit (across pantries) |
|---|---|---|
| (a) pantry name finds no app ingredient | 535 | 30 |
| (b) search lands on a different id of the same food | 2037 | 170 |
| (c) recipe key has no bridge | 1220 | 46 |
| genuinely not in the kitchen | 28123 | 960 |

## Remaining unresolved pantry items (after)

- chocolate chips
- cream of mushroom soup
- garam masala
- hot dogs
- instant ramen
- saltine crackers
- vanilla extract

## Remaining unbridged keys (after)

- none
