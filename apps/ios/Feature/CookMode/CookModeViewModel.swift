import FLFeatureLogic
import Foundation
import UserNotifications

/// Produces the step values a session cooks. On resume the store re-derives steps from the
/// recipe's instructions — the row deliberately does not duplicate them.
enum CookStepsProviding {
  static func steps(for recipe: Recipe) -> [CookStep] {
    CookStepParsing.parse(instructions: recipe.instructions).steps
  }
}

/// Schedules and cancels the device notifications behind cook timers (LeChef §4.2).
protocol CookTimerScheduling: Sendable {
  func schedule(id: String, label: String, deadline: Date)
  func cancel(id: String)
}

/// The real scheduler over user notifications.
struct CookTimerNotificationScheduler: CookTimerScheduling {
  func schedule(id: String, label: String, deadline: Date) {
    let content = UNMutableNotificationContent()
    content.title = label
    content.body = "Your timer is done."
    content.sound = .default
    let components = Calendar.current.dateComponents(
      [.year, .month, .day, .hour, .minute, .second], from: deadline)
    let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
    let request = UNNotificationRequest(identifier: id, content: content, trigger: trigger)
    UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
  }

  func cancel(id: String) {
    UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [id])
  }
}

/// One cook session, end to end. The session reducer is the state machine; this view model is
/// the device that performs its effects — timers, notifications, persistence, substitutions,
/// scaling, and the meal log (LeChef §3, §4). Views read `state` and call intents.
@MainActor
final class CookModeViewModel: ObservableObject {
  /// Everything the session touches outside its own state. A nil store means an in-memory
  /// session (tests, the chat surface); the shipped guide wires the real stores.
  struct Dependencies {
    var store: CookSessionPersisting?
    /// The substitution table's options for an ingredient id.
    var substitutionOptions: (Int64) -> [Substitution]
    /// Whether the substitute is an allergen for any eater: true blocks, false clears,
    /// nil is unknown — unknown blocks (fail closed, LeChef §7).
    var substituteIsAllergen: (Int64) -> Bool?
    var logMeal: (Recipe, Int?, Int, [IngredientSwap]) throws -> Void
    /// The recipe's scale lines for the scaling engine, for the current serving count.
    var scaleLines: () -> [CookScaleLine]
    /// Corrects a pantry line's quantity/state from an approved proposal; nil disables.
    var inventoryCorrection: ((Int64, String) -> Bool)?
    var now: () -> Date
    var newID: () -> String
    var scheduler: any CookTimerScheduling

    /// In-memory dependencies — no persistence, no notifications, no meal logging.
    static func ephemeral(now: @escaping () -> Date = Date.init) -> Dependencies {
      Dependencies(
        store: nil,
        substitutionOptions: { _ in [] },
        substituteIsAllergen: { _ in nil },
        logMeal: { _, _, _, _ in },
        scaleLines: { [] },
        inventoryCorrection: nil,
        now: now,
        newID: { UUID().uuidString.lowercased() },
        scheduler: NoopTimerScheduler())
    }
  }

  struct NoopTimerScheduler: CookTimerScheduling {
    func schedule(id: String, label: String, deadline: Date) {}
    func cancel(id: String) {}
  }

  @Published private(set) var state: CookModeState
  @Published private(set) var phase: CookSessionPhase = .idle
  /// The current step's stated duration, if the text gives one — no fake timers (LeChef §8.4).
  @Published private(set) var suggestedTimerSeconds: Int?
  /// The LeChef line currently shown: a repeated step, a safety check, or a command hint.
  @Published private(set) var hint: String?

  private(set) var session = CookSession.idle
  private var timerStore = CookTimerStore()
  private let recipe: Recipe
  private let servingsBase: Int
  private let logsMeal: Bool
  /// Structured catalog steps + identity for a catalog cook; nil for legacy recipes.
  private let catalog: CatalogCookContent?
  private var deps: Dependencies
  /// Set once the meal log has been written for this session — the finish path is exactly-once.
  private var mealLogged = false
  private var tickTask: Task<Void, Never>?

  init(recipe: Recipe, logsMeal: Bool, dependencies: Dependencies) {
    self.recipe = recipe
    self.logsMeal = logsMeal
    self.deps = dependencies
    self.servingsBase = max(recipe.servings, 1)
    self.state = CookModeState.build(
      session: .idle,
      timerStore: CookTimerStore(),
      now: dependencies.now(),
      hint: nil,
      suggestedTimerSeconds: nil)
  }

  deinit {
    tickTask?.cancel()
  }

  // MARK: Lifecycle

  /// Starts a fresh session, or resumes the persisted one for this recipe if one is still
  /// cooking (LeChef §4.2). Persists the session either way.
  func startOrResume() {
    let now = deps.now()
    let ref = CookRecipeRef(source: .catalog, id: String(recipe.id ?? -1), revision: 1)

    if let active = try? deps.store?.loadActiveSession(),
      active.session.phase == .cooking,
      active.session.recipeRef?.id == ref.id
    {
      // Resume: re-derive the steps from the recipe — the row does not duplicate them.
      var restored = active.session
      restored.attachSteps(CookStepsProviding.steps(for: recipe))
      session = restored
      timerStore = active.timers
    } else {
      let transition = CookSessionReducer.reduce(
        .idle,
        .start(CookSessionEvent.Start(
          id: "sess_" + deps.newID(),
          recipeRef: ref,
          servings: servingsBase,
          eaterIDs: [],
          steps: CookStepsProviding.steps(for: recipe),
          now: now)))
      session = transition.session
      timerStore = CookTimerStore()
    }

    phase = session.phase
    suggestedTimerSeconds = session.currentCookStep?.timerSeconds
    refreshState()
    persist()
    startTicking()
  }

  // MARK: Step navigation

  /// Next: marks the current step completed and moves on; on the last step it finishes
  /// cooking (LeChef §4.2).
  func advance() {
    guard session.phase == .cooking else { return }
    if session.currentStep == session.steps.count - 1 {
      complete()
    } else {
      apply(.advance(now: deps.now()))
    }
  }

  /// Back: leaves the current step unmarked and steps back — redo, not history (LeChef §5).
  func back() {
    guard session.phase == .cooking, session.currentStep > 0 else { return }
    apply(.back(now: deps.now()))
  }

  /// The step's completed check — toggle without moving (LeChef §4.2).
  func toggleCompleted() {
    guard session.phase == .cooking else { return }
    apply(.toggleCompleted(step: session.currentStep))
  }

  /// Repeat: re-reads the current step (LeChef §4.2).
  func repeatStep() {
    apply(.repeatStep)
  }

  // MARK: Timers

  /// Creates a device timer; the store's returned timer is the acknowledgment. Nothing here
  /// invents a duration from text (LeChef §8.4).
  @discardableResult
  func addTimer(seconds: Int, label: String) -> Bool {
    guard session.phase == .cooking else { return false }
    let id = "timer_" + deps.newID()
    guard let created = timerStore.create(
      id: id, sessionID: session.id, label: label, durationSeconds: Double(seconds), now: deps.now())
    else { return false }

    for effect in created.effects {
      perform(effect, timerID: id, label: label)
    }
    hint = "Timer set: \(label)"
    refreshState()
    persist()
    return true
  }

  /// Uses the current step's stated duration — the suggestion chip.
  func startSuggestedTimer() {
    guard let seconds = suggestedTimerSeconds else { return }
    addTimer(seconds: seconds, label: "Step \(session.currentStep + 1)")
  }

  func pauseTimer(id: String) {
    guard let effects = timerStore.pause(id: id, now: deps.now()) else { return }
    for effect in effects { perform(effect, timerID: id, label: nil) }
    refreshState()
    persist()
  }

  func resumeTimer(id: String) {
    guard let effects = timerStore.resume(id: id, now: deps.now()) else { return }
    for effect in effects { perform(effect, timerID: id, label: nil) }
    refreshState()
    persist()
  }

  /// Moves a running timer's deadline — an approved "add two minutes" proposal.
  @discardableResult
  func adjustTimer(id: String, seconds: Double) -> Bool {
    guard let effects = timerStore.adjust(id: id, durationSeconds: seconds, now: deps.now())
    else { return false }
    for effect in effects { perform(effect, timerID: id, label: nil) }
    refreshState()
    persist()
    return true
  }

  /// Acknowledges a fired timer — the only way it stops presenting as pending (LeChef §4.2).
  func acknowledgeTimer(id: String) {
    timerStore.acknowledge(id: id, at: deps.now())
    refreshState()
    persist()
  }

  func removeTimer(id: String) {
    guard let effects = timerStore.remove(id: id) else { return }
    for effect in effects { perform(effect, timerID: id, label: nil) }
    refreshState()
    persist()
  }

  private func perform(_ effect: CookTimerEffect, timerID: String, label: String?) {
    switch effect {
    case .scheduleNotification(_, let deadline):
      if let label {
        deps.scheduler.schedule(id: timerID, label: label, deadline: deadline)
      }
    case .cancelNotification(let id):
      deps.scheduler.cancel(id: id)
    }
  }

  // MARK: Substitutions

  /// The table's options for an ingredient — the swap sheet's data.
  func options(forIngredientID id: Int64) -> [Substitution] {
    deps.substitutionOptions(id)
  }

  /// Applies a swap after the allergen re-check — unknown blocks, fail closed (LeChef §7).
  /// Returns the re-check's canonical JSON and whether it executed; the blocked attempt is
  /// still recorded so the transcript shows the refusal, not silence.
  @discardableResult
  func applySubstitution(originalID: Int64, substitute: Substitution) -> (recheckJSON: String, executed: Bool) {
    guard session.phase == .cooking || session.phase == .remembering else {
      return (CookSubstitutionRecheck(blocked: true, checkedIDs: []).canonicalJSON, false)
    }

    let recheck: CookSubstitutionRecheck
    switch deps.substituteIsAllergen(substitute.substituteId) {
    case .some(false):
      recheck = CookSubstitutionRecheck(blocked: false, checkedIDs: [])
    case .some(true), .none:
      // Blocked or unknown composition — both block (fail closed, LeChef §7). The attempt is
      // recorded with its re-check so the transcript shows the refusal, not silence.
      recheck = CookSubstitutionRecheck(blocked: true, checkedIDs: [])
      try? deps.store?.record(
        substitution: CookSubstitution(
          originalKey: String(originalID),
          substituteKey: String(substitute.substituteId),
          note: substitute.note ?? "",
          source: .table,
          at: deps.now()),
        sessionID: session.id,
        allergenRecheckJSON: recheck.canonicalJSON)
      return (recheck.canonicalJSON, false)
    }

    let substitution = CookSubstitution(
      originalKey: String(originalID),
      substituteKey: String(substitute.substituteId),
      note: substitute.note ?? "swapped",
      source: .table,
      at: deps.now())
    apply(.applySubstitution(substitution))
    try? deps.store?.record(
      substitution: substitution,
      sessionID: session.id,
      allergenRecheckJSON: recheck.canonicalJSON)
    return (recheck.canonicalJSON, true)
  }

  // MARK: Scaling

  /// Adapts the recipe to a new serving count through the scaling engine and records the
  /// adaptation — captions kept, including "didn't scale" lines (LeChef §6). A no-op repeat
  /// (already at that count) reports success without recording anything.
  @discardableResult
  func adaptServings(to newServings: Int) -> Bool {
    guard session.phase == .cooking || session.phase == .remembering, newServings > 0
    else { return false }
    guard newServings != session.servings else { return true }

    let scaled = ScalingEngine.scale(deps.scaleLines(), from: session.servings, to: newServings)
    let changed = scaled.filter(\.changed).count
    let held = scaled.count - changed
    let caption = scaled.first(where: { !$0.changed && $0.caption != nil })?.caption
      ?? "scaled to \(newServings) servings"

    apply(.applyAdaptation(CookAdaptation(
      kind: .servings,
      input: "\(newServings) servings",
      applied: "\(changed) line(s) scaled, \(held) held",
      caption: caption,
      at: deps.now())))
    return true
  }

  // MARK: Voice and touch commands

  /// Routes a parsed command through the session — voice and touch feed the same reducer
  /// (LeChef §4.3). Returns the line to speak back, or nil for silence.
  @discardableResult
  func send(_ command: CookCommand) -> String? {
    switch command {
    case .next, .back, .repeatStep, .show, .timer, .unrecognized:
      let transition = apply(.command(command, now: deps.now()))
      for effect in transition.effects {
        switch effect {
        case .createTimer(let seconds):
          addTimer(seconds: seconds, label: "Voice timer")
        case .commandHint(let text):
          return text
        case .speakStep(_, let text):
          return text
        case .showSafetyCheck(_, let prompt):
          return prompt.instruction
        case .suggestTimer, .requestCameraLook:
          break
        }
      }
      return reply(for: command)
    }
  }

  private func reply(for command: CookCommand) -> String? {
    switch command {
    case .next:
      return session.phase == .cooking
        ? state.nextStepSummary.map { "Next: \($0)" } ?? "Next step."
        : nil
    case .back:
      return session.phase == .cooking ? "Going back." : nil
    case .show:
      return session.phase == .cooking ? "One look." : nil
    case .unrecognized:
      return "I only know next, back, repeat, show, and timer minutes."
    case .repeatStep, .timer:
      return nil
    }
  }

  // MARK: Finish

  /// Finish — reachable only from the last step (LeChef §4.2). Cooking ends, remembering begins.
  func complete() {
    guard session.phase == .cooking else { return }
    apply(.complete(now: deps.now()))
  }

  /// Skips the remember step entirely (LeChef §9).
  func skipRemember() {
    apply(.skipRemember(now: deps.now()))
    finishIntoMealLog()
  }

  /// Saves the remember receipt and finishes the session. The meal log is written at most once
  /// per session — a second save updates the receipt, never the log (LeChef §9, §10).
  func saveRemember(rating: Int?, note: String?) {
    guard session.phase == .remembering else { return }
    apply(.saveRemember(rating: rating, note: note, now: deps.now()))

    try? deps.store?.record(remember: CookRememberEntry(
      sessionID: session.id,
      rating: rating,
      note: note,
      savedAt: deps.now(),
      skipped: false))

    finishIntoMealLog()
  }

  /// Writes the meal log exactly once per session (LeChef §10). Remember save and skip both
  /// funnel here; the guard makes a double call a no-op.
  @discardableResult
  func finishIntoMealLog() -> Bool {
    guard logsMeal, !mealLogged,
      session.phase == .remembering || session.phase == .remembered
    else { return false }
    mealLogged = true

    let swaps = session.substitutions.compactMap { substitution -> IngredientSwap? in
      guard let original = Int64(substitution.originalKey), let substitute = Int64(substitution.substituteKey)
      else { return nil }
      return IngredientSwap(
        originalIngredientId: original,
        substituteIngredientId: substitute,
        ratio: 1.0)
    }

    do {
      try deps.logMeal(recipe, session.rating, session.servings, swaps)
      return true
    } catch {
      mealLogged = false
      return false
    }
  }

  /// Abandons the session — terminal, timers cancelled (LeChef §2).
  func abandon() {
    guard session.phase == .cooking || session.phase == .remembering else { return }
    for timer in timerStore.timers {
      deps.scheduler.cancel(id: timer.id)
    }
    apply(.abandon(now: deps.now()))
  }

  // MARK: Proposal execution (SPEC §8)

  /// Conformance is declared in the extension after the class; these are the witnesses.
  var snapshotRevision: Int { session.revision }

  func executeTimerStart(seconds: Int, label: String) -> Bool {
    addTimer(seconds: seconds, label: label)
  }

  func executeTimerAdjust(timerId: String, newDurationSeconds: Int) -> Bool {
    adjustTimer(id: timerId, seconds: Double(newDurationSeconds))
  }

  func executeStepAdvance() -> Bool {
    guard session.phase == .cooking else { return false }
    advance()
    return true
  }

  func executeSwap(originalIngredientId: Int64, substituteIngredientId: Int64) -> (recheckJSON: String, executed: Bool)? {
    // The proposal names ids only; the table supplies the swap it knows for that pair.
    guard let substitution = options(forIngredientID: originalIngredientId)
      .first(where: { $0.substituteId == substituteIngredientId })
    else { return nil }
    return applySubstitution(originalID: originalIngredientId, substitute: substitution)
  }

  func executeAdaptation(change: String, servings: Int?) -> Bool {
    guard let servings else { return false }
    return adaptServings(to: servings)
  }

  func executeMealLog() -> Bool {
    finishIntoMealLog()
  }

  func executeInventoryCorrection(ingredientId: Int64, correction: String) -> Bool {
    deps.inventoryCorrection?(ingredientId, correction) ?? false
  }

  /// Processes an approved proposal through the executor. Receipts persist, so a repeat of the
  /// same proposal resolves `already_resolved` — apply at most once (SPEC §8).
  @discardableResult
  func process(
    proposal: CookActionProposal, decision: CookProposalExecutor.Decision,
    deviceEvents: [CookDeviceEvent]
  ) -> CookActionReceipt {
    // Receipts persist through the real store; without one, the process-local fallback
    // dedupes within the process only (no cross-restart authority).
    let log: CookReceiptReading
    if let store = deps.store {
      log = CookReceiptLog(store: store)
    } else {
      log = InMemoryCookReceiptFallback.shared
    }
    let executor = CookProposalExecutor(receipts: log, target: self)
    return executor.process(
      proposal, decision: decision, deviceEvents: deviceEvents, now: deps.now())
  }

  // MARK: Plumbing

  /// Reduces one event, performs the session effects, refreshes state, and persists.
  @discardableResult
  private func apply(_ event: CookSessionEvent) -> CookSessionTransition {
    let transition = CookSessionReducer.reduce(session, event)
    guard transition.session != session else { return transition }

    session = transition.session
    phase = session.phase
    suggestedTimerSeconds = session.currentCookStep?.timerSeconds

    for effect in transition.effects {
      switch effect {
      case .speakStep(_, let text):
        hint = text
      case .showSafetyCheck(_, let prompt):
        hint = prompt.instruction
      case .suggestTimer(_, let seconds):
        suggestedTimerSeconds = seconds
      case .createTimer(let seconds):
        addTimer(seconds: seconds, label: "Timer")
      case .commandHint(let text):
        hint = text
      case .requestCameraLook:
        hint = "One look — under three seconds, no verdict."
      }
    }

    refreshState()
    persist()
    return transition
  }

  private func refreshState() {
    state = CookModeState.build(
      session: session,
      timerStore: timerStore,
      now: deps.now(),
      hint: hint,
      suggestedTimerSeconds: suggestedTimerSeconds)
  }

  private func persist() {
    guard let store = deps.store else { return }
    try? store.persist(session: session, timers: timerStore)
  }

  /// Recomputes rendered remainders once a second while any timer is pending (LeChef §4.2).
  private func startTicking() {
    tickTask?.cancel()
    tickTask = Task { [weak self] in
      while !Task.isCancelled {
        guard let self else { return }
        if self.timerStore.timers.contains(where: { !$0.isAcknowledged }) {
          self.refreshState()
        }
        try? await Task.sleep(nanoseconds: 1_000_000_000)
      }
    }
  }
}

/// The phone capabilities `CookProposalExecutor` may drive, implemented on the view model.
extension CookModeViewModel: CookProposalExecuting { }
