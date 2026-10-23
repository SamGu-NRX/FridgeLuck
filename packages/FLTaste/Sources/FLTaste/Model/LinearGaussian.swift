import Foundation

/// A Bayesian linear-Gaussian posterior over feature weights.
///
/// Conjugate update with known observation noise: the prior is
/// `w ~ N(0, priorVariance I)` and each weighted observation
/// `(x, r)` contributes `weight * x x^T` to the precision and
/// `weight * r * x` to the moment vector. The posterior mean solves
/// `A mu = b`; Thompson samples are `mu + temperature * L^{-T} z` with
/// `L L^T = A` and `z ~ N(0, I)`, which has covariance
/// `temperature^2 * A^{-1}`.
///
/// All operations are dense and deterministic: the same accumulators and
/// the same standard-normal draws always produce the same vectors, on any
/// host, because the arithmetic order is fixed (see `Cholesky` below).
public struct LinearGaussianPosterior: Sendable, Equatable {
    /// Precision matrix, row-major, dimension x dimension.
    public var precision: [Double]
    /// Moment vector `b = sum weight * r * x`.
    public var moment: [Double]
    /// Per-feature effective evidence: the summed observation weight of
    /// every update that touched the feature.
    public var evidence: [Double]
    /// Total effective evidence (sum of observation weights).
    public var totalEvidence: Double

    public let dimension: Int

    public init(dimension: Int, priorVariance: Double) {
        precondition(dimension >= 1, "posterior needs at least the intercept")
        precondition(priorVariance > 0, "prior variance must be positive")
        self.dimension = dimension
        self.precision = Array(repeating: 0, count: dimension * dimension)
        for i in 0..<dimension {
            precision[i * dimension + i] = 1.0 / priorVariance
        }
        self.moment = Array(repeating: 0, count: dimension)
        self.evidence = Array(repeating: 0, count: dimension)
        self.totalEvidence = 0
    }

    /// Adds one weighted observation. `components` must be sorted by index
    /// and duplicate-free — `SparseVector` guarantees both.
    public mutating func observe(
        _ x: SparseVector, reward: Double, weight: Double, noiseVariance: Double
    ) {
        precondition(noiseVariance > 0, "observation noise must be positive")
        let w = weight / noiseVariance
        guard w != 0 else { return }
        let support = x.components
        for a in support {
            let row = a.index * dimension
            for b in support where b.index >= a.index {
                precision[row + b.index] += w * a.value * b.value
                if b.index != a.index {
                    precision[b.index * dimension + a.index] += w * a.value * b.value
                }
            }
            moment[a.index] += w * reward * a.value
            evidence[a.index] += weight
        }
        totalEvidence += weight
    }

    /// Posterior mean: solves `A mu = b` by Cholesky.
    public func mean() -> [Double] {
        let factor = Cholesky(matrix: precision, dimension: dimension)
        return factor.solveSymmetric(b: moment)
    }

    /// One Thompson draw: `mu + temperature * L^{-T} z` with `L L^T = A`.
    ///
    /// - Parameters:
    ///   - standardNormals: one N(0,1) draw per dimension, in feature-index
    ///     order (the caller's seeded RNG produces them deterministically).
    ///   - temperature: exploration scale; 1 samples the true posterior.
    public func thompsonDraw(standardNormals: [Double], temperature: Double) -> [Double] {
        precondition(standardNormals.count == dimension, "one normal per dimension")
        precondition(temperature >= 0, "temperature must be non-negative")
        let factor = Cholesky(matrix: precision, dimension: dimension)
        let mu = factor.solveSymmetric(b: moment)
        // Covariance is A^{-1} = L^{-T} L^{-1}; solving L^T y = z gives
        // Cov(y) = L^{-T} L^{-1} = A^{-1}.
        let y = factor.solveTransposed(b: standardNormals)
        return zip(mu, y).map { $0 + temperature * $1 }
    }

    /// Exploration temperature: starts at `inflation` and decays to 1 as
    /// effective evidence accumulates (POLICY-3 in DESIGN.md).
    public func explorationTemperature(inflation: Double, decayEvidence: Double) -> Double {
        precondition(inflation >= 1, "inflation must not shrink the posterior")
        precondition(decayEvidence > 0, "decay evidence must be positive")
        let decay = Foundation.exp(-totalEvidence / decayEvidence)
        return 1.0 + (inflation - 1.0) * decay
    }
}

/// Dense symmetric positive-definite Cholesky factorization with fixed
/// arithmetic order (row-major, i/j/k loops) so factorizations are
/// bit-reproducible across runs and stable across hosts for the same
/// compiled arithmetic.
public struct Cholesky: Sendable {
    public let dimension: Int
    /// Lower-triangular factor L with L L^T = A; row-major, the strict
    /// upper triangle is zero.
    private let lower: [Double]

    /// - Precondition: the matrix is symmetric positive definite. The model
    ///   guarantees this (`priorVariance > 0` plus weighted outer products);
    ///   a violation is a broken invariant, so it traps.
    public init(matrix: [Double], dimension: Int) {
        precondition(matrix.count == dimension * dimension, "square matrix expected")
        var lower = Array(repeating: 0.0, count: dimension * dimension)
        for i in 0..<dimension {
            for j in 0...i {
                var sum = matrix[i * dimension + j]
                for k in 0..<j {
                    sum -= lower[i * dimension + k] * lower[j * dimension + k]
                }
                if i == j {
                    precondition(sum > 0, "precision matrix must be positive definite")
                    lower[i * dimension + i] = Foundation.sqrt(sum)
                } else {
                    let diagonal = lower[j * dimension + j]
                    precondition(diagonal > 0, "precision matrix must be positive definite")
                    lower[i * dimension + j] = sum / diagonal
                }
            }
        }
        self.dimension = dimension
        self.lower = lower
    }

    /// Solves `A x = b` via forward and backward substitution.
    public func solveSymmetric(b: [Double]) -> [Double] {
        // Forward: L v = b.
        var v = Array(repeating: 0.0, count: dimension)
        for i in 0..<dimension {
            var sum = b[i]
            for k in 0..<i { sum -= lower[i * dimension + k] * v[k] }
            v[i] = sum / lower[i * dimension + i]
        }
        // Backward: L^T x = v.
        var x = Array(repeating: 0.0, count: dimension)
        for i in stride(from: dimension - 1, through: 0, by: -1) {
            var sum = v[i]
            for k in (i + 1)..<dimension { sum -= lower[k * dimension + i] * x[k] }
            x[i] = sum / lower[i * dimension + i]
        }
        return x
    }

    /// Solves `L^T y = b` (used to draw from the covariance).
    public func solveTransposed(b: [Double]) -> [Double] {
        var y = Array(repeating: 0.0, count: dimension)
        for i in 0..<dimension {
            var sum = b[i]
            for k in 0..<i { sum -= lower[k * dimension + i] * y[k] }
            y[i] = sum / lower[i * dimension + i]
        }
        return y
    }
}
