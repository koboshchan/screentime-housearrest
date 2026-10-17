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

struct InstalledAppPicker: View {
    @Binding var selection: String
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var apps: [String] = []
    var filtered: [String] {
        apps.filter { query.isEmpty || $0.localizedCaseInsensitiveContains(query) ||
            AppIdentityResolver.shared.resolve($0).name.localizedCaseInsensitiveContains(query) }
    }
    static func installed() -> [String] {
        var found = Set<String>()
        let fm = FileManager.default
        for root in ["/Applications", "/System/Applications", "/System/Library/CoreServices",
                     NSHomeDirectory() + "/Applications"] {
            guard let files = fm.enumerator(at: URL(fileURLWithPath: root),
                includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { continue }
            while let url = files.nextObject() as? URL {
                if url.pathExtension == "app" {
                    if let id = Bundle(url: url)?.bundleIdentifier { found.insert(id) }
                    files.skipDescendants()
                }
            }
        }
        return found.sorted {
            AppIdentityResolver.shared.resolve($0).name.localizedStandardCompare(
                AppIdentityResolver.shared.resolve($1).name) == .orderedAscending
        }
    }
    var body: some View {
        VStack(spacing: 12) {
            Text("Choose app").font(.headline)
            TextField("Search name or bundle ID", text: $query).textFieldStyle(.roundedBorder)
            List(filtered, id: \.self) { id in
                Button {
                    selection = id
                    dismiss()
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            AppIdentityLabel(bundleID: id)
                            Text(id).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if selection == id { Image(systemName: "checkmark") }
                    }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
            HStack { Spacer(); Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction) }
        }.padding(16).frame(width: 460, height: 520)
        .onAppear { apps = Self.installed() }
    }
}

