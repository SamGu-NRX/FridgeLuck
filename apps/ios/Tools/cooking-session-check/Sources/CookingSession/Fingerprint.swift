import Foundation

/// Change-detection fingerprints for a cooking flow.
///
/// Deliberately not cryptographic: these hashes answer exactly one question —
/// "did the recipe or its instruction text change since the checkpoint was
/// written?" They are never used for security, and they are never used to
/// re-apply old step indices to new text: that decision is a deliberate
/// reconciliation surfaced to the user (see `RecipeFingerprint.compare(to:)`).
public struct RecipeFingerprint: Codable, Equatable {
    public var recipeID: String
    /// Over recipe identity + title + ingredient lines (what is being cooked).
    public var recipeFingerprint: String
    /// Over the parsed instruction step texts (how it is cooked).
    public var instructionFingerprint: String
    public var stepCount: Int

    public init(
        recipeID: String,
        recipeFingerprint: String,
        instructionFingerprint: String,
        stepCount: Int
    ) {
        self.recipeID = recipeID
        self.recipeFingerprint = recipeFingerprint
        self.instructionFingerprint = instructionFingerprint
        self.stepCount = stepCount
    }

    /// Deterministic fingerprints derived from the parsed recipe the session
    /// was started with. Same inputs always produce the same fingerprints, so
    /// a relaunch compares apples to apples.
    public static func compute(
        recipeID: String,
        title: String,
        ingredientLines: [String],
        stepTexts: [String]
    ) -> RecipeFingerprint {
        let recipePayload = ([title] + ingredientLines).joined(separator: separator)
        let instructionPayload = stepTexts.joined(separator: separator)
        return RecipeFingerprint(
            recipeID: recipeID,
            recipeFingerprint: fnv1a64(recipePayload),
            instructionFingerprint: fnv1a64(instructionPayload),
            stepCount: stepTexts.count
        )
    }

    /// 64-bit FNV-1a over UTF-8 bytes, hex encoded. Change detection only,
    /// not a security primitive.
    public static func fnv1a64(_ string: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return String(hash, radix: 16)
    }

    private static let separator = "\u{1F}"
}

/// Verdict of comparing a checkpoint's fingerprint against the recipe the
/// user is about to cook now. Any non-`compatible` answer means the UI must
/// stop and let the user reconcile deliberately — stored step indices must
/// never be applied silently to different text.
public enum CheckpointCompatibility: Equatable {
    /// Same recipe, same instructions: stored indices mean the same steps.
    case compatible
    /// The recipe identity, title, or ingredient set changed.
    case recipeChanged
    /// The instruction text or step count changed.
    case instructionsChanged
}

extension RecipeFingerprint {
    /// Compare this (checkpointed) fingerprint against the recipe being
    /// cooked now.
    public func compare(to current: RecipeFingerprint) -> CheckpointCompatibility {
        if recipeID != current.recipeID || recipeFingerprint != current.recipeFingerprint {
            return .recipeChanged
        }
        if instructionFingerprint != current.instructionFingerprint || stepCount != current.stepCount {
            return .instructionsChanged
        }
        return .compatible
    }
}
