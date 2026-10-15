import Foundation

/// The one moderation vocabulary an author sees everywhere (SPEC 9.9): recipe page, publish
/// flow, outbox status. No counters, no "reported N times", no reporter identity — ever.
public enum AuthorModerationState: String, Codable, Sendable, CaseIterable {
  case `private`
  case published
  case flagged
  case inReview = "in_review"
  case removedByReview = "removed_by_review"
  case withdrawn

  /// Short title shown on the recipe page and publish flow.
  public var displayTitle: String {
    switch self {
    case .private: "Private"
    case .published: "Published"
    case .flagged: "Published — flagged"
    case .inReview: "In review"
    case .removedByReview: "Removed by review"
    case .withdrawn: "Removed from Explore"
    }
  }

  /// Exact copy from SPEC 9.9. `reviewReason` is only used by `.removedByReview` — one of
  /// "rights", "food safety", "personal information", "other".
  public func displayDetail(reviewReason: String? = nil) -> String {
    switch self {
    case .private:
      return "Private — only you can see this."
    case .published:
      return "In Explore."
    case .flagged:
      return "In Explore — one tag is being double-checked."
    case .inReview:
      return "In review — hidden from Explore until a person checks it."
    case .removedByReview:
      let reason = reviewReason ?? "other"
      return
        "Removed by review. Reason: \(reason). You can edit and share a new version."
    case .withdrawn:
      return "Removed from Explore. Your recipe is still yours, here."
    }
  }

  /// Derives the author-visible state from the locally stored publication state
  /// (`community_user_recipes.publication_state`, snake_case per SPEC 8.1) and the pending
  /// flagged tag from screening. `author_only` shows as published: in burst5 the Explore
  /// feed is off by default, so every published recipe is visible to its author only.
  public static func derive(
    publicationState: String,
    flaggedTag: String? = nil
  ) -> AuthorModerationState {
    switch publicationState {
    case "private": return .private
    case "author_only": return flaggedTag == nil ? .published : .flagged
    case "published": return flaggedTag == nil ? .published : .flagged
    case "in_review": return .inReview
    case "withdrawn": return .withdrawn
    // `rejected` is spelled removed_by_review in the author vocabulary; anything unknown
    // stays conservative and private.
    case "rejected": return .removedByReview
    default: return .private
    }
  }

  /// The local publication state an author-visible state maps back to, if unambiguous.
  public var storageState: String {
    switch self {
    case .private: "private"
    case .published, .flagged: "published"
    case .inReview: "in_review"
    case .removedByReview: "rejected"
    case .withdrawn: "withdrawn"
    }
  }
}
