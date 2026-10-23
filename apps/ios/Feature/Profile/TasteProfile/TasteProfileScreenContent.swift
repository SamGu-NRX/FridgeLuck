import FLFeatureLogic
import Foundation

/// A correction the taste profile screen offers on a row.
enum TasteProfileRowAction: Hashable, Sendable {
  case markWrong
  case dontAskAgain
  case reopen

  var title: String {
    switch self {
    case .markWrong: "This is wrong"
    case .dontAskAgain: "Don't ask again"
    case .reopen: "Reopen"
    }
  }

  var accessibilityHint: String {
    switch self {
    case .markWrong:
      "Moves this to Corrected. FridgeLuck won't learn it again from the same meals."
    case .dontAskAgain:
      "Hides this for \(TasteProfileScreenContent.dontAskAgainDays) days."
    case .reopen:
      "Lets FridgeLuck consider this again."
    }
  }

  /// Spoken after the action succeeds: the row leaves the spot VoiceOver was focused on, so
  /// the user hears where it went.
  var confirmation: String {
    switch self {
    case .markWrong: "Marked wrong. Moved to Corrected."
    case .dontAskAgain:
      "Hidden for \(TasteProfileScreenContent.dontAskAgainDays) days. Moved to Corrected."
    case .reopen: "Reopened."
    }
  }

  var identifierStem: String {
    switch self {
    case .markWrong: "mark_wrong"
    case .dontAskAgain: "dont_ask_again"
    case .reopen: "reopen"
    }
  }

  /// The actions a row offers come only from the row's own flags, so a layer the view model
  /// refuses (restrictions) can never grow a button here.
  static func offered(for row: TasteProfileRow) -> [TasteProfileRowAction] {
    var actions: [TasteProfileRowAction] = []
    if row.canMarkWrong { actions.append(.markWrong) }
    if row.canDontAskAgain { actions.append(.dontAskAgain) }
    if row.canReopen { actions.append(.reopen) }
    return actions
  }
}

/// What `TasteProfileView` draws, derived from the view model in one place. The view
/// renders this and nothing else, so tests check what the screen shows without a UI-tree
/// inspector.
enum TasteProfileScreenContent: Equatable {
  case loading
  case empty
  case failed
  /// `actionError` is set when a correction failed and the page kept its rows.
  case loaded(sections: [Section], actionError: String?)

  struct Section: Equatable, Identifiable {
    let id: TasteProfileSection.Kind
    let title: String
    let rows: [Row]
    let footer: String?
    /// Shown inside the section when it has no rows but should still explain itself.
    let placeholder: String?
    /// Restrictions are edited in Food Preferences; their section links there instead of
    /// offering corrections.
    let linksToFoodPreferences: Bool
  }

  struct Row: Equatable, Identifiable {
    let source: TasteProfileRow
    let sentence: String
    let isStruckThrough: Bool
    /// "4 of 5 times · last Oct 12", "Hidden until Jan 21" or "Marked wrong"; nil when the
    /// sentence stands on no counts.
    let detail: String?
    let accessibilityLabel: String
    let actions: [TasteProfileRowAction]

    var id: String { source.id }
  }

  static let emptyTitle = "Nothing learned yet"
  static let emptyMessage =
    "Cook a few meals and rate them. What FridgeLuck notices about your taste shows up here, and you can correct it."
  static let learnedPlaceholder = "Nothing learned yet. Cook and rate a few meals."
  static let dontAskAgainDays = Int(TasteProfileViewModel.dontAskAgainDuration / 86_400)

  @MainActor
  static func make(
    from viewModel: TasteProfileViewModel,
    now: Date = Date(),
    locale: Locale = .autoupdatingCurrent,
    timeZone: TimeZone = .autoupdatingCurrent
  ) -> TasteProfileScreenContent {
    let hasRows = viewModel.sections.contains { !$0.rows.isEmpty }
    if !viewModel.hasLoaded || (viewModel.isLoading && !hasRows) {
      return .loading
    }
    if !hasRows {
      return viewModel.errorMessage == nil ? .empty : .failed
    }
    let dates = DateText(now: now, locale: locale, timeZone: timeZone)
    let sections = viewModel.sections.compactMap { section(from: $0, dates: dates) }
    return .loaded(sections: sections, actionError: viewModel.errorMessage)
  }

  /// Row ids per section, so the view can animate a row moving between sections.
  var rowLayout: [[String]] {
    guard case .loaded(let sections, _) = self else { return [] }
    return sections.map { $0.rows.map(\.id) }
  }

  // MARK: - Mapping

  @MainActor
  private static func section(
    from section: TasteProfileSection, dates: DateText
  ) -> Section? {
    let rows = section.rows.map { row(from: $0, dates: dates) }
    switch section.id {
    case .restrictions:
      guard !rows.isEmpty else { return nil }
      return Section(
        id: .restrictions, title: "Allergies & diet", rows: rows,
        footer: "Recipes with these never show up.",
        placeholder: nil, linksToFoodPreferences: true)
    case .stated:
      guard !rows.isEmpty else { return nil }
      return Section(
        id: .stated, title: "What you told us", rows: rows, footer: nil, placeholder: nil,
        linksToFoodPreferences: false)
    case .pinned:
      guard !rows.isEmpty else { return nil }
      return Section(
        id: .pinned, title: "Set by you", rows: rows, footer: nil, placeholder: nil,
        linksToFoodPreferences: false)
    case .learned:
      // Kept even when empty: a page with only restrictions should still say what will
      // appear here.
      return Section(
        id: .learned, title: "What FridgeLuck noticed", rows: rows, footer: nil,
        placeholder: rows.isEmpty ? learnedPlaceholder : nil,
        linksToFoodPreferences: false)
    case .corrections:
      guard !rows.isEmpty else { return nil }
      return Section(
        id: .corrections, title: "Corrected", rows: rows,
        footer: "Reopen anything to let FridgeLuck consider it again.",
        placeholder: nil, linksToFoodPreferences: false)
    }
  }

  @MainActor
  private static func row(from row: TasteProfileRow, dates: DateText) -> Row {
    let detail: String?
    let spokenDetail: String?
    switch row.state {
    case .rejected:
      detail = "Marked wrong"
      spokenDetail = "Marked wrong"
    case .muted:
      if let until = row.mutedUntil {
        detail = "Hidden until \(dates.short(until))"
        spokenDetail = "Hidden until \(dates.spoken(until))"
      } else {
        detail = "Hidden"
        spokenDetail = "Hidden"
      }
    case .active, .confirmed, .expired:
      if let counts = TasteProfileViewModel.evidenceDetail(for: row),
        let denominator = row.denominator
      {
        let times = "\(counts) \(denominator == 1 ? "time" : "times")"
        if let last = row.lastEvidenceAt {
          detail = "\(times) · last \(dates.short(last))"
          spokenDetail = "\(times), most recently \(dates.spoken(last))"
        } else {
          detail = times
          spokenDetail = times
        }
      } else {
        detail = nil
        spokenDetail = nil
      }
    }
    return Row(
      source: row,
      sentence: row.text,
      isStruckThrough: row.state == .rejected,
      detail: detail,
      accessibilityLabel: [row.text, spokenDetail].compactMap { $0 }.joined(separator: ". "),
      actions: TasteProfileRowAction.offered(for: row))
  }
}

/// Short dates for evidence lines ("Oct 12"; the year only when it isn't this year) and
/// their spelled-out form for VoiceOver.
private struct DateText {
  let now: Date
  let locale: Locale
  let timeZone: TimeZone

  func short(_ date: Date) -> String {
    format(date, month: .abbreviated)
  }

  func spoken(_ date: Date) -> String {
    format(date, month: .wide)
  }

  private func format(_ date: Date, month: Date.FormatStyle.Symbol.Month) -> String {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone
    var style = Date.FormatStyle(locale: locale, calendar: calendar, timeZone: timeZone)
      .month(month).day()
    if calendar.component(.year, from: date) != calendar.component(.year, from: now) {
      style = style.year()
    }
    return date.formatted(style)
  }
}

extension TasteProfileViewModel {
  /// The one path every row button takes, so tests drive exactly what a tap does.
  func perform(_ action: TasteProfileRowAction, on row: TasteProfileRow) async {
    switch action {
    case .markWrong: await markWrong(row)
    case .dontAskAgain: await dontAskAgain(row)
    case .reopen: await reopen(row)
    }
  }
}
