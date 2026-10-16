import Foundation
#if canImport(FoundationNetworking)
  import FoundationNetworking  // URLSession/URLRequest on Linux
#endif

// The community end-to-end walk: two users (and an operator) walk Explore publishing,
// Tables, moderation, and challenges through the real client stack — SessionViewModel /
// CommunitySessionService / CommunityAPIClient / the nonce binding — over localhost HTTP
// against backend/community/scripts/e2e-server.ts (production wiring, in-memory store).
// The test seams live only in the server: /mint plays Apple, /test/clock/advance moves the
// clock, /test/seed/challenge seeds a document (SPEC 4.2). Run: run.sh.

// MARK: - Boot

var stepCount = 0
func step(_ name: String, _ detail: String = "") {
  stepCount += 1
  print("step \(String(format: "%02d", stepCount)): \(name)\(detail.isEmpty ? "" : " — \(detail)")")
}

func fail(_ message: String) -> Never {
  print("WALK FAILED after step \(stepCount): \(message)")
  exit(1)
}

func require(_ condition: Bool, _ message: String) {
  if !condition { fail(message) }
}

let env = ProcessInfo.processInfo.environment
guard let baseArg = env["COMMUNITY_E2E_BASE"], let appleArg = env["COMMUNITY_E2E_APPLE"],
  let base = URL(string: baseArg), let apple = URL(string: appleArg)
else {
  fail("COMMUNITY_E2E_BASE and COMMUNITY_E2E_APPLE must be set (run.sh wires them)")
}

/// The walk binary's proof of which sources it exercises: refresh.sh runs immediately
/// before the build and embeds the combined digest, so a stale binary is detectable.
let sourceProof = pinnedSourceDigest

/// Plays Apple for the e2e test identities: mints an RS256 identity token embedding the
/// nonce claim the app bound into the (simulated) ASAuthorization request — SHA-256 of the
/// raw nonce, exactly what Apple echoes back (SPEC 3.3).
func mintIdentityToken(sub: String, rawNonce: String) async throws -> String {
  var request = URLRequest(url: apple.appendingPathComponent("mint"))
  request.httpMethod = "POST"
  request.setValue("application/json", forHTTPHeaderField: "Content-Type")
  request.httpBody = try JSONEncoder().encode(
    ["sub": sub, "nonce": CommunityNonce.authorizationNonce(forRaw: rawNonce)])
  let (data, response) = try await URLSession.shared.data(for: request)
  guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
    fail("mint failed for \(sub): \(response)")
  }
  return try JSONDecoder().decode([String: String].self, from: data)["identityToken"]!
}

/// The test seam only: moves the server clock (SPEC 4.3's 24 h account-age gate and the
/// challenge windows are unreachable without it).
func advanceClock(hours: Double) async throws {
  var request = URLRequest(url: apple.appendingPathComponent("test/clock/advance"))
  request.httpMethod = "POST"
  request.setValue("application/json", forHTTPHeaderField: "Content-Type")
  request.httpBody = try JSONEncoder().encode(["hours": hours])
  let (_, response) = try await URLSession.shared.data(for: request)
  guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
    fail("clock advance failed: \(response)")
  }
}

func seedChallenge(name: String, entryClosesInMinutes: Int? = nil) async throws -> String {
  var request = URLRequest(url: apple.appendingPathComponent("test/seed/challenge"))
  request.httpMethod = "POST"
  request.setValue("application/json", forHTTPHeaderField: "Content-Type")
  var payload: [String: Any] = ["name": name]
  if let entryClosesInMinutes { payload["entryClosesInMinutes"] = entryClosesInMinutes }
  request.httpBody = try JSONSerialization.data(withJSONObject: payload)
  let (data, response) = try await URLSession.shared.data(for: request)
  guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
    fail("challenge seed failed: \(response)")
  }
  return try JSONDecoder().decode([String: String].self, from: data)["challengeId"]!
}

/// Signs a user in through the real stack: binds a raw nonce, plays Apple via /mint, and
/// exchanges the minted identity token through CommunitySessionService (SPEC 3.3, 6.1).
func signIn(sub: String, birthYear: Int? = nil) async throws -> CommunitySessionService {
  // /mint plays Apple with the same binding the app performs: the raw nonce crosses the
  // sign-in body, the identity token carries its SHA-256 as the nonce claim (SPEC 3.3).
  let rawNonce = CommunityNonce.generate()
  let identityToken = try await mintIdentityToken(sub: sub, rawNonce: rawNonce)
  let service = CommunitySessionService(baseURL: base)
  let account = try await service.signIn(
    identityToken: identityToken, rawNonce: rawNonce, birthYear: birthYear)
  require(account.accountId.hasPrefix("acc_"), "\(sub): account id shape")
  return service
}

// MARK: - The walk

setvbuf(stdout, nil, _IOLBF, 0)  // keep step lines through a crash
step("pinned sources verified", "digest \(sourceProof.prefix(12))…")

// --- Alice: 18+ attested sign-in through the bound nonce (SPEC 3.3, 6.2).
let aliceService: CommunitySessionService
do {
  aliceService = try await signIn(sub: "e2e-alice", birthYear: 1990)
} catch let error as CommunityAPIError {
  if case let .http(_, body) = error {
    fail("alice sign-in rejected: \(String(decoding: body, as: UTF8.self))")
  }
  throw error
}
let alice = aliceService.account
require(alice?.isAdult == true, "alice carries the 18+ attestation")
step("alice signed in", "nonce bound, token exchanged, 18+ attested")

// --- Alice publishes a private recipe to Explore (SPEC 2.3).
let content = RecipeRevisionContent(
  title: "Sam's chili crisp noodles",
  description: "A 15-minute pantry dinner.",
  servings: 2,
  timeMinutes: 15,
  ingredientLines: [
    IngredientLine(name: "wheat noodles", quantity: 200, unit: .gram),
    IngredientLine(name: "chili crisp", quantity: 2, unit: .tablespoon),
  ],
  steps: [
    RecipeStep(text: "Boil the noodles."),
    RecipeStep(text: "Toss with chili crisp.", timerMinutes: 3),
  ])
let declaration = RecipeRightsDeclaration(ownRights: true, noPersonalData: true)
let recipeId = "rec_\(UUID().uuidString.lowercased().prefix(12))"
let preview = SharePreviewBuilder.preview(
  communityRecipeId: recipeId,
  revision: 1,
  content: content,
  declaration: declaration,
  operationId: UUID().uuidString.lowercased(),
  authorDisplayName: "Alice")
let publication = try await aliceService.client.createPublication(preview.payload)
require(publication.content.title == content.title, "publication round-trips")
step("alice published", "\(publication.publicationId)")

// --- Bob signs in and sees the publication in the Explore feed (SPEC 5.2).
let bobService = try await signIn(sub: "e2e-bob", birthYear: 2000)
let bob = bobService.account
step("bob signed in")
let feed = try await bobService.client.exploreFeed()
require(feed.contains { $0.recipeRef.id == recipeId && $0.title == content.title },
  "bob's Explore feed shows alice's publication; got \(feed.map(\.title))")
step("explore feed carries the publication", "\(feed.count) card(s)")

// --- A shared cook on a Table (SPEC 7): alice opens a table, bob joins by code.
let table = try await aliceService.client.createTable(.init(name: "Weeknight dinners"))
let invite = try await aliceService.client.createInvite(tableId: table.tableId)
require(invite.joinCode != nil, "invite carries a join code")
let joined = try await bobService.client.joinTable(code: invite.joinCode!)
require(joined.tableId == table.tableId, "bob joined the table by code")
let card = try await aliceService.client.shareCookToTable(
  tableId: table.tableId,
  .init(
    operationId: UUID().uuidString.lowercased(),
    cook: CommunitySharedCook(
      recipeRef: RecipeRef(source: .user, id: recipeId, revision: 1),
      dishName: content.title,
      servings: 2,
      rating: 5,
      day: "2026-10-15")))
require(card.cook.dishName == content.title, "card round-trips")
step("table card shared", "\(table.tableId) card \(card.cardId)")

// --- Bob reports the card; a queued case hides it from the feed (SPEC 8.3, 6.4).
try await bobService.client.createReport(
  .init(
    targetType: .tableCard, targetId: card.cardId, reason: .other,
    detail: "Walk exercise: queued report"))
let cardsAfterReport = try await aliceService.client.tableCards(tableId: table.tableId)
require(!cardsAfterReport.contains { $0.cardId == card.cardId },
  "a queued report hides the card; got \(cardsAfterReport.count) card(s)")
step("queued report hides the card")

// --- The operator signs in through the same identity route (SPEC 6.6) and hides the card.
let operatorService = try await signIn(sub: "e2e-operator")
let queue = try await operatorService.client.moderationQueue()
guard let moderationCase = queue.first(where: { $0.targetId == card.cardId }) else {
  fail("operator queue is missing the card case; got \(queue.count) case(s)")
}
require(moderationCase.state == "queued", "case is queued; got \(moderationCase.state)")
require(!moderationCase.reports.isEmpty, "the case carries bob's report")
let decided = try await operatorService.client.decideModerationCase(
  moderationCase.caseId, action: "hide", note: "e2e walk")
require(decided.state != "queued", "decision recorded; got \(decided.state)")
step("operator decided", "case \(moderationCase.caseId) → hide")

// --- Challenges (SPEC 4): seeded document, alice enters, bob hits the account-age gate.
// The seeded entry window closes in 30 minutes so voting opens while bob is still
// inside his 24 h account-age gate; alice's entry lands while entries are open.
let challengeId = try await seedChallenge(name: "E2E chili week", entryClosesInMinutes: 30)
let detail = try await aliceService.client.challenge(id: challengeId)
require(detail.challenge.challengeId == challengeId, "seeded challenge loads")
let entry = try await aliceService.client.createEntry(
  challengeId: challengeId,
  .init(
    operationId: UUID().uuidString.lowercased(),
    recipeRef: RecipeRef(source: .user, id: recipeId, revision: 1),
    note: "Walk entry"))
require(entry.entryId.hasPrefix("ent_"), "entry id shape")
step("alice entered the challenge", "\(entry.entryId)")

// Advance past the entry close so the voting window opens (§4.2); bob is 30
// minutes old — well inside the 24 h account-age gate.
try await advanceClock(hours: 0.5)

do {
  try await bobService.client.castVote(challengeId: challengeId, .init(entryId: entry.entryId))
  fail("bob's fresh account voted before the 24 h gate")
} catch {
  if let apiError = error as? CommunityAPIError, apiError.statusCode == 403 {
    // The server states the rule; the client view-model maps it to the
    // "Your vote counts tomorrow." copy moment (SPEC 4.3, §9.5).
    require(apiError.serverError?.reason == "account_too_new",
      "gate reason; got \(apiError.serverError?.reason ?? "<none>")")
    require(CommunityChallengeRules.voteCountsTomorrow(account: bob, now: Date()),
      "the view-model rule maps bob to tomorrow")
    step("bob's vote gated", "server reason account_too_new; copy moment holds")
  } else {
    if case let .http(_, body) = error as? CommunityAPIError {
      print("unexpected gated-vote response: \(String(decoding: body, as: UTF8.self))")
    }
    throw error
  }
}

try await advanceClock(hours: 25)
try await bobService.client.castVote(challengeId: challengeId, .init(entryId: entry.entryId))
// No live tallies while voting is open (SPEC 4.3) — the viewer's own vote rides
// `myVoteEntryId` in the challenge view instead.
let voted = try await bobService.client.challenge(id: challengeId)
require(voted.challenge.myVoteEntryId == entry.entryId,
  "bob's vote recorded; got \(voted.challenge.myVoteEntryId ?? "<none>")")
step("bob voted after aging", "vote recorded on \(entry.entryId)")

// Tally: voteCount is null until voting closes (no live tallies, SPEC 4.3) — advance
// past votingClosesAt and read the closed tally.
try await advanceClock(hours: 71)
let tallied = try await bobService.client.challenge(id: challengeId)
require(tallied.challenge.status == .closed, "challenge closed; got \(tallied.challenge.status)")
require(
  tallied.entries.first { $0.entryId == entry.entryId }?.voteCount.map { $0 >= 1 } == true,
  "the closed tally counts bob's vote; got \(tallied.entries.first { $0.entryId == entry.entryId }?.voteCount ?? nil)")
step("closed tally counts the vote", "\(entry.entryId)")

// --- Relaunch: restore from stored tokens (SPEC 9.2).
let restored = try await aliceService.restore()
require(restored?.accountId == alice?.accountId, "restore round-trips the account")
step("alice's session restored")

print("WALK PASS — \(stepCount) steps: sign-in (nonce-bound, 18+), publish, Explore, Tables, report→queue→decision, challenge entry, 24 h vote gate, closed tally, restore")
