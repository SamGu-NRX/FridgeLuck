# FridgeLuck — Agent Context

## What This App Is

You open your fridge. There's half an onion, some eggs, a sad pepper, and leftover rice from two days ago. The usual response is either "I have nothing" or "guess I'm ordering food."

This app says: actually, you have dinner.

**Core loop:** Take a picture of what you have → the app recognizes ingredients → shows what you can make with exactly what's in front of you. No recipes that require a grocery run. Just: here's what's possible right now.

**Philosophy:** What you have is enough. The app reframes the half-empty fridge from a problem into a prompt. This is about food waste through action, not guilt — the pepper going soft becomes tonight's dinner instead of tomorrow's trash.

**Target users:** Students with $30 for groceries this week. Home cooks who are tired. Anyone who stares at random ingredients and feels defeated. People on limited budgets, limited time, limited energy.

---

## Hard Constraints (Non-Negotiable)

These are WWDC Swift Student Challenge requirements. Violating any = disqualification.

| Constraint      | Requirement                                           |
| --------------- | ----------------------------------------------------- |
| **Format**      | `.swiftpm` app playground inside a ZIP                |
| **Size**        | ≤ 25 MB zipped                                        |
| **Network**     | Must run **fully offline** — judges test offline      |
| **Experience**  | Core experience completable in ~3 minutes             |
| **Tools**       | Swift Playgrounds 4.6+ or Xcode 26+                   |
| **Language**    | All content in English                                |
| **Originality** | Individual work; open-source allowed with attribution |

**Implications:**

- No `URLSession`, no remote APIs, no web fonts, no remote SwiftPM dependencies
- All data (recipes, nutrition, demo images) must be bundled locally
- Any third-party code must be included and credited
- Test with Wi-Fi off before submission

---

## Tech Stack

| Layer                 | Technology                                                  |
| --------------------- | ----------------------------------------------------------- |
| **UI**                | SwiftUI                                                     |
| **Image Recognition** | Vision (`VNClassifyImageRequest`, `VNRecognizeTextRequest`) |
| **Optional ML**       | Core ML with `VNCoreMLRequest` (if shipping custom model)   |
| **Text Processing**   | NaturalLanguage (string normalization, synonyms)            |
| **Photo Input**       | PhotosUI (picker) + optional camera capture                 |
| **Data**              | Local JSON (recipes, nutrition) via `Bundle.module`         |

**Not using:**

- Network-dependent LLMs (forbidden offline)
- Heavy third-party CV frameworks (size + licensing risk)
- Large on-device LLMs (won't fit in 25MB)

---

## Project Structure

```
FridgeLuck.swiftpm/
├── Package.swift
├── Sources/
│   └── FridgeLuck/
│       ├── App/
│       │   ├── FridgeLuckApp.swift
│       │   └── RootView.swift
│       ├── Features/
│       │   ├── Scan/ScanView.swift
│       │   ├── Results/ResultsView.swift
│       │   ├── Recipes/RecipeView.swift
│       │   └── Nutrition/NutritionDetailView.swift
│       ├── ML/
│       │   ├── VisionIngredientService.swift
│       │   ├── IngredientLexicon.swift
│       │   └── CoreMLModelRunner.swift (optional)
│       ├── Data/
│       │   ├── RecipeStore.swift
│       │   └── NutritionStore.swift
│       └── UI/
│           ├── PixelSpriteView.swift
│           └── PinCard.swift
└── Resources/
    ├── Demo/demo_fridge.jpg
    ├── Data/recipes.json
    ├── Data/nutrition.json
    ├── Art/spritesheet.png
    └── Models/IngredientClassifier.mlmodel (optional)
```

### Package.swift Template

```swift
// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "FridgeLuck",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "FridgeLuck", targets: ["FridgeLuck"])
    ],
    targets: [
        .target(
            name: "FridgeLuck",
            resources: [
                .process("Resources")
            ]
        )
    ]
)
```

---

## Core Features (MVP Scope)

### 1. Home Screen

Two primary paths:

- **Scan Fridge** → camera or photo picker
- **Demo Mode** → loads bundled test image (critical for judges)

### 2. Ingredient Recognition Pipeline

```
Input Image
    ↓
┌─────────────────────────────────────┐
│ Vision Pass 1: VNClassifyImageRequest │ → broad labels + confidence
│ Vision Pass 2: VNRecognizeTextRequest │ → packaging/label text
└─────────────────────────────────────┘
    ↓
Normalize with IngredientLexicon (synonyms, plurals)
    ↓
Output: Detection[] with confidence scores
```

**Why two passes:**

- **Image classification** gives quick "first guess" labels (apple, banana, bottle) with confidence scores
- **Text recognition** reads packaging/labels — surprisingly useful in real kitchens; if you can read "Greek Yogurt" on a container, you know what it is regardless of visual ambiguity
- The combination catches more than either alone

**Lexicon normalization:** Use NaturalLanguage framework to handle:

- Synonyms: "bell pepper" = "capsicum" = "pepper"
- Plurals: "eggs" → "egg"
- Common typos and OCR errors
- Regional variations

**Optional: Custom Core ML model.** If you ship `IngredientClassifier.mlmodel`, run it through Vision using `VNCoreMLRequest`. This lets you train specifically on food categories rather than relying on general-purpose classification. Keep it tiny and quantized to fit size limits.

### 3. Confidence-Based UX (Core Differentiator)

| Confidence | Behavior                                             |
| ---------- | ---------------------------------------------------- |
| ≥ 0.65     | Auto-add ingredient                                  |
| 0.35–0.65  | Prompt user: "Is this cucumber or zucchini?"         |
| < 0.35     | Show in "Possible items" tray; user can manually add |

This is the signature UX — the app admits what it doesn't know.

**Implementation pattern:**

```swift
struct Detection {
    let label: String
    let confidence: Float
    let alternatives: [String]  // top-3 for medium confidence prompts
}

func categorize(_ detection: Detection) -> DetectionCategory {
    switch detection.confidence {
    case 0.65...: return .autoConfirm
    case 0.35..<0.65: return .askUser(options: detection.alternatives)
    default: return .possibleItem
    }
}
```

**UX for medium confidence:** Show top-3 options as tappable chips + a search field. "Looks like cucumber or zucchini — tap to confirm." This feels professional because it's honest about uncertainty while still being helpful.

### 4. Results Screen

- Detected ingredients as tappable cards/pins
- High confidence = auto-added
- Medium confidence = confirmation picker
- Each ingredient tappable → nutrition card

### 5. Recipe Matching

**"Make Something Now"** mode: One best recipe suggestion immediately, then "See more."

**Design philosophy:** Don't overcomplicate. A crisp scoring function with great UX beats "AI vibes" that are slow or flaky — especially under a 3-minute judging window. Judges notice when something just _works_.

**Scoring algorithm (simple, explainable):**

```swift
func score(recipe: Recipe, available: Set<String>) -> Int {
    let matched = recipe.requiredIngredients.filter { available.contains($0) }
    let missing = recipe.requiredIngredients.count - matched.count

    var score = matched.count * 10
    score -= missing * 15  // heavy penalty for missing required

    if recipe.timeMinutes <= 15 { score += 5 }  // bonus for quick

    return score
}
```

**Why this works:**

- Transparent: user understands why a recipe was suggested
- Fast: no ML inference needed for matching
- Debuggable: easy to tune weights during development

**Recipe scope:** 30–80 recipes is the sweet spot. Enough to feel real and cover common ingredient combinations. Small enough to fit in 25MB. Focus on student-friendly meals that use overlapping ingredients.

### 6. Nutrition Cards

Tap any ingredient for:

- Basic nutrition (calories, protein, carbs, fat)
- Storage tips
- Cultural usage notes
- What it pairs well with

**Tone:** Educational, not preachy. "Oh, that's interesting" while cooking.

---

## Handling Calories Offline (Three Different Problems)

Without an online LLM, you need a **hybrid system** that's honest about uncertainty.

### A) Packaged Items → OCR the Label

**Best approach:** Use camera + `VNRecognizeTextRequest` to read "Calories", "Serving size", "Servings per container" directly from the nutrition label.

This works offline because you're reading what's physically printed — no database lookup needed.

**Fallback:** If you detect a barcode but can't match it, prompt "Scan nutrition label instead."

### B) Single Ingredients → Curated Database

Ship a small nutrition database from **USDA FoodData Central** (public domain/CC0).

**Practical scope for challenge:**

- ~150 common student-friendly ingredients
- Store per-100g values: calories, protein, carbs, fat
- Maybe 1-3 micronutrients if you want depth

**Portion size UX (critical for accuracy):**
Calories without quantity are fiction. Use frictionless portion UI:

- Default: "1 unit" (1 egg, 1 banana) or "100g"
- Quick chips: "½ cup", "1 cup", "1 tbsp", "1 handful"
- Optional: slider for grams
- Show **"~"** (approx) to communicate uncertainty honestly

### C) Prepared Dishes / Leftovers → Estimate + Ask

This is the hardest case. Without a custom model or online service, you _cannot reliably infer_ full recipe composition from a photo.

**Attack plan: estimate with guardrails.**

1. Try to classify dish type (weak signal is fine)
   - Vision might say "pizza / pasta / soup" — enough to propose options
2. Immediately show manual confirmation:
   - "Looks like: Fried rice / Stir fry / Pasta"
3. Use a **dish template table:**
   - Each template: calories per "typical serving" + macros
   - Serving-size selector: "small / normal / large"
4. Output a **range:**
   - e.g., "~450–650 kcal (normal bowl)"
   - Range communicates uncertainty honestly

**This fits your confidence-first philosophy:** Low confidence dish recognition → ask user smoothly.

---

## Gamification Layer (Light)

### Philosophy (Duolingo-Inspired)

The problem with "good choices": they're easy to abandon. You download a healthy eating app, use it twice, forget it exists.

**Duolingo's insight:** Make progress visible, make streaks meaningful, make the next action obvious. The learning happens as a side effect of engagement.

Apply this to cooking:

- Progress = meals cooked, ingredients saved from waste
- Streaks = consecutive days of cooking at home
- Next action = one clear recipe suggestion, not a wall of options

### Quest Log & Badges

**Quest types:**

- **Daily:** "Use something that's been in your fridge 3+ days"
- **Weekly:** "Cook three meals this week under $5 total ingredients"
- **Discovery:** "Try a recipe from a cuisine you've never made"
- **Seasonal:** Limited-time events tied to what's in season

**Badge categories:**

- **Permanent achievements:** "Zero Waste Week", "Budget Master", "World Explorer"
- **Limited-time events:** Seasonal challenges, holiday cooking, etc.
- **Milestone badges:** 10 meals, 50 meals, 100 meals cooked

### Nutritional Cards as Education

Integrate nutrition info naturally — not as a diet tracker, but as "oh, that's interesting" moments:

- Tap an ingredient during recipe selection (a flip-card design!)
- See a card with macros, storage tips, cultural context
- "Did you know? Eggs are one of the most complete protein sources"

**Key:** Information appears in context of cooking, not as a separate "health" section. Learning happens while doing.

### Goal

Make the app something you _want_ to open. The sustainable, healthy, budget-friendly choice becomes the one that also feels rewarding.

---

## Community Layer (Extension, Not Core)

**Note:** This is secondary to the core scan → recipe flow. Only implement if core is rock-solid.

### University Partnership Angle

The app can connect to broader challenges:

- University trying to reduce dining hall waste
- Residence hall competing to cook most meals from leftovers
- Shared recipe discoveries from people with similar ingredients

### What This Looks Like

- A student sees that 400 other people at their school made something this week instead of throwing food away
- Leaderboards for "most meals cooked" or "most food saved"
- Shared ingredient pools: "People with eggs + rice made these recipes"

### Important: Not Social Media

This isn't about performing your cooking for likes. It's about:

- **Collective motivation:** Other people are doing this too
- **Shared discovery:** See what others made with similar ingredients
- **Quiet impact:** Aggregate stats that feel meaningful

### For Challenge Submission

Keep community features as a "future direction" mention in your write-up, or implement as a mock/placeholder UI showing what it _could_ look like. Don't let it bloat the core experience.

---

## Data Schemas

### Recipe JSON Structure

```json
{
  "id": "string",
  "title": "string",
  "time_minutes": 15,
  "required_ingredients": ["egg", "rice", "soy sauce"],
  "optional_ingredients": ["green onion", "sesame oil"],
  "instructions": ["Step 1...", "Step 2..."],
  "tags": ["quick", "asian", "budget"],
  "calories_estimate": 350
}
```

**Scope:** 30–80 recipes for challenge build. Enough to feel real, small enough for 25MB.

### Nutrition JSON Structure

```json
{
  "id": "egg",
  "display_name": "Egg",
  "synonyms": ["eggs", "large egg"],
  "per_100g": {
    "calories": 155,
    "protein": 13,
    "carbs": 1.1,
    "fat": 11
  },
  "typical_unit": "1 large egg (50g)",
  "storage_tip": "Refrigerate, use within 3 weeks",
  "pairs_with": ["rice", "vegetables", "cheese"]
}
```

**Source:** USDA FoodData Central (public domain/CC0). Curate ~150 common student-friendly ingredients.

---

## Permissions & Platform Safety

### Info.plist Keys

```xml
<key>NSCameraUsageDescription</key>
<string>Scan fridge ingredients to suggest recipes.</string>
<key>NSPhotoLibraryUsageDescription</key>
<string>Pick a photo to scan ingredients.</string>
```

### Always Provide 3 Image Paths

1. **Demo image (bundled)** → never fails, critical for judges
2. **Photo picker** → usually works
3. **Camera** → best experience on iPad, can fail gracefully

Judges may run on Mac or deny camera. Demo Mode is the safety net.

---

## Core Invariant (Design Principle)

The app must behave well even if:

- Camera isn't available
- Apple Intelligence isn't available
- Vision is uncertain
- The photo is messy
- The user has weird ingredients

**This means:**

1. **Demo Mode always works** — bundled image, deterministic flow
2. **Vision returns candidates + confidence** — never assumes correctness
3. **UI converts confidence into interaction:**
   - High → auto-add
   - Medium → "tap to confirm" (top-3 options + search)
   - Low → "Possible" tray + manual add
4. **Recipe matching is deterministic** — no AI required for core flow
5. **Graceful degradation everywhere** — every enhancement has a fallback
6. **Recognizes when the image is blurry, recommend retake when confidence is low for everything**

This is exactly the kind of UX judges notice because it's **honest _and_ polished**.

---

## Size Optimization Tactics

| Asset Type     | Strategy                               |
| -------------- | -------------------------------------- |
| Images         | One spritesheet PNG, not many files    |
| Demo photos    | 1-2 max, compressed JPEG               |
| ML models      | Tiny classifier, quantized if possible |
| Nutrition data | Minimal (top nutrients + short tips)   |
| Recipes        | 30-80 carefully curated, not hundreds  |

### Offline Audit

Before submission, search codebase for:

- `URLSession`
- `http://` or `https://`
- `NWPathMonitor`
- `WKWebView` loading remote URLs
- Remote font references

Test with Wi-Fi off.

---

## UI Style Notes

### Visual Identity

- **Pixel food spritesheet** — Minecraft-style animated pixelated food sprites
- **3D pin cards** for ingredients — interactive, tactile feeling
- **Scan animation** — visual feedback during recognition (your signature style)

### Pin Card Implementation (SwiftUI)

```swift
struct PinCard: View {
    @State private var dragOffset: CGSize = .zero

    var body: some View {
        ingredientCard
            .rotation3DEffect(
                .degrees(Double(dragOffset.width) / 10),
                axis: (x: 0, y: 1, z: 0)
            )
            .rotation3DEffect(
                .degrees(Double(-dragOffset.height) / 10),
                axis: (x: 1, y: 0, z: 0)
            )
            .gesture(
                DragGesture()
                    .onChanged { value in
                        dragOffset = value.translation
                    }
                    .onEnded { _ in
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) {
                            dragOffset = .zero
                        }
                    }
            )
    }
}
```

### Asset Optimization

- **One spritesheet** instead of many individual images
- **Nearest-neighbor scaling** for pixel art (keeps crisp edges)
- **System SF Symbols** where possible (zero file size)
- **Compressed JPEG** for demo photo (aim for <500KB)

---

## Apple Intelligence / Foundation Models

**Policy:** Apple's 2026 SSC policy explicitly allows on-device Apple Intelligence frameworks. Submissions are judged offline, and Foundation Models framework runs on-device.

### The Availability Problem

Device support varies. Apple's docs explicitly call this out — Foundation Models requires:

- Supported hardware (newer devices)
- Apple Intelligence enabled by user
- Sufficient device resources

**This means:** If you use Foundation Models, it _will_ fail on some judge devices.

### Recommended Architecture

```
┌─────────────────────────────────────────────────┐
│                   Core Path                     │
│   Vision + deterministic tables + user confirm  │
│              (ALWAYS works)                     │
└─────────────────────────────────────────────────┘
                       ↓
┌─────────────────────────────────────────────────┐
│               Enhancement Path                  │
│         Foundation Models (if available)        │
│              (graceful fallback)                │
└─────────────────────────────────────────────────┘
```

### Good Uses (Optional Enhancements)

- **Label normalization:** Turn noisy Vision labels into cleaner ingredient names ("scallion" vs "green onion") while still letting user confirm
- **Friendly microcopy:** Generate warm, varied UI text ("Luck says: stir-fry time!") without affecting correctness
- **Ingredient suggestions:** "You have X and Y — people often pair these with Z"

### Do NOT Use For (Without Fallback)

- Calorie computation (must have database fallback)
- Dish identification (must have template fallback)
- Recipe matching (deterministic scoring is more reliable)
- Any correctness-critical path

### Implementation Pattern

```swift
func enhanceWithAI(_ label: String) async -> String {
    guard FoundationModels.isAvailable else {
        return label  // Fallback: use as-is
    }

    // Try AI enhancement, but always have fallback
    do {
        return try await FoundationModels.normalize(label)
    } catch {
        return label
    }
}
```

### Reality Check

Some Apple Intelligence features users see in the OS aren't exposed as public APIs. The **reliable, public, supported** route for recognition is still **Vision / Core ML**. Foundation Models is for text generation/processing, not image recognition.

---

## Submission Checklist

### Pre-Submission

- [ ] All resources load from `Bundle.module`
- [ ] Demo Mode works perfectly (judge safety net)
- [ ] Tested with Wi-Fi off
- [ ] No `URLSession` or remote calls in code
- [ ] ZIP size < 25 MB
- [ ] Core experience completes in < 3 minutes
- [ ] All content in English

### Packaging

1. Clean project (remove derived data, caches, `.DS_Store`)
2. ZIP the `FridgeLuck.swiftpm` folder itself (not a parent folder)
3. Verify ZIP size
4. Unzip on different machine/user account
5. Open in Swift Playgrounds → Demo Mode works in <10 seconds

### Helper Scripts (Optional)

**`scripts/prepare_submission.sh`**

```bash
#!/bin/bash
set -euo pipefail
find FridgeLuck.swiftpm -name ".DS_Store" -delete
zip -rq FridgeLuck.zip FridgeLuck.swiftpm
# hard fail if ZIP >= 25 MB
```

**`scripts/offline_audit.sh`**

```bash
#!/bin/bash
set -euo pipefail
# scan for runtime network API calls
rg -n "URLSession|http://|https://" FridgeLuck.swiftpm
# verify local vendored dependency exists
test -f FridgeLuck.swiftpm/Vendor/GRDB.swift/Package.swift
# verify usage descriptions are present
test -f FridgeLuck.swiftpm/Support/AdditionalInfo.plist
```

**Offline dependency strategy:** GRDB is vendored at `FridgeLuck.swiftpm/Vendor/GRDB.swift` and referenced through `.package(path: "Vendor/GRDB.swift")`, so a clean offline machine can open and build without fetching remote packages.

---

## 3-Minute Demo Flow (For Judges)

1. **Home** (5 sec): Two buttons — "Scan Fridge" and "Demo Mode"
2. **Tap Demo Mode** (2 sec): Loads bundled test image
3. **Scanning animation** (3 sec): Pixel sprite animation plays
4. **Results** (15 sec): Ingredients appear as cards
   - High confidence auto-added
   - One medium-confidence prompts "Is this X or Y?"
5. **"Make Something Now"** (10 sec): Best recipe appears immediately
6. **Tap ingredient** (10 sec): Nutrition card slides up
7. **Browse more recipes** (remaining): User explores

Total: ~45 seconds for core loop, leaving time for exploration.

---

## What This App Is NOT

- Not a meal planning app that tells you what to buy
- Not a diet app that judges your choices
- Not a social platform for performing your cooking
- Not a recipe database you have to search through

It's a tool that looks at what you already have and shows what's possible. Fast, private, offline, designed for how people actually live.

---

## Why This Matters (Personal Story Angle)

Past SSC winners consistently show that **the story behind your app matters as much as the app itself**.

### For Your Write-Up

Connect the app to your experience:

- "As a university student, I often see food go bad in my fridge because I don't know what to make with random ingredients"
- "I wanted to solve a small piece of the food waste problem — not by lecturing, but by making the sustainable choice the obvious one"
- "The confidence-based UI came from my frustration with apps that pretend to know things they don't"

### What Judges Look For

- **Passion and potential**, not perfection
- **Personal motivation** that's authentic
- **Small-scope ideas done with care** beat grand ideas executed poorly
- Something that makes them go "Oh, that's clever!"

### The Name: FridgeLuck

Consider the etymology if you want to explain it:

- "Fridge" = the literal starting point
- "Luck" = the serendipity of discovering what's possible with random ingredients
- Also evokes "potluck" — making do with what's available, community, resourcefulness

---

## Quick Reference: What To Build First

**Priority order for development:**

1. **Demo Mode + bundled image** (judge safety net)
2. **Basic Vision pipeline** (VNClassifyImageRequest)
3. **Confidence-based UI** (the core differentiator)
4. **Recipe matching** (deterministic scoring)
5. **Results display** (ingredient cards)
6. **Nutrition cards** (tap to learn)
7. **Polish** (animations, pixel art, spring effects)
8. **Gamification** (quests/badges — only if time)
9. **Apple Intelligence enhancements** (optional, with fallbacks)

**Rule:** Each layer must work before moving to the next. Don't add badges before recipe matching works perfectly.
