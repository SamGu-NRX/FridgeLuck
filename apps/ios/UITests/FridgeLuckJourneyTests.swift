import XCTest

/// The main journey from a fresh install to a logged meal: onboarding (including the
/// allergen-safety screen), landing on Home with the user's own kitchen, skipping the
/// short Home tour, manual kitchen inventory, a catalog recipe from Home
/// recommendations, the cooking guide with its structured steps and cook-mode timer,
/// and the meal appearing in Progress.
///
/// Launches with `-FLUITestJourney` so the app starts on an empty temporary database
/// with tour state cleared. The journey walks the real onboarding and the real Home
/// tour, so it fails if Skip leaves the accessibility tree or setup lands in a demo.
@MainActor
final class FridgeLuckJourneyTests: XCTestCase {
  private let launchArgument = "-FLUITestJourney"

  override func setUpWithError() throws {
    continueAfterFailure = false
  }

  func testFreshInstallToLoggedMealJourney() throws {
    let app = XCUIApplication()
    app.launchArguments = [launchArgument]

    // HealthKit may present a system permission dialog if the health step triggers
    // a request; dismiss it whichever way it lands.
    addUIInterruptionMonitor(withDescription: "system alerts") { alert in
      for label in ["Don't Allow", "Don’t Allow", "Deny", "Not Now"] where alert.buttons[label].exists {
        alert.buttons[label].tap()
        return true
      }
      if alert.buttons["Allow"].exists {
        alert.buttons["Allow"].tap()
        return true
      }
      return false
    }

    app.launch()

    finishOnboarding(in: app)
    skipHomeTour(in: app)
    addKitchenInventory(in: app)
    startCatalogRecipe(in: app)
    cookThroughGuide(in: app)
    verifyMealLogged(in: app)
  }

  // MARK: - Onboarding

  private func finishOnboarding(in app: XCUIApplication) {
    XCTContext.runActivity(named: "onboarding: welcome") { _ in
      let getStarted = app.buttons["onboarding_continue_without_apple"]
      XCTAssertTrue(appears(getStarted, in: app, timeout: 20), "Welcome screen did not appear")
      getStarted.tap()
    }

    XCTContext.runActivity(named: "onboarding: name") { _ in
      let nameField = app.textFields["onboarding_name_field"]
      XCTAssertTrue(appears(nameField, in: app, timeout: 15), "Name field did not appear")
      nameField.tap()
      nameField.typeText("Sam Test")
      tapPrimary(app, step: "name")
    }

    // Plain Continue steps between name and allergens: welcome detail, age, goal,
    // feature scan, calories, restrictions, chef intro.
    for step in ["personal", "age", "goal", "featureScan", "calories", "restrictions", "featureChef"] {
      XCTContext.runActivity(named: "onboarding: \(step)") { _ in
        tapPrimary(app, step: step)
      }
    }

    XCTContext.runActivity(named: "onboarding: allergens — select peanut") { _ in
      let peanut = app.buttons["onboarding_allergen_group_peanut"]
      XCTAssertTrue(appears(peanut, in: app, timeout: 15), "Allergen screen did not appear")
      peanut.tap()
      // One tap flags the whole group. The card used to read "3 selected", the number of
      // peanut ingredients behind the group, which looked like a wrong count.
      XCTAssertEqual(peanut.value as? String, "Flagged", "Peanut card did not report its state")
      XCTAssertFalse(
        peanut.label.contains("selected"), "Peanut card shows a count: \(peanut.label)")
      tapPrimary(app, step: "allergens")
    }

    XCTContext.runActivity(named: "onboarding: apple health value") { _ in
      tapPrimary(app, step: "healthValue")
    }

    XCTContext.runActivity(named: "onboarding: skip Apple Health permission") { _ in
      let skip = app.buttons["onboarding_secondary"]
      XCTAssertTrue(appears(skip, in: app, timeout: 15), "Health permission screen did not appear")
      skip.tap()
    }

    // The kitchen review step replaces the shared footer with its own Continue
    // control; every other tappable step advances through the footer primary.
    // The setup bridge has no button at all: it auto-advances to the handoff
    // screen once the profile save and its visual lead-in finish.
    let footerSteps = ["virtualFridgeIntro", "fridgeCapture", "pantryCapture"]
    for step in footerSteps {
      XCTContext.runActivity(named: "onboarding: \(step)") { _ in
        tapPrimary(app, step: step)
      }
    }

    XCTContext.runActivity(named: "onboarding: kitchen review continue") { _ in
      let cont = app.buttons["kitchen_review_continue"]
      XCTAssertTrue(appears(cont, in: app, timeout: 20), "Kitchen review screen did not appear")
      cont.tap()
      usleep(1_500_000)
    }

    XCTContext.runActivity(named: "onboarding: go to my kitchen") { _ in
      let primary = app.buttons["onboarding_primary"]
      XCTAssertTrue(appears(primary, in: app, timeout: 45), "Handoff screen did not appear")
      XCTAssertEqual(primary.label, "Go to my kitchen", "Setup must end in the kitchen, not a demo")
      XCTAssertTrue(
        app.staticTexts["1 allergen flagged"].waitForExistence(timeout: 5),
        "Handoff should count the one allergen group picked, not its ingredients")
      primary.tap()
    }
  }

  // MARK: - Home tour

  /// The tour runs once after setup. Skip must be reachable through the accessibility tree
  /// (it was not: only Next was exposed), and skipping must not claim the tour was finished
  /// or lock the dashboard behind a checklist.
  private func skipHomeTour(in app: XCUIApplication) {
    XCTContext.runActivity(named: "home: skip the tour") { _ in
      let skip = app.buttons["spotlight_skip"]
      XCTAssertTrue(appears(skip, in: app, timeout: 30), "Home tour did not offer Skip")
      XCTAssertEqual(skip.label, "Skip tour")
      XCTAssertTrue(waitUntilHittable(skip, timeout: 10), "Skip tour never became tappable")
      skip.tap()
      XCTAssertTrue(waitUntilGone(skip, timeout: 10), "Home tour did not close after Skip")
    }

    XCTContext.runActivity(named: "home: the user's kitchen, not a demo checklist") { _ in
      let scanFridge = app.buttons["home_scan_fridge"]
      XCTAssertTrue(
        appears(scanFridge, in: app, timeout: 20), "Home did not show the empty-kitchen prompt")
      XCTAssertFalse(
        app.staticTexts["Quick Setup"].exists, "Home is still gated by the tour checklist")
      XCTAssertFalse(
        app.staticTexts["Setup Complete!"].waitForExistence(timeout: 3),
        "Skipping the tour must not say it was finished")
    }
  }

  /// Taps the onboarding footer primary button, waiting for it to become enabled
  /// (setup work and step transitions disable it). Sleeps after the tap so the step
  /// transition lock cannot swallow the next tap as a double-advance.
  private func tapPrimary(_ app: XCUIApplication, step: String) {
    let primary = app.buttons["onboarding_primary"]
    XCTAssertTrue(appears(primary, in: app, timeout: 15), "\(step): primary button missing")
    let enabled = NSPredicate(format: "isEnabled == true")
    let enabledExpectation = expectation(for: enabled, evaluatedWith: primary)
    wait(for: [enabledExpectation], timeout: 15)
    primary.tap()
    usleep(1_500_000)
  }

  /// waitForExistence that prints the app's view hierarchy on a miss. CI uploads no
  /// xcresult, so the log is the only place a failed query can be diagnosed.
  private func appears(_ element: XCUIElement, in app: XCUIApplication, timeout: TimeInterval) -> Bool {
    if element.waitForExistence(timeout: timeout) { return true }
    print("JOURNEY-HIERARCHY-BEGIN\n\(app.debugDescription)\nJOURNEY-HIERARCHY-END")
    return false
  }

  private func waitUntilHittable(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
    let hittable = NSPredicate(format: "exists == true AND hittable == true")
    let expectation = XCTNSPredicateExpectation(predicate: hittable, object: element)
    return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
  }

  private func waitUntilGone(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
    let gone = NSPredicate(format: "exists == false")
    let expectation = XCTNSPredicateExpectation(predicate: gone, object: element)
    return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
  }

  // MARK: - Kitchen inventory

  private func addKitchenInventory(in app: XCUIApplication) {
    XCTContext.runActivity(named: "kitchen: open kitchen tab") { _ in
      let kitchenTab = app.buttons["tab_kitchen"]
      XCTAssertTrue(appears(kitchenTab, in: app, timeout: 20), "Bottom navigation did not appear")
      kitchenTab.tap()
      // Every tab stays mounted; the ones not on screen must leave the accessibility tree.
      let homeGone = waitUntilGone(app.buttons["home_scan_fridge"], timeout: 5)
      if !homeGone {
        print("JOURNEY-HIERARCHY-BEGIN\n\(app.debugDescription)\nJOURNEY-HIERARCHY-END")
      }
      XCTAssertTrue(homeGone, "Home is still in the accessibility tree behind the Kitchen tab")
    }

    XCTContext.runActivity(named: "kitchen: add groceries from the empty state") { _ in
      // A fresh install commits no inventory during onboarding, so the Kitchen
      // renders its empty state; the quick-add cards only appear once items exist.
      let add = app.buttons["Add Groceries"]
      XCTAssertTrue(appears(add, in: app, timeout: 20), "Kitchen empty-state Add Groceries CTA did not appear")
      add.tap()
    }

    // The empty-state CTA opens the mode chooser; the manual card then presents
    // the ingredient picker.
    XCTContext.runActivity(named: "kitchen: choose manual mode") { _ in
      let mode = app.buttons["groceries_mode_manual"]
      XCTAssertTrue(appears(mode, in: app, timeout: 20), "Manual mode card did not appear")
      mode.tap()
    }

    XCTContext.runActivity(named: "kitchen: pick four ingredients") { _ in
      let rows = app.buttons.matching(
        NSPredicate(format: "identifier BEGINSWITH %@", "picker_ingredient_"))
      XCTAssertTrue(appears(rows.firstMatch, in: app, timeout: 20), "Ingredient rows did not appear")
      let count = min(rows.count, 4)
      XCTAssertGreaterThanOrEqual(count, 2, "Fewer than two ingredients available to pick")
      for index in 0..<count {
        rows.element(boundBy: index).tap()
      }
    }

    XCTContext.runActivity(named: "kitchen: confirm picker and review") { _ in
      let done = app.buttons["picker_done_button"]
      XCTAssertTrue(appears(done, in: app, timeout: 15), "Picker Done button did not appear")
      done.tap()

      let commit = app.buttons["groceries_commit"]
      XCTAssertTrue(appears(commit, in: app, timeout: 20), "Review commit button did not appear")
      commit.tap()
    }
  }

  // MARK: - Home recommendation → catalog recipe

  private func startCatalogRecipe(in app: XCUIApplication) {
    XCTContext.runActivity(named: "home: open the primary recommendation") { _ in
      // The groceries sheet shows a success state and dismisses itself; the tab bar
      // is covered until then.
      let homeTab = app.buttons["tab_home"]
      XCTAssertTrue(waitUntilHittable(homeTab, timeout: 20), "Groceries sheet never dismissed")
      homeTab.tap()

      let letsCook = app.buttons["home_recommendation_lets_cook"]
      XCTAssertTrue(appears(letsCook, in: app, timeout: 45),
        "Home never offered a recommendation — inventory commit or recommendation reload failed")
      letsCook.tap()
    }

    XCTContext.runActivity(named: "results: open a catalog recipe") { _ in
      let anyStart = app.buttons.matching(
        NSPredicate(format: "identifier BEGINSWITH %@", "recipe_start_cooking_"))
      let catalogStart = app.buttons.matching(
        NSPredicate(format: "identifier BEGINSWITH %@", "recipe_start_cooking_catalog_"))

      // Results auto-presents the recommended recipe's preview drawer. When that
      // recipe is from the catalog, start it there; otherwise close the drawer and
      // pick a catalog recipe from the list.
      if anyStart.firstMatch.waitForExistence(timeout: 10), catalogStart.firstMatch.exists {
        XCTAssertTrue(
          waitUntilHittable(catalogStart.firstMatch, timeout: 10), "Start cooking never became tappable")
        catalogStart.firstMatch.tap()
        return
      }
      if anyStart.firstMatch.exists {
        let top = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.12))
        top.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.95)))
        XCTAssertTrue(waitUntilGone(anyStart.firstMatch, timeout: 10), "Auto-presented drawer did not close")
      }

      let catalogHero = app.buttons.matching(
        NSPredicate(format: "identifier BEGINSWITH %@", "results_hero_catalog_"))
      let catalogCards = app.buttons.matching(
        NSPredicate(format: "identifier BEGINSWITH %@", "results_card_catalog_"))

      if catalogHero.firstMatch.waitForExistence(timeout: 20) {
        catalogHero.firstMatch.tap()
      } else {
        XCTAssertTrue(appears(catalogCards.firstMatch, in: app, timeout: 20),
          "No catalog recipe in the results — the journey must exercise the bundle pool, not the demo pool")
        catalogCards.firstMatch.tap()
      }

      XCTAssertTrue(appears(catalogStart.firstMatch, in: app, timeout: 20),
        "Preview drawer did not present a catalog recipe")
      XCTAssertTrue(
        waitUntilHittable(catalogStart.firstMatch, timeout: 10), "Start cooking never became tappable")
      catalogStart.firstMatch.tap()
    }
  }

  // MARK: - Cooking guide

  private func cookThroughGuide(in app: XCUIApplication) {
    XCTContext.runActivity(named: "guide: walk the steps") { _ in
      let next = app.buttons["guide_next"]
      XCTAssertTrue(appears(next, in: app, timeout: 20), "Cooking guide did not appear")

      var stepTexts: [String] = []
      var sawTimerControl = false

      // Page 0 is the ingredients checklist; steps start after it. Walk until the
      // completion button replaces Next.
      var guardCounter = 0
      while !app.buttons["guide_complete"].exists && guardCounter < 30 {
        guardCounter += 1

        let stepText = app.staticTexts["guide_step_text"].firstMatch
        if stepText.exists {
          stepTexts.append(stepText.label)
        }

        let timerButton = app.buttons["guide_start_timer"].firstMatch
        if timerButton.exists && timerButton.isHittable {
          sawTimerControl = true
          timerButton.tap()
          // The tap must show something: the countdown replaces the start button in place.
          XCTAssertTrue(
            appears(app.descendants(matching: .any)["guide_timer_card"].firstMatch, in: app, timeout: 5),
            "Starting the step timer showed no countdown")
          XCTAssertFalse(
            app.buttons["guide_start_timer"].exists,
            "The start button stayed up, so a second tap could start a duplicate timer")
        }

        next.tap()
        usleep(800_000)
      }

      // The final step is on screen when the complete button appears.
      let finalStep = app.staticTexts["guide_step_text"].firstMatch
      if finalStep.exists {
        stepTexts.append(finalStep.label)
      }

      XCTAssertGreaterThanOrEqual(
        stepTexts.count, 2,
        "Guide showed \(stepTexts.count) structured steps; expected at least two")
      XCTAssertTrue(
        sawTimerControl,
        "No step offered a timer — a timed step should surface the cook-mode timer chip")
      XCTAssertTrue(app.buttons["guide_complete"].exists, "Guide never reached its final step")
    }

    XCTContext.runActivity(named: "guide: complete the meal") { _ in
      app.buttons["guide_complete"].tap()

      let done = app.buttons["celebration_done"]
      XCTAssertTrue(appears(done, in: app, timeout: 20), "Celebration did not appear")
      done.tap()

      // The rating nudge alert fires before the meal is saved; skip the rating.
      let skip = app.alerts.buttons["Skip"]
      XCTAssertTrue(appears(skip, in: app, timeout: 10), "Rating nudge did not appear")
      skip.tap()
    }
  }

  // MARK: - Progress

  private func verifyMealLogged(in app: XCUIApplication) {
    XCTContext.runActivity(named: "progress: the logged meal appears") { _ in
      // Cooking completion returns Home, where the bottom navigation is visible again.
      let progressTab = app.buttons["tab_progress"]
      XCTAssertTrue(appears(progressTab, in: app, timeout: 20), "Bottom navigation did not return")

      let back = app.navigationBars.buttons.firstMatch
      if back.exists && back.isHittable {
        back.tap()
      }

      progressTab.tap()

      let meal = app.descendants(matching: .any).matching(
        NSPredicate(format: "identifier BEGINSWITH %@", "progress_recent_meal_")
      ).firstMatch
      XCTAssertTrue(appears(meal, in: app, timeout: 20), "The cooked meal never appeared in Progress")
    }
  }
}
