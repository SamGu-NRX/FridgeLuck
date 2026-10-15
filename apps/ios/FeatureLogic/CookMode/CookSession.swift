import Foundation

/// Where a cooked recipe came from — the shared RecipeRef contract
/// (`source: catalog|user|community|generated`, `id`, `revision: Int >= 1`).
public enum CookRecipeSource: String, Equatable, Sendable, Codable {
  case catalog, user, community, generated
}

public struct CookRecipeRef: Equatable, Hashable, Sendable, Codable {
  public let source: CookRecipeSource
  public let id: String
  /// The bundle revision the session cooks against, so later refreshes can tell what changed.
  public let revision: Int

  public init(source: CookRecipeSource, id: String, revision: Int) {
    self.source = source
    self.id = id
    self.revision = max(1, revision)
  }
}

/// The cook-session phases (LeChef spec §4.1).
///
/// There is no `paused` phase: pausing a cook is a per-timer concept, not a session state —
/// a paused session is still `cooking`, and the timers know they're paused.
public enum CookSessionPhase: String, Equatable, Sendable, Codable {
  case idle, cooking, remembering, remembered, abandoned
}

/// What kind of change an adaptation records (LeChef §11, `cook_adaptation.kind`).
public enum CookAdaptationKind: String, Equatable, Sendable, Codable {
  case servings, quantity, equipment
}

/// One applied adaptation, kept so the remember receipt is a view of the record, not a new write.
public struct CookAdaptation: Equatable, Hashable, Sendable, Codable {
  public let kind: CookAdaptationKind
  /// What was asked for, e.g. "6 servings".
  public let input: String
  /// What the scaling engine applied, e.g. "herbs 2 tsp".
  public let applied: String
  /// The caption shown in yolk ink, e.g. "season to taste — didn't scale".
  public let caption: String
  public let at: Date

  public init(kind: CookAdaptationKind, input: String, applied: String, caption: String, at: Date) {
    self.kind = kind
    self.input = input
    self.applied = applied
    self.caption = caption
    self.at = at
  }
}

/// Where a substitution came from (LeChef §11, `cook_substitution.source`).
public enum CookSubstitutionSource: String, Equatable, Sendable, Codable {
  case table, live, manual
}

public struct CookSubstitution: Equatable, Hashable, Sendable, Codable {
  public let originalKey: String
  public let substituteKey: String
  /// The difference in words — never "no change" (PR #86 §3.1).
  public let note: String
  public let source: CookSubstitutionSource
  public let at: Date

  public init(originalKey: String, substituteKey: String, note: String, source: CookSubstitutionSource, at: Date) {
    self.originalKey = originalKey
    self.substituteKey = substituteKey
    self.note = note
    self.source = source
    self.at = at
  }
}

/// The cook session as a plain value, so it can be persisted and replayed (LeChef §4).
///
/// All mutation goes through `CookSessionReducer.reduce(_:event:)`; every applied event bumps
/// `revision`, and folding the event log reproduces the same session exactly.
public struct CookSession: Equatable, Sendable, Codable {
  public internal(set) var id: String
  public internal(set) var phase: CookSessionPhase
  public internal(set) var recipeRef: CookRecipeRef?
  public internal(set) var servings: Int
  public internal(set) var eaterIDs: [String]
  /// The structured steps the session cooks, carried from the recipe bundle so effects
  /// (repeat, safety, timer suggestions) can be derived on replay without re-reading it.
  public internal(set) var steps: [CookStep]
  /// 0-based index into `steps`.
  public internal(set) var currentStep: Int
  public internal(set) var completedSteps: Set<Int>
  public internal(set) var adaptations: [CookAdaptation]
  public internal(set) var substitutions: [CookSubstitution]
  public internal(set) var startedAt: Date?
  public internal(set) var endedAt: Date?
  /// Bumped on every applied event; the phone's write-authority revision (LeChef §4.2, §11).
  public internal(set) var revision: Int
  public internal(set) var rating: Int?
  public internal(set) var note: String?
  public internal(set) var rememberSkipped: Bool

  init() {
    id = ""
    phase = .idle
    recipeRef = nil
    servings = 0
    eaterIDs = []
    steps = []
    currentStep = 0
    completedSteps = []
    adaptations = []
    substitutions = []
    startedAt = nil
    endedAt = nil
    revision = 0
    rating = nil
    note = nil
    rememberSkipped = false
  }

  /// A session that has not started; `id` is empty until `start` applies.
  public static let idle = CookSession()

  /// The step the session is on, or nil in phases with no current step.
  public var currentCookStep: CookStep? {
    phase == .cooking && steps.indices.contains(currentStep) ? steps[currentStep] : nil
  }
}

/// Events into the session reducer. Carrying `now` inside the event keeps the reducer pure,
/// so persistence and replay need nothing but the event log.
public enum CookSessionEvent: Equatable, Sendable {
  public struct Start: Equatable, Sendable {
    public let id: String
    public let recipeRef: CookRecipeRef
    public let servings: Int
    public let eaterIDs: [String]
    public let steps: [CookStep]
    public let now: Date

    public init(id: String, recipeRef: CookRecipeRef, servings: Int, eaterIDs: [String], steps: [CookStep], now: Date) {
      self.id = id
      self.recipeRef = recipeRef
      self.servings = servings
      self.eaterIDs = eaterIDs
      self.steps = steps
      self.now = now
    }
  }

  case start(Start)
  /// Touch Next or voice "next": mark the current step completed and move on.
  case advance(now: Date)
  /// Touch Back or voice "back": leave the current step unmarked and step back.
  case back(now: Date)
  /// A touch toggle on a step's completed check.
  case toggleCompleted(step: Int)
  /// Touch step-number tap or voice "repeat": re-read the current step.
  case repeatStep
  /// Finish — reachable only from the last step (LeChef §4.2).
  case complete(now: Date)
  case abandon(now: Date)
  /// Save the remember receipt. `rating` must be nil or 1...5.
  case saveRemember(rating: Int?, note: String?, now: Date)
  /// Skip the remember receipt; resolves to `remembered{skipped}` (LeChef §4.1).
  case skipRemember(now: Date)
  case applyAdaptation(CookAdaptation)
  case applySubstitution(CookSubstitution)
  /// A command from voice or touch (see `VoiceCommandParser`), stamped when it arrived.
  case command(CookCommand, now: Date)
}

/// The outcome of reducing one event: the next state and the effects the device should perform.
public struct CookSessionTransition: Equatable, Sendable {
  public let session: CookSession
  public let effects: [CookSessionEffect]

  public init(session: CookSession, effects: [CookSessionEffect]) {
    self.session = session
    self.effects = effects
  }
}

/// Device actions the reducer asks for but never performs itself: the device owns the timer,
/// the microphone and the camera (LeChef §2, §4.2 — the model never creates the timer).
public enum CookSessionEffect: Equatable, Sendable {
  /// Re-read the step text aloud and re-render it.
  case speakStep(index: Int, text: String)
  /// Surface the checkable thermometer test. Emitted before any timer suggestion for the
  /// same step — safetyCheck has display priority over a timer suggestion (LeChef §8.4).
  case showSafetyCheck(step: Int, prompt: CookSafetyPrompt)
  /// The step carries a natural timer; suggest it. Never fake — only real durations exist.
  case suggestTimer(step: Int, seconds: Int)
  /// A "timer N minutes" command: create the device timer. The session changes nothing here;
  /// the timer is acknowledged only after `CookTimerStore.create` succeeds (LeChef §4.2).
  case createTimer(seconds: Int)
  /// A "show" command: one push-to-look capture, ≤3 s, never a safety verdict (LeChef D3).
  case requestCameraLook
  /// An unknown phrase: state unchanged; tell the cook what the local vocabulary is.
  case commandHint(text: String)
}

/// The pure session state machine (LeChef §4): event in, new state and effects out.
public enum CookSessionReducer {
  public static func reduce(_ session: CookSession, _ event: CookSessionEvent) -> CookSessionTransition {
    var next = session
    var effects: [CookSessionEffect] = []

    switch event {
    case let .start(start):
      guard session.phase == .idle, !start.steps.isEmpty, start.servings > 0 else { break }
      next = CookSession()
      next.apply(start)
      effects.append(contentsOf: stepEffects(next.currentCookStep, at: next.currentStep))

    case let .advance(now):
      guard session.phase == .cooking, session.currentStep < session.steps.count - 1 else { break }
      next.completedSteps.insert(session.currentStep)
      next.currentStep += 1
      next.revision += 1
      effects.append(contentsOf: stepEffects(next.currentCookStep, at: next.currentStep))

    case let .back(now):
      guard session.phase == .cooking, session.currentStep > 0 else { break }
      next.currentStep -= 1
      // Landing on the previous step unmarks it: the cook is redoing it, not reviewing it.
      next.completedSteps.remove(next.currentStep)
      next.revision += 1
      effects.append(contentsOf: stepEffects(next.currentCookStep, at: next.currentStep))

    case let .toggleCompleted(step):
      guard session.phase == .cooking, session.steps.indices.contains(step) else { break }
      if next.completedSteps.contains(step) {
        next.completedSteps.remove(step)
      } else {
        next.completedSteps.insert(step)
      }
      next.revision += 1

    case .repeatStep:
      guard session.phase == .cooking, let step = session.currentCookStep else { break }
      effects.append(.speakStep(index: session.currentStep, text: step.text))

    case let .complete(now):
      guard session.phase == .cooking, session.currentStep == session.steps.count - 1 else { break }
      next.completedSteps.insert(session.currentStep)
      next.phase = .remembering
      next.endedAt = now
      next.revision += 1

    case let .abandon(now):
      guard session.phase == .cooking else { break }
      next.phase = .abandoned
      next.endedAt = now
      next.revision += 1

    case let .saveRemember(rating, note, now):
      guard session.phase == .remembering, rating == nil || (1...5).contains(rating ?? 0) else { break }
      next.phase = .remembered
      next.rating = rating
      next.note = note
      next.endedAt = now
      next.revision += 1

    case let .skipRemember(now):
      guard session.phase == .remembering else { break }
      next.phase = .remembered
      next.rememberSkipped = true
      next.endedAt = now
      next.revision += 1

    case let .applyAdaptation(adaptation):
      guard session.phase == .cooking else { break }
      next.adaptations.append(adaptation)
      next.revision += 1

    case let .applySubstitution(substitution):
      guard session.phase == .cooking else { break }
      next.substitutions.append(substitution)
      next.revision += 1

    case let .command(command, now):
      return reduce(session, command, now: now)
    }

    return CookSessionTransition(session: next, effects: effects)
  }

  /// Voice and touch are the same reducer calls (LeChef §4.2): the parser produces commands,
  /// touch buttons produce the same commands, and only this mapping changes the session.
  /// `now` is the moment the command arrived, kept in the caller's hands for replay purity.
  static func reduce(_ session: CookSession, _ command: CookCommand, now: Date) -> CookSessionTransition {
    switch command {
    case .next:
      return reduce(session, .advance(now: now))
    case .back:
      return reduce(session, .back(now: now))
    case .repeatStep:
      return reduce(session, .repeatStep)
    case .show:
      // The camera is the most sensitive device surface (LeChef D3): like next/back/repeat,
      // "show" acts only inside a live cook. Outside one it changes nothing.
      guard session.phase == .cooking else {
        return CookSessionTransition(session: session, effects: [])
      }
      return CookSessionTransition(session: session, effects: [.requestCameraLook])
    case let .timer(seconds):
      guard session.phase == .cooking else {
        return CookSessionTransition(session: session, effects: [])
      }
      return CookSessionTransition(session: session, effects: [.createTimer(seconds: seconds)])
    case let .unrecognized(phrase):
      return CookSessionTransition(
        session: session,
        effects: [.commandHint(text: "Offline — say next, back, repeat, show, or timer N minutes. Didn't understand: \(phrase)")])
    }
  }

  /// Effects for arriving at a step. Safety first: the checkable thermometer test has display
  /// priority over any timer suggestion (LeChef §8.4).
  public static func stepEffects(_ step: CookStep?, at index: Int) -> [CookSessionEffect] {
    guard let step else { return [] }
    var effects: [CookSessionEffect] = []
    if let prompt = step.safetyPrompt {
      effects.append(.showSafetyCheck(step: index, prompt: prompt))
    }
    if let seconds = step.timerSeconds {
      effects.append(.suggestTimer(step: index, seconds: seconds))
    }
    return effects
  }
}

/// The spec's named machine surface (LeChef §15): `start`, `advance`, `back`, `repeat`,
/// `complete`, `abandon`, `state`. A thin mutable wrapper over the pure reducer.
public struct CookSessionMachine: Sendable {
  /// The current session value — persist this; relaunch replays the log into it.
  public internal(set) var session: CookSession

  public init(session: CookSession = .idle) {
    self.session = session
  }

  @discardableResult
  public mutating func send(_ event: CookSessionEvent) -> [CookSessionEffect] {
    let transition = CookSessionReducer.reduce(session, event)
    session = transition.session
    return transition.effects
  }

  @discardableResult
  public mutating func start(id: String, recipeRef: CookRecipeRef, servings: Int, eaterIDs: [String], steps: [CookStep], now: Date) -> [CookSessionEffect] {
    send(.start(CookSessionEvent.Start(id: id, recipeRef: recipeRef, servings: servings, eaterIDs: eaterIDs, steps: steps, now: now)))
  }

  /// Touch Next and voice "next" both land here through `.command(.next, now:)` — or call
  /// this directly with the same `now`.
  @discardableResult
  public mutating func advance(now: Date) -> [CookSessionEffect] {
    send(.advance(now: now))
  }

  @discardableResult
  public mutating func back(now: Date) -> [CookSessionEffect] {
    send(.back(now: now))
  }

  @discardableResult
  public mutating func repeatStep() -> [CookSessionEffect] {
    send(.repeatStep)
  }

  @discardableResult
  public mutating func complete(now: Date) -> [CookSessionEffect] {
    send(.complete(now: now))
  }

  @discardableResult
  public mutating func abandon(now: Date) -> [CookSessionEffect] {
    send(.abandon(now: now))
  }

  /// A command from voice or touch, stamped with its arrival time.
  @discardableResult
  public mutating func send(_ command: CookCommand, at now: Date) -> [CookSessionEffect] {
    send(.command(command, now: now))
  }

  /// Folds an event log into the session it produced — relaunch replays the log and lands on
  /// the same step with the same completed checks (LeChef §4.2 durability).
  public static func replay(_ events: [CookSessionEvent]) -> CookSession {
    events.reduce(CookSession.idle) { state, event in
      CookSessionReducer.reduce(state, event).session
    }
  }
}

extension CookSession {
  fileprivate mutating func apply(_ start: CookSessionEvent.Start) {
    id = start.id
    phase = .cooking
    recipeRef = start.recipeRef
    servings = start.servings
    eaterIDs = start.eaterIDs
    steps = start.steps
    currentStep = 0
    completedSteps = []
    adaptations = []
    substitutions = []
    startedAt = start.now
    endedAt = nil
    revision = 1
    rating = nil
    note = nil
    rememberSkipped = false
  }
}
