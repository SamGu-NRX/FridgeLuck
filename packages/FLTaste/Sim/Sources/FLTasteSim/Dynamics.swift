import Foundation
import FLTaste

/// Mid-history dynamics: slow taste drift and abrupt shifts.
///
/// Drift is a norm-preserving rotation of each eater's latent vector in an
/// eater-specific pseudo-random plane — taste direction slowly turns while
/// its strength stays put. Shifts are discrete events from `SimConfig.shifts`
/// (diet change, budget change, lost capability), applied at the start of
/// their week in the order listed.
public enum Dynamics {

    /// One recorded shift application, for the ground truth.
    public struct AppliedShift: Sendable {
        public let spec: ShiftSpec
        public let atMillis: Int64
    }

    /// Rotates `latent` by `angle` radians in the plane spanned by two
    /// deterministic pseudo-random orthonormal vectors for `eaterIndex`.
    /// Norm is preserved to floating-point precision; taste strength never
    /// grows or shrinks, it turns.
    public static func applyDrift(
        _ latent: inout [Double], angle: Double, eaterIndex: Int, masterSeed: UInt64
    ) {
        guard latent.count > 1, angle != 0 else { return }
        var rng = SeededRNG(seed: SeedDeriver.child(masterSeed, "drift-plane", eaterIndex))
        let a = normalized(residual(randomVector(&rng, latent.count), against: nil))
        let b = normalized(residual(randomVector(&rng, latent.count), against: a))

        let u = dot(latent, a)
        let w = dot(latent, b)
        let cosA = cos(angle), sinA = sin(angle)
        for i in 0..<latent.count {
            latent[i] +=
                (cosA - 1) * u * a[i] - sinA * u * b[i] + sinA * w * a[i] + (cosA - 1) * w * b[i]
        }
    }

    /// Applies every shift scheduled for `week`, in config order, and
    /// returns the applied ones (with the timestamp they took effect).
    /// Diet shifts mutate the eater's restrictions; the simulator emits the
    /// matching `profileEdit` event.
    public static func applyShifts(
        _ shifts: [ShiftSpec], week: Int, atMillis: Int64, world: inout World,
        household: inout Household
    ) -> [AppliedShift] {
        var applied: [AppliedShift] = []
        for spec in shifts where spec.week == week {
            switch spec {
            case .diet(let eaterIndex, let diet, _):
                guard household.eaters.indices.contains(eaterIndex) else { continue }
                let restriction = Restriction(
                    kind: .diet, target: diet.rawValue, source: "shift")
                var eater = household.eaters[eaterIndex]
                guard !eater.restrictions.contains(restriction) else { continue }
                eater.restrictions.append(restriction)
                household.eaters[eaterIndex] = eater
            case .budgetChange(let factor, _):
                world.applyBudgetFactor(factor)
            case .lostCapability(let needle, _):
                world.loseCapability(needle: needle)
            }
            applied.append(AppliedShift(spec: spec, atMillis: atMillis))
        }
        return applied
    }

    // MARK: - Plane construction (pure, deterministic)

    private static func randomVector(_ rng: inout SeededRNG, _ dimension: Int) -> [Double] {
        (0..<dimension).map { _ in rng.nextNormal() }
    }

    /// Component of `v` orthogonal to `against` (nil = return v).
    private static func residual(_ v: [Double], against: [Double]?) -> [Double] {
        guard let against, !against.isEmpty else { return v }
        let projection = dot(v, against)
        return zip(v, against).map { $0 - projection * $1 }
    }

    private static func dot(_ a: [Double], _ b: [Double]) -> Double {
        zip(a, b).reduce(0) { $0 + $1.0 * $1.1 }
    }

    private static func normalized(_ v: [Double]) -> [Double] {
        let norm = sqrt(dot(v, v))
        guard norm > 1e-12 else { return v }
        return v.map { $0 / norm }
    }
}
