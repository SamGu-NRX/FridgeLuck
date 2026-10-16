import XCTest
@testable import CommunityCheckKit

/// Decodes and encodes every contract example the app uses (copied from
/// `docs/spec/community/contracts/examples/` into `Tests/Community/Fixtures/`), so a contract
/// change that breaks the app fails a test the same day it lands (community SPEC 8.5).
final class CommunityContractRoundTripTests: XCTestCase {
  func testDecodeAndReEncodeCreatePublicationRequestExample() throws {
    let data = try CommunityContractFixtures.load("createPublication.request")
    let decoded = try JSONDecoder().decode(CreatePublicationRequest.self, from: data)

    XCTAssertEqual(decoded.operationId, "d1b2f0a4-9c3e-4a7f-8b21-5f6a7b8c9d0e")
    XCTAssertEqual(decoded.recipeRef, RecipeRef(source: .user, id: "ur_7Kq2m", revision: 3))
    XCTAssertEqual(decoded.content.title, "Butter bean curry")
    XCTAssertEqual(decoded.content.servings, 2)
    XCTAssertEqual(decoded.content.timeMinutes, 35)
    XCTAssertEqual(decoded.content.ingredientLines.count, 3)
    XCTAssertEqual(decoded.content.ingredientLines.first?.fdcId, 173_736)
    XCTAssertEqual(decoded.content.ingredientLines.first?.unit, .gram)
    XCTAssertEqual(decoded.content.steps.count, 2)
    XCTAssertEqual(decoded.content.steps.first?.timerMinutes, 5)
    XCTAssertEqual(decoded.content.equipment, ["frying pan", "wooden spoon"])
    XCTAssertEqual(decoded.content.dietaryTags, ["vegetarian", "vegan"])
    XCTAssertEqual(decoded.declaration, RecipeRightsDeclaration(ownRights: true, noPersonalData: true))
    XCTAssertNil(decoded.challengeId)

    // Re-encode and decode again: the struct survives the round trip unchanged.
    let redecoded = try JSONDecoder().decode(
      CreatePublicationRequest.self, from: JSONEncoder().encode(decoded))
    XCTAssertEqual(redecoded, decoded)
  }

  func testBuilderReproducesTheRequestExampleFromItsContent() throws {
    let data = try CommunityContractFixtures.load("createPublication.request")
    let decoded = try JSONDecoder().decode(CreatePublicationRequest.self, from: data)

    let built = SharePreviewBuilder.payload(
      communityRecipeId: decoded.recipeRef.id,
      revision: decoded.recipeRef.revision,
      content: decoded.content,
      declaration: decoded.declaration,
      operationId: decoded.operationId,
      challengeId: decoded.challengeId)
    XCTAssertEqual(built, decoded, "the builder produces exactly the contract's request shape")
  }

  func testDecodeAndReEncodeCreatePublicationResponseExample() throws {
    let data = try CommunityContractFixtures.load("createPublication.response")
    let decoded = try JSONDecoder().decode(Publication.self, from: data)

    XCTAssertEqual(decoded.publicationId, "pub_M3Np8qXw2R")
    XCTAssertEqual(decoded.recipeRef, RecipeRef(source: .user, id: "ur_7Kq2m", revision: 3))
    XCTAssertEqual(decoded.authorDisplayName, "Sam")
    XCTAssertEqual(decoded.allergenTags, [.milk, .eggs])
    XCTAssertEqual(decoded.state, .published)
    XCTAssertEqual(decoded.publishedAt, "2026-10-15T18:40:00Z")
    XCTAssertNil(decoded.withdrawnAt)
    XCTAssertNil(decoded.flaggedTag)
    XCTAssertNil(decoded.challengeId)

    let redecoded = try JSONDecoder().decode(
      Publication.self, from: JSONEncoder().encode(decoded))
    XCTAssertEqual(redecoded, decoded)
  }

  func testDecodeGetPublicationResponseExample() throws {
    let data = try CommunityContractFixtures.load("getPublication.response")
    let decoded = try JSONDecoder().decode(Publication.self, from: data)
    XCTAssertEqual(decoded.publicationId, "pub_M3Np8qXw2R")
    XCTAssertEqual(decoded.state, .published)
    XCTAssertEqual(decoded.content.title, "Butter bean curry")
  }

  func testDecodeListMyPublicationsResponseExample() throws {
    let data = try CommunityContractFixtures.load("listMyPublications.response")
    let decoded = try JSONDecoder().decode(PublicationList.self, from: data)

    XCTAssertFalse(decoded.publications.isEmpty)
    let first = try XCTUnwrap(decoded.publications.first)
    XCTAssertEqual(first.publicationId, "pub_M3Np8qXw2R")
    // Every entry decodes with a valid contract state.
    for publication in decoded.publications {
      XCTAssertFalse(publication.content.title.isEmpty)
      XCTAssertFalse(publication.authorDisplayName.isEmpty)
    }
  }

  func testDecodePublishedWithFlaggedTag() throws {
    // A published-with-flag document is the "Published — flagged" author state (SPEC 2.3).
    let flaggedJSON = """
      {
        "publicationId": "pub_flaggedtest",
        "recipeRef": {"source": "user", "id": "ur_7Kq2m", "revision": 1},
        "content": {
          "title": "Something", "servings": 2, "timeMinutes": null,
          "ingredientLines": [{"name": "mystery greens"}],
          "steps": [{"text": "Cook."}], "equipment": [], "dietaryTags": []
        },
        "authorDisplayName": "Sam",
        "allergenTags": ["unknown-contents"],
        "state": "published",
        "publishedAt": "2026-10-15T18:40:00Z",
        "withdrawnAt": null,
        "flaggedTag": "unknown-contents",
        "challengeId": null
      }
      """
    let decoded = try JSONDecoder().decode(Publication.self, from: Data(flaggedJSON.utf8))
    XCTAssertEqual(decoded.flaggedTag, .unknownContents)
    XCTAssertEqual(decoded.allergenTags, [.unknownContents])
  }
}
