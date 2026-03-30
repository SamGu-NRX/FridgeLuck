import SwiftUI

enum UpdateGroceriesLaunchMode: String, Identifiable, Sendable {
  case chooser
  case photo
  case receipt
  case manual

  static let entryModes: [UpdateGroceriesLaunchMode] = [.photo, .receipt, .manual]

  var id: String { rawValue }

  var title: String {
    switch self {
    case .chooser:
      "Add groceries"
    case .photo:
      "Photograph groceries"
    case .receipt:
      "Scan a receipt"
    case .manual:
      "Add items manually"
    }
  }

  var subtitle: String {
    switch self {
    case .chooser:
      "Choose an entry method"
    case .photo:
      "Snap a photo of your haul"
    case .receipt:
      "OCR your shopping receipt"
    case .manual:
      "Search and add by hand"
    }
  }

  var icon: String {
    switch self {
    case .chooser:
      "plus.circle.fill"
    case .photo:
      "camera.fill"
    case .receipt:
      "doc.text.viewfinder"
    case .manual:
      "text.badge.plus"
    }
  }

  var iconColor: Color {
    switch self {
    case .chooser:
      AppTheme.accent
    case .photo:
      AppTheme.accent
    case .receipt:
      AppTheme.sage
    case .manual:
      AppTheme.oat
    }
  }

  var captureTitle: String {
    switch self {
    case .receipt:
      "Scan Receipt"
    case .chooser, .photo, .manual:
      "Photograph Groceries"
    }
  }

  var captureSubtitle: String {
    switch self {
    case .receipt:
      "Center the receipt in frame"
    case .chooser, .photo, .manual:
      "Lay out items for best results"
    }
  }

  var isDirectEntry: Bool {
    self != .chooser
  }
}
