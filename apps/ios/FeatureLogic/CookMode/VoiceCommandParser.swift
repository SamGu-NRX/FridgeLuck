import Foundation

/// The cook-mode command vocabulary — what voice parses into and what touch buttons produce
/// (LeChef §4.3). Both paths feed the same `CookSessionReducer` calls.
public enum CookCommand: Equatable, Hashable, Sendable {
  case next
  case back
  case repeatStep
  /// Push-to-look: one capture, ≤3 s, never a safety verdict.
  case show
  /// "Timer N minutes" resolved to seconds (1–180 minutes accepted, halves and quarters too).
  case timer(seconds: Int)
  /// Anything the local vocabulary can't carry. Changes nothing; the UI says so and — when
  /// Live is connected — forwards the phrase as a free-form turn.
  case unrecognized(phrase: String)
}

/// The local, offline five-word parser (LeChef §4.3).
///
/// It runs first on the partial transcript; if it matches, the intent fires even when the
/// Live session is down. It matches whole utterances only — anything longer or different is
/// `.unrecognized`, never a guess.
public struct VoiceCommandParser: Equatable, Sendable {
  /// The accepted unit words after the number: "minutes", "mins", "min".
  static let unitWords: Set<String> = ["minute", "minutes", "min", "mins"]

  public init() {}

  public func parse(_ input: String) -> CookCommand {
    let phrase = Self.normalized(input)
    if phrase.isEmpty { return .unrecognized(phrase: input) }

    switch phrase {
    case "next":
      return .next
    case "back", "go back":
      return .back
    case "repeat", "again", "say that again":
      return .repeatStep
    case "show", "show it", "look", "look at this":
      return .show
    default:
      break
    }

    let tokens = phrase.split(separator: " ").map(String.init)
    if let seconds = Self.timerSeconds(in: tokens) {
      return .timer(seconds: seconds)
    }

    return .unrecognized(phrase: input)
  }

  /// Lowercase, collapse whitespace, drop trailing punctuation. Quotation marks around the
  /// phrase are stripped so dictation quirks don't eat a match.
  static func normalized(_ input: String) -> String {
    var phrase = input.lowercased()
      .trimmingCharacters(in: .whitespacesAndNewlines)
    while let last = phrase.last, ".!?,".contains(last) {
      phrase.removeLast()
      phrase = phrase.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    if phrase.count >= 2, phrase.hasPrefix("\""), phrase.hasSuffix("\"") {
      phrase = String(phrase.dropFirst().dropLast())
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    return phrase
      .components(separatedBy: .whitespacesAndNewlines)
      .filter { !$0.isEmpty }
      .joined(separator: " ")
  }

  /// Matches the §4.3 timer grammar: `timer (N) minutes`, `timer (N) min`, `N minutes`, with
  /// N a spoken or written number (1–180, integer or decimal, halves and quarters via
  /// "and a half" / "and a quarter"). Returns nil unless the whole token list matches.
  static func timerSeconds(in tokens: [String]) -> Int? {
    var rest = tokens
    if rest.first == "timer" {
      rest.removeFirst()
      // "timer" alone names no duration — that's the Timer tile's job, not a parse.
      guard !rest.isEmpty else { return nil }
    }

    guard let number = Self.minutes(from: rest) else { return nil }
    return Int((number * 60).rounded())
  }

  /// Parses `N unit` from the front of `tokens`, where N is a number, optionally followed by
  /// "and a half" / "and a quarter" (the spec's halves and quarters).
  ///
  /// Returns the minutes as a decimal, or nil when the tokens aren't a well-formed timer
  /// phrase in range.
  static func minutes(from tokens: [String]) -> Double? {
    var tokens = tokens
    var value = 0.0

    if let leading = leadingNumber(from: tokens) {
      value = leading.value
      tokens.removeFirst(leading.consumed)
    } else {
      return nil
    }

    // Optional "and a half" / "and a quarter" — the spec's halves and quarters.
    if tokens.first == "and", tokens.count >= 3, tokens[1] == "a" {
      let fractionWord = tokens[2]
      if fractionWord == "half" {
        value += 0.5
        tokens.removeFirst(3)
      } else if fractionWord == "quarter" {
        value += 0.25
        tokens.removeFirst(3)
      }
    }

    guard tokens.count == 1, Self.unitWords.contains(tokens[0]) else { return nil }

    guard value >= 1, value <= 180 else { return nil }
    return value
  }

  /// Reads a number from the front of the tokens: Arabic digits ("3", "1.5") or words
  /// ("three", "twenty-five", "one hundred eighty").
  static func leadingNumber(from tokens: [String]) -> (value: Double, consumed: Int)? {
    guard let first = tokens.first else { return nil }

    // Arabic numeral, optionally decimal.
    if let value = Double(first), first.contains(where: { $0.isNumber }) {
      return (value, 1)
    }

    // Spoken number: one … nine hundred (and) eighty, hyphens or spaces.
    var index = 0
    var total = 0.0
    var sawAny = false

    while index < tokens.count, index < 5 {
      let token = tokens[index]
      // "and" is only part of the number when a number word follows it
      // ("one hundred and eighty"); "one and a half" keeps it for the fraction pass.
      if token == "and", sawAny, index + 1 < tokens.count,
        Self.numberWordValue(tokens[index + 1]) != nil || tokens[index + 1] == "hundred" {
        index += 1
        continue
      }
      if token == "hundred", sawAny {
        total = (total == 0 ? 1 : total) * 100
        index += 1
        continue
      }
      if let unit = Self.numberWordValue(token) {
        total += unit
        sawAny = true
        index += 1
        continue
      }
      // Hyphenated compound: "twenty-five" splits into two values.
      if token.contains("-"), let compound = Self.hyphenatedValue(token) {
        total += compound
        sawAny = true
        index += 1
        continue
      }
      break
    }

    guard sawAny else { return nil }
    return (total, index)
  }

  /// "twenty-five" → 25.
  static func hyphenatedValue(_ token: String) -> Double? {
    let parts = token.components(separatedBy: "-")
    guard parts.count == 2, let tens = numberWordValue(parts[0]), let ones = numberWordValue(parts[1]),
      tens >= 20, ones > 0, ones < 10
    else { return nil }
    return tens + ones
  }

  /// The value of single number words, hyphens aside: one–nine, ten–nineteen, twenty…ninety.
  static func numberWordValue(_ word: String) -> Double? {
    let ones: [String: Double] = ["one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9]
    let teens: [String: Double] = ["ten": 10, "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14, "fifteen": 15,
      "sixteen": 16, "seventeen": 17, "eighteen": 18, "nineteen": 19]
    let tens: [String: Double] = ["twenty": 20, "thirty": 30, "forty": 40, "fifty": 50, "sixty": 60, "seventy": 70, "eighty": 80, "ninety": 90]
    if let value = ones[word] ?? teens[word] ?? tens[word] {
      return value
    }
    // A tens word joined to its ones by a hyphen was already handled elsewhere.
    if word.contains("-"), hyphenatedValue(word) != nil {
      return hyphenatedValue(word)
    }
    return nil
  }
}
