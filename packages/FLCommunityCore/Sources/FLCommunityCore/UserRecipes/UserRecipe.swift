import Foundation
import FLDomain

// MARK: - User recipes: household-authored, private by default
// SPEC 3.4/3.5: a recipe a household writes is theirs alone until they
// explicitly share it into a Table or publish it to Explore. Privacy is
// structural here: visibility starts at `.private`, changes only through a
// named transition that returns a new value, and publishing builds the wire
// payload through `RecipeSharePayload`'s export policy with a mandatory
// own-work rights declaration — the same redaction boundary and rights
// checks as sharing, so nothing about publishing is a second, weaker path.

/// Who can see a household-authored recipe. Raw values are the on-device
/// storage strings.
public enum UserRecipeVisibility: String, Codable, Sendable, CaseIterable {
    /// Only the household sees it. The default for every new user recipe.
    case `private`
    /// Shared into one named Table. Consented, revocable: the Table sees the
    /// recipe, Explore does not.
    case sharedToTable
    /// Published to Explore's community catalog.
    case published
}

/// A household-authored recipe and its current visibility state.
///
/// The value is immutable: every state change is an explicit call that
/// returns a new `UserRecipe`, so no code path can widen visibility as a
/// side effect. The revision is carried as-is — authorship and license
/// evidence recorded on it are never rewritten by a transition.
public struct UserRecipe: Hashable, Sendable {
    /// The authored revision. Its key must have `RecipeSource.Kind.user`.
    public let revision: RecipeRevision
    /// Who can see it. Starts `.private`.
    public let visibility: UserRecipeVisibility
    /// The Table the recipe is shared into. Non-nil only while visibility
    /// is `.sharedToTable`.
    public let tableID: String?
    /// When this visibility state was reached (device-local bookkeeping;
    /// never leaves the phone).
    public let updatedAt: Date

    /// Creates a user recipe. Defaults to `.private` with no Table — the
    /// default is the safe direction and is not configurable.
    public init(
        revision: RecipeRevision,
        visibility: UserRecipeVisibility = .private,
        tableID: String? = nil,
        updatedAt: Date
    ) throws {
        guard revision.key.source == .user else {
            throw FLDomainError.validation(
                target: "UserRecipe.revision",
                reason: "a user recipe carries RecipeKey(source: .user); got \(revision.key.source.rawValue)"
            )
        }
        switch visibility {
        case .sharedToTable:
            guard let tableID, !tableID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw FLDomainError.validation(
                    target: "UserRecipe.tableID",
                    reason: "a Table-shared recipe names its Table"
                )
            }
        case .private, .published:
            guard tableID == nil else {
                throw FLDomainError.validation(
                    target: "UserRecipe.tableID",
                    reason: "tableID is only meaningful while the recipe is shared with a Table"
                )
            }
        }
        self.revision = revision
        self.visibility = visibility
        self.tableID = tableID.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        self.updatedAt = updatedAt
    }

    // MARK: Explicit transitions

    /// Share the recipe into one named Table. Returns a new value; the
    /// original is untouched. The Table name is trimmed and must be non-empty.
    public func shared(toTable tableID: String, at date: Date) throws -> UserRecipe {
        try UserRecipe(revision: revision, visibility: .sharedToTable, tableID: tableID, updatedAt: date)
    }

    /// Return the recipe to private: the Table reference is cleared, the
    /// revision and its evidence are untouched.
    public func madePrivate(at date: Date) throws -> UserRecipe {
        try UserRecipe(revision: revision, visibility: .private, tableID: nil, updatedAt: date)
    }

    /// Publish to Explore. One call does the two coupled things publishing
    /// is: the recipe becomes `.published`, and the payload that leaves is
    /// built under the share export policy with a mandatory own-work rights
    /// declaration. If the payload cannot legally be built — forbidden text
    /// or offline rights, caching not explicitly permitted — the visibility
    /// does not change and the error names the reason.
    ///
    /// - Returns: the published recipe state and the validated payload.
    public func published(statement: String, at date: Date) throws -> (recipe: UserRecipe, payload: RecipeSharePayload) {
        let payload = try RecipeSharePayload(
            revision: revision,
            declaration: try RecipeRightsDeclaration(kind: .ownWork, statement: statement, declaredAt: date),
            sharedAt: date
        )
        let recipe = try UserRecipe(revision: revision, visibility: .published, tableID: nil, updatedAt: date)
        return (recipe, payload)
    }
}
