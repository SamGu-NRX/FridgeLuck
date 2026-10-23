import Foundation
import FLDomain

// MARK: - Pantry identity

/// A household scope for pantry truth. Every ledger row, event and lot is
/// household-scoped, so a synced household pantry is a schema change away
/// (SPEC 3.2: one person's pantry on one phone in the first release; the
/// tables are multi-household ready from day one).
public struct FLHouseholdID: Hashable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init(_ rawValue: String) throws {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw FLDomainError.validation(target: "FLHouseholdID", reason: "must not be empty")
        }
        guard trimmed.count <= 128 else {
            throw FLDomainError.validation(target: "FLHouseholdID", reason: "must be at most 128 characters")
        }
        self.rawValue = trimmed
    }

    public var description: String { rawValue }
}

extension FLHouseholdID: Codable {
    private enum CodingKeys: String, CodingKey { case rawValue }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(try container.decode(String.self, forKey: .rawValue))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(rawValue, forKey: .rawValue)
    }
}

/// Stable stock-event identity. Nonempty, at most 128 characters. Event IDs
/// are immutable: a retried confirmation reuses the SAME event ID and command
/// ID and the ledger answers "already applied" instead of adding stock twice.
public struct StockEventID: Hashable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init(_ rawValue: String) throws {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw FLDomainError.validation(target: "StockEventID", reason: "must not be empty")
        }
        guard trimmed.count <= 128 else {
            throw FLDomainError.validation(target: "StockEventID", reason: "must be at most 128 characters")
        }
        self.rawValue = trimmed
    }

    public var description: String { rawValue }
}

extension StockEventID: Codable {
    private enum CodingKeys: String, CodingKey { case rawValue }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(try container.decode(String.self, forKey: .rawValue))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(rawValue, forKey: .rawValue)
    }
}

// MARK: - Event kinds and sources

/// What happened to stock. Raw values are part of the cross-language fixture
/// contract (SPEC 3.2; suite A property tests assert these semantics).
public enum FLStockEventKind: String, Codable, Sendable, CaseIterable {
    /// Stock is added: a receipt, a "New groceries" confirmation, or manual
    /// entry. Only purchase-shaped events add stock (scans observe).
    case purchase
    /// Stock is eaten, via a Cook record or a manual entry.
    case consumption
    /// Stock is thrown away.
    case spoilage
    /// A scan observation. Observing never adds stock: it reconciles what the
    /// scan saw and refreshes the item's last-confirmed evidence.
    case observation
    /// A correction that supersedes a prior event rather than erasing it.
    case correction
}

/// Where an event came from. Explicit on every event: recognition confidence
/// is not quantity confidence (SPEC 3.2), so the source of every quantity is
/// recorded next to the quantity itself.
public enum FLStockEventSource: String, Codable, Sendable, CaseIterable {
    /// A receipt or "New groceries" confirmation.
    case receipt
    /// The user typed or confirmed it by hand.
    case manual
    /// A shelf scan. A scan of one shelf refreshes only what it saw.
    case scan
    /// Derived from a finished Cook record.
    case cook
    /// Stock added from a finished cook's leftovers (leftovers are lots).
    case leftover
}

/// The correction reference: an event that supersedes a prior event always
/// names it and says how (the PreferenceEvent pattern, applied to stock).
/// Corrections target the event they revise — never another correction — so
/// the effective history is one resolution step, always.
public struct FLStockCorrection: Hashable, Sendable {
    public enum Mode: String, Codable, Sendable {
        /// The prior event's quantity was wrong; this event carries the truth.
        case corrects
        /// The prior event should never have existed.
        case retracts
    }

    public let priorEventID: StockEventID
    public let mode: Mode

    public init(priorEventID: StockEventID, mode: Mode) {
        self.priorEventID = priorEventID
        self.mode = mode
    }
}

extension FLStockCorrection: Codable {
    private enum CodingKeys: String, CodingKey { case priorEventID, mode }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            priorEventID: try StockEventID(try container.decode(String.self, forKey: .priorEventID)),
            mode: try container.decode(Mode.self, forKey: .mode)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(priorEventID.rawValue, forKey: .priorEventID)
        try container.encode(mode, forKey: .mode)
    }
}

// MARK: - The stock event

/// One pantry event: the append-only unit of pantry truth.
///
/// Validation rules enforced here (each has a test):
/// - Every event names exactly one ingredient and carries quantity evidence.
///   Unknown is a first-class value: a receipt without a weight, or a
///   recognition the app cannot count, records `unknown` and never a number.
/// - Kind/source compatibility: `observation` comes from a scan (scans
///   observe, purchases add); `purchase` from a receipt, manual entry, or a
///   cook's leftovers; `consumption` from a cook record or manual entry;
///   `spoilage` is manual.
/// - `supersedes` is required on corrections, forbidden elsewhere. A
///   `.retracts` correction carries no quantity (`unknown`) — there is
///   nothing to quantity about an event that never existed.
/// - `lotID` (a targeted draw-down) is allowed only on consumption/spoilage.
/// - `cookID` is required exactly when the source is a cook or leftover.
public struct FLStockEvent: Hashable, Sendable {
    public let id: StockEventID
    /// The client command this event belongs to. Retries of one confirmation
    /// reuse the command ID; the ledger applies it exactly once.
    public let commandID: String
    public let householdID: FLHouseholdID
    public let kind: FLStockEventKind
    public let ingredient: IngredientReference
    public let quantity: QuantityEvidence
    /// A specific lot to draw down (consumption/spoilage). When absent the
    /// ledger draws down oldest first.
    public let lotID: String?
    /// The cook this event belongs to, when the source is a cook or leftover.
    public let cookID: String?
    /// The preparation form of the stock ("finely chopped", "cooked"), when
    /// recorded. Raw stock has none and can be prepared freely.
    public let preparation: String?
    public let source: FLStockEventSource
    /// When the event happened (not when it was ingested).
    public let timestamp: Date
    /// Set exactly on corrections.
    public let supersedes: FLStockCorrection?

    public init(
        id: String,
        commandID: String,
        householdID: FLHouseholdID,
        kind: FLStockEventKind,
        ingredient: IngredientReference,
        quantity: QuantityEvidence,
        lotID: String? = nil,
        cookID: String? = nil,
        preparation: String? = nil,
        source: FLStockEventSource,
        timestamp: Date,
        supersedes: FLStockCorrection? = nil
    ) throws {
        let eventID = try StockEventID(id)
        let trimmedCommand = commandID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedCommand.isEmpty else {
            throw FLDomainError.validation(target: "FLStockEvent.commandID", reason: "must not be empty")
        }
        guard trimmedCommand.count <= 128 else {
            throw FLDomainError.validation(target: "FLStockEvent.commandID", reason: "must be at most 128 characters")
        }
        let trimmedLotID = try FLStockEvent.optionalLabel(lotID, target: "FLStockEvent.lotID")
        let trimmedCookID = try FLStockEvent.optionalLabel(cookID, target: "FLStockEvent.cookID")
        let trimmedPreparation = try FLStockEvent.optionalLabel(preparation, target: "FLStockEvent.preparation")

        // Kind/source compatibility: the source must be able to cause the kind.
        switch kind {
        case .purchase:
            switch source {
            case .receipt, .manual, .leftover:
                if source == .leftover {
                    guard trimmedCookID != nil else {
                        throw FLDomainError.validation(target: "FLStockEvent.cookID", reason: "leftover purchases must name the cook they came from")
                    }
                } else {
                    guard trimmedCookID == nil else {
                        throw FLDomainError.validation(target: "FLStockEvent.cookID", reason: "only leftover purchases name a cook")
                    }
                }
            case .scan, .cook:
                throw FLDomainError.validation(target: "FLStockEvent.source", reason: "a purchase cannot come from a scan or a cook record")
            }
            guard trimmedLotID == nil else {
                throw FLDomainError.validation(target: "FLStockEvent.lotID", reason: "a purchase mints its own lot; it cannot target one")
            }
        case .consumption:
            switch source {
            case .cook:
                guard trimmedCookID != nil else {
                    throw FLDomainError.validation(target: "FLStockEvent.cookID", reason: "cook-sourced consumption must name the cook")
                }
            case .manual:
                guard trimmedCookID == nil else {
                    throw FLDomainError.validation(target: "FLStockEvent.cookID", reason: "manual consumption does not name a cook")
                }
            case .receipt, .scan, .leftover:
                throw FLDomainError.validation(target: "FLStockEvent.source", reason: "consumption comes from a cook record or a manual entry")
            }
        case .spoilage:
            guard source == .manual else {
                throw FLDomainError.validation(target: "FLStockEvent.source", reason: "spoilage is recorded by hand")
            }
            guard trimmedCookID == nil else {
                throw FLDomainError.validation(target: "FLStockEvent.cookID", reason: "spoilage does not name a cook")
            }
        case .observation:
            guard source == .scan else {
                throw FLDomainError.validation(target: "FLStockEvent.source", reason: "observations come from scans; purchases add stock")
            }
            guard trimmedCookID == nil else {
                throw FLDomainError.validation(target: "FLStockEvent.cookID", reason: "observations do not name a cook")
            }
            guard trimmedLotID == nil else {
                throw FLDomainError.validation(target: "FLStockEvent.lotID", reason: "an observation reconciles the item, not one lot")
            }
        case .correction:
            guard let correction = supersedes else {
                throw FLDomainError.validation(target: "FLStockEvent.supersedes", reason: "a correction must name the event it revises")
            }
            guard source == .manual else {
                throw FLDomainError.validation(target: "FLStockEvent.source", reason: "corrections are manual")
            }
            guard trimmedCookID == nil else {
                throw FLDomainError.validation(target: "FLStockEvent.cookID", reason: "corrections do not name a cook")
            }
            guard trimmedLotID == nil else {
                throw FLDomainError.validation(target: "FLStockEvent.lotID", reason: "corrections revise the revised event, not a lot target")
            }
            if correction.mode == .retracts {
                guard quantity.isUnknown else {
                    throw FLDomainError.validation(target: "FLStockEvent.quantity", reason: "a retraction carries no quantity; there is nothing to measure about an event that never existed")
                }
            }
        }

        if let supersedes, kind != .correction {
            throw FLDomainError.validation(target: "FLStockEvent.supersedes", reason: "only corrections supersede another event")
        }

        self.id = eventID
        self.commandID = trimmedCommand
        self.householdID = householdID
        self.kind = kind
        self.ingredient = ingredient
        self.quantity = quantity
        self.lotID = trimmedLotID
        self.cookID = trimmedCookID
        self.preparation = trimmedPreparation
        self.source = source
        self.timestamp = timestamp
        self.supersedes = supersedes
    }

    private static func optionalLabel(_ raw: String?, target: String) throws -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw FLDomainError.validation(target: target, reason: "must not be empty when present")
        }
        guard trimmed.count <= 128 else {
            throw FLDomainError.validation(target: target, reason: "must be at most 128 characters")
        }
        return trimmed
    }
}

extension FLStockEvent: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, commandID, householdID, kind, ingredient, quantity
        case lotID, cookID, preparation, source, timestamp, supersedes
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: try container.decode(String.self, forKey: .id),
            commandID: try container.decode(String.self, forKey: .commandID),
            householdID: try container.decode(FLHouseholdID.self, forKey: .householdID),
            kind: try container.decode(FLStockEventKind.self, forKey: .kind),
            ingredient: try container.decode(IngredientReference.self, forKey: .ingredient),
            quantity: try container.decode(QuantityEvidence.self, forKey: .quantity),
            lotID: try container.decodeIfPresent(String.self, forKey: .lotID),
            cookID: try container.decodeIfPresent(String.self, forKey: .cookID),
            preparation: try container.decodeIfPresent(String.self, forKey: .preparation),
            source: try container.decode(FLStockEventSource.self, forKey: .source),
            timestamp: try FLTimestamp.decode(
                try container.decode(String.self, forKey: .timestamp),
                target: "FLStockEvent.timestamp"
            ),
            supersedes: try container.decodeIfPresent(FLStockCorrection.self, forKey: .supersedes)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id.rawValue, forKey: .id)
        try container.encode(commandID, forKey: .commandID)
        try container.encode(householdID, forKey: .householdID)
        try container.encode(kind, forKey: .kind)
        try container.encode(ingredient, forKey: .ingredient)
        try container.encode(quantity, forKey: .quantity)
        try container.encodeIfPresent(lotID, forKey: .lotID)
        try container.encodeIfPresent(cookID, forKey: .cookID)
        try container.encodeIfPresent(preparation, forKey: .preparation)
        try container.encode(source, forKey: .source)
        try container.encode(FLTimestamp.encode(timestamp), forKey: .timestamp)
        try container.encodeIfPresent(supersedes, forKey: .supersedes)
    }
}
