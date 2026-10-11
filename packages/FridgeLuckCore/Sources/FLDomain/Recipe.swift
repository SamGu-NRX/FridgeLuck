import Foundation

// MARK: - Structured recipe revisions
// SPEC 3.5: ship structured or not at all — ingredient lines with quantity
// evidence, steps split at timer and action boundaries, equipment, safety
// checks. A step without a natural timer does not get a fake one.

/// A food-safety check attached to a step (SPEC 3.1): doneness for meat,
/// poultry, fish, eggs and leftovers is stated as a checkable test with a
/// thermometer temperature from a reviewed source, never by colour or time alone.
public struct SafetyCheck: Hashable, Sendable {
    /// The checkable test, e.g. "insert the thermometer into the thickest part
    /// of the thigh and read the temperature". Never empty.
    public let instruction: String
    /// Reviewed safe minimum internal temperature in Celsius, when the check is
    /// a thermometer test. Sourced from USDA FSIS safe minimum internal
    /// temperatures for meat, poultry, fish and eggs.
    public let minimumInternalCelsius: Double?
    /// The reviewed source, e.g. "USDA FSIS Safe Minimum Internal Temperature Chart".
    /// Never empty.
    public let source: String

    public init(instruction: String, minimumInternalCelsius: Double?, source: String) throws {
        let trimmed = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw FLDomainError.validation(target: "SafetyCheck.instruction", reason: "must not be empty")
        }
        if let minimumInternalCelsius {
            guard minimumInternalCelsius.isFinite, minimumInternalCelsius > -100, minimumInternalCelsius < 400 else {
                throw FLDomainError.validation(target: "SafetyCheck.minimumInternalCelsius", reason: "must be a plausible finite Celsius temperature (got \(minimumInternalCelsius))")
            }
        }
        let trimmedSource = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSource.isEmpty else {
            throw FLDomainError.validation(target: "SafetyCheck.source", reason: "must not be empty")
        }
        self.instruction = trimmed
        self.minimumInternalCelsius = minimumInternalCelsius
        self.source = trimmedSource
    }
}

extension SafetyCheck: Codable {
    private enum CodingKeys: String, CodingKey {
        case instruction, minimumInternalCelsius, source
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            instruction: try container.decode(String.self, forKey: .instruction),
            minimumInternalCelsius: try container.decodeIfPresent(Double.self, forKey: .minimumInternalCelsius),
            source: try container.decode(String.self, forKey: .source)
        )
    }
}

/// A temperature on a step. `purpose` separates an appliance setting (an oven
/// target) from a thermometer test of the food (an internal doneness check);
/// conflating them would let a timer pretend to be a doneness test (SPEC 3.1).
public struct CookingTemperature: Hashable, Sendable {
    public enum Purpose: String, Codable, Sendable {
        /// The appliance's set temperature.
        case ovenTarget
        /// A thermometer test of the food itself.
        case internalDoneness
    }

    /// Plausible finite Celsius value.
    public let celsius: Double
    public let purpose: Purpose

    public init(celsius: Double, purpose: Purpose) throws {
        guard celsius.isFinite, celsius > -100, celsius < 400 else {
            throw FLDomainError.validation(target: "CookingTemperature.celsius", reason: "must be a plausible finite Celsius temperature (got \(celsius))")
        }
        self.celsius = celsius
        self.purpose = purpose
    }
}

extension CookingTemperature: Codable {
    private enum CodingKeys: String, CodingKey { case celsius, purpose }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            celsius: try container.decode(Double.self, forKey: .celsius),
            purpose: try container.decode(Purpose.self, forKey: .purpose)
        )
    }
}

/// One structured cooking step. `durationSeconds` is present only when the
/// source gives a natural timer — a step without one never gets a fake one
/// (SPEC 3.5). Timers say when to check, and doneness comes from `safetyCheck`.
public struct Step: Hashable, Sendable {
    /// Stable step identity within a revision. Never empty; unique within a revision.
    public let stepID: String
    /// The action text. Never empty.
    public let action: String
    /// A natural timer in seconds, only when real. Strictly positive when present.
    public let durationSeconds: Int?
    public let temperature: CookingTemperature?
    /// Equipment this step needs, e.g. "oven", "12-inch skillet". Never empty strings.
    public let equipment: [String]
    /// A checkable doneness/safety test when the step involves meat, poultry,
    /// fish, eggs or leftovers.
    public let safetyCheck: SafetyCheck?

    public init(
        stepID: String,
        action: String,
        durationSeconds: Int? = nil,
        temperature: CookingTemperature? = nil,
        equipment: [String] = [],
        safetyCheck: SafetyCheck? = nil
    ) throws {
        let trimmedStepID = stepID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedStepID.isEmpty else {
            throw FLDomainError.validation(target: "Step.stepID", reason: "must not be empty")
        }
        let trimmedAction = action.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedAction.isEmpty else {
            throw FLDomainError.validation(target: "Step.action", reason: "must not be empty")
        }
        if let durationSeconds {
            guard durationSeconds > 0 else {
                throw FLDomainError.validation(target: "Step.durationSeconds", reason: "must be > 0 when present (got \(durationSeconds)); a step without a natural timer gets no timer")
            }
        }
        let trimmedEquipment = try equipment.map { item -> String in
            let trimmed = item.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                throw FLDomainError.validation(target: "Step.equipment", reason: "equipment names must not be empty")
            }
            return trimmed
        }
        self.stepID = trimmedStepID
        self.action = trimmedAction
        self.durationSeconds = durationSeconds
        self.temperature = temperature
        self.equipment = trimmedEquipment
        self.safetyCheck = safetyCheck
    }
}

extension Step: Codable {
    private enum CodingKeys: String, CodingKey {
        case stepID, action, durationSeconds, temperature, equipment, safetyCheck
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            stepID: try container.decode(String.self, forKey: .stepID),
            action: try container.decode(String.self, forKey: .action),
            durationSeconds: try container.decodeIfPresent(Int.self, forKey: .durationSeconds),
            temperature: try container.decodeIfPresent(CookingTemperature.self, forKey: .temperature),
            equipment: try container.decodeIfPresent([String].self, forKey: .equipment) ?? [],
            safetyCheck: try container.decodeIfPresent(SafetyCheck.self, forKey: .safetyCheck)
        )
    }
}

/// The servings a revision's quantities are written for.
public struct ServingBasis: Hashable, Sendable {
    /// Servings count. At least 1.
    public let servings: Int
    /// What one serving means, e.g. "one 25 cm galette", "one jar". Optional.
    public let basis: String?

    public init(servings: Int, basis: String? = nil) throws {
        guard servings >= 1 else {
            throw FLDomainError.validation(target: "ServingBasis.servings", reason: "must be >= 1 (got \(servings))")
        }
        self.servings = servings
        self.basis = basis
    }
}

extension ServingBasis: Codable {
    private enum CodingKeys: String, CodingKey { case servings, basis }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            servings: try container.decode(Int.self, forKey: .servings),
            basis: try container.decodeIfPresent(String.self, forKey: .basis)
        )
    }
}

// MARK: - Rights and license evidence
// SPEC 3.5: ship only recipes the app has the right to ship. Rights are recorded
// separately per use; unknown rights means quarantine.

/// A recorded right for one use of one recipe. `unknown` is explicit and means
/// quarantine, not permission.
public struct RecipeLicense: Hashable, Sendable {
    public enum Grant: String, Codable, Sendable {
        /// A verified right (licence, commission, or author declaration).
        case permitted
        /// A recorded prohibition.
        case forbidden
        /// Unknown. Means quarantine.
        case unknown
    }

    public let textRedistribution: Grant
    public let imageRedistribution: Grant
    public let modificationAllowed: Grant
    public let attributionRequired: Bool
    public let cachingAllowed: Grant
    public let offlineUseAllowed: Grant
    /// Where the right comes from: licence name, commissioning contract, or
    /// author declaration. Never empty — "a URL attribution is not permission",
    /// so the evidence names an actual right.
    public let evidence: String

    public init(
        textRedistribution: Grant,
        imageRedistribution: Grant,
        modificationAllowed: Grant,
        attributionRequired: Bool,
        cachingAllowed: Grant,
        offlineUseAllowed: Grant,
        evidence: String
    ) throws {
        let trimmed = evidence.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw FLDomainError.validation(target: "RecipeLicense.evidence", reason: "must not be empty; a right without evidence is quarantine")
        }
        self.textRedistribution = textRedistribution
        self.imageRedistribution = imageRedistribution
        self.modificationAllowed = modificationAllowed
        self.attributionRequired = attributionRequired
        self.cachingAllowed = cachingAllowed
        self.offlineUseAllowed = offlineUseAllowed
        self.evidence = trimmed
    }

    /// SPEC 3.5: unknown rights means quarantine. A revision may ship and cook
    /// offline only when every offline-relevant right is explicitly granted.
    public var isQuarantined: Bool {
        if textRedistribution == .unknown || offlineUseAllowed == .unknown || modificationAllowed == .unknown {
            return true
        }
        return textRedistribution == .forbidden || offlineUseAllowed == .forbidden
    }
}

extension RecipeLicense: Codable {
    private enum CodingKeys: String, CodingKey {
        case textRedistribution, imageRedistribution, modificationAllowed
        case attributionRequired, cachingAllowed, offlineUseAllowed, evidence
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            textRedistribution: try container.decode(Grant.self, forKey: .textRedistribution),
            imageRedistribution: try container.decode(Grant.self, forKey: .imageRedistribution),
            modificationAllowed: try container.decode(Grant.self, forKey: .modificationAllowed),
            attributionRequired: try container.decode(Bool.self, forKey: .attributionRequired),
            cachingAllowed: try container.decode(Grant.self, forKey: .cachingAllowed),
            offlineUseAllowed: try container.decode(Grant.self, forKey: .offlineUseAllowed),
            evidence: try container.decode(String.self, forKey: .evidence)
        )
    }
}

/// Source and license evidence attached to a revision.
public struct RecipeSourceEvidence: Hashable, Codable, Sendable {
    public let origin: RecipeSource
    /// Attribution string when the licence requires one.
    public let attribution: String?
    public let license: RecipeLicense

    public init(origin: RecipeSource, attribution: String?, license: RecipeLicense) {
        self.origin = origin
        self.attribution = attribution
        self.license = license
    }
}

/// One revision of one recipe: the unit the app reasons about, shares and
/// learns from. Ingredient lines are ordered; line identity (`IngredientLine.lineID`)
/// is separate from ingredient identity, so one ingredient can appear on two
/// lines (oil for frying and oil in the dressing) without collapsing them.
public struct RecipeRevision: Hashable, Sendable {
    public let key: RecipeKey
    /// Never empty.
    public let title: String
    public let servingBasis: ServingBasis
    /// Ordered ingredient lines. Repeated lines for the same ingredient are
    /// summed by feasibility (SPEC 3.2); optional garnish is marked separate.
    public let ingredientLines: [IngredientLine]
    /// Ordered steps. At least one; IDs unique within the revision.
    public let steps: [Step]
    public let source: RecipeSourceEvidence

    public init(
        key: RecipeKey,
        title: String,
        servingBasis: ServingBasis,
        ingredientLines: [IngredientLine],
        steps: [Step],
        source: RecipeSourceEvidence
    ) throws {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else {
            throw FLDomainError.validation(target: "RecipeRevision.title", reason: "must not be empty")
        }
        guard !steps.isEmpty else {
            throw FLDomainError.validation(target: "RecipeRevision.steps", reason: "a recipe revision has at least one step")
        }
        let lineIDs = ingredientLines.map(\.lineID)
        guard Set(lineIDs).count == lineIDs.count else {
            throw FLDomainError.validation(target: "RecipeRevision.ingredientLines", reason: "duplicate lineID; line identity must be unique within a revision")
        }
        let stepIDs = steps.map(\.stepID)
        guard Set(stepIDs).count == stepIDs.count else {
            throw FLDomainError.validation(target: "RecipeRevision.steps", reason: "duplicate stepID; step identity must be unique within a revision")
        }
        self.key = key
        self.title = trimmedTitle
        self.servingBasis = servingBasis
        self.ingredientLines = ingredientLines
        self.steps = steps
        self.source = source
    }

    /// Required (non-garnish) lines, in order. Feasibility is computed over
    /// this bill; optional garnish is separate (SPEC 3.2).
    public var requiredIngredientLines: [IngredientLine] {
        ingredientLines.filter { !$0.isOptionalGarnish }
    }
}

extension RecipeRevision: Codable {
    private enum CodingKeys: String, CodingKey {
        case key, title, servingBasis, ingredientLines, steps, source
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            key: try container.decode(RecipeKey.self, forKey: .key),
            title: try container.decode(String.self, forKey: .title),
            servingBasis: try container.decode(ServingBasis.self, forKey: .servingBasis),
            ingredientLines: try container.decode([IngredientLine].self, forKey: .ingredientLines),
            steps: try container.decode([Step].self, forKey: .steps),
            source: try container.decode(RecipeSourceEvidence.self, forKey: .source)
        )
    }
}

/// One ingredient line: line identity, ingredient identity, quantity evidence,
/// and preparation. Line identity is separate from ingredient identity so the
/// same ingredient can appear on two lines.
public struct IngredientLine: Hashable, Sendable {
    /// Stable line identity within a revision. Never empty.
    public let lineID: String
    public let ingredient: IngredientReference
    public let quantity: QuantityEvidence
    /// Preparation as stated ("finely chopped", "at room temperature"). Affects
    /// unit and preparation compatibility during allocation.
    public let preparation: String?
    /// True for optional garnish: tracked, shown, but never required for
    /// feasibility (SPEC 3.2: "optional garnish is separate").
    public let isOptionalGarnish: Bool
    public let note: String?

    public init(
        lineID: String,
        ingredient: IngredientReference,
        quantity: QuantityEvidence,
        preparation: String? = nil,
        isOptionalGarnish: Bool = false,
        note: String? = nil
    ) throws {
        let trimmed = lineID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw FLDomainError.validation(target: "IngredientLine.lineID", reason: "must not be empty")
        }
        self.lineID = trimmed
        self.ingredient = ingredient
        self.quantity = quantity
        self.preparation = preparation
        self.isOptionalGarnish = isOptionalGarnish
        self.note = note
    }
}

extension IngredientLine: Codable {
    private enum CodingKeys: String, CodingKey {
        case lineID, ingredient, quantity, preparation, isOptionalGarnish, note
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            lineID: try container.decode(String.self, forKey: .lineID),
            ingredient: try container.decode(IngredientReference.self, forKey: .ingredient),
            quantity: try container.decode(QuantityEvidence.self, forKey: .quantity),
            preparation: try container.decodeIfPresent(String.self, forKey: .preparation),
            isOptionalGarnish: try container.decodeIfPresent(Bool.self, forKey: .isOptionalGarnish) ?? false,
            note: try container.decodeIfPresent(String.self, forKey: .note)
        )
    }
}
