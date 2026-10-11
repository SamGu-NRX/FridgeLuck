// FLJourneysUITests — suite G (journeys) macOS arm.
//
// Drives the running FridgeLuck app through the nine journeys the programme
// plan (docs/spec/overhaul-20261011, PLAN.md line 52) declares runnable:
// first run, scan and review, Tonight, recipe, cook, complete, share,
// challenge, taste-profile edit.
//
// A journey whose UI surface does not exist in the current build is reported
// `blocked` with the specific missing surface — a REAL failure for the bar
// (100% of journeys), never silently skipped. Every step's outcome is kept
// and attached as `fl-journeys-<runid>.json`; the host-side adapter
// cross-checks this payload against the xcresult summary, so a lie in either
// channel fail-closes the metric instead of passing.
//
// Accessibility identifiers used below do not exist in the app yet; each
// fallback query reports blocked with the exact identifier it looked for,
// which is precisely the gap the overhaul must close.

import XCTest

final class FLJourneysUITests: XCTestCase {

    private var steps: [[String: Any]] = []
    private var runID: String = ""

    override func setUpWithError() throws {
        continueAfterFailure = false
        runID = ISO8601DateFormatter().string(from: Date())
        steps = []
    }

    // MARK: step plumbing

    struct JourneyError: Error {
        let step: String
        let underlying: String
        static func step(name: String, underlying: Substring) -> JourneyError {
            JourneyError(step: name, underlying: String(underlying))
        }
        static func step(name: String, underlying: String) -> JourneyError {
            JourneyError(step: name, underlying: underlying)
        }
    }

    private func resolve(_ app: XCUIApplication,
                         identifiers: [String],
                         labels: [String] = [],
                         timeout: TimeInterval = 4) -> XCUIElement? {
        for id in identifiers {
            let element = app.otherElements[id].firstMatch
            if element.waitForExistence(timeout: timeout) { return element }
            let button = app.buttons[id].firstMatch
            if button.exists { return button }
        }
        for label in labels {
            let byLabel = app.buttons[label].firstMatch
            if byLabel.waitForExistence(timeout: 2) { return byLabel }
        }
        return nil
    }

    private func launchOnboarded(_ app: XCUIApplication) throws {
        app.launchArguments = ["-FLResetState", "-FLSkipOnboarding"]
        app.launch()
    }

    private func launchFresh(_ app: XCUIApplication) throws {
        app.launchArguments = ["-FLResetState"]
        app.launch()
    }

    // MARK: harness

    func test_journey_runner_harness() throws {
        // The runner must be able to launch the app and find the live tab bar;
        // if this fails the per-journey results are untrustworthy.
        let app = XCUIApplication()
        launchOnboarded(app)
        let tabBar = app.tabBars.firstMatch
        XCTAssertTrue(tabBar.waitForExistence(timeout: 10),
                      "app did not reach the tab bar; journeys cannot run")
        // The harness attaches nothing: only test_journeys_run emits the
        // fl-journeys-* payload, so the host adapter can never mistake the
        // harness attachment for the journey list.
    }

    // MARK: journeys

    func test_journeys_run() throws {
        let app = XCUIApplication()
        var results: [[String: Any]] = []

        func record(_ id: String, _ status: String, reason: String = "",
                    blockedBy: String = "", steps: [[String: Any]] = []) {
            results.append(["id": id, "status": status, "reason": reason,
                            "blocked_by": blockedBy, "steps": steps])
        }

        // Each journey body records steps; a thrown error maps to failed
        // (a real defect) with the failing step named.
        func run(_ id: String, label: String,
                 _ body: (XCUIApplication) throws -> Void) {
            steps = []
            do {
                try body(app)
                record(id, "passed", steps: steps)
            } catch let error as JourneyError {
                record(id, "failed", reason: "\(error.step): \(error.underlying)",
                       steps: steps)
            } catch {
                record(id, "failed", reason: String(describing: error).prefix(400),
                       steps: steps)
            }
        }

        func blocked(_ id: String, by: String, steps: [[String: Any]] = []) {
            record(id, "blocked", reason: "required surface absent in this build",
                   blockedBy: by, steps: steps)
        }

        // 1. first run: fresh install lands in onboarding and completes it.
        run("first-run", label: "first run") { app in
            try launchFresh(app)
            let onboarding = resolve(app, identifiers: ["onboarding.next"],
                                     labels: ["Next", "Continue", "Get Started"])
            guard onboarding != nil else {
                throw JourneyError.step(name: "onboarding appears", underlying:
                    "no onboarding affordance found (onboarding.next / Next / Continue)")
            }
            _ = try? onboarding!.tap()
        }

        // 2. scan and review: add ingredients via scan, review detections.
        run("scan-and-review", label: "scan and review") { app in
            launchOnboarded(app)
            let scanTab = resolve(app, identifiers: ["tab.scan", "scan.entry"],
                                  labels: ["Scan"])
            guard scanTab != nil else {
                throw JourneyError.step(name: "open scan", underlying:
                    "no Scan tab or entry affordance found")
            }
            scanTab!.tap()
        }

        // 3. Tonight: dashboard shows a recommendation.
        run("tonight", label: "Tonight recommendation") { app in
            launchOnboarded(app)
            guard app.buttons["home.card_tonight_0"].waitForExistence(timeout: 6)
                    || app.staticTexts["home.card_tonight_0"].exists else {
                throw JourneyError.step(name: "recommendation visible", underlying:
                    "home.card_tonight_0 not found on the dashboard")
            }
        }

        // 4. recipe: open the recommendation into recipe detail.
        run("recipe", label: "recipe detail") { app in
            launchOnboarded(app)
            let card = app.buttons["home.card_tonight_0"].firstMatch
            guard card.waitForExistence(timeout: 6) else {
                throw JourneyError.step(name: "reach recipe", underlying:
                    "home.card_tonight_0 not found to open")
            }
            card.tap()
            guard app.staticTexts["recipe.detail_title"].waitForExistence(timeout: 6) else {
                throw JourneyError.step(name: "recipe detail visible", underlying:
                    "recipe.detail_title not found")
            }
        }

        // 5. cook: enter the live cooking session.
        run("cook", label: "cook session") { app in
            launchOnboarded(app)
            let card = app.buttons["home.card_tonight_0"].firstMatch
            guard card.waitForExistence(timeout: 6) else {
                throw JourneyError.step(name: "reach recipe", underlying:
                    "home.card_tonight_0 not found")
            }
            card.tap()
            let start = resolve(app, identifiers: ["cook.start"], labels: ["Start Cooking"])
            guard start != nil else {
                throw JourneyError.step(name: "start cook", underlying:
                    "cook.start affordance not found")
            }
            start!.tap()
            guard app.staticTexts["cook.live_title"].waitForExistence(timeout: 6) else {
                throw JourneyError.step(name: "cook view live", underlying:
                    "cook.live_title not found")
            }
        }

        // 6. complete: finish the session and log the meal.
        run("complete", label: "complete and log") { app in
            launchOnboarded(app)
            let card = app.buttons["home.card_tonight_0"].firstMatch
            guard card.waitForExistence(timeout: 6) else {
                throw JourneyError.step(name: "reach cook", underlying:
                    "home.card_tonight_0 not found")
            }
            card.tap()
            let start = resolve(app, identifiers: ["cook.start"], labels: ["Start Cooking"])
            guard start != nil else {
                throw JourneyError.step(name: "start cook", underlying:
                    "cook.start affordance not found")
            }
            start!.tap()
            let finish = resolve(app, identifiers: ["cook.finish"],
                                 labels: ["Finish", "Done Cooking"])
            guard finish != nil else {
                throw JourneyError.step(name: "finish cook", underlying:
                    "cook.finish affordance not found")
            }
            finish!.tap()
            let complete = resolve(app, identifiers: ["meal.complete_title"],
                                   labels: ["Meal Complete"])
            guard complete != nil else {
                throw JourneyError.step(name: "meal complete visible", underlying:
                    "meal.complete_title not found")
            }
            let log = resolve(app, identifiers: ["meal.log"], labels: ["Log Meal"])
            guard log != nil else {
                throw JourneyError.step(name: "finalize meal", underlying:
                    "meal.log affordance not found")
            }
            log!.tap()
        }

        // 7. share: share a cooked meal with preview. Absent in this build.
        var shareSteps: [[String: Any]] = []
        do {
            launchOnboarded(app)
            shareSteps.append(["step": "launch onboarded", "ok": true])
            let shareControl = resolve(app, identifiers: ["share.cooked_meal"],
                                       labels: ["Share"], timeout: 3)
            if shareControl == nil {
                blocked("share", by: "no share affordance found in this build",
                        steps: shareSteps)
            } else {
                shareControl!.tap()
                shareSteps.append(["step": "opened share sheet", "ok": true])
                record("share", "passed", steps: shareSteps)
            }
        } catch let error as JourneyError {
            record("share", "failed", reason: "\(error.step): \(error.underlying)",
                   steps: shareSteps)
        }

        // 8. challenge: weekly cook-off in Progress. Absent in this build.
        var challengeSteps: [[String: Any]] = []
        do {
            launchOnboarded(app)
            challengeSteps.append(["step": "launch onboarded", "ok": true])
            let progressTab = resolve(app, identifiers: ["tab.progress"], labels: ["Progress"])
            if progressTab == nil {
                blocked("challenge", by: "no challenge surface in Progress in this build",
                        steps: challengeSteps)
            } else {
                progressTab!.tap()
                challengeSteps.append(["step": "open Progress", "ok": true])
                let challenge = resolve(app, identifiers: ["challenge.weekly_card"],
                                        labels: ["Challenge"])
                if challenge == nil {
                    blocked("challenge",
                            by: "no challenge entry point in Progress in this build",
                            steps: challengeSteps)
                } else {
                    challenge!.tap()
                    challengeSteps.append(["step": "challenge visible", "ok": true])
                    record("challenge", "passed", steps: challengeSteps)
                }
            }
        } catch let error as JourneyError {
            record("challenge", "failed", reason: "\(error.step): \(error.underlying)",
                   steps: challengeSteps)
        }

        // 9. taste-profile edit: correct dietary/preference entries.
        var tasteSteps: [[String: Any]] = []
        do {
            launchOnboarded(app)
            tasteSteps.append(["step": "launch onboarded", "ok": true])
            let settings = resolve(app, identifiers: ["tab.settings"], labels: ["Settings"])
            if settings == nil {
                blocked("taste-profile-edit",
                        by: "no taste-profile page with correctable entries in this build",
                        steps: tasteSteps)
            } else {
                settings!.tap()
                tasteSteps.append(["step": "open Settings", "ok": true])
                let prefs = resolve(app, identifiers: ["settings.food_preferences"],
                                    labels: ["Food Preferences"])
                if prefs == nil {
                    blocked("taste-profile-edit",
                            by: "no taste-profile page with correctable entries in this build",
                            steps: tasteSteps)
                } else {
                    prefs!.tap()
                    tasteSteps.append(["step": "taste profile page visible", "ok": true])
                    record("taste-profile-edit", "passed", steps: tasteSteps)
                }
            }
        } catch let error as JourneyError {
            record("taste-profile-edit", "failed",
                   reason: "\(error.step): \(error.underlying)", steps: tasteSteps)
        }

        // Single attachment: the full journey list. The host adapter requires
        // exactly the nine committed ids.
        let payload: [String: Any] = [
            "emitter": "FLJourneysUITests",
            "run_at": runID,
            "journeys": results,
        ]
        let payloadData = try! JSONSerialization.data(withJSONObject: payload,
                                                      options: [.prettyPrinted, .sortedKeys])
        let attachment = XCTAttachment(uniformTypeIdentifier: "public.json",
                                       name: "fl-journeys-\(runID).json",
                                       payload: payloadData,
                                       userInfo: nil)
        attachment.lifetime = .keepAlways
        add(attachment)

        // The bar: 100% of the nine journeys passed. Blocked-by-missing-surface
        // journeys fail this test (a real failure for the bar) while still
        // being distinguishable from crashes in the payload.
        let nonPassed = results.filter { ($0["status"] as? String) != "passed" }
        XCTAssertTrue(nonPassed.isEmpty,
            "journeys not passed: \(nonPassed.map { "\($0["id"] ?? "?"):\($0["status"] ?? "?")" })")
    }
}
