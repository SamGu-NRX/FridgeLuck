import SwiftUI

enum UpdateGroceriesLaunchMode: String, Identifiable, Sendable {
  case chooser
  case photo
  case receipt
  case manual
  case barcode

  static let entryModes: [UpdateGroceriesLaunchMode] = [.photo, .receipt, .manual, .barcode]

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
    case .barcode:
      "Scan a barcode"
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
    case .barcode:
      "Point at the package or type the number"
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
    case .barcode:
      "barcode.viewfinder"
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
    case .barcode:
      AppTheme.accent
    }
  }

  var captureTitle: String {
    switch self {
    case .receipt:
      "Scan Receipt"
    case .barcode:
      "Scan Barcode"
    case .chooser, .photo, .manual:
      "Photograph Groceries"
    }
  }

  var captureSubtitle: String {
    switch self {
    case .receipt:
      "Center the receipt in frame"
    case .barcode:
      "Center the barcode in frame"
    case .chooser, .photo, .manual:
      "Lay out items for best results"
    }
  }

  var isDirectEntry: Bool {
    self != .chooser
  }
}
