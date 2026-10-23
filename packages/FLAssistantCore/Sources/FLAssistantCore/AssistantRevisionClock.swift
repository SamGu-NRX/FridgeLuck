import Foundation

// MARK: - Snapshot revision clock
// FLDomain's snapshot contract: "revision increases monotonically with every
// app-state change the snapshot covers". Revision therefore tracks state
// versions, not snapshot builds — building the same state twice yields the
// same revision, so a proposal minted at revision N stays approvable until the
// state actually moves (an inflation-on-every-build rule would wrongly stale
// proposals on intervening context rebuilds). The host bumps the clock when
// its state changes; the builder reads it.

/// The monotonic source of snapshot revisions. An actor: bumps serialize even
/// under concurrent app-state changes, so revisions can never repeat or
/// regress.
public actor AssistantRevisionClock {
    private var revision: Int

    /// Starts at `revision`, at least 1 (the FLDomain snapshot floor).
    public init(revision: Int = 1) throws {
        guard revision >= 1 else {
            throw FLAssistantError.revisionBelowFloor(value: revision)
        }
        self.revision = revision
    }

    /// The current revision. Stable until the next `bump()`.
    public func current() -> Int {
        revision
    }

    /// Advance one step for a state change; returns the new revision (always
    /// strictly greater than the previous one).
    @discardableResult
    public func bump() -> Int {
        revision += 1
        return revision
    }
}
