/// Future-facing boundary for live conversational agents.
/// This is intentionally minimal to avoid over-specifying provider payload shapes
/// before online integrations are implemented.
typealias AgentSessionID = String

protocol AgentConversationProviding: Sendable {
  func beginSession() async throws -> AgentSessionID
  func send(_ input: String, in sessionID: AgentSessionID) async throws -> String
  func endSession(_ sessionID: AgentSessionID) async
}
