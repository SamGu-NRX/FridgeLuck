import GRDB
import XCTest
@testable import CommunityCheckKit

/// User-recipe lifecycle in `CommunityStore`: private by default, revisions on edit,
/// duplicate with attribution, publication-state linkage (community SPEC 2.1–2.4, 9.9).
final class CommunityStoreTests: XCTestCase {
  private var db: DatabaseQueue!
  private var store: CommunityStore!

  override func setUpWithError() throws {
    db = try DatabaseQueue()
    try DatabaseMigrations.migrate(db)
    store = CommunityStore(db: db)
  }

  private static func curryContent(title: String = "Butter bean curry") -> RecipeRevisionContent {
    RecipeRevisionContent(
      title: title,
      description: "One-pan, mild, cheap.",
      servings: 2,
      timeMinutes: 35,
      ingredientLines: [
        IngredientLine(name: "butter beans", quantity: 400, unit: .gram, preparation: "drained"),
        IngredientLine(name: "onion", quantity: 1, unit: .piece),
      ],
      steps: [
        RecipeStep(text: "Sweat the onion.", timerMinutes: 5),
        RecipeStep(text: "Add beans and simmer.", timerMinutes: 20),
      ],
      equipment: ["frying pan"],
      dietaryTags: ["vegetarian"])
  }

  func testCreatedRecipeIsPrivateAtRevisionOne() throws {
    let recipeId = try store.createUserRecipe(Self.curryContent())

    let recipe = try XCTUnwrap(store.userRecipe(recipeId: recipeId))
    XCTAssertEqual(recipe.authorModerationState, .private)
    XCTAssertEqual(recipe.latestRevision, 1)
    XCTAssertTrue(recipe.communityRecipeId.hasPrefix("ur_"))
    XCTAssertTrue(try store.isPublishable(recipeId: recipeId))

    let content = try JSONDecoder().decode(
      RecipeRevisionContent.self,
      from: try XCTUnwrap(store.latestRevisionPayload(recipeId: recipeId)))
    XCTAssertEqual(content, Self.curryContent())
  }

  func testEditForksANewRevisionAndKeepsHistoryFrozen() throws {
    let recipeId = try store.createUserRecipe(Self.curryContent())

    let edited = RecipeRevisionContent(
      title: "Butter bean curry",
      description: "One-pan, mild, cheap.",
      servings: 4,
      timeMinutes: 40,
      ingredientLines: [IngredientLine(name: "butter beans", quantity: 800, unit: .gram)],
      steps: [RecipeStep(text: "Simmer everything.")])
    let revision = try store.editUserRecipe(recipeId, to: edited)

    XCTAssertEqual(revision, 2)
    XCTAssertEqual(try store.latestRevision(recipeId: recipeId), 2)
    let v1 = try JSONDecoder().decode(
      RecipeRevisionContent.self,
      from: try XCTUnwrap(store.revisionPayload(recipeId: recipeId, revision: 1)))
    let v2 = try JSONDecoder().decode(
      RecipeRevisionContent.self,
      from: try XCTUnwrap(store.revisionPayload(recipeId: recipeId, revision: 2)))
    XCTAssertEqual(v1.servings, 2)
    XCTAssertEqual(v2.servings, 4)
  }

  func testDuplicateCopiesIntoNewRecipeAtRevisionOneWithAttribution() throws {
    let recipeId = try store.createUserRecipe(Self.curryContent())
    let sourceCommunityId = try XCTUnwrap(store.userRecipe(recipeId: recipeId)).communityRecipeId
    try store.editUserRecipe(recipeId, to: Self.curryContent(title: "Edited curry"))

    let duplicateId = try store.duplicateUserRecipe(recipeId, attributedTo: "Sam")

    XCTAssertNotEqual(duplicateId, recipeId)
    let duplicate = try XCTUnwrap(store.userRecipe(recipeId: duplicateId))
    XCTAssertEqual(duplicate.latestRevision, 1)
    XCTAssertEqual(duplicate.authorModerationState, .private)
    XCTAssertEqual(duplicate.duplicatedFrom, "Sam")
    XCTAssertNotEqual(duplicate.communityRecipeId, sourceCommunityId)
    let content = try JSONDecoder().decode(
      RecipeRevisionContent.self,
      from: try XCTUnwrap(store.latestRevisionPayload(recipeId: duplicateId)))
    XCTAssertEqual(content.title, "Edited curry")
  }

  func testApplyPublicationRecordsStateAndWithdrawal() throws {
    let recipeId = try store.createUserRecipe(Self.curryContent())
    let communityId = try XCTUnwrap(store.userRecipe(recipeId: recipeId)).communityRecipeId

    let publication = Publication(
      publicationId: "pub_M3Np8qXw2R",
      recipeRef: RecipeRef(source: .user, id: communityId, revision: 1),
      content: Self.curryContent(),
      authorDisplayName: "Sam",
      allergenTags: [.soy],
      state: .queued,
      publishedAt: "2026-10-15T18:40:00Z")
    try store.applyPublication(publication, recipeId: recipeId)

    XCTAssertEqual(try store.authorModerationState(recipeId: recipeId), .inReview)
    let recipe = try XCTUnwrap(store.userRecipe(recipeId: recipeId))
    XCTAssertEqual(recipe.publicationId, "pub_M3Np8qXw2R")
    XCTAssertEqual(recipe.publishedRevision, 1)

    try store.markWithdrawn(recipeId: recipeId)
    XCTAssertEqual(try store.authorModerationState(recipeId: recipeId), .withdrawn)
  }

  func testFlaggedTagDerivesFlaggedAuthorState() throws {
    let recipeId = try store.createUserRecipe(Self.curryContent())
    let communityId = try XCTUnwrap(store.userRecipe(recipeId: recipeId)).communityRecipeId
    let publication = Publication(
      publicationId: "pub_flagged0000",
      recipeRef: RecipeRef(source: .user, id: communityId, revision: 1),
      content: Self.curryContent(),
      authorDisplayName: "Sam",
      allergenTags: [.unknownContents],
      state: .published,
      publishedAt: "2026-10-15T18:40:00Z",
      flaggedTag: .unknownContents)
    try store.applyPublication(publication, recipeId: recipeId)
    XCTAssertEqual(try store.authorModerationState(recipeId: recipeId), .flagged)
  }

  func testWithdrawCancelsQueuedPublishes() throws {
    let recipeId = try store.createUserRecipe(Self.curryContent())
    let communityId = try XCTUnwrap(store.userRecipe(recipeId: recipeId)).communityRecipeId
    let payload = SharePreviewBuilder.payload(
      communityRecipeId: communityId, revision: 1, content: Self.curryContent(),
      declaration: RecipeRightsDeclaration(ownRights: true, noPersonalData: true),
      operationId: UUID().uuidString)
    let outboxId = try store.enqueue(
      .publish, payload: JSONEncoder().encode(payload), recipeId: recipeId)

    let cancelled = try store.cancelQueuedPublishes(recipeId: recipeId, reason: "withdrawn")

    XCTAssertEqual(cancelled, 1)
    XCTAssertEqual(try store.outboxState(id: outboxId), .cancelled)
    XCTAssertEqual(try store.queuedOutboxCount(), 0)
  }
}
