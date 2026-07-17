// swift-tools-version: 6.1

import PackageDescription

let package = Package(
  name: "ProGhostty",
  defaultLocalization: nil,
  platforms: [
    .macOS(.v14)
  ],
  pkgConfig: nil,
  providers: nil,
  products: [
    .library(name: "ProGhosttyCore", targets: ["ProGhosttyCore"]),
    .executable(name: "ProGhostty", targets: ["ProGhosttyApp"]),
    .executable(name: "pg", targets: ["ProGhosttyPG"]),
  ],
  dependencies: [],
  targets: [
    .target(
      name: "ProGhosttyGhosttyVT",
      publicHeadersPath: "include",
      cSettings: [
        .unsafeFlags(["-IVendor/ghostty/zig-out/include"])
      ],
      linkerSettings: [
        .unsafeFlags(["Vendor/ghostty/zig-out/lib/libghostty-vt.a"])
      ]
    ),
    .target(
      name: "ProGhosttyPTY",
      publicHeadersPath: "include"
    ),
    .target(
      name: "ProGhosttyCore",
      dependencies: ["ProGhosttyGhosttyVT", "ProGhosttyPTY"],
      linkerSettings: [
        .linkedLibrary("sqlite3")
      ]
    ),
    .executableTarget(
      name: "ProGhosttyApp",
      dependencies: ["ProGhosttyCore"],
      resources: [.copy("Resources/notification-piano.mp3")]
    ),
    .executableTarget(
      name: "ProGhosttyPG",
      dependencies: ["ProGhosttyCore"]
    ),
    .testTarget(
      name: "ProGhosttyCoreTests",
      dependencies: ["ProGhosttyCore"]
    ),
    .testTarget(
      name: "ProGhosttyAppTests",
      dependencies: ["ProGhosttyApp"]
    ),
  ],
  swiftLanguageModes: [.v6]
)
