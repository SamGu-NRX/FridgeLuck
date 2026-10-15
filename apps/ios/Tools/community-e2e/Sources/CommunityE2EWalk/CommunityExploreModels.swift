import Foundation

// Explore feed views (contracts/explore.schema.json, SPEC 3.2): published recipes only,
// newest first, cook counts below the trust floor of 10 served as null.

/// One card of the Explore feed.
public struct CommunityExploreCard: Codable, Sendable, Equatable {
  public var recipeRef: RecipeRef
  public var title: String
  public var authorDisplayName: String
  public var timeMinutes: Int
  public var allergenTags: [String]
  public var publishedAt: String
  /// Distinct cooks behind the recipe; null below the floor of 10 (SPEC 3.2).
  public var cookedBy: Int?
  public var challengeId: String?
}

/// Envelope of `GET /explore/feed`.
public struct CommunityExploreFeed: Codable, Sendable {
  public var items: [CommunityExploreCard]
  public var fetchedAt: String
}
