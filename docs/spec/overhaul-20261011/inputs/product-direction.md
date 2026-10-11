# FridgeLuck product direction

For Sam and whoever implements the overhaul. Answers: what the app is, who it is for, which moments earn it a home-screen slot, and what to stop building. Source read: `apps/ios/DesignSystem/*`, `apps/ios/Feature/{Home,Scan,Recipe,Assistant,Inventory,Progress}`, `planning/stage_2-features_to_build/product-structure-and-feature-redesign.md`, `planning/stage_4-gemini_live/user-direction-and-feature-intent.md`.

## Who it is for

The person standing in front of an open fridge at 6:40 pm on a weekday. They cook most nights for one or two people, shop once a week, and throw out produce they meant to use. They are not meal-prepping from a spreadsheet, not counting macros as a primary hobby, and not browsing NYT Cooking for inspiration. They want the decision made.

That excludes two audiences the current app half-serves: calorie trackers (Cal AI and MyFitnessPal own that, with budgets you cannot match) and recipe browsers (the 166-recipe catalog cannot compete as a catalog). Nutrition stays as a byproduct of cooking. Browsing goes away.

## One sentence

FridgeLuck tells you what to cook tonight from what is actually in your fridge, and gets better at it every time you cook.

## The moments

1. **Zero taps to tonight.** Open the app. The first thing on screen is one dish, the time it takes, and "you have 9 of 10, swap lime for lemon". No greeting, no dashboard, no browsing. The 6:40 pm problem is solved before the thumb moves.
2. **A scan you finish in ten seconds.** The camera finds 14 things, 11 are sure, 3 need a tap each. The sure ones are already in. The screen asks only the three questions it cannot answer.
3. **LeChef takes the timer.** Hands wet, you say "give me eight minutes on the rice". It says "eight minutes" and later "rice is done, stir the sauce in". The first time this works, the app stops being a recipe list.
4. **It says what it learned, and you can say no.** After five cooks: "You've taken coriander out every time. Stop suggesting it?" Tap yes. It never does again, and the profile page shows the sentence with "5 of 5" next to it. The app got to know you in public.
5. **A friend's cook you can make right now.** Maya cooked butter bean curry last night and wrote "add lemon at the end". Your card says "you have everything". One tap and it is tonight's dish, with her note on step 6.

## Where the brief is wrong, or needs narrowing

**The app is three products and the shell shows all three.** Kitchen intelligence, nutrition logging, guided cooking. Each has a home tab's worth of UI. This is the structure under "the UI is ugly": no amount of restyling fixes a home screen that carries a nutrition ring, a tutorial quest, a use-soon alert, a recommendation card and a fallback row at once (`HomeDashboardView` composes all of these). Decision: the app is one product (decide, cook, remember) and nutrition is a line on the cook-complete screen and a lens inside Cookbook. Progress stops being a tab.

**"Community features" as a feed will be dead on arrival.** The earlier planning doc deprioritized social feeds and it was right about feeds. What it missed is that the app already produces a social object for free: a finished cook, with the substitutions you made, your rating, and one line of what you'd change. Nobody has to "post". The model below is built on that object and on small groups, and it must be useful at 1 person, 3 people, and 10,000 people. Design for 3 first.

**Continuous camera is the wrong default for LeChef.** Stage 4 put "continuous camera stream plus voice" as the second priority. A 40-minute cook with the camera streaming means a hot phone, a dead battery by dessert, and a phone that has to be propped facing the hob. Voice is continuous and cheap; camera is on demand ("show me") and lasts a few seconds. Push-to-look, not always-on.

**"Many more recipes" is a structure problem before it is a count problem.** 166 feels like a demo, agreed. But a 2,000-recipe catalog where steps are prose paragraphs cannot drive timers, substitutions, or fit-to-pantry. The bar is structural: every recipe needs ingredient IDs with grams, steps split at the point a timer or a hands-free "next" makes sense, and a tested flag. Target 1,500 structured recipes before launch; a recipe without timers and grams does not ship. LeChef-generated recipes are the long tail, labelled "made for your fridge" and only promoted into the catalog after someone cooks and rates them.

**The gamification in the app rewards the wrong thing.** Streaks, confetti, tutorial quests and spotlight overlays (`FLStreakBadge`, `ConfettiOverlay`, `TutorialQuestCard`, `SpotlightCoordinator`) reward opening and logging. The thing worth rewarding is a finished cook, and the reward is the dish. Cut all of it. The one celebratory moment that stays is cook-complete, and it is quiet.

## Shell

Four tabs plus a scan action, matching the iOS 26 tab bar with a trailing action role.

| Tab | Question it answers | What is on it |
| --- | --- | --- |
| Tonight | What do I cook now? | One pick with reasons and fit, two alternatives, use-soon items, one line from your table, resume-cook bar when a cook is in progress |
| Kitchen | What do I actually have? | Fridge, freezer, pantry; use-soon; needs-a-look queue; assumed staples |
| Table | What are the people I eat with cooking? | Cook cards from your table, notes on recipes you've cooked |
| Cookbook | What have I cooked and what do I like? | Your cooks, saved recipes, your taste profile, nutrition as a lens |
| Scan (action) | | One camera; the app decides whether it saw a shelf, a receipt or a plate and asks if unsure |

LeChef has no tab. It is reachable from Tonight (the pick), from any recipe, and from the Kitchen when you ask "what can I make with this". It is a mode you enter, not a place you visit.

## Learning: the taste profile

The profile is a page of short sentences, each with an evidence count and a Right/Wrong control. That is the whole design. It is readable in ten seconds, every claim shows its receipts, and every claim can be rejected.

What feeds it, in order of weight:
1. Cooks completed (strongest; it is the only signal that costs the user something).
2. Ratings and the one-line note at cook-complete.
3. Substitutions chosen, and ingredients removed from a recipe before cooking.
4. Picks skipped on Tonight (weak; "something else" is pressed for many reasons).
5. What keeps showing up in scans (what you buy).

What never feeds it: location, contacts, calendar, photos outside the app, time-of-day inference beyond "weeknight / weekend", anything from the Table that the user did not do themselves.

How it shows up outside the profile page:
- Tonight: one "why" line under the pick, written as evidence ("you've cooked noodles 4 times this month"), never as flattery ("we think you'll love this").
- Recipe detail: "Why it fits you", two or three lines, each tappable to the profile sentence it came from.
- LeChef: "Last time you said this was too salty, I've cut the soy by a third" at the relevant step.
- The ask: when a pattern reaches five observations, the app asks once, on Tonight, in one line, with Yes / No. It never asks twice about the same thing.

Confidence is expressed in language ("you seem to", "you always"), never as a percentage. Each sentence has "Forget this". The page has "Forget everything" at the bottom. New users (<3 cooks) see one sentence: "Cook three things and I'll start writing this. Until then I'm using what you told me at setup."

## LeChef

LeChef is a cooking companion with five jobs. Chat is the fallback for when none of them fit, hidden behind a transcript toggle.

| Job | Trigger | What it does | What it must not do |
| --- | --- | --- | --- |
| Plan | "What can I make this week?" from Tonight or Kitchen | Three or four dinners from what is on hand plus a short shopping list (under 8 items), ordered so use-soon items go first | Produce a 7-day grid |
| Substitute | "I don't have X" or a missing row on recipe detail | One swap, grounded in the kitchen, with the macro delta if it matters ("lemon for lime: a little sharper, less floral", superseded by SPEC 3.1: swaps describe the difference, never "no change") | Offer five options |
| Coach | In cook mode | Reads the step on request, starts and names timers by voice, answers "how do I know when it's done", looks at the pan on request | Talk unprompted between steps |
| Adapt | Quantity mismatch found at scan or by voice | Rescales the recipe, flags the step that changes ("one breast, so 6 minutes not 8") | Silently change quantities |
| Remember | Cook-complete | Captures the one-line note by voice, files it against the recipe and the taste profile | Ask more than one question |

Cook mode is a screen, not a chat. Current step in large type, timers as first-class objects with their own tiles, voice state as a small indicator, transcript hidden by default. Hands-free vocabulary is five words: next, back, repeat, timer N minutes, show. Targets are 64 pt because hands are wet.

Backstage requirements that decide whether this is trustworthy:
- Timers run on device. A dropped Live session never stops a timer.
- Step state persists. Kill the app at step 4, reopen to step 4 with the timer still counting.
- When Live drops, the screen says so in one line ("LeChef is offline. Steps and timers still work") and voice commands fall back to on-device recognition for the five words.
- Camera look is a single frame or a 3-second clip, sent on request, with a visible viewfinder while it happens.

## Community: tables and cook notes

The unit is a cook, not a post. A cook is: recipe, who, when, substitutions made, rating, one line, optional photo. It is created by finishing a cook. Nobody writes a post.

**Tables.** A table is 2 to 8 people who eat together or near each other: a flat, a couple, two friends who text recipes. You see their cooks, they see yours. Each cook card carries your own fit line ("you have everything" or "missing beansprouts, 1 swap") and a "Cook tonight" button. That button is why the feed is not dead: every card is a decision you can act on with what is in your fridge.

What a table does not have: likes, follower counts, comment threads, hashtags, a discover tab, public profiles, algorithmic ranking. Cards are in time order. The only response to a card is to cook it or save it. If someone wants to say "that looks great", they have iMessage.

**Cook notes.** The aggregate layer. On any recipe you have cooked, the app shows what everyone's cooks say: "212 cooks, 31% swapped lime for lemon, most common note: add the ginger late (41)". This works at scale and is honestly empty below it. Rule: never show a count under 10. Below that, the section reads "Be the first to leave a note" and nothing else. No seeded fake notes, no LeChef-written notes dressed as human ones.

**Why it works at N=1, 3, 10,000.** At one person, Cookbook is your own table: your cooks, your notes. At three, the table is live because three people who cook produce a card a day between them, and every card is actionable. At scale, cook notes make every recipe better. Each layer is useful without the next.

**Invite.** A table is created by one person and joined by code or link. Onboarding never asks you to invite anyone. The first prompt appears after your third cook, once there is something of yours worth seeing.

## Recipes

- Structured or not shipped. Ingredient IDs with grams, steps split at timer and action boundaries, equipment list, tested flag.
- 1,500 at launch. Source is a licensing or a verified-scrape question for Sam; the structure bar does not change with the source.
- Fit-to-pantry is computed on device from the Kitchen ledger. The score is "n of m, k swaps", never a percentage. Assumed staples (oil, salt, pepper, rice, pasta, soy) count as present unless the user has unassumed them.
- Substitutions are a table, not a model call: ingredient pairs with a quality note and a macro delta. LeChef falls back to the table first and reasons only when the table has nothing.
- LeChef-generated recipes are labelled "made for your fridge", carry no cook notes, and enter the catalog only after a cook with a rating of 4 or more.

## Cut list

With the reason, so the lead can push back on any line.

- Tutorial quests, spotlight overlays, `TutorialProgressView`: a home screen that needs a tutorial is the problem. Tonight is self-explaining or it has failed.
- Streak badge, confetti, celebration view: reward the wrong thing; cook-complete gets one quiet moment instead.
- Progress tab: nutrition becomes a lens in Cookbook and a line on cook-complete. Apple Health sync stays as a setting.
- Demo mode as a user-facing surface: keep behind a developer flag.
- Scan fan menu with three modes: one scan that classifies shelf / receipt / plate and asks only when unsure.
- Reverse scan ("estimate a prepared dish") as a primary entry: survives as "log a meal you didn't cook here" inside Cookbook. It competes with Cal AI and loses; keep it only because the inventory deduction is useful.
- Ambient animated background, hero gradients, dark olive slabs on linen: see design-direction.
- The 50-token `AppMotion` file: replaced by five.
- Household scaling for guests (planning doc section G): fold into Adapt; no separate feature.

## Open questions, in order of how much I would pay to resolve them

1. Does "Tonight" with one pick feel confident or bossy? Test with five people: open the app at dinner time, say nothing. If more than two scroll past the pick without reading the fit line, the hierarchy is wrong.
2. Is the two-to-eight table the right size, and does anyone invite anyone? If after a month fewer than a quarter of cooks happen in a table, drop Table to a section of Cookbook and keep cook notes only.
3. Is yolk-yellow as the single accent readable as "attention" rather than "warning"? See design-direction. It is the one aesthetic risk in the visual system and it is reversible.
