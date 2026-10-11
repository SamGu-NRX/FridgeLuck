import Foundation

/// On-demand provenance notes for the Progress cards (R4). Pure text
/// builders so the wording is testable off-host: each note states where a
/// number comes from and how it was aggregated. No medical or health-advice
/// language — these describe data sources and counting policy only.
enum ProgressSourceNotes {
  static let localJournalName = "your meal log"
  static let appleHealthName = "Apple Health"

  static func sourceName(_ source: ProgressNutritionSource) -> String {
    switch source {
    case .localJournal: localJournalName
    case .appleHealth: appleHealthName
    }
  }

  /// Today's calorie/macro card.
  static func todayNote(reading: ProgressTodayReading) -> String {
    let base = "Today's totals come from \(sourceName(reading.source))."
    if let reason = reading.fallbackReason {
      return base + " \(reason)."
    }
    return base
  }

  /// The trend chart card: source, window, and the aggregate policy for
  /// unknown days.
  static func rangeNote(reading: ProgressRangeReading) -> String {
    var lines: [String] = [
      "This chart reads \(sourceName(reading.source)) for the last \(reading.lastDays) days."
    ]
    lines.append(
      "Days with nothing recorded are left out of the average — they are not counted as zero calories. \(reading.coverageSummary)."
    )
    if let reason = reading.fallbackReason {
      lines.append("\(reason).")
    }
    return lines.joined(separator: " ")
  }

  /// The goal target: a confirmed personal target vs the goal's suggested
  /// default. A default never presents as user-set.
  static func goalNote(target: ProgressGoalTarget) -> String {
    switch target.provenance {
    case .confirmedPersonalTarget:
      return "This target was saved in your profile. Edit it in Settings → Profile."
    case .suggestedTarget:
      return
        "This is the suggested target for the \(target.goalName) goal — not one you set. Save your own target in Settings → Profile to replace it."
    }
  }
}
