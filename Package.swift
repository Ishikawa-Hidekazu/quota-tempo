// swift-tools-version: 6.0

import Foundation
import PackageDescription

// Opt-in local integration only. Distribution scripts reject this environment.
let desktopIntegrationPreview =
  ProcessInfo.processInfo.environment["QUOTATEMPO_DESKTOP_INTEGRATION_PREVIEW"] == "1"

let package = Package(
  name: "QuotaTempo",
  defaultLocalization: "en",
  platforms: [.macOS(.v14)],
  products: [
    .library(name: "QuotaTempoCore", targets: ["QuotaTempoCore"]),
    .executable(name: "QuotaTempo", targets: ["QuotaTempoApp"]),
    .executable(name: "QuotaTempoFixtureRenderer", targets: ["QuotaTempoFixtureRenderer"]),
    .executable(name: "QuotaTempoBridge", targets: ["QuotaTempoBridge"]),
    .executable(name: "QuotaTempoBrowserHost", targets: ["QuotaTempoBrowserHost"]),
  ],
  dependencies: [
    .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.6")
  ],
  targets: [
    .target(
      name: "QuotaTempoCore",
      exclude: ["Resources"]
    ),
    // Excluded from all default product graphs; local integration is opt-in.
    .target(
      name: "QuotaTempoDesktopCandidate",
      dependencies: ["QuotaTempoCore"]
    ),
    .executableTarget(
      name: "QuotaTempoApp",
      dependencies: [
        "QuotaTempoCore",
        .product(name: "Sparkle", package: "Sparkle"),
      ] + (desktopIntegrationPreview ? [.target(name: "QuotaTempoDesktopCandidate")] : []),
      swiftSettings: desktopIntegrationPreview ? [.define("DESKTOP_INTEGRATION_PREVIEW")] : []
    ),
    .executableTarget(
      name: "QuotaTempoFixtureRenderer",
      dependencies: ["QuotaTempoCore"]
    ),
    .executableTarget(
      name: "QuotaTempoBridge",
      dependencies: ["QuotaTempoCore"]
    ),
    .executableTarget(
      name: "QuotaTempoBrowserHost",
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
        + (desktopIntegrationPreview ? [.target(name: "QuotaTempoDesktopCandidate")] : []),
      swiftSettings: desktopIntegrationPreview ? [.define("DESKTOP_INTEGRATION_PREVIEW")] : []
    ),
    .testTarget(
      name: "QuotaTempoDesktopCandidateTests",
      dependencies: ["QuotaTempoDesktopCandidate", "QuotaTempoCore"]
    ),
  ]
)
