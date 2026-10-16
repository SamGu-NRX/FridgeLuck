import FLFeatureLogic
import XCTest
@testable import FridgeLuck

/// The share preview never carries a forbidden field: whatever the builder can produce, the
/// encoded payload contains only the spec's whitelisted keys — never pantry, health, taste
/// data, photos, contact or device identifiers (community SPEC 2.3, 8.2; extends PR #106's
/// SharedCookRedactionTests policy to publications).
final class SharePreviewRedactionTests: XCTestCase {
  private static func maximalContent() -> RecipeRevisionContent {
    RecipeRevisionContent(
      title: "Butter bean curry",
      description: "One-pan, mild, cheap.",
      servings: 2,
      timeMinutes: 35,
      ingredientLines: [
        IngredientLine(
          name: "butter beans", quantity: 400, unit: .gram, preparation: "drained", fdcId: 173_736),
        IngredientLine(name: "onion", quantity: 1, unit: .piece, preparation: nil, fdcId: 11_282),
      ],
      steps: [
        RecipeStep(text: "Sweat the onion.", timerMinutes: 5),
        RecipeStep(text: "Simmer.", timerMinutes: nil),
      ],
      equipment: ["frying pan", "wooden spoon"],
      dietaryTags: ["vegetarian", "vegan"])
  }

  private static func maximalPayload() -> CreatePublicationRequest {
    SharePreviewBuilder.payload(
      communityRecipeId: "ur_7Kq2m",
      revision: 3,
      content: maximalContent(),
      declaration: RecipeRightsDeclaration(ownRights: true, noPersonalData: true),
      operationId: "D1B2F0A4-9C3E-4A7F-8B21-5F6A7B8C9D0E",
      challengeId: nil)
  }

  func testBuiltPayloadHasNoForbiddenKeys() throws {
    let forbidden = SharePreviewBuilder.forbiddenKeys(in: Self.maximalPayload())
    XCTAssertEqual(forbidden, [], "keys outside the whitelist: \(forbidden)")
  }

  func testEncodedPayloadTopLevelKeysAreExactlyTheWhitelist() throws {
    let object = try JSONSerialization.jsonObject(
      with: JSONEncoder().encode(Self.maximalPayload())) as! [String: Any]
    XCTAssertEqual(
      Set(object.keys), SharePreviewBuilder.allowedRequestKeys,
      "the payload carries exactly the contract's fields, nothing more")
  }

  func testContentKeysAreExactlyTheSpecPayloadFields() throws {
    let object = try JSONSerialization.jsonObject(
      with: JSONEncoder().encode(Self.maximalPayload())) as! [String: Any]
    let content = try XCTUnwrap(object["content"] as? [String: Any])
    XCTAssertEqual(Set(content.keys), SharePreviewBuilder.allowedContentKeys)
    let lines = try XCTUnwrap(content["ingredientLines"] as? [[String: Any]])
    for line in lines {
      XCTAssertEqual(Set(line.keys), SharePreviewBuilder.allowedIngredientLineKeys)
    }
    let steps = try XCTUnwrap(content["steps"] as? [[String: Any]])
    for step in steps {
      XCTAssertTrue(Set(step.keys).isSubset(of: SharePreviewBuilder.allowedStepKeys))
    }
  }

  func testEncodedJSONNeverNamesForbiddenCategories() throws {
    let json = String(decoding: try JSONEncoder().encode(Self.maximalPayload()), as: UTF8.self)
    for forbiddenWord in ["pantry", "health", "taste", "photo", "device_id", "email", "phone"]
    where json.lowercased().contains(forbiddenWord) {
      XCTFail("encoded payload mentions '\(forbiddenWord)': \(json)")
    }
  }

  func testPreviewRendersTheSameStructThatIsSent() throws {
    let preview = SharePreviewBuilder.preview(
      communityRecipeId: "ur_7Kq2m",
      revision: 3,
      content: Self.maximalContent(),
      declaration: RecipeRightsDeclaration(ownRights: true, noPersonalData: true),
      operationId: "D1B2F0A4-9C3E-4A7F-8B21-5F6A7B8C9D0E",
      authorDisplayName: "Sam",
      willQueueOffline: true)
    // The preview carries the outgoing struct itself, so the sheet cannot drift from the wire.
    XCTAssertEqual(preview.payload, Self.maximalPayload())
    XCTAssertTrue(preview.willQueueOffline)
    XCTAssertEqual(
      SharePreview.neverSentCopy,
      "Never sent: your pantry, health information, taste profile, photos, or anything else about you.")
    XCTAssertEqual(preview.authorDisplayName, "Sam")
  }
}
