import Foundation

// MARK: - Seeded RNG (SplitMix64)
//
// The eval corpus must be reproducible byte-for-byte on any host that runs it,
// so randomness never touches system entropy.

public struct SeededRandom: Sendable {
  public var state: UInt64

  public init(seed: UInt64) {
    self.state = seed
  }

  public mutating func nextUInt64() -> UInt64 {
    state &+= 0x9E3779B97F4A7C15
    var z = state
    z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
    z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
    return z ^ (z >> 31)
  }

  /// Uniform in [0, 1).
  public mutating func nextDouble() -> Double {
    Double(nextUInt64() >> 11) * (1.0 / Double(UInt64(1) << 53))
  }

  /// Uniform integer in [lower, upper] inclusive.
  public mutating func nextInt(_ lower: Int, _ upper: Int) -> Int {
    guard upper > lower else { return lower }
    let span = UInt64(upper - lower + 1)
    return lower + Int(nextUInt64() % span)
  }

  public mutating func chance(_ probability: Double) -> Bool {
    nextDouble() < probability
  }

  public mutating func pick<C: Collection>(_ collection: C) -> C.Element? {
    guard !collection.isEmpty else { return nil }
    let index = collection.index(collection.startIndex, offsetBy: nextInt(0, collection.count - 1))
    return collection[index]
  }
}
