// swift-tools-version:6.0
import PackageDescription
let package = Package(
  name: "ScreenTimeEditor",
  platforms: [.macOS(.v14)],
  targets: [
    .target(name: "STCore", path: "Sources/STCore"),
    .executableTarget(name: "ScreenTimeEditor", dependencies: ["STCore"], path: "Sources/ScreenTimeEditor",
      resources: [.copy("Resources/backend.py")]),
    .testTarget(name: "STCoreTests", dependencies: ["STCore"], path: "Tests/STCoreTests"),
  ]
)
