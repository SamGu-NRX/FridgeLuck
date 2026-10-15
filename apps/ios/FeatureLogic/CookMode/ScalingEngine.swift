import Foundation

/// One ingredient line offered to scaling: the bundle's line quantity plus the ingredient
/// class a scaling rule can match on. Evidence rides inside `quantity` (LeChef §5).
public struct CookScaleLine: Equatable, Hashable, Sendable, Codable {
  /// The bundle's canonical ingredient key.
  public let key: String
  /// The class a rule matches on, e.g. "salt" or "dried_herbs"; nil means linear scaling.
  public let ingredientClass: String?
  public let quantity: CookQuantity
  /// Optional lines (garnish) scale too; `required` only marks what the fit line counts.
  public let required: Bool

  public init(key: String, ingredientClass: String? = nil, quantity: CookQuantity, required: Bool = true) {
    self.key = key
    self.ingredientClass = ingredientClass
    self.quantity = quantity
    self.required = required
  }
}

/// One line after scaling: the new quantity, which rule applied, and the caption for the
/// yolk-ink change line (LeChef §5, §11 `cook_adaptation`).
public struct CookScaledLine: Equatable, Hashable, Sendable, Codable {
  public let key: String
  public let quantity: CookQuantity
  /// True when the quantity text changed.
  public let changed: Bool
  /// The rule that produced the result, nil for plain linear scaling or no change.
  public let rule: CookScalingRuleKind?
  /// What to tell the cook: "season to taste — didn't scale", "check amount", the rule's
  /// own note, or nil when nothing needs saying.
  public let caption: String?
  /// True when the line scaled into equipment territory (count-hold: "6 servings won't fit
  /// one pan").
  public let needsEquipmentCheck: Bool
}

/// What adaptation decided about a step's time (LeChef §5): the proposed seconds, whether
/// they changed, and the caption. A time changes only under a reviewed rule; otherwise the
/// caption says to check — never a silent change, never a percentage of doneness.
public struct CookTimeAdaptation: Equatable, Hashable, Sendable, Codable {
  public let seconds: Int
  public let changed: Bool
  public let caption: String
}

/// The local scaling engine (LeChef §5): amounts rescale predictably from servings and
/// quantity evidence; time changes only under the shipped rules.
public enum ScalingEngine {
  /// Rescales every line from `oldServings` to `newServings`.
  ///
  /// - Linear by default: grams multiply; household amounts keep their unit text
  ///   ("2 cans → 3 cans"); counted amounts keep their honest value, halves included
  ///   (count-hold lines are the exception — they round to whole items).
  /// - `unknown` evidence never scales — the line holds at "check amount".
  /// - The rule table's exceptions apply by ingredient class: to-taste lines don't scale;
  ///   sub-linear lines scale at (new/old)^exponent (¼-rounded on small household measures);
  ///   count-hold lines scale and flag an equipment check.
  public static func scale(
    _ lines: [CookScaleLine],
    from oldServings: Int,
    to newServings: Int,
    rules: ScalingRules = .shipped
  ) -> [CookScaledLine] {
    guard oldServings > 0, newServings > 0 else {
      return lines.map { CookScaledLine(key: $0.key, quantity: $0.quantity, changed: false, rule: nil, caption: "check amount", needsEquipmentCheck: false) }
    }

    let factor = Double(newServings) / Double(oldServings)
    return lines.map { line in
      scale(line, factor: factor, rules: rules)
    }
  }

  static func scale(_ line: CookScaleLine, factor: Double, rules: ScalingRules) -> CookScaledLine {
    let rule = rules.quantityRule(for: line.ingredientClass)

    // Unknown evidence stays unknown — never an invented mass (LeChef §5).
    if line.quantity.isUnknown {
      return CookScaledLine(key: line.key, quantity: line.quantity, changed: false, rule: rule?.rule, caption: "check amount", needsEquipmentCheck: false)
    }

    switch rule?.rule {
    case .toTaste:
      return CookScaledLine(key: line.key, quantity: line.quantity, changed: false, rule: .toTaste, caption: rule?.note, needsEquipmentCheck: false)

    case .subLinear:
      let exponent = rule?.exponent ?? 0.5
      return scaled(line, multiplier: pow(factor, exponent), rule: rule?.rule, caption: rule?.note, rounding: .quarter)

    case .countHold:
      return scaled(line, multiplier: factor, rule: .countHold, caption: rule?.note, rounding: .whole, equipmentCheck: true)

    case .none:
      return scaled(line, multiplier: factor, rule: nil, caption: nil, rounding: .wholeIfCount)
    }
  }

  enum AmountRounding {
    /// Counted items stay whole.
    case wholeIfCount
    /// Count-hold lines are counts by definition; stay whole.
    case whole
    /// Sub-linear household measures round to ¼ tsp steps.
    case quarter
  }

  static func scaled(
    _ line: CookScaleLine, multiplier: Double, rule: CookScalingRuleKind?,
    caption: String?, rounding: AmountRounding, equipmentCheck: Bool = false
  ) -> CookScaledLine {
    let quantity: CookQuantity
    switch line.quantity {
    case let .grams(grams):
      quantity = .grams(round(grams * multiplier, rounding == .quarter ? 0.25 : nil))
    case let .household(amount, unit, grams):
      let step: Double? = rounding == .quarter ? 0.25 : nil
      quantity = .household(
        amount: round(amount * multiplier, step),
        unit: unit,
        grams: grams.map { $0 * multiplier })
    case let .count(amount, unit, grams):
      // Count-hold lines round to whole items; linear counts keep the honest value.
      let step: Double? = rounding == .whole ? 1 : (rounding == .quarter ? 0.25 : nil)
      quantity = .count(
        amount: round(amount * multiplier, step),
        unit: unit,
        grams: grams.map { $0 * multiplier })
    case .unknown:
      quantity = line.quantity
    }

    let changed = quantity != line.quantity
    return CookScaledLine(
      key: line.key,
      quantity: quantity,
      changed: changed,
      rule: rule,
      caption: caption,
      needsEquipmentCheck: equipmentCheck && changed)
  }

  /// Rounds to a step (¼ tsp units, whole items) keeping at least the smallest positive step.
  static func round(_ value: Double, _ step: Double?) -> Double {
    guard let step, step > 0 else { return value }
    let stepped = (value / step).rounded() * step
    // 4 eggs × 1.5 must read 6, not 5.999…; kill binary dust.
    return (stepped * 1_000_000).rounded() / 1_000_000
  }

  // MARK: - Time

  /// Adapts a step's cook time — only under a reviewed rule (LeChef §5, PR #86 §3.1).
  ///
  /// - `thicknessChanged`: the recipe stated a thickness and the cook changed it (pounded
  ///   or cut thinner/thicker). Proposes a bounded change in proportion to the servings
  ///   factor; the bound caps it at ±25 %.
  /// - `panFactor`: the pan's capacity ratio to the recipe's pan (1.5 = 1.5× the surface).
  ///   A wider or shallower pan checks earlier; bound ±25 %.
  /// - `batchCount`: quantity cooks in N batches — per-batch time holds, total time grows
  ///   by the batches.
  /// - `singlePanLoadDoubled`: one pan loaded with double the recipe — no reviewed rule
  ///   gives a number, so the time stays and the caption says to check.
  ///
  /// With no applicable rule the time is unchanged and the caption tells the cook to
  /// check rather than trust the timer.
  public static func adaptTime(
    seconds: Int,
    from oldServings: Int,
    to newServings: Int,
    thicknessChanged: Bool = false,
    panFactor: Double? = nil,
    batchCount: Int = 1,
    singlePanLoadDoubled: Bool = false,
    rules: ScalingRules = .shipped
  ) -> CookTimeAdaptation {
    let unchanged = CookTimeAdaptation(seconds: seconds, changed: false, caption: "same time — check, don't trust the timer")

    // No time in the step to adapt.
    guard seconds > 0 else { return unchanged }

    var proposed = Double(seconds)
    var caption = ""

    if thicknessChanged, let rule = rules.timeRule(.thickness) {
      let factor = (oldServings > 0 ? Double(newServings) / Double(oldServings) : 1)
      proposed = clamp(proposed * factor, around: Double(seconds), pct: rule.boundPct)
      caption = rule.copy
    } else if let panFactor, panFactor > 0, panFactor != 1, let rule = rules.timeRule(.panSize) {
      // A bigger cooking surface browns faster: divide by the factor, then bound it.
      proposed = clamp(proposed / panFactor, around: Double(seconds), pct: rule.boundPct)
      caption = rule.copy
    } else {
      // No thickness or pan rule applies.
      if singlePanLoadDoubled {
        guard let rule = rules.timeRule(.quantityInPan) else { return unchanged }
        return CookTimeAdaptation(seconds: seconds, changed: false, caption: rule.copy)
      }
      if batchCount <= 1 {
        return unchanged
      }
      guard let rule = rules.timeRule(.quantityInPan) else { return unchanged }
      // Per-batch time roughly unchanged; total time grows by the batch count.
      proposed = proposed * Double(batchCount)
      caption = "\(batchCount) batches — \(rule.copy)"
    }

    let finalSeconds = Int(proposed.rounded())
    if finalSeconds == seconds {
      return CookTimeAdaptation(seconds: seconds, changed: false, caption: caption.isEmpty ? unchanged.caption : caption)
    }
    return CookTimeAdaptation(seconds: finalSeconds, changed: true, caption: caption)
  }

  static func clamp(_ value: Double, around base: Double, pct: Double) -> Double {
    let low = base * (1 - pct / 100)
    let high = base * (1 + pct / 100)
    return min(max(value, low), high)
  }
}
