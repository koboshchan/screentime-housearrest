import Foundation

/// Launch argument `--verify-read-only`: after bootstrap, writes a private status report. Never applies or writes usage data.
@MainActor
enum ReadCheck {
  static let flag = "--verify-read-only"
  static var requested: Bool { CommandLine.arguments.contains(flag) }

  static func reportURL(home: String = NSHomeDirectory()) -> URL {
    URL(fileURLWithPath: home).appendingPathComponent("Library/Logs/ScreenTimeEditor/read-check.json")
  }

  static func report(_ m: EditorModel) -> [String: Any] {
    [
      "generatedAt": ISO8601DateFormatter().string(from: Date()),
      "source": "native-gui",
      "pid": Int(ProcessInfo.processInfo.processIdentifier),
      "statusLoaded": m.status != nil,
      "statusError": m.statusError as Any? ?? NSNull(),
      "macOS": m.status?.macOS ?? NSNull(),
      "sip": m.status?.sip ?? NSNull(),
      "statusCanApply": m.status?.canApply ?? false,
      "readCanApply": m.readCanApply,
      "canApply": m.canApply,
      "loadError": m.loadError ?? NSNull(),
      "permissionDenied": m.permissionDenied,
      "needsFullDiskAccess": m.needsFullDiskAccess,
      "applyBlockedReason": m.applyBlockedReason ?? NSNull(),
      "sessionCount": m.sessions.count,
      "warningCount": m.warnings.count,
      "dirty": m.dirty,
      "stale": m.stale,
      "hasRevision": !m.revision.isEmpty,
    ]
  }

  /// Parent dir mode 0700, file 0600, refuses symlinks, atomic replace.
  @discardableResult
  static func write(_ m: EditorModel, to url: URL = reportURL()) throws -> URL {
    let fm = FileManager.default
    let dir = url.deletingLastPathComponent()
    if let a = try? fm.attributesOfItem(atPath: dir.path), a[.type] as? FileAttributeType == .typeSymbolicLink {
      throw CocoaError(.fileWriteInvalidFileName)
    }
    try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
    if let a = try? fm.attributesOfItem(atPath: url.path), a[.type] as? FileAttributeType == .typeSymbolicLink {
      throw CocoaError(.fileWriteInvalidFileName)
    }
    let data = try JSONSerialization.data(withJSONObject: report(m), options: [.prettyPrinted, .sortedKeys])
    let tmp = dir.appendingPathComponent(".read-check.\(UUID().uuidString).tmp")
    guard fm.createFile(atPath: tmp.path, contents: data, attributes: [.posixPermissions: 0o600]) else { throw CocoaError(.fileWriteUnknown) }
    _ = try fm.replaceItemAt(url, withItemAt: tmp)
    try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    return url
  }
}
