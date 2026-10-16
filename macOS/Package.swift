// swift-tools-version:6.0
import PackageDescription
let package = Package(
  name: "ScreenTimeEditor",
  platforms: [.macOS("26.0")],
  targets: [
    .target(name: "STCore", path: "Sources/STCore"),
    .executableTarget(name: "ScreenTimeEditor", dependencies: ["STCore"], path: "Sources/ScreenTimeEditor",
      resources: [.copy("Resources/backend.py"), .copy("Resources/original_local.py"), .copy("Resources/local_reset.py")]),
    .testTarget(name: "ScreenTimeEditorTests", dependencies: ["ScreenTimeEditor", "STCore"], path: "Tests/ScreenTimeEditorTests"),
    .testTarget(name: "STCoreTests", dependencies: ["STCore"], path: "Tests/STCoreTests"),
  ]
)
