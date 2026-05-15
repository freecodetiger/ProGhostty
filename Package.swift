// swift-tools-version: 6.1

import PackageDescription

let package = Package(
  name: "ProGhostty",
  defaultLocalization: nil,
  platforms: [
    .macOS(.v13)
  ],
  pkgConfig: nil,
  providers: nil,
  products: [
    .library(name: "ProGhosttyCore", targets: ["ProGhosttyCore"]),
    .executable(name: "ProGhostty", targets: ["ProGhosttyApp"]),
  ],
  dependencies: [],
  targets: [
    .target(
      name: "ProGhosttyCore",
      linkerSettings: [
        .linkedLibrary("sqlite3")
      ]
    ),
    .executableTarget(
      name: "ProGhosttyApp",
      dependencies: ["ProGhosttyCore"]
    ),
    .testTarget(
      name: "ProGhosttyCoreTests",
      dependencies: ["ProGhosttyCore"]
    ),
  ],
  swiftLanguageModes: [.v6]
)
