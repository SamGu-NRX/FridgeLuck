#if canImport(PackageDescription)
  // swift-tools-version:6.1
  import PackageDescription

  let darwinPlatforms: [Platform] = [
    .iOS,
    .macOS,
    .macCatalyst,
    .tvOS,
    .visionOS,
    .watchOS,
  ]

  var swiftSettings: [SwiftSetting] = [
    .define("SQLITE_ENABLE_FTS5"),
    .define("SQLITE_ENABLE_SNAPSHOT"),
  ]

  var cSettings: [CSetting] = []

  let package = Package(
    name: "GRDB",
    defaultLocalization: "en",
    platforms: [
      .iOS(.v13),
      .macOS(.v10_15),
      .tvOS(.v13),
      .watchOS(.v7),
    ],
    products: [
      .library(name: "GRDBSQLite", targets: ["GRDBSQLite"]),
      .library(name: "GRDB", targets: ["GRDB"]),
      .library(name: "GRDB-dynamic", type: .dynamic, targets: ["GRDB"]),
    ],
    targets: [
      .systemLibrary(
        name: "GRDBSQLite",
        providers: [.apt(["libsqlite3-dev"])]
      ),
      .target(
        name: "GRDB",
        dependencies: [
          .target(name: "GRDBSQLite")
        ],
        path: "GRDB",
        resources: [.copy("PrivacyInfo.xcprivacy")],
        cSettings: cSettings,
        swiftSettings: swiftSettings
      ),
    ],
    swiftLanguageModes: [.v6]
  )
#endif
