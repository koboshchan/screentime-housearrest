import XCTest
import AppKit
@testable import ScreenTimeEditor

@MainActor
final class AppIdentityTests: XCTestCase {
  func fixture(display: String? = nil, name: String? = nil) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".app")
    let contents = url.appendingPathComponent("Contents")
    try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
    var info: [String: Any] = ["CFBundleIdentifier": "fixture." + UUID().uuidString, "CFBundlePackageType": "APPL"]
    info["CFBundleDisplayName"] = display; info["CFBundleName"] = name
    let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
    try data.write(to: contents.appendingPathComponent("Info.plist"))
    addTeardownBlock { try? FileManager.default.removeItem(at: url) }
    return url
  }

  func testDisplayNameAndNativeIconLookupCached() throws {
    let url = try fixture(display: "Friendly App", name: "Internal Name")
    let image = NSImage(size: NSSize(width: 32, height: 32))
    var calls = 0, paths: [String] = []
    let resolver = AppIdentityResolver(locate: { id in
      XCTAssertEqual(id, "com.fixture.app"); calls += 1; return url
    }, icon: { paths.append($0); return image })
    let result = resolver.resolve("com.fixture.app")
    XCTAssertEqual(result.name, "Friendly App")
    XCTAssertTrue(result.icon === image)
    XCTAssertEqual(paths, [url.path])
    XCTAssertEqual(resolver.resolve("com.fixture.app").name, result.name)
    XCTAssertEqual(calls, 1)
  }

  func testBundleNameFallback() throws {
    let url = try fixture(display: "  ", name: "Bundle Name")
    let resolver = AppIdentityResolver(locate: { _ in url })
    XCTAssertEqual(resolver.resolve("com.fixture.app").name, "Bundle Name")
  }

  func testAbsentAppUsesExactRawIDWithoutIconLookup() {
    var icons = 0
    let resolver = AppIdentityResolver(locate: { _ in nil }, icon: { _ in icons += 1; return NSImage() })
    let result = resolver.resolve("com.not.installed")
    XCTAssertEqual(result.name, "com.not.installed")
    XCTAssertNil(result.icon)
    XCTAssertEqual(icons, 0)
  }

  func testMissingNamesFallBackToID() throws {
    let url = try fixture()
    XCTAssertEqual(AppIdentityResolver(locate: { _ in url }).resolve("com.fixture").name, "com.fixture")
  }

  func testRealInstalledAppResolvesThroughNSWorkspace() throws {
    let url = try XCTUnwrap(NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.finder"))
    let bundle = try XCTUnwrap(Bundle(url: url))
    let result = AppIdentityResolver().resolve("com.apple.finder")
    let expected = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
      ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
    XCTAssertEqual(result.name, expected)
    XCTAssertNotNil(result.icon)
    XCTAssertNotEqual(result.name, "com.apple.finder")
  }
}
