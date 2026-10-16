import FLFeatureLogic
import XCTest

/// Table-driven transitions of the cook-session reducer (LeChef §4), including replay
/// after a simulated app kill.
final class CookSessionReducerTests: XCTestCase {
  private let t0 = Date(timeIntervalSince1970: 1_760_000_000)
  private let t1 = Date(timeIntervalSince1970: 1_760_000_060)
  private let t2 = Date(timeIntervalSince1970: 1_760_000_120)

  private func steps(_ count: Int) -> [CookStep] {
    (0..<count).map { CookStep(text: "Step \($0 + 1)", timerSeconds: $0 == 1 ? 120 : nil) }
  }

  private func ref() -> CookRecipeRef {
    CookRecipeRef(source: .catalog, id: "chicken-udon", revision: 3)
  }

  private func started(_ stepCount: Int = 4, servings: Int = 2) -> CookSession {
    CookSessionMachine().sessionAfter(
      .start(CookSessionEvent.Start(
        id: "sess_test", recipeRef: ref(), servings: servings, eaterIDs: ["you"],
        steps: steps(stepCount), now: t0)))
  }

  private func advanced(_ times: Int, from base: CookSession) -> CookSession {
    var machine = CookSessionMachine(session: base)
    for index in 0..<times {
      machine.send(.advance(now: t1.addingTimeInterval(Double(index))))
    }
    return machine.session
  }

  // MARK: - Transition table

  func testTransitionTable() {
    let started = started()
    let advancedOnce = advanced(1, from: started)
    let atLast = advanced(3, from: started)

    let table: [(String, CookSession, CookSessionEvent, CookSessionPhase, Int, Set<Int>)] = [
      // (name, from, event, expected phase, expected currentStep, expected completed)
      ("start from idle", .idle, .start(CookSessionEvent.Start(id: "s", recipeRef: ref(), servings: 2, eaterIDs: [], steps: steps(3), now: t0)), .cooking, 0, []),
      ("start when cooking is a no-op", started, .start(CookSessionEvent.Start(id: "s2", recipeRef: ref(), servings: 4, eaterIDs: [], steps: steps(3), now: t1)), .cooking, 0, []),
      ("advance marks current and moves on", started, .advance(now: t1), .cooking, 1, [0]),
      ("advance at the last step is a no-op", atLast, .advance(now: t1), .cooking, 3, [0, 1, 2]),
      ("back steps back and unmarks", advancedOnce, .back(now: t1), .cooking, 0, []),
      ("back at the first step is a no-op", started, .back(now: t1), .cooking, 0, []),
      ("toggle adds a check", started, .toggleCompleted(step: 2), .cooking, 0, [2]),
      ("abandon keeps the record", started, .abandon(now: t1), .abandoned, 0, []),
      ("complete only from the last step", advancedOnce, .complete(now: t1), .cooking, 1, [0]),
      ("complete reaches remembering from the last step", atLast, .complete(now: t2), .remembering, 3, [0, 1, 2, 3]),
      ("saveRemember from remembering", advanced(3, from: started).after(.complete(now: t2)), .saveRemember(rating: 5, note: "use less salt", now: t2), .remembered, 3, [0, 1, 2, 3]),
      ("skipRemember from remembering", advanced(3, from: started).after(.complete(now: t2)), .skipRemember(now: t2), .remembered, 3, [0, 1, 2, 3]),
    ]

    for (name, from, event, phase, currentStep, completed) in table {
      let transition = CookSessionReducer.reduce(from, event)
      XCTAssertEqual(transition.session.phase, phase, name)
      XCTAssertEqual(transition.session.currentStep, currentStep, name)
      XCTAssertEqual(transition.session.completedSteps, completed, name)
    }
  }

  func testStartGuards() {
    // Empty steps never start a session — cook mode cannot be empty (LeChef §3.1).
    let empty = CookSessionReducer.reduce(
      .idle,
      .start(CookSessionEvent.Start(id: "s", recipeRef: ref(), servings: 2, eaterIDs: [], steps: [], now: t0)))
    XCTAssertEqual(empty.session.phase, .idle)

    // Servings must be positive.
    let zeroServings = CookSessionReducer.reduce(
      .idle,
      .start(CookSessionEvent.Start(id: "s", recipeRef: ref(), servings: 0, eaterIDs: [], steps: steps(3), now: t0)))
    XCTAssertEqual(zeroServings.session.phase, .idle)
  }

  func testStartCarriesServingsEatersAndRevision() {
    let session = CookSessionReducer.reduce(
      .idle,
      .start(CookSessionEvent.Start(id: "sess_a", recipeRef: ref(), servings: 4, eaterIDs: ["you", "ada"], steps: steps(3), now: t0))
    ).session

    XCTAssertEqual(session.id, "sess_a")
    XCTAssertEqual(session.servings, 4)
    XCTAssertEqual(session.eaterIDs, ["you", "ada"])
    XCTAssertEqual(session.startedAt, t0)
    XCTAssertEqual(session.revision, 1)
    XCTAssertNil(session.endedAt)
  }

  func testInvalidRememberRatingIsRejected() {
    var machine = CookSessionMachine(session: started(3))
    machine.send(.advance(now: t1))
    machine.send(.advance(now: t1))
    machine.send(.complete(now: t2))
    let remembering = machine.session

    let rated6 = CookSessionReducer.reduce(remembering, .saveRemember(rating: 6, note: nil, now: t2))
    XCTAssertEqual(rated6.session.phase, .remembering, "rating 6 is out of range")

    let rated0 = CookSessionReducer.reduce(remembering, .saveRemember(rating: 0, note: nil, now: t2))
    XCTAssertEqual(rated0.session.phase, .remembering, "rating 0 is out of range")

    let unrated = CookSessionReducer.reduce(remembering, .saveRemember(rating: nil, note: nil, now: t2))
    XCTAssertEqual(unrated.session.phase, .remembered, "nil rating is a valid save")
  }

  func testAbandonedThenRememberFlowsAreSeparated() {
    // abandon is only reachable from cooking; remembering only from the last step.
    var machine = CookSessionMachine(session: started(3))
    machine.send(.abandon(now: t1))
    let abandoned = machine.session
    XCTAssertEqual(abandoned.endedAt, t1)

    let saveAfterAbandon = CookSessionReducer.reduce(abandoned, .saveRemember(rating: 3, note: nil, now: t2))
    XCTAssertEqual(saveAfterAbandon.session.phase, .abandoned, "abandoned sessions don't move to remembered")
  }

  func testAdaptationsAndSubstitutionsAreRecorded() {
    var machine = CookSessionMachine(session: started(3))
    machine.send(.applyAdaptation(CookAdaptation(kind: .servings, input: "6 servings", applied: "herbs 2 tsp", caption: "dried herbs — scaled less", at: t1)))
    machine.send(.applySubstitution(CookSubstitution(originalKey: "sour_cream", substituteKey: "greek_yoghurt", note: "a little tangier, less rich", source: .table, at: t1)))

    XCTAssertEqual(machine.session.adaptations.count, 1)
    XCTAssertEqual(machine.session.substitutions.count, 1)
    XCTAssertEqual(machine.session.adaptations.first?.caption, "dried herbs — scaled less")
    XCTAssertEqual(machine.session.substitutions.first?.note, "a little tangier, less rich")
  }

  // MARK: - Commands (voice and touch are the same reducer calls)

  func testVoiceAndTouchCommandsShareTheReducer() {
    var byTouch = CookSessionMachine(session: started(3))
    byTouch.send(.advance(now: t1))

    var byVoice = CookSessionMachine(session: started(3))
    byVoice.send(.command(.next, now: t1))

    XCTAssertEqual(byTouch.session, byVoice.session)
    XCTAssertEqual(byVoice.session.completedSteps, [0])
  }

  func testShowCommandRequestsACameraLookAndChangesNothing() {
    let session = started(3)
    let transition = CookSessionReducer.reduce(session, .command(.show, now: t1))
    XCTAssertEqual(transition.session, session)
    XCTAssertEqual(transition.effects, [.requestCameraLook])
  }

  func testTimerCommandEmitsCreateTimerAndChangesNothing() {
    let session = started(3)
    let transition = CookSessionReducer.reduce(session, .command(.timer(seconds: 90), now: t1))
    XCTAssertEqual(transition.session, session)
    XCTAssertEqual(transition.effects, [.createTimer(seconds: 90)])
  }

  func testShowAndTimerCommandsActOnlyInsideALiveCook() {
    // The camera is the most sensitive device surface (LeChef D3): outside `.cooking` no
    // command opens it or starts a timer — the same guard next/back/repeat already have.
    for phase in [CookSession.idle, started(3).after(.abandon(now: t1))] {
      XCTAssertEqual(CookSessionReducer.reduce(phase, .command(.show, now: t1)).effects, [], "\(phase.phase): no camera request")
      XCTAssertEqual(CookSessionReducer.reduce(phase, .command(.timer(seconds: 90), now: t1)).effects, [], "\(phase.phase): no timer")
    }
  }

  func testUnrecognizedCommandChangesNothingAndSaysSo() {
    let session = started(3)
    let transition = CookSessionReducer.reduce(session, .command(.unrecognized(phrase: "what can I do with fennel"), now: t1))
    XCTAssertEqual(transition.session, session, "an unknown phrase changes nothing")
    guard case let .commandHint(text)? = transition.effects.first else {
      return XCTFail("expected a command hint effect")
    }
    XCTAssertTrue(text.contains("next, back, repeat, show"))
    XCTAssertTrue(text.contains("what can I do with fennel"))
  }

  // MARK: - Effects

  func testSafetyCheckHasPriorityOverTimerSuggestion() {
    let both = CookStep(
      text: "Fry the chicken until done.",
      timerSeconds: 240,
      thermometer: CookThermometer(endpointC: 74, food: "chicken, thickest piece", source: "usda-fsis: poultry 165 F"))
    let effects = CookSessionReducer.stepEffects(both, at: 2)

    guard effects.count >= 2, case let .showSafetyCheck(step, prompt)? = effects.first else {
      return XCTFail("safety check must come first when a step carries one")
    }
    XCTAssertEqual(step, 2)
    XCTAssertEqual(prompt.temperatureC, 74)
    XCTAssertTrue(prompt.source.hasPrefix("usda-fsis"))
    guard case let .suggestTimer(_, seconds)? = effects.last else {
      return XCTFail("timer suggestion should still be offered")
    }
    XCTAssertEqual(seconds, 240)
  }

  func testRepeatEmitsSpeakStep() {
    var machine = CookSessionMachine(session: started(3))
    let effects = machine.send(.repeatStep)
    XCTAssertEqual(effects, [.speakStep(index: 0, text: "Step 1")])
  }

  func testAdvancingToATimedStepSuggestsItsTimer() {
    var machine = CookSessionMachine(session: started(4))
    let effects = machine.send(.advance(now: t1))
    XCTAssertEqual(effects, [.suggestTimer(step: 1, seconds: 120)])
  }

  // MARK: - Persistence and replay (app kill / relaunch)

  func testReplayReproducesTheSession() {
    var machine = CookSessionMachine()
    machine.start(id: "sess_k", recipeRef: ref(), servings: 2, eaterIDs: ["you"], steps: steps(4), now: t0)
    machine.send(.advance(now: t1))
    machine.send(.toggleCompleted(step: 2))
    machine.send(.applySubstitution(CookSubstitution(originalKey: "a", substituteKey: "b", note: "n", source: .manual, at: t1)))
    machine.send(.advance(now: t1))

    let log: [CookSessionEvent] = [
      .start(CookSessionEvent.Start(id: "sess_k", recipeRef: ref(), servings: 2, eaterIDs: ["you"], steps: steps(4), now: t0)),
      .advance(now: t1),
      .toggleCompleted(step: 2),
      .applySubstitution(CookSubstitution(originalKey: "a", substituteKey: "b", note: "n", source: .manual, at: t1)),
      .advance(now: t1),
    ]

    XCTAssertEqual(CookSessionMachine.replay(log), machine.session, "folding the log reproduces the session exactly")
  }

  func testSessionSurvivesAKillThroughJSONRoundTrip() throws {
    var machine = CookSessionMachine()
    machine.start(id: "sess_k", recipeRef: ref(), servings: 2, eaterIDs: ["you"], steps: steps(4), now: t0)
    machine.send(.advance(now: t1))
    machine.send(.advance(now: t1))
    let beforeKill = machine.session

    // The app is killed here; only the persisted value survives.
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let persisted = try encoder.encode(beforeKill)

    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let afterRelaunch = try decoder.decode(CookSession.self, from: persisted)

    // The session resumes on the same step with the same completed checks.
    XCTAssertEqual(afterRelaunch, beforeKill)
    XCTAssertEqual(afterRelaunch.currentStep, 2)
    XCTAssertEqual(afterRelaunch.completedSteps, [0, 1])
    XCTAssertEqual(afterRelaunch.phase, .cooking)

    // And it continues from there.
    var resumed = CookSessionMachine(session: afterRelaunch)
    resumed.send(.advance(now: t2))
    XCTAssertEqual(resumed.session.currentStep, 3)
    XCTAssertEqual(resumed.session.completedSteps, [0, 1, 2])
  }
}

extension CookSession {
  /// Convenience for tests: reduce an event on this session and return the next session.
  func after(_ event: CookSessionEvent) -> CookSession {
    CookSessionReducer.reduce(self, event).session
  }
}

extension CookSessionMachine {
  /// Convenience for tests: send an event and return the resulting session.
  func sessionAfter(_ event: CookSessionEvent) -> CookSession {
    var machine = self
    machine.send(event)
    return machine.session
  }
}
