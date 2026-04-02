import Foundation

struct SpotlightStep: Identifiable, Equatable {
  let id: String
  let anchorID: String?
  let icon: String
  let title: String
  let message: String
}

struct SpotlightPresentation: Identifiable, Equatable {
  let id = UUID()
  let source: String
  let steps: [SpotlightStep]
}

extension SpotlightStep {
  static let onboarding: [SpotlightStep] = [
    SpotlightStep(
      id: "welcome",
      anchorID: nil,
      icon: "sparkles",
      title: "Welcome to FridgeLuck",
      message:
        "This guided tour teaches the app itself. You already handled setup before entering — now we’ll show you where everything lives."
    ),
    SpotlightStep(
      id: "setup",
      anchorID: "progressView",
      icon: "rectangle.stack",
      title: "Your Guided Tour",
      message:
        "These 4 steps unlock one at a time: start with a demo scan, review uncertain ingredients, choose a recipe match, then cook with Le Chef."
    ),
    SpotlightStep(
      id: "scan_first",
      anchorID: "quest_0",
      icon: "camera.viewfinder",
      title: "Start With Demo Mode",
      message:
        "Use the demo scenarios first. They make it easy to understand the full scan-to-recipe loop before you use your own kitchen."
    ),
    SpotlightStep(
      id: "wrapup",
      anchorID: nil,
      icon: "arrow.right.circle",
      title: "Before You Begin",
      message:
        "After your demo scan, FridgeLuck will meet you inside ingredient review for the next lesson. Want to redo this tour later? Scroll to the bottom and tap “Reset progress”."
    ),
  ]

  static let completion: [SpotlightStep] = [
    SpotlightStep(
      id: "congrats",
      anchorID: nil,
      icon: "party.popper.fill",
      title: "Setup Complete!",
      message:
        "You’ve finished the guided tour. Your personalized kitchen dashboard is now fully unlocked."
    ),
    SpotlightStep(
      id: "rhythm",
      anchorID: "myRhythm",
      icon: "book.closed.fill",
      title: "My Rhythm",
      message:
        "This is your cooking journal at a glance. Your latest recipes and cooking history live here whenever you want a quick snapshot of your momentum."
    ),
    SpotlightStep(
      id: "explore_done",
      anchorID: nil,
      icon: "checkmark.seal.fill",
      title: "You’re All Set",
      message:
        "Use the scan button to photograph your fridge, try demo scenarios, or open Dashboard for full analytics. Happy cooking!"
    ),
  ]

  static let ingredientReview: [SpotlightStep] = [
    SpotlightStep(
      id: "review_welcome",
      anchorID: nil,
      icon: "eyes.inverse",
      title: "Review Your Ingredients",
      message:
        "This page shows everything the scan detected. Items are sorted by confidence — review uncertain ones before finding recipes."
    ),
    SpotlightStep(
      id: "review_confidence",
      anchorID: "confidenceLevels",
      icon: "gauge.with.dots.needle.33percent",
      title: "Confidence Levels",
      message:
        "Auto = high confidence (auto-selected). Confirm = medium confidence (pick the right match). Maybe = low confidence (tap to include)."
    ),
    SpotlightStep(
      id: "review_auto",
      anchorID: "autoDetected",
      icon: "checkmark.seal.fill",
      title: "Auto-Detected Items",
      message:
        "These ingredients were detected with high confidence and are already selected. Tap any chip to deselect it, or tap the ⓘ icon to view nutrition details."
    ),
    SpotlightStep(
      id: "review_confirm",
      anchorID: "needsConfirmation",
      icon: "questionmark.circle.fill",
      title: "Needs Confirmation",
      message:
        "These items need your help. Pick the correct match from the options, tap “Choose another” to search, or “Not this item” to skip."
    ),
    SpotlightStep(
      id: "review_bulk",
      anchorID: "bulkActions",
      icon: "checklist",
      title: "Quick Actions & Add",
      message:
        "“Select Auto” accepts all high-confidence items at once. “Clear Uncertain” resets your choices. The “+ Add” button lets you manually add ingredients the scan missed."
    ),
    SpotlightStep(
      id: "review_toolbar_add",
      anchorID: "toolbarAdd",
      icon: "plus.circle.fill",
      title: "Toolbar Add Button",
      message:
        "You can also add ingredients from the toolbar — same action, always accessible regardless of scroll position."
    ),
    SpotlightStep(
      id: "review_find_recipes",
      anchorID: "findRecipes",
      icon: "fork.knife",
      title: "Find Recipes",
      message:
        "When you’re happy with your selection, tap this button. The count updates as you toggle ingredients — aim for at least 3–5 for better recipe matches."
    ),
  ]

  static let demoMode: [SpotlightStep] = [
    SpotlightStep(
      id: "demo_welcome",
      anchorID: nil,
      icon: "play.rectangle.fill",
      title: "Welcome to Demo Mode",
      message:
        "Each card is a different fridge scenario with real ingredients. Pick one to see how FridgeLuck scans and finds recipes."
    ),
    SpotlightStep(
      id: "demo_scenarios",
      anchorID: "scenarioGrid",
      icon: "square.grid.2x2.fill",
      title: "Pick a Scenario",
      message:
        "Tap any card to preview what’s inside, then scan it. Everything here is safe to explore — try as many as you like."
    ),
  ]

  static let swapIngredients: [SpotlightStep] = [
    SpotlightStep(
      id: "swap_intro",
      anchorID: "swapButton",
      icon: "arrow.triangle.swap",
      title: "Swap Ingredients",
      message:
        "Tap this swap button to open substitutions. Great for dietary needs, allergies, or using what you already have."
    )
  ]

  static let liveAssistantLesson: [SpotlightStep] = [
    SpotlightStep(
      id: "live_lesson_intro",
      anchorID: nil,
      icon: "sparkles.rectangle.stack.fill",
      title: "Your Recipe Match Is Ready",
      message:
        "Before you start cooking, FridgeLuck can turn that recipe into a hands-free kitchen guide from Home."
    ),
    SpotlightStep(
      id: "live_lesson_entry",
      anchorID: "liveAssistantEntry",
      icon: "waveform.and.mic",
      title: "Cook With Le Chef",
      message:
        "Place the phone on a counter stand near your prep area so Gemini can see your cutting board, ingredients, and pan while it guides you live."
    ),
    SpotlightStep(
      id: "live_lesson_grounding",
      anchorID: nil,
      icon: "checkmark.shield.fill",
      title: "Stay Grounded",
      message:
        "Use the assistant for step-by-step coaching, substitutions, and food-safety checks. You can skip this lesson now and reopen it from Home later."
    ),
  ]

  static let recipeMatchReplay: [SpotlightStep] = [
    SpotlightStep(
      id: "recipe_match_intro",
      anchorID: nil,
      icon: "fork.knife.circle.fill",
      title: "Pick A Recipe Match",
      message:
        "This screen turns confirmed ingredients into ranked meal options. Start with the summary, then inspect the strongest match before browsing the full list."
    ),
    SpotlightStep(
      id: "recipe_match_summary",
      anchorID: "recipeResultsSummary",
      icon: "slider.horizontal.3",
      title: "Read The Match Context",
      message:
        "This header explains how FridgeLuck ranked the results, which dietary rules were applied, and how many exact or near matches are available."
    ),
    SpotlightStep(
      id: "recipe_match_best",
      anchorID: "recipeResultsBestMatch",
      icon: "star.circle.fill",
      title: "Start With The Best Match",
      message:
        "The lead card is the fastest way into a strong option. Tap it when you want the most complete fit for your current ingredients."
    ),
    SpotlightStep(
      id: "recipe_match_list",
      anchorID: "recipeResultsList",
      icon: "square.grid.2x2.fill",
      title: "Browse Alternatives",
      message:
        "Use the grid and the near-match section to compare time, nutrition, and coverage before opening a recipe."
    ),
  ]

  static let liveCookReplay: [SpotlightStep] = [
    SpotlightStep(
      id: "live_cook_intro",
      anchorID: nil,
      icon: "waveform.and.mic.circle.fill",
      title: "Cook With Le Chef",
      message:
        "This is the hands-free cooking surface. Keep the setup simple: prop the phone nearby, glance when needed, and let the guide stay out of the way."
    ),
    SpotlightStep(
      id: "live_cook_focus",
      anchorID: "liveCookFocusFrame",
      icon: "viewfinder.circle.fill",
      title: "Frame Your Workspace",
      message:
        "Keep your board, ingredients, and pan inside this area so the assistant has stable visual context while you prep and cook."
    ),
    SpotlightStep(
      id: "live_cook_controls",
      anchorID: "liveCookControls",
      icon: "mic.circle.fill",
      title: "Use The Main Controls",
      message:
        "These controls let you reconnect, toggle the microphone, open the transcript, or end the session without leaving the cooking surface."
    ),
    SpotlightStep(
      id: "live_cook_panel",
      anchorID: "liveCookPanel",
      icon: "list.bullet.rectangle.portrait.fill",
      title: "Follow The Guidance Panel",
      message:
        "The bottom panel keeps the current step, progress, and extra guidance in one place. Swipe up when you need more detail."
    ),
  ]

  static func questAdvance(for quest: TutorialQuest) -> [SpotlightStep] {
    [
      SpotlightStep(
        id: "quest_advance_\(quest.rawValue)",
        anchorID: "quest_\(quest.rawValue)",
        icon: quest.icon,
        title: "Next Up: \(quest.title)",
        message: quest.subtitle
      )
    ]
  }
}
