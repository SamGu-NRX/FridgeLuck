# FLCommunityCore frozen fixtures

Cross-language contract fixtures for the community package, in the same
pattern as `FridgeLuckCore/Fixtures/`. Each file is the **canonical JSON
encoding** of one domain value: sorted keys, pretty-printed, UTC millisecond
timestamps (`FLTimestamp`).

| file | kind | what it freezes |
|---|---|---|
| `shared-cook.json` | `SharedCook` | The redacted shared-cook wire shape: full revision with license evidence, servings, swaps (with necessity), rating, one-line note, calendar day. No pantry, health, taste data, or exact times. |
| `challenge-progress.json` | `ChallengeProgress` | Challenge progress derived from cook records: two qualifying cooks (distinct revisions), one repeat excluded as `duplicateOfCountedRevision`, completion at the crossing cook. |
| `profile-edit-event.json` | `PreferenceEvent` | A `profileEdit` event with `sentenceID` and verdict `.corrected`, superseding the prior event (`EventCorrection`, mode `.corrects`). |

The manifest (`manifest.json`) lists schema (`flcommunity.v1`) and every
fixture; `FixtureContractTests` asserts the manifest covers the directory
exactly and that each file decodes to a freshly built value and re-encodes to
the same bytes.

## Regenerating

```sh
FL_UPDATE_FIXTURES=1 swift test --filter FixtureContractTests
```

Regeneration is a contract change: commit the diff and review every byte.
Anything that consumes these files from another language must be updated in
the same change.
