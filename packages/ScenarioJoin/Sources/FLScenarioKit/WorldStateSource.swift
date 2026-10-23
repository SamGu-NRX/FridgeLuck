import Foundation
import FLDomain
import FLAssistantCore

// The join's AssistantStateSource: an immutable snapshot of what the phone
// knows at proposal time. Scenarios build it from the same pantry truth the
// fold produced (no parallel stock state), so the assistant's context
// builder consumes exactly what the ledger reports.

public struct WorldStateSource: AssistantStateSource {
    public let lines: [AssistantPantryLine]
    public let recipe: RecipeKey?
    public let step: Int?

    public init(lines: [AssistantPantryLine], recipe: RecipeKey? = nil, step: Int? = nil) {
        self.lines = lines
        self.recipe = recipe
        self.step = step
    }

    public func pantryLines() throws -> [AssistantPantryLine] {
        lines
    }

    public func recipeContext() throws -> RecipeKey? {
        recipe
    }

    public func currentStepIndex() throws -> Int? {
        step
    }
}
