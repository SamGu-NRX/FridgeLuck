import SwiftUI

// Profile Basics–scoped semantic tokens for the explicit flow-state rendering in
// SettingsProfileBasicsView. Colors reuse existing AppTheme palette tokens where one
// fits; only the semantics live here so the screen's state rendering reads locally.

extension AppTheme {
  enum ProfileBasics {
    /// Inline validation and save-failure messaging.
    static let errorText = AppTheme.accent
    /// Soft wash behind the inline error message in the footer slot.
    static let errorBackground = AppTheme.accentMuted
    /// Hairline stroke framing the inline error message.
    static let errorStroke = AppTheme.accent.opacity(0.3)
  }
}
