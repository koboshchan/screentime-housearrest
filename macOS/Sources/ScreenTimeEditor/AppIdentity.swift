import AppKit
import SwiftUI

struct AppIdentity {
  let name: String
  let icon: NSImage?
}

/// Presentation only. Session identifiers and stored bundle IDs never change.
@MainActor
final class AppIdentityResolver {
  static let shared = AppIdentityResolver()
  private var cache: [String: AppIdentity] = [:]
  private let locate: (String) -> URL?
  private let icon: (String) -> NSImage

  init(locate: @escaping (String) -> URL? = { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) },
       icon: @escaping (String) -> NSImage = { NSWorkspace.shared.icon(forFile: $0) }) {
    self.locate = locate; self.icon = icon
  }

  func resolve(_ identifier: String) -> AppIdentity {
    if let found = cache[identifier] { return found }
    guard let url = locate(identifier), let bundle = Bundle(url: url) else {
      return AppIdentity(name: identifier, icon: nil)
    }
    let names = [bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String,
                 bundle.object(forInfoDictionaryKey: "CFBundleName") as? String]
    let name = names.compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
      .first { !$0.isEmpty } ?? identifier
    let found = AppIdentity(name: name, icon: icon(url.path))
    cache[identifier] = found
    return found
  }
}

struct AppIdentityLabel: View {
  let bundleID: String
  var body: some View {
    let app = AppIdentityResolver.shared.resolve(bundleID)
    HStack(spacing: 6) {
      if let icon = app.icon {
        Image(nsImage: icon).resizable().scaledToFit().frame(width: 18, height: 18)
          .accessibilityHidden(true)
      } else {
        Color.clear.frame(width: 18, height: 18).accessibilityHidden(true)
      }
      Text(app.name).lineLimit(1)
    }
    .help(bundleID)
  }
}
