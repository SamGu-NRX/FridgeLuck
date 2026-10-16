import Foundation

/// Mirror-local stand-in for the production `RecipeBundleV2Loader` seam.
///
/// The production loader (apps/ios/Platform/Persistence/Bundle/RecipeBundleV2Loader.swift)
/// also hydrates the catalog tables: it takes `AppDatabase` and the full migration chain,
/// which this portable taste-store mirror deliberately does not carry. The mirrored
/// `TasteCatalogFeatureIndex` needs only the bundle-URL lookup, so this shim reproduces
/// exactly that one function from the production loader. Everything else on the loader
/// (catalog hydration, legacy fallback) is out of scope for this check. It is
/// intentionally not pinned in SOURCES.txt — refresh.sh would overwrite it with the
/// production file and drag AppDatabase in.
enum RecipeBundleV2Loader {
  /// The shipped v2 bundle, under Resources/RecipeCatalog/ or at the resources root.
  /// Mirrors the pinned production `bundleV2URL(in:)`.
  static func bundleV2URL(in bundle: Bundle) -> URL? {
    bundle.url(forResource: "recipes-v2", withExtension: "json", subdirectory: "RecipeCatalog")
      ?? bundle.url(forResource: "recipes-v2", withExtension: "json")
  }
}
