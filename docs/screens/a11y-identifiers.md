# Proposed accessibility identifiers — all FLScreens screens

(Part 6 adds Shell S's kitchen composition, Progress and Profile, and
the quests and tour CANDIDATE screens; the earlier sections are
unchanged. Part 7's cross-screen polish adds exactly ONE identifier:
Explore's screen title (`fl.explore.title`) — the plain large-title
header Part 3's notes had already recorded as the mock adaptation; it
now exists in the view. No other identifier changed. Part 7 also marks
the screen-title elements as accessibility headers
(`.accessibilityAddTraits(.isHeader)`) — a trait, not an identifier, so
it is not a table row anywhere.)

**Status: PROPOSAL, not an agreement.** The evaluation `CONTRACTS.md` is
absent on alpha, so nothing here has been agreed with the evaluation
side. These are the `fl.`-prefixed identifiers the FLScreens views set
today, offered for confirmation. Nothing should key on them (tests,
automation, XCUITest) until evaluation confirms this file. If evaluation
proposes different names, the views change — the identifiers are
one-line edits by design. (Extended in Part 3 with the Explore feed,
the beta Table screens and the Recipe document — same conventions,
same open questions. Extended again in Part 4 with the Scan
capture-and-review flow and the taste profile — same conventions,
and one new interpolation note per screen below. Extended once more in
Part 5 with the LeChef cook mode — a presentation/destination the host
presents from a recipe or from Tonight, never a tab — same conventions,
plus its own interpolation note.)

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

## Explore (`FLExplore`)

Identifiers below follow the same conventions. The feed's per-item ids
are the recipe ids the host supplied (`Row.id`), so automation targets a
recipe, not a position; section ids are the band raw values, so a
renamed section heading does not break a query.

| Identifier | Element | Notes |
|---|---|---|
| `fl.explore.screen` | The Explore root container | |
| `fl.explore.title` | Screen title ("Explore") | Part 7: the large-title header, matching the mock's h1 |
| `fl.explore.search` | The search field | Query text is read from the field's value, never from the identifier |
| `fl.explore.filter.<rawValue>` | One filter chip | `.canCookNow`, `.underThirtyMinutes`, `.vegetarian`; selected state is a trait, not a name |
| `fl.explore.section.<band>` | A feed section container | Bands: `.madeForYourFridge`, `.canCookNow`, `.oneSwapAway`, `.moreToCook` |
| `fl.explore.row.<recipeId>` | One recipe row | e.g. `fl.explore.row.noodles` |
| `fl.explore.withdraw` | "Withdraw" (a row in review) | On the row's own draft, only visible to its author |
| `fl.explore.tableEntry` | The "Community tables" entry row | Present only while the beta flag is on — its absence is the off state |
| `fl.explore.loading` | The late-rows loading line | Over the last valid list |
| `fl.explore.zeroHits` | The zero-hits container | States the query, offers "Clear" |
| `fl.explore.clearFilters` | "Clear" (zero-hits action) | Keeps the query |
| `fl.explore.empty` | The empty state (nothing published) | Distinct from zero hits |

## Table (`FLExplore`, reached from Explore behind the beta flag)

The beta entry row lives in Explore (`fl.explore.tableEntry`); Table is
not a tab, so its identifiers use `fl.table.` while it renders inside
the Explore navigation context. Cook ids come from the host.

| Identifier | Element | Notes |
|---|---|---|
| `fl.table.screen` | The Table root container | |
| `fl.table.title` | Screen title ("Community tables") | |
| `fl.table.subtitle` | The quiet beta line under the title | Also names the BETA badge's container |
| `fl.table.asOf` | The provenance line ("As of 18:40") | Offline rows keep their timestamp |
| `fl.table.weekSummary` | The week's cook summary line | |
| `fl.table.loading` | The late-rows loading line | |
| `fl.table.offline` | The offline notice | With `fl.table.retry` |
| `fl.table.retry` | "Try again" (offline action) | |
| `fl.table.card.<cookId>` | One cook card container | Tap opens the detail state |
| `fl.table.cardButton.<cookId>` | The card's fit action ("Cook it at 2") | Derived servings, never a guess |
| `fl.table.share.<cookId>` | The card's "Share" action | |
| `fl.table.start` | "Start tonight" | |
| `fl.table.join` | "Join the table" (empty, no members) | |
| `fl.table.invite` | The invite panel container | |
| `fl.table.inviteRow` | One pending-invite row | |
| `fl.table.challenge` | The weekly challenge container | |
| `fl.table.challengeTitle` | The challenge's title line | |
| `fl.table.challengeJoin` | "Count me in" (challenge join) | |
| `fl.table.notesLabel` | The notes section heading | |
| `fl.table.note.<noteId>` | One cook note | |
| `fl.table.shareTitle` | The share-preview sheet title | |
| `fl.table.shareFields` | The preview's frozen fields container | Exactly what leaves the phone |
| `fl.table.sharePrivacy` | The share privacy line | |
| `fl.table.shareConfirm` | The share confirm action | |
| `fl.table.shareCancel` | The share cancel action | |

## Recipe (`FLRecipe`)

| Identifier | Element | Notes |
|---|---|---|
| `fl.recipe.screen` | The Recipe root container | |
| `fl.recipe.hero` | The hero photo area | 3:2, capped at 40% of container height (`PhotoLayoutRule`) |
| `fl.recipe.title` | The recipe title | |
| `fl.recipe.byline` | The publisher/revision line | |
| `fl.recipe.stats` | The fit + minutes stats line | |
| `fl.recipe.servingsRow` | The servings stepper container | |
| `fl.recipe.servingsMinus` | Servings − button | |
| `fl.recipe.servingsValue` | Servings value | |
| `fl.recipe.servingsPlus` | Servings + button | |
| `fl.recipe.primaryAction` | **Primary action: "Cook for N"** | N follows the stepper |
| `fl.recipe.ingredientsLabel` | The ingredients section heading | |
| `fl.recipe.ingredient.<ingredientId>` | One ingredient row (at current servings) | e.g. `fl.recipe.ingredient.udon` |
| `fl.recipe.swap.<ingredientId>` | The row's swap line ("no udon? spaghetti") | |
| `fl.recipe.method` | The method section heading | |
| `fl.recipe.stepCount` | "Step 2 of 6" | |
| `fl.recipe.step.<stepId>` | One step's body text | |
| `fl.recipe.stepNote.<stepId>` | The step's cook note (when present) | |
| `fl.recipe.next` | "Next step" | |
| `fl.recipe.skip` | "Skip to the end" | |
| `fl.recipe.tipsLabel` | The notes & tips heading | |
| `fl.recipe.tip.<index>` | One tip line | Positional: tips are copy, not host records |
| `fl.recipe.relatedLabel` | The related-recipes heading | |
| `fl.recipe.related.<recipeId>` | One related-recipe row | |
| `fl.recipe.recordTitle` | The record sheet's title | |
| `fl.recipe.rating.<star>` | One rating star (1–5) | Selected count is a trait/value, not a name |
| `fl.recipe.differently` | "Cooked it differently?" text input | |
| `fl.recipe.recordPrivacy` | The record's privacy line | |
| `fl.recipe.recordSave` | "Save" (record sheet) | |
| `fl.recipe.recordShare` | "Share to a table" (record sheet) | Never auto-shares |

## Scan (`FLScan`)

The grocery capture-and-review destination (mock: `scan-review.html`).
Its stages share one prefix; stage-specific identifiers exist for every
element the stage shows.

| Identifier | Element | Notes |
|---|---|---|
| `fl.scan.screen` | The Scan destination container | |
| `fl.scan.title` | Screen title ("Scan") | |
| `fl.scan.start` | **Primary action: "Start scanning"** (idle) | Opens the capture stage |
| `fl.scan.idleCaption` | The idle explainer line | "Point at a shelf of groceries and I'll read it. Add by hand any time — both count the same." |
| `fl.scan.addByName` | "Add by name" (idle) | Ranks equal to scanning, as in Kitchen |
| `fl.scan.capture` | The capture-stage container | |
| `fl.scan.shutter` | The shutter button | Apple-gated camera capture behind `canImport` |
| `fl.scan.preview` | The captured photo preview | |
| `fl.scan.captureClose` | Close/cancel capture | Returns to the landing, keeps nothing |
| `fl.scan.qualityIssue` | The capture-quality notice over the photo | "Too dark to read" / "Too blurry" — a notice, never an alert |
| `fl.scan.retake` | "Retake" | |
| `fl.scan.addByHand` | "Add by hand" (capture stage) | Reveals the manual-entry row |
| `fl.scan.addByNameRow` | One manual-entry row | Shared row; ids stay positional-free |
| `fl.scan.cameraRefused` | The camera-refused notice | "The camera didn't open. Add by hand any time." — an escape, not a dead end |
| `fl.scan.analysing` | The analysing container | |
| `fl.scan.analysingPhoto` | The photo being read | |
| `fl.scan.analysingTitle` | "Looking" headline | |
| `fl.scan.progressLine` | The indeterminate progress line | One hairline under the title; still under reduce motion |
| `fl.scan.review` | The review-stage container | The mock's review screen |
| `fl.scan.count` | The header count | "9 seen · 7 sure" — the only tallies besides quantities |
| `fl.scan.looksRight` | The "Looks right" rows container | |
| `fl.scan.looksRightLabel` | The "Looks right" heading | |
| `fl.scan.looksRightCount` | The sure count beside the heading | |
| `fl.scan.item.<itemId>` | One sure row | Quantity rides `accessibilityValue`, not the label |
| `fl.scan.receiptLine.<itemId>` | The row's receipt-line provenance (when present) | |
| `fl.scan.duplicateNote.<itemId>` | The duplicate notice | "In your kitchen already — a scan never adds" |
| `fl.scan.duplicateStill.<itemId>` | **"Still N" reconciliation chip** | Observes; never adds on its own |
| `fl.scan.duplicateBoughtMore.<itemId>` | **"Bought more" reconciliation chip** | |
| `fl.scan.needsYou` | The "Needs you" rows container | |
| `fl.scan.needsYouLabel` | The "Needs you" heading | |
| `fl.scan.needsYouCount` | The needs-you count | |
| `fl.scan.uncertain.<itemId>` | One uncertain row container | |
| `fl.scan.uncertainLine.<itemId>` | What the scan saw ("Leafy, pale stems, top shelf.") | |
| `fl.scan.uncertainOption.<itemId>.<index>` | One name option for the row | Positional options: option ids are capture-local, not host records |
| `fl.scan.uncertainNeither.<itemId>` | "Neither" | Removes the misread from the scan |
| `fl.scan.dock` | The commit dock container | The Scan flow's commit dock inside the screen — **not** the shell's tab dock |
| `fl.scan.confirm` | **Primary action: "Add N to kitchen"** | The confirm-to-pantry commit; "Adding…" while saving |
| `fl.scan.confirmCaption` | The dock caption | "Tonight's pick updates when you do." |
| `fl.scan.committed` | The committed confirmation line | "Added to your kitchen." |
| `fl.scan.commitError` | The commit-failed notice | "Couldn't save. Nothing changed — try again." — state returns to review |
| `fl.scan.problem` | The problem container (recognition failed) | The photo is kept; nothing is lost |
| `fl.scan.problemPhoto` | The kept photo on the failure panel | |
| `fl.scan.problemSection` | The problem panel heading | |
| `fl.scan.retry` | "Try again" | Re-runs recognition on the kept photo |
| `fl.scan.problemAddByName` | "Missed something? Add by name" (problem panel) | Recognition failure ends in manual entry, never a dead end |
| `fl.scan.plateOffer` | The plate-switch offer line | "This looks like a meal. Log it instead?" — shown until answered, never auto-applied |
| `fl.scan.plateYes` | "Yes" on the plate offer | Yes is host-routed (`.logMeal`); the scan never auto-switches |
| `fl.scan.plateNo` | "No" on the plate offer | Dismisses the offer |

## Taste profile (`FLTasteProfile`)

The on-device taste editor (mock: `taste-profile.html`). Per-sentence and
per-note identifiers append the sentence's or memory's stable id
(`fl.taste.sentence.s2`), so automation targets a row, not a position.

| Identifier | Element | Notes |
|---|---|---|
| `fl.taste.screen` | The taste-profile destination container | |
| `fl.taste.title` | Screen title ("Your taste") | |
| `fl.taste.cooks` | The cook-count context line | "Over 23 cooks" — host-verbatim evidence grammar |
| `fl.taste.newUser` | The new-user explainer container | Shown before there is anything to edit |
| `fl.taste.learnedLabel` | The "What I've learned" heading | |
| `fl.taste.sentences` | The taste-sentence list container | |
| `fl.taste.sentenceRow.<sentenceId>` | One sentence's row container | |
| `fl.taste.sentence.<sentenceId>` | One sentence's text | |
| `fl.taste.evidence.<sentenceId>` | The sentence's evidence tag | "18 of 23" |
| `fl.taste.confirmed.<sentenceId>` | The sentence's confirmed state line | "Won't use this." confirms a rejected read |
| `fl.taste.rejected.<sentenceId>` | The sentence's rejected state line | |
| `fl.taste.sentenceUndo.<sentenceId>` | "Undo" on a changed judgement | Undoes exactly one judgement |
| `fl.taste.sentenceRight.<sentenceId>` | "Right" | Confirms the sentence |
| `fl.taste.sentenceWrong.<sentenceId>` | "Wrong" | Rejects the sentence |
| `fl.taste.offerSuggest.<sentenceId>` | "Suggest some" (offer) | Host-routed to Explore's filter |
| `fl.taste.offerDecline.<sentenceId>` | "Not interested" (offer) | Declines this once |
| `fl.taste.offerNever.<sentenceId>` | "Never suggest" (offer) | Suppresses the prompt for that sentence kind |
| `fl.taste.restrictions` | The restrictions container | Filtered before ranking, per product law |
| `fl.taste.restriction.<restrictionId>` | One restriction row | |
| `fl.taste.restrictionField` | The new-restriction text field ("Restriction name") | |
| `fl.taste.restrictionAddApply` | The add-restriction "Add" button | Blank names are refused |
| `fl.taste.restrictionAdd` | "Add restriction" | |
| `fl.taste.memories` | The remembered-notes container | |
| `fl.taste.memoriesLabel` | The "LeChef remembers" heading | |
| `fl.taste.memoriesCount` | The "N seen" count line | |
| `fl.taste.memoriesEmpty` | The "Nothing remembered yet." line | |
| `fl.taste.memoryRow.<memoryId>` | One memory's row container | |
| `fl.taste.memory.<memoryId>` | One memory's text | |
| `fl.taste.memoryDish.<memoryId>` | The memory's dish line (when present) | |
| `fl.taste.forgetReceipt` | The post-forget receipt ("Forgotten.") | |
| `fl.taste.forgetUndo` | "Undo" on the receipt | Restores exactly the forgotten note |
| `fl.taste.setup` | The setup summary container | Restrictions + setup at a glance |
| `fl.taste.setupLabel` | The setup heading ("What you told me at setup") | |
| `fl.taste.setupSummary` | The setup summary text | "Set in setup. Edited there, never here." |
| `fl.taste.setupEdit` | "Edit" (setup summary) | Opens the restrictions-and-setup editor |
| `fl.taste.savePending` | The unsaved indicator | "Changes not saved yet." |
| `fl.taste.saveError` | The save-failed notice | "Couldn't save. Changes kept — try again." |
| `fl.taste.forgetAll` | "Forget everything" | Confirmation-gated in the view, not a tap-through |
| `fl.taste.forgetAllPrompt` | The forget-all confirmation container | |
| `fl.taste.forgetAllConfirm` | The confirmation's "Forget everything" | Preserves restrictions by design |
| `fl.taste.forgetAllCancel` | The confirmation's "Keep everything" | |
| `fl.taste.export` | "Export everything I know about you" | |
| `fl.taste.footer` | The on-device footer line | |

## LeChef (`FLLeChef`) — the cook mode

A mode the host presents (full screen, sheet or navigation destination)
from a recipe or from Tonight's pick — never a tab. One screen hosts
five stages (cooking, parked, look viewfinder, complete, cancelled);
stage-specific containers are prefixed per stage below. Interpolation
note: like Parts 3–4, per-object identifiers append a stable id —
proposals use the queue's proposal ids, timers the timer ids, progress
segments and stars their 1-based numbers (`fl.lechef.progress.3`,
`fl.lechef.rating.star.5`). Proposal and timer ids are host/queue
vocabulary; if evaluation needs a fixed vocabulary, the ids go into
fixtures, not the views.

| Identifier | Element | Notes |
|---|---|---|
| `fl.lechef.screen` | The whole cook-mode destination | The presentation seam's anchor |
| `fl.lechef.idle.title` | Idle entry title (no recipe handed over) | Host must dispatch `.enter` to leave idle |
| `fl.lechef.idle.caption` | Idle caption | |
| `fl.lechef.offline` | The "LeChef is offline. Steps and timers still work." notice | The local-core promise, stated in the UI |
| `fl.lechef.dishTitle` | The dish name (cooking) | |
| `fl.lechef.leaveCook` | The X ("Leave cook") | Parks the session; a11y label "Leave cook" |
| `fl.lechef.progressLine` | The "Step 3 of 6" line | |
| `fl.lechef.progress` | The progress segments container | |
| `fl.lechef.progress.<n>` | One progress segment | a11y label "Step n"; `.isSelected` marks the current step |
| `fl.lechef.stepCard` | The step card container | Children combined for VoiceOver |
| `fl.lechef.stepBody` | The step's text | |
| `fl.lechef.checkLine` | One fired timer check line ("Rice done — stir the sauce in") | Never advances a step by itself |
| `fl.lechef.back` | "Back" (secondary) | Never before the first step |
| `fl.lechef.addTimer` | The add-timer tile | Host presents the duration picker; the state machine owns the timer |
| `fl.lechef.next` | "Next" — "Done cooking" on the last step (primary) | On the last step it completes the cook |
| `fl.lechef.timers` | The timer strip container | Shared `FLTimerTile`s |
| `fl.lechef.timerTile.<timerId>` | One timer tile | Tap pauses/resumes, long-press removes |
| `fl.lechef.panel` | The proposals panel container | |
| `fl.lechef.panelCard` | One panel card | |
| `fl.lechef.mutationFailed` | The "couldn't apply that" line | Approved mutations that failed return to pending |
| `fl.lechef.proposal.<proposalId>` | One proposal card | Reads and mutations render the same grammar |
| `fl.lechef.timerChip` | The timer suggestion's chip ("Set 2 min timer") | Routes to the LOCAL timer path — no approval ceremony |
| `fl.lechef.applied` | The "Done" mark on an applied read | Reads apply without ceremony |
| `fl.lechef.approve` | "Approve" (a mutation) | The only approval path — voice can never approve |
| `fl.lechef.decline` | "Not now" (a proposal) | |
| `fl.lechef.voice` | The voice row ("Voice off — Just the steps") | OFF is the default until a cost budget exists |
| `fl.lechef.voiceToggle` | The row's "Turn on"/"Turn off" action | Opt-in per cook; a reopen starts silent again |
| `fl.lechef.voiceHint` | The five-word grammar hint (voice on) | On-device vocabulary; works offline |
| `fl.lechef.chatField` | The chat text field (voice on) | The fallback, behind the toggle; a11y label "Ask LeChef" |
| `fl.lechef.chatSend` | The chat send button | |
| `fl.lechef.transcriptTurn` | One live transcript turn | Live session only — never persisted |
| `fl.lechef.viewfinder` | The look viewfinder overlay | Push-to-look is the built candidate |
| `fl.lechef.lookCaption` | The look contract caption ("Camera look: one frame, viewfinder visible, never a safety verdict.") | |
| `fl.lechef.lookProblem` | The look problem line ("Couldn't send that look. Try again or keep cooking.") | An escape line, never a dead end, never a verdict |
| `fl.lechef.lookFrame` | The shutter ("Send one frame") | Explicit capture |
| `fl.lechef.lookClip` | "3-second clip" | Explicit capture, capped at 3 s |
| `fl.lechef.lookSend` | "Send" (upload the capture) | Explicit upload |
| `fl.lechef.lookUploading` | The uploading indicator | |
| `fl.lechef.lookRetry` | "Try again" (upload failed) | The capture is the host's to hold |
| `fl.lechef.lookCancel` | "Cancel" (the look) | Nothing was sent; also closes a completed look |
| `fl.lechef.paused.title` | The parked session's title | |
| `fl.lechef.paused.caption` | The parked session's caption | |
| `fl.lechef.paused.progress` | The parked session's progress line | |
| `fl.lechef.resume` | "Resume cooking" | Timers keep their device deadlines |
| `fl.lechef.cancelCook` | "Cancel this cook" | Nothing is recorded for a cancelled session |
| `fl.lechef.complete.title` | The complete surface's title | The mock's serif title has no token role; uses `.screenTitle` |
| `fl.lechef.complete.subtitle` | The complete surface's subtitle | |
| `fl.lechef.duration` | The "Cooked in 24 min · 2 servings" line | Live-session arithmetic — absent on a restored session |
| `fl.lechef.rating` | The rating stars container | |
| `fl.lechef.rating.star.<star>` | One star, 1...5 | a11y label "Rate n of 5"; `.isSelected` marks the current |
| `fl.lechef.note` | The note editor | A draft until the explicit save |
| `fl.lechef.sayIt` | "Say it instead" (voice note draft) | Host runs the draft flow; the transcription is a draft |
| `fl.lechef.save` | "Save" | The explicit save; idempotent while in flight |
| `fl.lechef.receipt` | The saved receipt ("Saved on this phone.") | |
| `fl.lechef.saveFailed` | The save-failed line ("Couldn't save just now — it's all still here. Try again.") | Everything kept; try again |
| `fl.lechef.privacy` | The privacy line (nothing leaves the phone) | |
| `fl.lechef.nutrition` | The complete surface's nutrition line | Host verbatim, never derived |
| `fl.lechef.done` | "Done" (dismiss the mode) | The host dismisses; the snapshot clears |
| `fl.lechef.cancelled` | The cancelled-session container ("Nothing was saved. Start again from the recipe whenever you like.") | States what was (and was not) kept |

## Shell S kitchen composition (`FLKitchen`, alternate configuration)

Shell S presents the SAME `KitchenView` with alternate chrome around
it — these identifiers belong to the composition, never to Kitchen
itself (Kitchen's own ids are unchanged under either configuration).

| Identifier | Element | Notes |
|---|---|---|
| `fl.kitchen.shellSScreen` | The Shell S kitchen composition root | Same `KitchenView` inside |
| `fl.kitchen.shellSExplore` | The "Explore recipes" access row | Shell S has no Explore tab; Explore is reached from here |

## Progress under Shell S (`FLProgress`)

Shell S's second tab. All values are host-supplied; the counters row is
structured counts, never personal rows.

| Identifier | Element | Notes |
|---|---|---|
| `fl.progress.screen` | The Progress root container | |
| `fl.progress.title` | Screen title ("Progress") | |
| `fl.progress.weekLabel` | The host's week label line | |
| `fl.progress.counters` | The counters row (cooks · recipes · food saved) | Saved grams render through the shared `FLSavedFoodLine` |
| `fl.progress.weekSection` | The "Your week" section container | |
| `fl.progress.weekRow.<cookId>` | One week row | e.g. `fl.progress.weekRow.mon` |
| `fl.progress.asOf` | The provenance line ("As of 18:40") | |
| `fl.progress.questsEntry` | The "Weekly quests" entry row | Present only while the quests CANDIDATE flag is on — its absence is the off state |
| `fl.progress.profileEntry` | The profile entry row | Pushed destination; the host routes |

## Profile (`FLProgress`, pushed from Progress)

Identifiers use `fl.profile.` while the screen lives in the FLProgress
target (the Table precedent: ids name the screen, not the module).

| Identifier | Element | Notes |
|---|---|---|
| `fl.profile.screen` | The Profile root container | |
| `fl.profile.title` | Screen title ("Profile") | |
| `fl.profile.phoneCaption` | The "on this phone" caption | |
| `fl.profile.householdSection` | The household section container | |
| `fl.profile.household` | The household line ("Cooking for 2") | |
| `fl.profile.evidenceSection` | The taste-evidence section container | Hidden while a confirmed forget is undoable; gone for good at expiry |
| `fl.profile.tasteEntry` | The taste profile entry row | Host-routed |
| `fl.profile.cookbookEntry` | The cookbook records entry row | Host-routed; records survive a forget |
| `fl.profile.dataSection` | The data-controls section container | |
| `fl.profile.exportRow` | The export row | Host-routed |
| `fl.profile.signOutRow` | The sign-out row | Host-routed |
| `fl.profile.forgetRow` | The "Forget" row | Present only with taste evidence to forget |
| `fl.profile.forgetConfirm` | The forget confirmation container | |
| `fl.profile.forgetConfirmTitle` | The confirmation's question line | States the size baked into its copy |
| `fl.profile.forgetConfirmButton` | "Forget" (confirm) | |
| `fl.profile.forgetCancelButton` | "Cancel" | |
| `fl.profile.forgetReceipt` | The "Forgotten." receipt | |
| `fl.profile.forgetUndo` | The undo row | Only within the window; expired windows offer no undo |
| `fl.profile.onDeviceLine` | The on-device privacy line | |

## Quests (`FLQuests`) — CANDIDATE, behind a default-off flag

The whole screen exists only while the candidate flag is on: automation
must enable the flag first — the identifiers' absence is the off state,
not a bug.

| Identifier | Element | Notes |
|---|---|---|
| `fl.quests.screen` | The Quests root container | |
| `fl.quests.title` | Screen title ("Weekly quests") | |
| `fl.quests.weekCaption` | The saved-food week caption ("620 g food saved") | Same `FLSavedFoodLine` grammar as Progress |
| `fl.quests.asOf` | The provenance line ("As of 18:40") | |
| `fl.quests.joinReceipt` | The offline-queued receipt ("You're in — this queued while offline.") | |
| `fl.quests.empty` | The empty-quests container | |
| `fl.quests.featuredSection` | The featured-quest section container | |
| `fl.quests.featuredCard` | The featured card container | |
| `fl.quests.featuredTitle` | The featured quest's name | |
| `fl.quests.featuredBrief` | The featured quest's brief | |
| `fl.quests.featuredRules` | The featured quest's rules line | |
| `fl.quests.featuredCooks` | The aggregate cooks line ("14 cooking · 3 cooks made it") | Host counts, never personal rows |
| `fl.quests.rewardChip` | The reward chip ("unlocks an explore filter") | A chip, never points or a currency |
| `fl.quests.doneLine` | The done line ("You made it") | |
| `fl.quests.joinButton` | "Join" | Offline joins queue with the visible receipt |
| `fl.quests.leaveButton` | "Leave" | Quiet — no confirmation dialog |
| `fl.quests.alsoSection` | The "Also this week" section container | |
| `fl.quests.questRow.<questId>` | One other quest row | e.g. `fl.quests.questRow.swap-1` |
| `fl.quests.yourWeekSection` | The "Your week" section container | |
| `fl.quests.weekCounters` | The week counters container | |
| `fl.quests.sharePreviewSection` | The share-preview container | Shows the EXACT payload before anything sends |
| `fl.quests.sharePreview` | The preview's payload lines | The allowlisted fields only |
| `fl.quests.shareConfirm` | "Share" | |
| `fl.quests.shareCancel` | "Cancel" | |

## Tour (`FLTour`) — CANDIDATE, behind a default-off flag

The card exists only while a step is presenting (auto-returns home
between steps); automation must enable the flag and `.start` the tour.

| Identifier | Element | Notes |
|---|---|---|
| `fl.tour.backdrop` | The dimmed backdrop behind the card | |
| `fl.tour.screen` | The tour container | |
| `fl.tour.card` | The promise card | |
| `fl.tour.pager` | The pager line ("1 of 3") | Counts from one |
| `fl.tour.stepTitle` | The step's promise line | Host verbatim |
| `fl.tour.stepBody` | The step's one-or-two sentences | Host verbatim |
| `fl.tour.photo` | The step's decorative photo | 3:2 through `PhotoLayoutRule` |
| `fl.tour.fitBlock` | The fit-meter block (first step) | Hidden when the step carries none |
| `fl.tour.fitCount` | The fit meter ("0 of 24") | |
| `fl.tour.fitLine` | The meter's caption ("starts at zero, grows as it learns") | |
| `fl.tour.privacyBlock` | The step's privacy-lines container | |
| `fl.tour.privacyLine.<offset>` | One privacy line, 0-based | e.g. `fl.tour.privacyLine.0` |
| `fl.tour.back` | The back button | Never goes before the first step |
| `fl.tour.skip` | "Skip" | Always available |
| `fl.tour.primary` | The step's single action | Host-supplied label |
| `fl.tour.footer` | The caption under the pager ("no account needed") | |

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
