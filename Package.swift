// swift-tools-version: 6.0

import Foundation
import PackageDescription

// Normal Desktop connection is opt-in at runtime. This environment adds only
// isolated preview/headless entry points; distribution scripts reject it.
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
    // Internal implementation for App/AppTests only; never a public product.
    .target(
      name: "QuotaTempoDesktopCandidate",
      dependencies: ["QuotaTempoCore"],
      exclude: desktopIntegrationPreview
        ? []
        : [
          "DesktopPreviewModel.swift",
          "DesktopPreviewMenu.swift",
          "DesktopPreviewInstanceLock.swift",
          "DesktopPreviewTermination.swift",
        ]
    ),
    .executableTarget(
      name: "QuotaTempoApp",
      dependencies: [
        "QuotaTempoCore",
        .product(name: "Sparkle", package: "Sparkle"),
        .target(name: "QuotaTempoDesktopCandidate"),
      ],
      exclude: desktopIntegrationPreview
        ? []
        : [
          "CodeComparisonPackageValidation.swift",
          "CodeComparisonStartupValidation.swift",
        ],
      swiftSettings: [.define("DESKTOP_CONNECTION"), .define("CODE_USAGE_COMPARISON")]
        + (desktopIntegrationPreview ? [.define("DESKTOP_INTEGRATION_PREVIEW")] : [])
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
      dependencies: [
        "QuotaTempoApp", "QuotaTempoCore", .target(name: "QuotaTempoDesktopCandidate"),
      ],
      exclude: desktopIntegrationPreview
        ? []
        : [
          "CodeComparisonOfficialWireTests.swift",
          "CodeComparisonPackageValidationTests.swift",
          "CodeComparisonStartupValidationTests.swift",
        ],
      swiftSettings: [.define("DESKTOP_CONNECTION"), .define("CODE_USAGE_COMPARISON")]
        + (desktopIntegrationPreview ? [.define("DESKTOP_INTEGRATION_PREVIEW")] : [])
    ),
    .testTarget(
      name: "QuotaTempoDesktopCandidateTests",
      dependencies: ["QuotaTempoDesktopCandidate", "QuotaTempoCore"],
      exclude: desktopIntegrationPreview
        ? []
        : [
          "DesktopPreviewModelTests.swift",
          "DesktopPreviewMenuTests.swift",
          "DesktopPreviewInstanceLockTests.swift",
          "DesktopPreviewTerminationTests.swift",
        ]
    ),
  ]
)
