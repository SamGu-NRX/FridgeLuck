import Foundation

/// Text and status for an item in the grocery review list.
enum GroceryReviewPresentation {
  struct Confidence {
    let text: String
    let kind: FLStatusPill.Kind
  }

  static func confidence(for item: GroceryPendingItem) -> Confidence {
    if item.source == .manual {
      return Confidence(text: "Added by you", kind: .neutral)
    }

    let score = item.confidenceScore
    let percentage = Int((score * 100).rounded())
    let kind: FLStatusPill.Kind =
      score >= 0.80 ? .positive : score >= 0.50 ? .warning : .neutral
    return Confidence(text: "\(percentage)%", kind: kind)
  }
}
