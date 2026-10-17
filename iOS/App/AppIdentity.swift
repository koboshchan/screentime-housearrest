import SwiftUI
import UIKit

/// Read-only bundle metadata. Missing or removed apps retain their raw identifier.
final class AppIdentity {
    static let shared = AppIdentity()
    private var bundles: [String: Bundle] = [:]
    private var icons: [String: UIImage] = [:]
    private init() {
        let fm = FileManager.default
        for root in ["/Applications", "/System/Applications", "/var/containers/Bundle/Application",
                     "/rootfs/Applications", "/rootfs/var/containers/Bundle/Application"] {
            guard let children = try? fm.contentsOfDirectory(atPath: root) else { continue }
            for child in children where !child.hasPrefix(".") {
                let path = root + "/" + child
                if child.hasSuffix(".app") { register(path) }
                else if let apps = try? fm.contentsOfDirectory(atPath: path) {
                    for app in apps where app.hasSuffix(".app") { register(path + "/" + app) }
                }
            }
        }
    }
    var identifiers: [String] {
        bundles.keys.sorted { name($0).localizedStandardCompare(name($1)) == .orderedAscending }
    }
    private func register(_ path: String) {
        guard let bundle = Bundle(path: path), let id = bundle.bundleIdentifier else { return }
        if bundles[id] == nil { bundles[id] = bundle }
    }
    func name(_ id: String) -> String {
        guard let bundle = bundles[id] else { return id }
        for key in ["CFBundleDisplayName", "CFBundleName"] {
            if let value = bundle.object(forInfoDictionaryKey: key) as? String, !value.isEmpty { return value }
        }
        return id
    }
    func icon(_ id: String) -> UIImage? {
        if let cached = icons[id] { return cached }
        guard let bundle = bundles[id] else { return nil }
        let info = bundle.infoDictionary ?? [:]
        let iconSets = info["CFBundleIcons"] as? [String: Any]
        let primary = iconSets?["CFBundlePrimaryIcon"] as? [String: Any]
        let names = (primary?["CFBundleIconFiles"] as? [String] ?? []) +
                    (info["CFBundleIconFiles"] as? [String] ?? []) + ["AppIcon", "Icon"]
        for name in names.reversed() {
            if let image = UIImage(named: name, in: bundle, compatibleWith: nil) {
                icons[id] = image; return image
            }
        }
        return nil
    }
}

struct AppLabel: View {
    let bundleID: String
    var body: some View {
        HStack(spacing: 10) {
            if let icon = AppIdentity.shared.icon(bundleID) {
                Image(uiImage: icon).resizable().scaledToFit().frame(width: 30, height: 30)
                    .clipShape(RoundedRectangle(cornerRadius: 7))
            } else {
                Image(systemName: "app.fill").foregroundStyle(.secondary).frame(width: 30, height: 30)
            }
            Text(AppIdentity.shared.name(bundleID)).lineLimit(1)
        }.accessibilityLabel(AppIdentity.shared.name(bundleID))
    }
}

struct InstalledAppPicker: View {
    @Binding var selection: String
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    private var apps: [String] {
        AppIdentity.shared.identifiers.filter {
            query.isEmpty || $0.localizedCaseInsensitiveContains(query) ||
            AppIdentity.shared.name($0).localizedCaseInsensitiveContains(query)
        }
    }
    var body: some View {
        NavigationStack {
            List(apps, id: \.self) { id in
                Button {
                    selection = id
                    dismiss()
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            AppLabel(bundleID: id)
                            Text(id).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if selection == id { Image(systemName: "checkmark") }
                    }
                }.foregroundStyle(.primary)
            }
            .searchable(text: $query, prompt: "Name or bundle ID")
            .navigationTitle("Choose app")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .overlay { if apps.isEmpty { ContentUnavailableView.search(text: query) } }
        }
    }
}

