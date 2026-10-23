import Foundation
import FLTaste
import FLTasteSim

/// The preregistered 12-arm list: 5 PLAN model families, 4 baselines,
/// 3 family-2 ablations. One shared read-only feature cache.
public enum ArmRegistry {
    public static func all(catalog: RecipeCatalog) -> [any ArmFactory] {
        let cache = FeatureCache(catalog: catalog)
        return [
            // Baselines (4)
            PopularityArm(),
            RandomArm(),
            RuleRankerArm(catalog: catalog),
            ProfileOnlyArm(catalog: catalog),
            // Model families (5)
            TrustVectorArm(cache: cache),
            EngineArm.engine(catalog: catalog),
            LogisticArm(cache: cache),
            PairwiseArm(cache: cache),
            EmbeddingArm(cache: cache),
            // Family-2 ablations (3)
            EngineArm.noExposureWeighting(catalog: catalog),
            EngineArm.noRecency(catalog: catalog),
            EngineArm.noExploration(catalog: catalog),
        ]
    }
}
