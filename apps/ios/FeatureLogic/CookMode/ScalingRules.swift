import Foundation

/// The reviewed exceptions to linear scaling (LeChef §5), in the
/// `docs/spec/lechef/contracts/scaling-rules.schema.json` shape: `to-taste`, `sub-linear`,
/// `count-hold`. Matched by ingredient class — the first matching rule wins.
public enum CookScalingRuleKind: String, Equatable, Sendable, Codable {
  case toTaste = "to-taste"
  case subLinear = "sub-linear"
  case countHold = "count-hold"
}

public struct CookQuantityRule: Equatable, Hashable, Sendable, Codable {
  public let rule: CookScalingRuleKind
  /// The ingredient class this rule governs, e.g. "salt", "dried_herbs", "egg".
  public let ingredientClass: String
  /// The caption fragment shown to the cook, e.g. "season to taste — didn't scale".
  public let note: String
  /// For `sub-linear`: scale at (new/old)^exponent. The spec's √(new/old) is 0.5.
  public let exponent: Double?

  public init(rule: CookScalingRuleKind, ingredientClass: String, note: String, exponent: Double? = nil) {
    self.rule = rule
    self.ingredientClass = ingredientClass
    self.note = note
    self.exponent = exponent
  }
}

/// The only ways a cook time may change (LeChef §5, PR #86 §3.1): thickness, pan size,
/// quantity in the pan. Anything else keeps the step's time and says to check.
public enum CookTimeRuleName: String, Equatable, Sendable, Codable {
  case thickness
  case panSize = "pan_size"
  case quantityInPan = "quantity_in_pan"
}

public struct CookTimeRule: Equatable, Hashable, Sendable, Codable {
  public let rule: CookTimeRuleName
  /// When the rule applies, e.g. "recipe states thickness and the user changed it".
  public let appliesWhen: String
  /// Maximum relative change in percent, e.g. 25 caps a time at ±25 %.
  public let boundPct: Double
  /// The reviewed source of the rule.
  public let source: String
  /// The caption; it instructs to check rather than trust the timer.
  public let copy: String

  public init(rule: CookTimeRuleName, appliesWhen: String, boundPct: Double, source: String, copy: String) {
    self.rule = rule
    self.appliesWhen = appliesWhen
    self.boundPct = boundPct
    self.source = source
    self.copy = copy
  }
}

/// The shipped rule table. Kept as data so the integrations slice can render it and a spec
/// revision can extend it without touching the engine.
public struct ScalingRules: Equatable, Sendable, Codable {
  public let quantityRules: [CookQuantityRule]
  public let timeRules: [CookTimeRule]

  public init(quantityRules: [CookQuantityRule], timeRules: [CookTimeRule]) {
    self.quantityRules = quantityRules
    self.timeRules = timeRules
  }

  /// The LeChef §5 table: to-taste seasonings don't scale; strong dried aromatics for long
  /// simmers scale at √(new/old), rounded to ¼ tsp; countable items where pan geometry binds
  /// scale but flag an equipment check. The three time rules each carry a source and a bound.
  public static let shipped = ScalingRules(
    quantityRules: [
      CookQuantityRule(rule: .toTaste, ingredientClass: "salt", note: "season to taste — didn't scale"),
      CookQuantityRule(rule: .toTaste, ingredientClass: "pepper", note: "season to taste — didn't scale"),
      CookQuantityRule(rule: .toTaste, ingredientClass: "chili", note: "season to taste — didn't scale"),
      CookQuantityRule(rule: .toTaste, ingredientClass: "lemon_juice", note: "season to taste — didn't scale"),
      CookQuantityRule(rule: .toTaste, ingredientClass: "seasoning", note: "season to taste — didn't scale"),
      CookQuantityRule(rule: .subLinear, ingredientClass: "dried_herbs", note: "dried herbs — scaled less, they concentrate", exponent: 0.5),
      CookQuantityRule(rule: .countHold, ingredientClass: "egg", note: "eggs scaled — check the pan fits them"),
    ],
    timeRules: [
      CookTimeRule(
        rule: .thickness, appliesWhen: "the recipe states a thickness and the user changed it",
        boundPct: 25, source: "LeChef §5 thickness",
        copy: "thickness changed — check early, don't trust the timer"),
      CookTimeRule(
        rule: .panSize, appliesWhen: "a deeper or wider pan than the recipe states",
        boundPct: 25, source: "LeChef §5 pan size",
        copy: "pan changed — check earlier, don't trust the timer"),
      CookTimeRule(
        rule: .quantityInPan, appliesWhen: "the quantity cooks in batches, or one pan load doubled",
        boundPct: 0, source: "LeChef §5 quantity in the pan",
        copy: "more in the pan — check, don't trust the timer"),
    ])

  /// The first quantity rule naming `ingredientClass`, or nil for linear scaling.
  public func quantityRule(for ingredientClass: String?) -> CookQuantityRule? {
    guard let ingredientClass else { return nil }
    return quantityRules.first { $0.ingredientClass == ingredientClass }
  }

  public func timeRule(_ name: CookTimeRuleName) -> CookTimeRule? {
    timeRules.first { $0.rule == name }
  }
}
