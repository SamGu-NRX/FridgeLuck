import Foundation

/// Every random draw in FLTaste flows through this protocol, so identical
/// seeds and identical event streams produce identical state and rankings.
public protocol RandomSource: Sendable {
    mutating func nextUniform() -> Double
    mutating func nextNormal() -> Double
}

/// SplitMix64 counter-based generator with a Box-Muller normal transform.
///
/// SplitMix64 is fully deterministic, has no hidden platform state, and its
/// 64-bit mixing makes low seeds usable directly. The normal transform caches
/// the spare variate from each Box-Muller pair so no draw is discarded and
/// the sequence depends only on the seed.
public struct SeededRNG: RandomSource {
    private var state: UInt64
    private var spareNormal: Double?

    public init(seed: UInt64) {
        self.state = seed
        self.spareNormal = nil
    }

    public mutating func nextUniform() -> Double {
        // 53 bits of mantissa: uniform on [0, 1) with double granularity.
        let bits = next64() >> 11
        return Double(bits) * (1.0 / 9_007_199_254_740_992.0)
    }

    public mutating func nextNormal() -> Double {
        if let spare = spareNormal {
            spareNormal = nil
            return spare
        }
        var u1 = nextUniform()
        // log(0) is undefined; u1 == 0 happens with probability 2^-53 and is
        // remapped rather than crashing a legitimate run.
        if u1 < Double.leastNonzeroMagnitude {
            u1 = Double.leastNonzeroMagnitude
        }
        let u2 = nextUniform()
        let r = (-2.0 * Foundation.log(u1)).squareRoot()
        let theta = 2.0 * Double.pi * u2
        spareNormal = r * Foundation.sin(theta)
        return r * Foundation.cos(theta)
    }

    private mutating func next64() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
