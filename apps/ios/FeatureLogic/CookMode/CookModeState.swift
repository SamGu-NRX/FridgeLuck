import Foundation

/// The timer as cook mode renders it — remaining time recomputed from the absolute deadline
/// at render time, so a relaunch or a clock change needs no re-derivation (LeChef §4.2).
public struct CookTimerState: Equatable, Sendable {
  public let id: String
  public let label: String
  /// Seconds left from the render instant; 0 on a fired timer.
  public let remainingSeconds: Int
  /// The duration the timer was created with, for the drain ring. nil on resume when the
  /// original duration is unknown (deadline-only restoration).
  public let totalSeconds: Int?
  public let isFired: Bool
  public let isPaused: Bool

  public init(id: String, label: String, remainingSeconds: Int, totalSeconds: Int?, isFired: Bool, isPaused: Bool) {
    self.id = id
    self.label = label
    self.remainingSeconds = remainingSeconds
    self.totalSeconds = totalSeconds
    self.isFired = isFired
    self.isPaused = isPaused
  }
}

/// Everything cook mode renders, as a plain value (LeChef §3.1). The current redesign source
/// of truth: the views read this instead of holding step state themselves, so the upcoming
/// surface overhaul re-renders the same state without touching the session machine.
public struct CookModeState: Equatable, Sendable {
  public let phase: CookSessionPhase
  /// 0-based current step; nil in phases with no current step.
  public let stepIndex: Int?
  public let totalSteps: Int
  public let stepText: String?
  /// The checkable thermometer test for the current step; renders before any timer suggestion.
  public let safetyPrompt: CookSafetyPrompt?
  public let completedSteps: Set<Int>
  /// "Stir in the sauce" — the next step's lead, so Next's decision is readable at arm's length.
  public let nextStepSummary: String?
  public let timers: [CookTimerState]
  /// One entry per applied swap, in order — "Changed: Greek yoghurt, a little tangier".
  public let substitutionLines: [String]
  /// Applied adaptation captions (yolk-ink lines, remember receipt).
  public let adaptationCaptions: [String]
  /// The LeChef line / command hint currently shown, or nil when nothing applies.
  public let hint: String?
  /// The step's natural timer suggestion, or nil — no fake timers (LeChef §8.4).
  public let suggestedTimerSeconds: Int?
  public let servings: Int
  public let startedAt: Date?
  /// Whole minutes from start to end once finished; nil while cooking.
  public let cookedMinutes: Int?

  public init(
    phase: CookSessionPhase,
    stepIndex: Int?,
    totalSteps: Int,
    stepText: String?,
    safetyPrompt: CookSafetyPrompt?,
    completedSteps: Set<Int>,
    nextStepSummary: String?,
    timers: [CookTimerState],
    substitutionLines: [String],
    adaptationCaptions: [String],
    hint: String?,
    suggestedTimerSeconds: Int?,
    servings: Int,
    startedAt: Date?,
    cookedMinutes: Int?
  ) {
    self.phase = phase
    self.stepIndex = stepIndex
    self.totalSteps = totalSteps
    self.stepText = stepText
    self.safetyPrompt = safetyPrompt
    self.completedSteps = completedSteps
    self.nextStepSummary = nextStepSummary
    self.timers = timers
    self.substitutionLines = substitutionLines
    self.adaptationCaptions = adaptationCaptions
    self.hint = hint
    self.suggestedTimerSeconds = suggestedTimerSeconds
    self.servings = servings
    self.startedAt = startedAt
    self.cookedMinutes = cookedMinutes
  }

  /// Builds the render state from the session and its device timers at `now`.
  public static func build(
    session: CookSession,
    timerStore: CookTimerStore,
    now: Date,
    hint: String?,
    suggestedTimerSeconds: Int?
  ) -> CookModeState {
    let step = session.currentCookStep
    let nextSummary: String? = {
      guard session.phase == .cooking, session.steps.indices.contains(session.currentStep + 1) else { return nil }
      return Self.summary(session.steps[session.currentStep + 1].text)
    }()

    let timers = timerStore.timers.map { timer in
      CookTimerState(
        id: timer.id,
        label: timer.label,
        remainingSeconds: Int(timer.remainingSeconds(from: now).rounded(.up)),
        // Drain ring total: the model keeps Double seconds; the render state is integer.
        totalSeconds: timer.totalSeconds.map { Int($0.rounded(.up)) },
        isFired: timer.isFired(at: now),
        isPaused: timer.isPaused)
    }

    let cookedMinutes: Int? = {
      guard let start = session.startedAt, let end = session.endedAt else { return nil }
      return max(0, Int(end.timeIntervalSince(start).rounded() / 60))
    }()

    return CookModeState(
      phase: session.phase,
      stepIndex: step != nil ? session.currentStep : nil,
      totalSteps: session.steps.count,
      stepText: step?.text,
      safetyPrompt: step?.safetyPrompt,
      completedSteps: session.completedSteps,
      nextStepSummary: nextSummary,
      timers: timers,
      substitutionLines: session.substitutions.map { "Changed: \($0.substituteKey), \($0.note)" },
      adaptationCaptions: session.adaptations.map(\.caption),
      hint: hint,
      suggestedTimerSeconds: suggestedTimerSeconds,
      servings: session.servings,
      startedAt: session.startedAt,
      cookedMinutes: cookedMinutes)
  }

  /// The next step's short name: the first clause, capped for the Next button.
  public static func summary(_ text: String) -> String {
    let lead = text
      .components(separatedBy: CharacterSet(charactersIn: ".!"))
      .first?
      .trimmingCharacters(in: .whitespacesAndNewlines) ?? text
    let words = lead.split(separator: " ").prefix(6)
    let capped = words.joined(separator: " ")
    return capped.count < lead.count ? capped + "…" : capped
  }
}

/// Parses a stored recipe's instructions into structured cook steps (LeChef §8.4, RECONCILE
/// resolved to the recipe bundle's v2 shape — until the bundle loader lands, bundled recipes
/// carry text instructions, and this is the adapter that gives them real step values).
public enum CookStepParsing {
  /// A step without a stated duration has no timer — no fake timers (LeChef §8.4). Legacy
  /// recipes carry no thermometer data, so steps get no safety check; nothing is invented.
  public struct Result: Equatable, Sendable {
    public let steps: [CookStep]
    public let attribution: RecipeAttribution?
  }

  public static func parse(instructions: String) -> Result {
    var steps: [CookStep] = []
    var attribution: RecipeAttribution?

    for rawLine in instructions.components(separatedBy: .newlines) {
      let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !line.isEmpty else { continue }

      if let source = sourceText(in: line) {
        if attribution == nil, !source.isEmpty {
          attribution = RecipeAttribution(source: source)
        }
        continue
      }

      let text = removingStepNumber(from: line)
      guard !text.isEmpty else { continue }
      steps.append(CookStep(text: text, uses: [], timerSeconds: parsedTimerSeconds(in: text), thermometer: nil))
    }

    return Result(steps: steps, attribution: attribution)
  }

  /// The stated duration, only where the text clearly gives one: "for 3 minutes", "for 2 min",
  /// "for 1 ½ hours". A number without "for" ("2 minutes per side") is not this step's timer.
  static func parsedTimerSeconds(in text: String) -> Int? {
    let pattern = /for\s+(\d{1,3})\s+(?:and\s+a\s+(half|quarter)\s+)?(minutes?|mins?|hours?|hrs?)/
      .ignoresCase()
    guard let match = text.firstMatch(of: pattern) else { return nil }
    guard let value = Double(match.1) else { return nil }

    var seconds = 0.0
    switch match.3.lowercased() {
    case let unit where unit.hasPrefix("h"):
      seconds = value * 3600
    default:
      seconds = value * 60
    }
    if let fraction = match.2 {
      seconds += fraction.lowercased() == "half" ? value / 2 : value / 4
    }

    let total = Int(seconds.rounded())
    return (1...180 * 60).contains(total) ? total : nil
  }

  /// The text after "Source:" (any case), or nil when the line isn't a source line.
  static func sourceText(in line: String) -> String? {
    let prefix = "source:"
    guard line.lowercased().hasPrefix(prefix) else { return nil }
    return line.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
  }

  /// Drops a leading "1. " or "12) ". The number must be followed by whitespace or the end of
  /// the line, so "1.5 cups" and "2 eggs" keep their numbers.
  static func removingStepNumber(from line: String) -> String {
    guard let match = line.prefixMatch(of: #/\d{1,3}[.)](?:\s+|$)/#) else { return line }
    return String(line[match.range.upperBound...])
  }
}
