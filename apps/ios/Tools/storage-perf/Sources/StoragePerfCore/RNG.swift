import Foundation

/// Deterministic SplitMix64 generator. Every seeded database byte-for-byte
/// reproduces from (seed, profile, scale): one stream per database, draws in a
/// fixed code order.
struct SplitMix64: RandomNumberGenerator {
  var state: UInt64

  init(seed: UInt64) {
    state = seed
  }

  mutating func next() -> UInt64 {
    state &+= 0x9E37_79B9_7F4A_7C15
    var z = state
    z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
    z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
    return z ^ (z >> 31)
  }

  /// Uniform integer in `0..<bound` (bound > 0), rejection-sampled.
  mutating func uniform(_ bound: UInt64) -> UInt64 {
    precondition(bound > 0)
    let limit = UInt64.max - UInt64.max % bound
    var draw = next()
    while draw >= limit {
      draw = next()
    }
    return draw % bound
  }

  mutating func int(_ bound: Int) -> Int {
    Int(uniform(UInt64(bound)))
  }

  /// Uniform double in [0, 1).
  mutating func unit() -> Double {
    Double(next() >> 11) / Double(1 << 53)
  }
}

/// Stable string hash (FNV-1a 64) for deriving per-run stream seeds.
func fnv1a(_ string: String) -> UInt64 {
  var hash: UInt64 = 0xcbf2_9ce4_8422_2325
  for byte in string.utf8 {
    hash ^= UInt64(byte)
    hash = hash &* 0x0000_0100_0000_01B3
  }
  return hash
}
