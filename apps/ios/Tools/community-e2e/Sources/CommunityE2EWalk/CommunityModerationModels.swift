import Foundation

// Moderation views for the operator surfaces (contracts/moderation-case.schema.json,
// SPEC 6.6). Cases are server-generated (`cse_` ids); the client reads the queue and
// records decisions — it never creates or edits cases directly.

/// One queued (or just-decided) moderation case as the queue returns it.
public struct CommunityModerationCase: Codable, Sendable, Equatable {
  public var caseId: String
  public var targetType: String
  public var targetId: String
  public var origin: String
  public var state: String
  public var createdAt: String
  public var declaration: RecipeRightsDeclaration?
  public var screening: [String]
  public var reports: [CommunityReportSummary]
  public var decision: CommunityModerationDecision?
}

/// One report inside a case: reason code and optional free-text detail.
public struct CommunityReportSummary: Codable, Sendable, Equatable {
  public var reason: String
  public var detail: String?
}

/// The recorded operator decision; present once the case is resolved.
public struct CommunityModerationDecision: Codable, Sendable, Equatable {
  public var action: String
  public var note: String?
  public var decidedAt: String
}

/// Body of `POST /moderation/cases/{caseId}/decision`.
public struct CommunityModerationDecisionRequest: Codable, Sendable {
  public var action: String
  public var note: String?

  public init(action: String, note: String?) {
    self.action = action
    self.note = note
  }
}

/// Envelope of `GET /moderation/queue`.
public struct CommunityModerationCaseList: Codable, Sendable {
  public var cases: [CommunityModerationCase]
}
