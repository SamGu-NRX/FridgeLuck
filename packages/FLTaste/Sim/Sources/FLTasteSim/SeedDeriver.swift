import Foundation

/// Deterministic child-seed derivation for the simulator's random streams.
///
/// Every stochastic component (household generation, shopping, session
/// timing, choice, rating) draws from its own `SeededRNG` seeded with
/// `SeedDeriver.child(master, stream, index)`. Independent streams therefore
/// never share a state, and the same master seed reproduces the same run
/// byte for byte.
public enum SeedDeriver {

    /// SplitMix64 mixing, the same generator Part 1's `SeededRNG` builds on.
    private static func splitMix(_ state: UInt64) -> UInt64 {
        var z = state &+ 0x9E37_79B9_7F4A_7C15
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// FNV-1a over the stream name, so stream names mix independently of
    /// position in the string.
    private static func hash(_ string: String) -> UInt64 {
        var h: UInt64 = 0xCBD1_994C_04EE_8DB9
        for byte in string.utf8 {
            h ^= UInt64(byte)
            h = h &* 0x0000_0100_0000_01B3
        }
        return h
    }

    /// A child seed for `stream` number `index` under `master`. Distinct
    /// (stream, index) pairs give well-mixed, independent seeds.
    public static func child(_ master: UInt64, _ stream: String, _ index: Int) -> UInt64 {
        splitMix(master ^ splitMix(hash(stream) ^ UInt64(bitPattern: Int64(index))))
    }
}
