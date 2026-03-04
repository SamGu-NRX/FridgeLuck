// swift-tools-version: 6.0

import AppleProductTypes
import PackageDescription

let package = Package(
  name: "FridgeLuck",
  platforms: [
    .iOS("18.0")
  ],
  products: [
    .iOSApplication(
      name: "FridgeLuck",
      targets: ["AppModule"],
      bundleIdentifier: "samgu.FridgeLuck",
      teamIdentifier: "DWGXWVUR2B",
      displayVersion: "1.0",
      bundleVersion: "1",
      appIcon: .asset("AppIcon"),
      accentColor: .presetColor(.brown),
      supportedDeviceFamilies: [
        .pad,
        .phone,
      ],
      supportedInterfaceOrientations: [
        .portrait,
        .landscapeRight,
        .landscapeLeft,
        .portraitUpsideDown(.when(deviceFamilies: [.pad])),
      ],
      appCategory: .healthcareFitness,
      additionalInfoPlistContentFilePath: "Support/AdditionalInfo.plist"
    )
  ],
  dependencies: [
    .package(url: "https://github.com/groue/GRDB.swift.git", "7.10.0"..<"8.0.0")
  ],
  targets: [
    .target(
      name: "FLFeatureLogic",
      path: "FeatureLogic"
    ),
    .executableTarget(
      name: "AppModule",
      dependencies: [
        "FLFeatureLogic",
        .product(name: "GRDB", package: "GRDB.swift"),
      ],
      path: ".",
      exclude: ["Tests", "Vendor"],
      sources: [
        "App",
        "Capability",
        "DesignSystem",
        "Domain",
        "Feature",
        "Platform",
      ],
      resources: [
        .process("Resources")
      ]
    ),
    .testTarget(
      name: "AppModuleTests",
      dependencies: [
        "FLFeatureLogic",
        .product(name: "GRDB", package: "GRDB.swift"),
      ],
      path: "Tests"
    ),
  ],
  swiftLanguageModes: [.v6]
)
