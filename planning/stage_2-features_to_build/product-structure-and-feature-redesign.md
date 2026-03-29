# FridgeLuck Product Structure and Feature Redesign

Date: 2026-03-28
Status: product strategy document

## Purpose

This document expands the earlier product plan into a more comprehensive redesign strategy for FridgeLuck.

The goal is not to prescribe visual styling. The goal is to define:

- what the app should feel like to an everyday user
- which destinations should exist in the product structure
- which features are core to the loop and which are secondary
- how the current app can be reorganized into a cleaner, more useful system
- why those changes would make the app more attractive, easier to understand, and more likely to convert and retain mainstream users

This document is grounded in the current codebase, not generic product advice.

## Lens Used To Think Through This

This strategy was developed using principles from the following skills:

- `holistic-ux`
- `frontend-design`
- `web-animation-design`

Those skills matter here even though this is not an implementation task:

- `holistic-ux` pushes the analysis beyond screens into jobs-to-be-done, backstage systems, trust, recovery, and cognitive load.
- `frontend-design` is useful as a reminder that the product should feel intentional and distinctive, but this document avoids dictating specific visual styling so a UI specialist can take over.
- `web-animation-design` is relevant at the systems level: high-frequency product actions should stay fast and low-friction, while motion should be reserved for orientation, transitions, and confidence-building moments.

## Current App Reading

The current app is already much deeper than a simple "scan fridge and get recipes" prototype.

From the current codebase:

- The root shell in `apps/ios/App/ContentView.swift` already supports:
  - home
  - scan modes
  - demo mode
  - direct ingredient review
  - recipe results
  - virtual fridge
  - grocery update
  - live assistant
  - dashboard/profile routing
- Inventory is already real, not hypothetical:
  - inventory lots
  - intake from scan
  - consumption from cooking
  - spoilage/use-soon suggestions
  - confidence-aware quantity storage
- Reverse scan already exists:
  - meal photo capture
  - analysis
  - candidate matching
  - portion size controls
  - inventory deduction preview
- Cooking guidance already exists:
  - recipe preview
  - cooking guide
  - celebration state
  - live assistant session
- Progress already exists:
  - macro totals
  - weekly history
  - cooking journal
  - streaks
  - Apple Health integration

The real issue is not feature absence. The issue is that the product structure does not yet surface those capabilities in the clearest or most useful way.

## What The Current App Already Has, Interpreted As Product Surfaces

| Current capability | Where it lives now | What it really is |
| --- | --- | --- |
| Guided home/tutorial | `HomeDashboardView` | onboarding plus launch surface |
| Virtual fridge | `VirtualFridgeView` | a hidden Kitchen product |
| Grocery update | `UpdateGroceriesView` | a hidden inventory maintenance workflow |
| Reverse scan | `ReverseScanMealView` | a hidden meal logging workflow |
| Dashboard + Recipe Book | `DashboardView`, `RecipeBookView` | a hidden Progress product |
| Live assistant | `LiveAssistantView` | a contextual cooking copilot |
| Recipe matching | `RecipeResultsView` | the decision engine of the app |
| Ingredient review | `IngredientReviewView` | the trust and correction layer |

The app is already close to having three strong products inside it:

1. a kitchen intelligence app
2. a meal logging and nutrition app
3. a guided cooking app

Right now those three products are present but not clearly organized.

## Core Product Problem

The current structure makes the app feel more complex than it is.

For a mainstream user, the app should be legible at first glance. They should immediately understand:

- what I have
- what I can make
- what I ate
- what I should do next

At the moment, too much value is hidden in nested flows and context-specific screens. That causes three problems:

1. The app feels less useful than it really is.
2. The user cannot build a strong habit around obvious destinations.
3. The product promise is diluted because too many core capabilities look like side features.

## Product Principles For A Mainstream User

If FridgeLuck should appeal to a broad non-technical audience, the product has to optimize for these principles:

### 1. The app must answer one real question per destination

Every main destination should exist because it answers a user question:

- `Home`: What should I do right now?
- `Kitchen`: What do I actually have?
- `Progress`: What did I eat and how am I doing?

If a destination does not answer a clear question, it should not be in the main shell.

### 2. Trust is more important than novelty

Users will forgive fewer features if the app feels trustworthy.

Trust in this app comes from:

- transparent ingredient review
- clear confidence handling
- visible inventory state
- confirm-before-finalize meal logging
- explanations for why a recipe is recommended

This is more important than flashy AI positioning.

### 3. The app must reduce decisions, not create more browsing

Recipe products often fail because they become catalogs.

FridgeLuck should act like a decision engine:

- best thing to make now
- best thing to use soon
- best thing for today’s macro situation
- best fallback if the fridge is thin

The user should feel helped, not sent to browse.

### 4. The app must reward maintenance with better outcomes

If users scan groceries, confirm ingredients, and log meals, they should feel that the app becomes smarter and more useful.

The value exchange should be obvious:

- more confirmations -> better inventory
- better inventory -> better recipes
- better meal confirmation -> better macros
- better ratings -> better recommendations

### 5. High-frequency actions must stay simple

From a holistic UX and motion perspective, the most frequent actions should be light:

- open app
- scan
- confirm ingredients
- choose recipe
- log meal

These should not be overloaded with tutorial text, decorative UI, or slow transitions.

## Recommended Product Structure

### Main shell

Recommended primary structure:

- `Home`
- `Kitchen`
- centered `Scan`
- `Progress`

### Secondary/contextual surfaces

- `Profile`
- `Live Coach`
- `Recipe Detail`
- `Cooking Guide`
- `Settings`

### Why this structure is the strongest

It maps directly to the real loop:

1. understand current kitchen state
2. choose a meal
3. cook or log it
4. update inventory and nutrition state
5. come back tomorrow to a system that remembers

### Why `Profile` should not be a primary tab

Profile is necessary, but it is not a daily-use destination for most users.

It contains:

- goals
- dietary restrictions
- allergens
- personal settings

Those matter, but they do not need top-tier navigation priority.

### Why `Coach` should not be a primary tab yet

The assistant is powerful, but it is contextual. Most users do not start by opening a coach.

They start by asking:

- what can I make
- what do I have
- what should I log

The assistant becomes powerful after a recipe is selected or an active cook session exists.

## Destination Specifications

## 1. Home

### Job-to-be-done

Help the user decide what to do next with the least mental effort.

### What Home should become

Home should become a decision surface, not a mixed dashboard.

It should not try to hold:

- full inventory browsing
- full journaling
- full settings
- deep editing workflows

It should hold:

- the best recommendation
- the most urgent kitchen signal
- the most relevant daily nutrition signal
- an obvious resume point if the user is in the middle of cooking or logging

### Core Home sections

#### A. Primary recommendation

One strong card:

- best thing to make now
- reason it was chosen
- time to cook
- what it helps with

Valid reasons:

- uses expiring spinach and chicken
- fits high-protein goal
- 20 minutes
- only missing one ingredient
- good for your usual lunch pattern

This should behave like a recommendation, not a card gallery.

#### B. Use-soon action

Not just "items expiring."

It should connect urgency to action:

- use your mushrooms in this stir fry
- use your yogurt in this breakfast bowl
- use these tomatoes before tomorrow

The important shift is from warning language to action language.

#### C. Active cook / active meal state

If the user started cooking or started a reverse-scan meal flow, Home should show an obvious resume surface.

Examples:

- resume cooking chicken stir fry
- finish confirming last meal
- review items from your latest grocery intake

This creates continuity and reduces abandonment.

#### D. Daily nutrition context

Home should show only the most useful summary:

- how far through today’s calories/macros the user is
- what type of meal would best fit next

This should not duplicate the full Progress screen.

#### E. Fast fallback options

When the best recommendation is not appealing, the user should see immediate alternatives:

- fastest meal from what you have
- easiest low-effort option
- almost-there option missing 1 item

This keeps the app useful when the perfect match is not emotionally right.

### Why this matters for mainstream appeal

Mainstream users do not want to manage a system first. They want help making one decision.

Home should feel like:

- useful in 3 seconds
- clear without study
- personalized without being cluttered

## 2. Kitchen

### Job-to-be-done

Give the user an understandable, trustworthy picture of what is actually available at home.

### Why this should be promoted into a first-class destination

The current app already has the pieces:

- virtual fridge
- update groceries
- confidence-aware inventory
- shelf-life/use-soon logic

That is already enough to support a dedicated Kitchen product.

For everyday users, this is one of the strongest reasons to keep the app installed. It makes the app useful before meal time, not only during meal time.

### What Kitchen should contain

#### A. On hand now

The main inventory state, grouped by location:

- fridge
- pantry
- freezer

This should answer:

- what is definitely here
- what is low stock
- what was recently added
- what still needs confirmation

#### B. Use soon

A dedicated section for ingredients that should be prioritized.

This should not be a generic alert area. It should connect directly to decisions:

- item
- urgency
- best next uses

#### C. Needs review

One of the biggest opportunities in the current system is making uncertainty visible but not annoying.

Kitchen should expose:

- low-confidence scanned items
- old items likely no longer present
- inventory that has not been confirmed recently

This is important because it gives the app a cleaner truth model without forcing all confirmation into the initial scan flow.

#### D. Grocery maintenance

The current grocery update flow should become a core kitchen function, not an isolated task.

Users should feel that the kitchen can be maintained through multiple entry styles:

- grocery photo
- receipt scan
- manual add
- later: quick add staples

#### E. Pantry assumptions

This is a major usability feature for mainstream users.

Users should be able to define:

- staples I almost always have
- staples recipes may assume
- staples that still require confirmation

Examples:

- oil
- rice
- pasta
- soy sauce
- common spices

Without this layer, inventory systems become too literal and too tedious.

#### F. Stock intelligence

Useful kitchen-level signals:

- low stock on frequently used items
- ingredients used often but not recently restocked
- ingredients added but never used
- "quiet waste" patterns like yogurt repeatedly expiring

This is practical, not gimmicky.

### Why Kitchen is such a strong product feature

It gives FridgeLuck a durable identity beyond recipe recommendation.

A photo-calorie app can estimate what you ate.
It cannot easily become your kitchen state manager.

If Kitchen is strong, FridgeLuck becomes a household utility rather than a one-time novelty.

## 3. Progress

### Job-to-be-done

Show the user what they actually ate, how that aligns with their goals, and what meals are worth repeating.

### Why this needs to be a first-class destination

The current dashboard and recipe book already provide the beginnings of this, but they feel like secondary screens.

For mainstream users, visible progress is one of the biggest retention drivers.

This destination should not feel like a settings page. It should feel like a living meal and nutrition record.

### What Progress should contain

#### A. Today

The most important section:

- calories consumed
- macros consumed
- meals logged today
- remaining target context

This is the "how am I doing?" screen.

#### B. Recent meals

This should make repeat behavior easy:

- repeat this meal
- log it again
- edit the previous logged portion
- compare similar meals

Most users repeat meals. The product should embrace that.

#### C. Saved winners

Meals should not just disappear into history.

The app should elevate:

- highly rated meals
- meals cooked multiple times
- meals that worked well for macros
- meals that used home inventory efficiently

This transforms raw history into useful memory.

#### D. Accuracy and confidence context

This is an underused differentiator.

FridgeLuck wants to be more accurate than generic photo-calorie apps. That promise should be visible in Progress.

Useful concepts:

- confirmed meal
- estimated meal
- adjusted ingredients
- portion edited

This gives the user a mental model of why the app is trustworthy.

#### E. Longitudinal patterns

The app should help the user see useful patterns, not just charts.

Examples:

- your protein is usually low on lunch days
- your highest-rated meals are also your fastest weekday meals
- you often log meals late at night without scanning ingredients first

The point is interpretation, not data density.

### Why Progress matters

Without a strong Progress destination, the app will feel like a smart scanner.
With a strong Progress destination, it starts to feel like a daily health and food system.

## 4. Scan

### Job-to-be-done

Let the user enter the system from the fastest possible path for the job they are doing right now.

### Current direction is correct

The existing scan mode split is already one of the strongest structural decisions in the app:

- scan ingredients
- update groceries
- log meal

This is good because it maps to three distinct intents rather than one overloaded capture flow.

### What should improve conceptually

The product should make those modes feel like three entrance doors into the same system, not three separate tools.

That means the user should understand:

- ingredient scan updates recipe options and inventory
- grocery update updates kitchen state
- meal log updates nutrition and may deduct inventory

The same system is being updated from different directions.

## 5. Active Cook

### Job-to-be-done

Let the user continue an in-progress cooking session without losing state.

### Why this is important

The current cooking guide and assistant are good, but they still behave mostly like branch flows.

The app should support an `Active Cook` state that can be resumed from Home and possibly Kitchen.

This state could preserve:

- current recipe
- current step
- substitutions already chosen
- ingredient checklist progress
- whether the user is using live guidance

### Why this helps the product

It makes the assistant feel integrated and practical rather than like a special demo-only mode.

## Core Feature Expansions Worth Building

## A. Meal Finalization System

### Why this is one of the most important missing pieces

The app already has:

- cooking completion
- reverse scan results
- portion control
- inventory deduction preview
- meal journaling

What it needs is a unified finalization step that closes the loop in a trustworthy way.

### What the finalization step should do

Before the app says a meal is final, it should let the user confirm:

- what recipe it actually was
- portion size
- substitutions made
- whether leftovers were saved
- optional taste rating
- optional ease rating

### Why this is strategically critical

This is the step that turns FridgeLuck from:

- a recommendation app

into:

- a kitchen-aware, ingredient-grounded meal system

It is also the strongest answer to "why would I use this instead of a generic calorie scanner?"

## B. Repeatable Meal Intelligence

### Problem

Most users do not want infinite novelty.

They want:

- reliable breakfasts
- repeat lunches
- easy dinners
- meals that worked before

### What the feature should do

The app should learn and surface:

- meals you repeat often
- meals you rate highly
- meals that fit weekday behavior
- meals that work well with your actual home inventory

### Why this matters

This reduces friction and increases retention.

The app becomes more useful over time not only because it recognizes ingredients better, but because it recognizes habits better.

## C. Pantry Assumptions Layer

### Problem

Inventory systems break when they require explicit tracking of every staple.

### What the feature should do

Let users classify pantry items as:

- always assume
- usually assume
- only use if confirmed

### Why it matters

This dramatically improves recommendation realism without requiring a burdensome setup flow.

For a mainstream user, this is one of the highest-value quality-of-life features in the entire product.

## D. Kitchen Recovery and Correction Queue

### Problem

Not every decision should be forced into the scan review moment.

### What the feature should do

Create a lightweight recovery queue inside Kitchen:

- items with low confidence
- items not reconfirmed in a while
- items the system thinks may be gone
- grocery receipt line items that need normalization

### Why it matters

This lowers cognitive load during scan, while still preserving long-term data quality.

It turns trust maintenance into an asynchronous kitchen management habit rather than a blocking step.

## E. Recommendation Explanations

### Problem

Recommendations are stronger when users understand why they were shown.

### What the feature should do

Every top recommendation should have plain-language reasons, not just metadata.

Examples:

- uses 2 items expiring soon
- fits your protein target
- 15-minute lunch
- reuses ingredients from your last grocery haul

### Why it matters

This improves trust and reduces the feeling that the app is making arbitrary suggestions.

## F. Saved Winners and Meal Templates

### Problem

Users often discover one meal that works and want to return to it easily.

### What the feature should do

Promote:

- favorite meals
- best macro meals
- easiest weekday meals
- "make again" templates

This should work for:

- known recipes
- user-confirmed variants
- reverse-scanned meals that were later confirmed

### Why it matters

This is a straightforward, low-confusion feature with strong retention value.

It feels useful to a mainstream user immediately.

## G. Simple Household Readiness Features

### Problem

Users often care about whether they can feed themselves tonight, or feed two or three people soon.

### What the feature should do

Without building a full event planner, the app can support:

- can make for 1 / 2 / 4 people
- which ingredients will run short
- what to buy to scale a meal for guests

### Why it matters

This strengthens the "real kitchen utility" story without requiring a commerce layer.

## Why This Redesign Would Make The App More Attractive

## 1. It gives the product a simpler story

The product story becomes:

- see what you have
- know what to cook
- log what you ate

That is easier to understand than a broad "AI kitchen assistant" pitch.

## 2. It turns hidden features into persistent value

Right now many strong capabilities live behind flows.

Promoting Kitchen and Progress into first-class destinations turns latent value into obvious value.

## 3. It reduces perceived complexity

Even though the underlying system is complex, the user sees a cleaner map:

- Home = next action
- Kitchen = state of food at home
- Progress = state of meals and nutrition

This is much easier to learn.

## 4. It improves trust

The redesign surfaces:

- inventory truth
- confidence and correction
- clear meal finalization
- explicit recommendation reasoning

That makes the app feel rigorous rather than "AI magic."

## 5. It supports stronger retention loops

The app can create repeatable habits around:

- checking Kitchen before shopping
- checking Home before deciding what to eat
- checking Progress after meals

These are practical habits, not artificial engagement hooks.

## Holistic UX Implications

This redesign should be evaluated with system-level UX principles, not only screen-level polish.

### Reduce extraneous load

Each destination should have a tight responsibility.

Avoid:

- duplicate stats across screens
- multiple places to do the same edit
- decorative metadata that does not drive action

### Use progressive disclosure

Do not force users to make every correction immediately.

Show:

- what matters now first
- deeper editing only when needed

### Keep status visible

Users should always understand:

- whether inventory is trustworthy
- whether a recipe is exact or almost-there
- whether a meal log is estimated or confirmed
- whether an active cooking session is still in progress

### Use friction only where it protects trust

Fast where possible:

- choosing scan mode
- repeating meals
- resuming cooking

Intentional friction where accuracy matters:

- ingredient confirmation
- meal finalization
- substitutions that change macros materially

### Keep motion purposeful

From the motion standpoint:

- frequent actions should feel immediate
- orientation transitions can be slightly richer
- celebration moments can be more expressive
- repeated maintenance actions should not be slowed down by theatrics

This is important for a kitchen app because users often interact while distracted, busy, or cooking.

## Recommended Delivery Order

### Phase 1: Product structure

- Promote `Kitchen` into the main shell
- Promote `Progress` into the main shell
- Move `Profile` into Progress/settings
- Keep scan orb central

### Phase 2: Loop completion

- Build unified meal finalization
- Add active cook continuity
- Add stronger recommendation explanations

### Phase 3: Utility refinement

- Add pantry assumptions
- Add kitchen correction/recovery queue
- Add saved winners / meal templates

### Phase 4: Smarter planning

- Add simple household scaling
- Add better use-soon recipe prioritization
- Add stronger behavior-based meal repetition logic

## Features To Explicitly Deprioritize

These may be attractive in the abstract, but they are not core to the current loop and should not dilute the redesign:

- community forums
- social feed features
- broad gamification systems that require large asset work
- grocery commerce integrations
- highly speculative freshness-from-image systems
- general chat assistant surfaces with no kitchen or meal grounding

## Final Product Direction

The strongest version of FridgeLuck is not:

- a prettier recipe browser
- a generic AI calorie scanner
- a kitchen social app

The strongest version of FridgeLuck is:

- a kitchen-aware meal system that knows what is on hand
- helps the user decide what to cook
- guides them through cooking or logging
- confirms what was actually eaten
- improves both inventory and nutrition understanding over time

That is a product with a much clearer mainstream story, stronger retention potential, and a more trustworthy identity than a simple scan-and-suggest app.
