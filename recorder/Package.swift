// swift-tools-version:6.0
import PackageDescription

let package = Package(
  name: "LoomyRecorder",
  platforms: [.macOS(.v15)],
  targets: [
    .executableTarget(
      name: "LoomyRecorder",
      path: "Sources/LoomyRecorder",
      swiftSettings: [.swiftLanguageMode(.v5)]
    )
  ]
)
