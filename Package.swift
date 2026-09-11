// swift-tools-version: 6.0

import PackageDescription

let package = Package(
  name: "QuotaTempo",
  defaultLocalization: "en",
  platforms: [.macOS(.v14)],
  products: [
    .library(name: "QuotaTempoCore", targets: ["QuotaTempoCore"]),
    .executable(name: "QuotaTempo", targets: ["QuotaTempoApp"]),
    .executable(name: "QuotaTempoFixtureRenderer", targets: ["QuotaTempoFixtureRenderer"]),
    .executable(name: "QuotaTempoBridge", targets: ["QuotaTempoBridge"]),
  ],
  targets: [
    .target(
      name: "QuotaTempoCore",
      exclude: ["Resources"]
    ),
    .executableTarget(
      name: "QuotaTempoApp",
      dependencies: ["QuotaTempoCore"]
    ),
    .executableTarget(
      name: "QuotaTempoFixtureRenderer",
      dependencies: ["QuotaTempoCore"]
    ),
    .executableTarget(
      name: "QuotaTempoBridge",
      dependencies: ["QuotaTempoCore"]
    ),
    .testTarget(
      name: "QuotaTempoCoreTests",
      dependencies: ["QuotaTempoCore"],
      resources: [.process("Fixtures")]
    ),
    .testTarget(
      name: "QuotaTempoAppTests",
      dependencies: ["QuotaTempoApp", "QuotaTempoCore"]
    ),
  ]
)
