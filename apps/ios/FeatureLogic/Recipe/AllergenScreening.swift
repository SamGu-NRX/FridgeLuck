import Foundation

/// Screens recipe text against a user's avoided-ingredient names before a
/// recipe is shown. Matching is word-boundary aware, case-insensitive, and
/// tolerant of simple plurals, so "peanut" blocks "Peanut Sauce" and
/// "peanut-free" but never "eggplant".
public enum AllergenScreening {
  public struct Rejection: Sendable, Equatable {
    public enum Field: String, Sendable { case title, instructions }

    public let avoidedIngredient: String
    public let matchedTerm: String
    public let field: Field

    public init(avoidedIngredient: String, matchedTerm: String, field: Field) {
      self.avoidedIngredient = avoidedIngredient
      self.matchedTerm = matchedTerm
      self.field = field
    }
  }

  /// Returns the first rejection found, or nil when the recipe is safe to show.
  ///
  /// Avoid names are checked in list order; each name is checked against the
  /// title first and the instructions second, and the first match wins.
  public static func rejection(
    title: String,
    instructions: String,
    avoidingIngredients: [String]
  ) -> Rejection? {
    for name in avoidingIngredients {
      guard let pattern = matchPattern(forName: name) else { continue }
      if let range = title.range(of: pattern, options: [.regularExpression, .caseInsensitive]) {
        return Rejection(
          avoidedIngredient: trimmedName(name),
          matchedTerm: String(title[range]),
          field: .title)
      }
      if let range = instructions.range(
        of: pattern, options: [.regularExpression, .caseInsensitive]) {
        return Rejection(
          avoidedIngredient: trimmedName(name),
          matchedTerm: String(instructions[range]),
          field: .instructions)
      }
    }
    return nil
  }

  /// Builds a `\b`-anchored regular expression for one avoid-list name, or nil
  /// when the trimmed name is empty or contains no alphanumeric character.
  private static func matchPattern(forName name: String) -> String? {
    let trimmed = trimmedName(name)
    // Splitting on non-alphanumerics yields at least one word exactly when the
    // name contains an alphanumeric character.
    let words = trimmed
      .components(separatedBy: CharacterSet.alphanumerics.inverted)
      .filter { !$0.isEmpty }
    guard !words.isEmpty else { return nil }

    let tokens = words.map { word -> String in
      if word.count >= 2, word.hasSuffix("s") {
        // A plural avoid-list entry ("Peanuts") also matches the singular
        // ("peanut") through an optional trailing "s".
        return NSRegularExpression.escapedPattern(for: String(word.dropLast())) + "s?"
      }
      return NSRegularExpression.escapedPattern(for: word) + "(?:es|s)?"
    }
    return "\\b" + tokens.joined(separator: "[\\W_]+") + "\\b"
  }

  private static func trimmedName(_ name: String) -> String {
    name.trimmingCharacters(in: .whitespacesAndNewlines)
  }
}
