import XCTest

@testable import CommunityCheckKit

/// Contract-example round-trips for the sign-in, Tables, and challenge surfaces (community
/// SPEC 8.5): every example the app uses decodes into the wire models, and every request
/// example is reproduced from the model — a contract change that breaks the app fails a test
/// the same day it lands. Pattern follows CommunityContractRoundTripTests.
final class CommunitySessionRoundTripTests: XCTestCase {
  private func decode<T: Decodable>(_ type: T.Type, _ name: String) throws -> T {
    try JSONDecoder().decode(type, from: try CommunityContractFixtures.load(name))
  }

  /// Decoded model → re-encoded JSON compared by value, not byte order.
  private func assertReencodes<T: Codable & Equatable>(_ value: T) throws {
    let roundTripped = try JSONDecoder().decode(T.self, from: JSONEncoder().encode(value))
    XCTAssertEqual(roundTripped, value)
  }

  private func assertSameJSON(_ lhs: Data, _ rhs: Data) throws {
    let a = try JSONSerialization.jsonObject(with: lhs)
    let b = try JSONSerialization.jsonObject(with: rhs)
    let left = try JSONSerialization.data(withJSONObject: a, options: [.sortedKeys])
    let right = try JSONSerialization.data(withJSONObject: b, options: [.sortedKeys])
    XCTAssertEqual(left, right)
  }

  // MARK: - Sign-in (SPEC 6.1, 6.2)

  func testDecodeAndReEncodeAuthAppleRequestExample() throws {
    let body = try decode(AuthAppleRequest.self, "authApple.request")
    XCTAssertEqual(
      body.identityToken, "eyJhbGciOiJSUzI1NiJ9.<apple-jws-payload>.<apple-signature>")
    XCTAssertEqual(body.nonce, "9f8e7d6c-5b4a-3f2e-1d0c-9b8a7f6e5d4c")
    XCTAssertEqual(body.attest18Plus, CommunityBirthYearAttestation(birthYear: 2001))
    try assertReencodes(body)
    try assertSameJSON(
      JSONEncoder().encode(body), CommunityContractFixtures.load("authApple.request"))
  }

  func testDecodeAuthAppleResponseExample() throws {
    let session = try decode(CommunitySession.self, "authApple.response")
    XCTAssertEqual(session.accessToken, "fla1.b64payload.b64mac")
    XCTAssertEqual(session.refreshToken, "flr1.b64random")
    XCTAssertEqual(session.account.accountId, "acc_Q8W2Yt0pXa")
    XCTAssertEqual(session.account.displayName, "Sam")
    XCTAssertTrue(session.account.isAdult)
    XCTAssertNil(session.account.canVoteAt)
    XCTAssertEqual(session.account.moderationOperator, false)
  }

  func testDecodeAuthRefreshExamples() throws {
    let request = try decode(AuthRefreshRequest.self, "authRefresh.request")
    XCTAssertEqual(request.refreshToken, "flr1.b64random")
    try assertReencodes(request)

    let rotated = try decode(CommunitySession.self, "authRefresh.response")
    XCTAssertEqual(rotated.refreshToken, "flr1.b64random2")
    XCTAssertEqual(rotated.account.accountId, "acc_Q8W2Yt0pXa")
  }

  func testDecodeGetMeResponseExample() throws {
    let account = try decode(CommunityAccount.self, "getMe.response")
    XCTAssertEqual(
      account,
      CommunityAccount(
        accountId: "acc_Q8W2Yt0pXa", displayName: "Sam", isAdult: true, canVoteAt: nil,
        moderationOperator: false))
  }

  // MARK: - Tables (SPEC 5)

  func testDecodeAndReEncodeCreateTableRequestExample() throws {
    let body = try decode(CommunityCreateTableRequest.self, "createTable.request")
    XCTAssertEqual(body.name, "Flat 4B")
    try assertSameJSON(
      JSONEncoder().encode(body), CommunityContractFixtures.load("createTable.request"))
  }

  func testDecodeCreateTableResponseExample() throws {
    let table = try decode(CommunityTable.self, "createTable.response")
    XCTAssertEqual(table.tableId, "tbl_F6hJk1Mw9Q")
    XCTAssertEqual(table.name, "Flat 4B")
    XCTAssertEqual(table.createdAt, "2026-10-02T19:00:00Z")
    XCTAssertEqual(table.members.count, 2)
    XCTAssertEqual(
      table.members[0],
      CommunityTableMember(
        accountId: "acc_Q8W2Yt0pXa", displayName: "Sam", role: .owner,
        joinedAt: "2026-10-02T19:00:00Z"))
    XCTAssertEqual(table.members[1].displayName, "Maya")
    XCTAssertEqual(table.members[1].role, .member)
    XCTAssertTrue(table.pendingInvites?.isEmpty ?? false)
    XCTAssertFalse(table.isOwnerAlone)
  }

  func testDecodeCreateInviteResponseExampleShowsTheJoinCodeOnce() throws {
    let invite = try decode(CommunityTableInvite.self, "createInvite.response")
    XCTAssertEqual(invite.inviteId, "inv_A1bC2dE3f4G")
    XCTAssertEqual(invite.state, .pending)
    XCTAssertEqual(invite.joinCode, "M4KPXQ")
    XCTAssertEqual(invite.expiresAt, "2026-10-22T18:40:00Z")
  }

  func testDecodeApproveInviteResponseExampleHidesTheJoinCode() throws {
    let invite = try decode(CommunityTableInvite.self, "approveInvite.response")
    XCTAssertEqual(invite.state, .approved)
    XCTAssertEqual(invite.requestedByDisplayName, "Dev")
    XCTAssertNil(invite.joinCode, "the code is shown exactly once — at minting (SPEC 5.1)")
  }

  func testDecodeJoinTableResponseExample() throws {
    let join = try decode(CommunityTableJoinView.self, "joinTable.response")
    XCTAssertEqual(join.inviteId, "inv_A1bC2dE3f4G")
    XCTAssertEqual(join.tableId, "tbl_F6hJk1Mw9Q")
    XCTAssertEqual(join.tableName, "Flat 4B")
    XCTAssertEqual(join.state, .pending)
  }

  func testDecodeListBlocksResponseExample() throws {
    let blocks = try decode(CommunityBlockList.self, "listBlocks.response").blocks
    XCTAssertEqual(blocks.count, 1)
    XCTAssertEqual(blocks[0].accountId, "acc_X9mQw3Vb1N")
    XCTAssertEqual(blocks[0].displayName, "Riley")
  }

  // MARK: - Shared cook (SPEC 5.2)

  func testDecodeAndReEncodeShareCookToTableRequestExample() throws {
    let body = try decode(CommunityShareCookRequest.self, "shareCookToTable.request")
    XCTAssertEqual(body.operationId, "f3d4e1b6-9e5f-4c9f-ad43-7b8c9d0e1f2a")
    XCTAssertEqual(body.cook.recipeRef, RecipeRef(source: .user, id: "ur_7Kq2m", revision: 3))
    XCTAssertEqual(body.cook.dishName, "Butter bean curry")
    XCTAssertEqual(body.cook.servings, 2)
    XCTAssertEqual(
      body.cook.swaps, [CommunityCookSwap(fromName: "curry powder", toName: "cumin + paprika")])
    XCTAssertEqual(body.cook.rating, 5)
    XCTAssertEqual(body.cook.note, "Worked with cumin and paprika instead.")
    XCTAssertEqual(body.cook.day, "2026-10-14")
    // The server stamps the display name (views.ts `allowed` rejects authorDisplayName in
    // the share payload), so request examples decode with it absent.
    XCTAssertNil(body.cook.authorDisplayName)
    XCTAssertNil(body.cook.content)
    try assertReencodes(body)
    try assertSameJSON(
      JSONEncoder().encode(body), CommunityContractFixtures.load("shareCookToTable.request"))
  }

  func testDecodeShareCookToTableResponseExample() throws {
    let card = try decode(CommunityTableCard.self, "shareCookToTable.response")
    XCTAssertEqual(card.cardId, "crd_J8kLm2Nx0R")
    XCTAssertEqual(card.tableId, "tbl_F6hJk1Mw9Q")
    XCTAssertEqual(card.isMine, true)
    XCTAssertEqual(card.cook.dishName, "Butter bean curry")
    XCTAssertFalse(card.isDepartedMemberRedaction)
  }

  /// A departed member's card renders without the cook content or their name (SPEC 5.1);
  /// the backend collapses `dishName` to the mock's copy and drops the author.
  func testDepartedMemberCardRedactionPredicate() throws {
    var cook = CommunitySharedCook(
      recipeRef: RecipeRef(source: .user, id: "ur_7Kq2m", revision: 3),
      dishName: "Left the table", servings: 0, day: "2026-10-14")
    cook.authorDisplayName = nil
    let card = CommunityTableCard(
      cardId: "crd_departed", tableId: "tbl_F6hJk1Mw9Q", cook: cook, isMine: false,
      createdAt: "2026-10-14T09:00:00Z")
    XCTAssertTrue(card.isDepartedMemberRedaction)
  }

  // MARK: - Challenges (SPEC 4)

  func testDecodeListChallengesResponseExample() throws {
    let list = try decode(CommunityChallengeList.self, "listChallenges.response")
    XCTAssertEqual(list.challenges.count, 1)
    let challenge = list.challenges[0]
    XCTAssertEqual(challenge.challengeId, "chl_B4t8VvQ7Lk")
    XCTAssertEqual(challenge.type, .battle)
    XCTAssertEqual(challenge.name, "3 ingredients: eggs, tortillas, scallions")
    XCTAssertEqual(challenge.status, .voting)
    XCTAssertEqual(challenge.entryCount, 11)
    XCTAssertEqual(challenge.resolvedItems?.count, 3)
    XCTAssertEqual(challenge.resolvedItems?[0].fdcId, 11282)
    XCTAssertEqual(challenge.resolvedItems?[2].quantityText, "one bunch")
    XCTAssertEqual(challenge.myEntryId, "ent_K2mNp4Rs8T")
    XCTAssertNil(challenge.myVoteEntryId)
  }

  func testDecodeGetChallengeResponseExample() throws {
    let detail = try decode(CommunityChallengeDetail.self, "getChallenge.response")
    XCTAssertEqual(detail.challenge.challengeId, "chl_B4t8VvQ7Lk")
    XCTAssertEqual(detail.entries.count, 2)
    XCTAssertEqual(detail.entries[0].entryId, "ent_K2mNp4Rs8T")
    XCTAssertEqual(detail.entries[0].title, "Egg and scallion tortilla fold")
    XCTAssertEqual(detail.entries[0].authorDisplayName, "Sam")
    XCTAssertEqual(detail.entries[0].state, .visible)
    XCTAssertEqual(detail.entries[1].entryId, "ent_Y9dHj3Lw5P")
    XCTAssertEqual(detail.entries[1].authorDisplayName, "Dev")
    // No live tallies: voteCount is null while voting is open (SPEC 4.3).
    XCTAssertNil(detail.entries[0].voteCount)
    XCTAssertNil(detail.entries[1].voteCount)
  }

  func testDecodeAndReEncodeCreateEntryRequestExample() throws {
    let body = try decode(CommunityCreateEntryRequest.self, "createEntry.request")
    XCTAssertEqual(body.operationId, "e2c3d0a5-8d4e-4b8f-9c32-6a7b8c9d0e1f")
    XCTAssertEqual(body.recipeRef, RecipeRef(source: .user, id: "ur_7Kq2m", revision: 3))
    XCTAssertEqual(body.note, "Crisped the tortilla in the pan first.")
    try assertReencodes(body)
    try assertSameJSON(
      JSONEncoder().encode(body), CommunityContractFixtures.load("createEntry.request"))

    let entry = try decode(CommunityChallengeEntry.self, "createEntry.response")
    XCTAssertEqual(entry.entryId, "ent_K2mNp4Rs8T")
    XCTAssertEqual(entry.state, .visible)
    XCTAssertNil(entry.voteCount)
  }

  func testDecodeAndReEncodeCastVoteRequestExample() throws {
    let body = try decode(CommunityCastVoteRequest.self, "castVote.request")
    XCTAssertEqual(body.entryId, "ent_Y9dHj3Lw5P")
    try assertSameJSON(
      JSONEncoder().encode(body), CommunityContractFixtures.load("castVote.request"))
  }
}
