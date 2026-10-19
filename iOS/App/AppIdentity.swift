import SwiftUI
import UIKit

/// Read-only app metadata scanned from bundle files (system, App Store, rootful,
/// rootless /var/jb and RootHide jbroot). Missing apps retain their raw identifier.
final class AppIdentity {
    static let shared = AppIdentity()

    private struct Record { let path: String; let info: [String: Any] }
    private var records: [String: Record] = [:]
    private var icons: [String: UIImage] = [:]
    private var names: [String: String] = [:]
    private static let maxApps = 4000
    private static let maxPlistBytes = 2_000_000
    private static let maxIconCandidates = 400
    private static let maxEntriesPerDir = 3000

    private init() {
        let fm = FileManager.default
        var seen = Set<String>()
        for root in Self.roots(fm) {
            let real = URL(fileURLWithPath: root).resolvingSymlinksInPath().path
            guard seen.insert(real).inserted else { continue }
            scan(root, depth: 0, fm)
        }
    }

    /// Candidate application directories. Only reads directory listings.
    private static func roots(_ fm: FileManager) -> [String] {
        var out = ["/Applications", "/System/Applications", "/var/containers/Bundle/Application", "/var/jb/Applications", "/rootfs/Applications", "/rootfs/var/containers/Bundle/Application", "/rootfs/var/jb/Applications"]
        let list = { (p: String) -> [String] in ((try? fm.contentsOfDirectory(atPath: p)) ?? []).prefix(maxEntriesPerDir).map { $0 } }
        // Rootless: /var/jb is a symlink into /private/preboot; resolve it instead of enumerating preboot.
        let jb = URL(fileURLWithPath: "/var/jb").resolvingSymlinksInPath().path
        if jb != "/var/jb" { out.append(jb + "/Applications") }
        // RootHide: hidden /var/containers/Bundle/Application/.jbroot-<id>/ (Applications and var/jb layouts)
        let bundleRoot = "/var/containers/Bundle/Application"
        for dir in list(bundleRoot) where dir.hasPrefix(".jbroot") {
            out.append("\(bundleRoot)/\(dir)/Applications")
            out.append("\(bundleRoot)/\(dir)/var/jb/Applications")
            out.append("\(bundleRoot)/\(dir)/procursus/Applications")
        }
        return out
    }

    private func scan(_ dir: String, depth: Int, _ fm: FileManager) {
        guard depth < 3, records.count < Self.maxApps,
              let children = try? fm.contentsOfDirectory(atPath: dir) else { return }
        for child in children.prefix(Self.maxEntriesPerDir) {
            guard records.count < Self.maxApps else { return }
            if child.hasSuffix(".app") { register(dir + "/" + child) }
            else if depth < 2, !child.hasPrefix(".") || child.hasPrefix(".jbroot") {
                var isDir: ObjCBool = false
                let path = dir + "/" + child
                if fm.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue { scan(path, depth: depth + 1, fm) }
            }
        }
    }

    var identifiers: [String] {
        records.keys.sorted { name($0).localizedStandardCompare(name($1)) == .orderedAscending }
    }

    private func register(_ path: String) {
        let url = URL(fileURLWithPath: path + "/Info.plist")
        let size = ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? Int) ?? 0
        guard size > 0, size <= Self.maxPlistBytes,
              let data = try? Data(contentsOf: url, options: .mappedIfSafe),
              let info = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any],
              let id = info["CFBundleIdentifier"] as? String, !id.isEmpty else { return }
        if records[id] == nil { records[id] = Record(path: path, info: info) }
    }

    // MARK: Names

    func name(_ id: String) -> String {
        if let cached = names[id] { return cached }
        guard let record = records[id] else { return id }
        let resolved = localizedName(record) ?? id
        names[id] = resolved
        return resolved
    }

    private func localizedName(_ record: Record) -> String? {
        let keys = ["CFBundleDisplayName", "CFBundleName"]
        for lproj in languageFolders(record.path) {
            let file = "\(record.path)/\(lproj).lproj/InfoPlist.strings"
            guard let strings = NSDictionary(contentsOfFile: file) as? [String: String] else { continue }
            for key in keys { if let v = strings[key], !v.isEmpty { return v } }
        }
        for key in keys { if let v = record.info[key] as? String, !v.isEmpty { return v } }
        // Jailbreak apps without CFBundleName: use the .app folder name.
        let base = (record.path as NSString).lastPathComponent
        let stem = (base as NSString).deletingPathExtension
        return stem.isEmpty ? nil : stem
    }

    /// Existing .lproj folders ordered by the user's language preference, then Base/en.
    private func languageFolders(_ appPath: String) -> [String] {
        let existing = Set(((try? FileManager.default.contentsOfDirectory(atPath: appPath)) ?? [])
            .filter { $0.hasSuffix(".lproj") }.map { String($0.dropLast(6)) })
        guard !existing.isEmpty else { return [] }
        var wanted: [String] = []
        for lang in Locale.preferredLanguages {
            wanted.append(lang)
            wanted.append(lang.replacingOccurrences(of: "-", with: "_"))
            let parts = lang.split(separator: "-").map(String.init)
            if parts.count > 2 { wanted.append(parts[0] + "-" + parts[1]); wanted.append(parts[0] + "_" + parts[1]) }
            if let first = parts.first { wanted.append(first) }
        }
        wanted += ["en", "Base"]
        var seen = Set<String>()
        return wanted.filter { existing.contains($0) && seen.insert($0).inserted }
    }

    // MARK: Icons

    func icon(_ id: String) -> UIImage? {
        if let cached = icons[id] { return cached }
        guard let record = records[id] else { return nil }
        let image = fileIcon(record) ?? catalogIcon(record)
        if let image { icons[id] = image }
        return image
    }

    private func iconNames(_ info: [String: Any]) -> [String] {
        var out: [String] = []
        for key in ["CFBundleIcons", "CFBundleIcons~ipad"] {
            if let set = info[key] as? [String: Any], let primary = set["CFBundlePrimaryIcon"] {
                if let dict = primary as? [String: Any] {
                    out += dict["CFBundleIconFiles"] as? [String] ?? []
                    if let n = dict["CFBundleIconName"] as? String { out.append(n) }
                } else if let s = primary as? String { out.append(s) }
            }
        }
        out += info["CFBundleIconFiles"] as? [String] ?? []
        if let f = info["CFBundleIconFile"] as? String { out.append(f) }
        return out + ["AppIcon", "Icon", "icon"]
    }

    private func fileIcon(_ record: Record) -> UIImage? {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: record.path)) ?? []
        let pngs = Array(files.filter { $0.lowercased().hasSuffix(".png") }.prefix(Self.maxIconCandidates))
        var best: (path: String, score: Int)?
        for raw in iconNames(record.info) {
            let stem = ((raw as NSString).pathExtension.lowercased() == "png") ? (raw as NSString).deletingPathExtension : raw
            let lowered = stem.lowercased()
            for file in pngs {
                let l = file.lowercased()
                guard l.hasPrefix(lowered), !l.contains("settings"), !l.contains("spotlight"), !l.contains("notification") else { continue }
                let path = record.path + "/" + file
                let size = ((try? FileManager.default.attributesOfItem(atPath: path)[.size]) as? Int) ?? 0
                // Prefer iPhone over iPad, then larger files (higher resolution).
                let score = size + (l.contains("~ipad") ? 0 : 1_000_000)
                if best == nil || score > best!.score { best = (path, score) }
            }
            if best != nil { break }
        }
        guard let best, let image = UIImage(contentsOfFile: best.path) else { return nil }
        return image
    }

    private func catalogIcon(_ record: Record) -> UIImage? {
        guard let bundle = Bundle(path: record.path) else { return nil }
        for name in iconNames(record.info) {
            if let image = UIImage(named: name, in: bundle, compatibleWith: nil) { return image }
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

