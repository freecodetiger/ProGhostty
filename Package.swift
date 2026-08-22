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
  dependencies: [
    // Markdown parsing for the preview float (spec: 2026-08-18-markdown-preview-float).
    // Reuses Apple's markdown parser instead of hand-writing one.
    .package(url: "https://github.com/apple/swift-markdown.git", from: "0.4.0"),
  ],
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
      dependencies: [
        "ProGhosttyGhosttyVT",
        "ProGhosttyPTY",
        .product(name: "Markdown", package: "swift-markdown"),
      ],
      linkerSettings: [
        .linkedLibrary("sqlite3")
      ]
    ),
    .executableTarget(
      name: "ProGhosttyApp",
      dependencies: ["ProGhosttyCore"],
      resources: [
        .copy("Resources/notification-piano.mp3"),
        .copy("Resources/markdown-preview-light.css"),
        .copy("Resources/markdown-preview-highlight-theme.css"),
        .copy("Resources/markdown-preview-highlight.js"),
      ]
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
