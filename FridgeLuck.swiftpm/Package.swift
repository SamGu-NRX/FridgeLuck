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
      appIcon: .placeholder(icon: .moon),
      accentColor: .presetColor(.yellow),
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
      additionalInfoPlistContentFilePath: "Support/AdditionalInfo.plist"
    )
  ],
  dependencies: [
    .package(path: "Vendor/GRDB.swift")
  ],
  targets: [
    .executableTarget(
      name: "AppModule",
      dependencies: [
        .product(name: "GRDB", package: "GRDB.swift")
      ],
      path: ".",
      exclude: [
        "Tests",
        "Vendor",
      ],
      resources: [
        .process("Resources")
      ]
    ),
    .testTarget(
      name: "AppModuleTests",
      dependencies: [
        .product(name: "GRDB", package: "GRDB.swift")
      ],
      path: "Tests"
    ),
  ],
  swiftLanguageModes: [.v6]
)
