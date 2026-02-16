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
      ]
    )
  ],
  dependencies: [
    .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0")
  ],
  targets: [
    .executableTarget(
      name: "AppModule",
      dependencies: [
        .product(name: "GRDB", package: "GRDB.swift")
      ],
      path: ".",
      resources: [
        .process("Resources")
      ]
    )
  ],
  swiftLanguageVersions: [.v6]
)
