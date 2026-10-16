import Foundation

/// The stable integer handle a reverse-scan candidate rides under in the cloud ranking
/// round trip. Both the direct Gemini prompt and the backend `/v1/reverse-scan/rank`
/// contract key rankings on an integer `recipe_id`; catalog candidates (no legacy row,
/// `Recipe(id: nil, …)`) keep their identity under a negative handle — legacy ids are
/// always positive, so the two spaces never collide. The agent assigns handles when it
/// builds the request and the service maps rankings back through the same rule, so the
/// pairing lives in one tested place, not in an agreed-on convention.
enum ReverseScanCandidateHandle {
  /// The handle for each candidate, in the order the candidates will be sent. Legacy
  /// recipes keep their positive row id; catalog candidates number from -1 in their own
  /// counter — a global position offset would leave holes (-2, -4, …) between legacy
  /// entries and make the handle space look sparser than it is to the ranking backend.
  static func handles(for candidates: [ReverseScanRecipeCandidate]) -> [Int64] {
    var catalogHandle = Int64(0)
    return candidates.map { candidate in
      guard let id = candidate.recipe.recipe.id else {
        catalogHandle += 1
        return -catalogHandle
      }
      return id
    }
  }
}
