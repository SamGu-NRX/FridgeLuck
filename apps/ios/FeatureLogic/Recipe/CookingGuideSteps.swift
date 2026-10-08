import Foundation

/// The cooking guide's step pages, built from a recipe's stored instructions.
///
/// Bundled recipes keep their source on the first line ("Source: https://www.bbcgoodfood.com/…",
/// 141 of the 166 recipes in data.json) and number every step ("1. Toast the peppercorns.").
/// Read raw, the guide showed the URL as step 1 and printed "1." under its own "02 of 7".
/// A source line becomes `attribution` instead of a step, and leading step numbers are removed
/// because the guide numbers its pages itself.
public struct CookingGuideSteps: Equatable, Sendable {
  public let steps: [String]
  public let attribution: RecipeAttribution?

  public init(instructions: String) {
    var steps: [String] = []
    var attribution: RecipeAttribution?

    for rawLine in instructions.components(separatedBy: .newlines) {
      let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !line.isEmpty else { continue }

      if let source = Self.sourceText(in: line) {
        if attribution == nil, !source.isEmpty {
          attribution = RecipeAttribution(source: source)
        }
        continue
      }

      let step = Self.removingStepNumber(from: line)
      if !step.isEmpty {
        steps.append(step)
      }
    }

    self.steps = steps
    self.attribution = attribution
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

/// Where a recipe came from, for the line at the end of the cooking guide.
public struct RecipeAttribution: Equatable, Sendable {
  /// The site's host without "www." for a web address, otherwise the source as written.
  public let label: String
  /// Set only for http(s) addresses, so the guide never links to anything else.
  public let url: URL?

  public init(source: String) {
    if let url = URL(string: source),
      let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
      let host = url.host(), !host.isEmpty
    {
      self.url = url
      self.label = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    } else {
      self.url = nil
      self.label = source
    }
  }
}
