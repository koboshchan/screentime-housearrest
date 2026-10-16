// Offscreen render harness, never shipped. Defaults to a real backend read.
// --fixture explicitly selects synthetic visual QA records without reading stores.
// Output is an offscreen NSHostingView capture, NOT a screenshot of a display.
import SwiftUI
import AppKit
import STCore

@MainActor func render<V: View>(_ v: V, _ scheme: ColorScheme, w: CGFloat, h: CGFloat, to path: String, model: EditorModel) {
  let view = v.environment(model).environment(\.colorScheme, scheme)
    .frame(width: w, height: h).background(scheme == .dark ? Color(white: 0.118) : Color(white: 0.925))
  // AppKit-backed controls and scroll views need NSHostingView, not ImageRenderer.
  let host = NSHostingView(rootView: view)
  let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: w, height: h),
                        styleMask: [.borderless], backing: .buffered, defer: false)
  window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
  window.contentView = host
  host.frame = NSRect(x: 0, y: 0, width: w, height: h)
  host.layoutSubtreeIfNeeded()
  host.displayIfNeeded()
  guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { exit(1) }
  host.cacheDisplay(in: host.bounds, to: rep)
  guard let png = rep.representation(using: .png, properties: [:]) else { exit(1) }
  try! png.write(to: URL(fileURLWithPath: path)); print("wrote", path)
  window.contentView = nil
}

@main struct Main {
  @MainActor static func main() async {
    _ = NSApplication.shared
    let args = CommandLine.arguments
    let model = EditorModel(scriptURL: URL(fileURLWithPath: args[1]))
    let fixture = args.contains("--fixture")
    if fixture {
      // Explicit visual-test data only. This executable is never shipped.
      model.status = try! JSONDecoder().decode(SystemStatus.self, from:
        Data(#"{"macOS":"27.0.1","build":"26A434","sip":"disabled","canApply":true}"#.utf8))
      model.readCanApply = true
      let day = model.dayStart
      model.sessions = [
        Session(bundle: "com.apple.Safari", start: day + 3600, end: day + 10800),
        Session(bundle: "com.apple.finder", start: day + 12000, end: day + 15600),
        Session(bundle: "com.apple.systempreferences", start: day + 16000, end: day + 17000)
      ] + (0..<30).map { i in
        Session(bundle: "com.apple.Safari", start: day + Double(i * 30), end: day + Double(i * 30) + 0.2)
      }
      model.warnings = ["Historical unmatched start ignored for com.apple.Safari."]
    } else {
      await model.bootstrap()
    }
    print("status:", model.status.map { "\($0.macOS) canApply=\($0.canApply)" } ?? "nil", "statusError:", model.statusError ?? "-")
    print("loadError:", model.loadError ?? "-", "permissionDenied:", model.permissionDenied, "sessions:", model.sessions.count)
    for (s, n) in [(ColorScheme.light, "light"), (.dark, "dark")] {
      render(VStack(alignment: .leading, spacing: 14) {
        AppIdentityLabel(bundleID: "com.apple.finder")
        AppIdentityLabel(bundleID: "com.apple.Safari")
        AppIdentityLabel(bundleID: "com.not.installed")
      }.padding(20), s, w: 300, h: 150, to: args[2] + "/app-identities-\(n).png", model: model)
      let prefix = fixture ? "macos-fixture" : "macos-real"
      render(DetailPane(), s, w: 1000, h: 600, to: args[2] + "/\(prefix)-\(n).png", model: model)
      if fixture {
        render(ContentView(), s, w: 1300, h: 760, to: args[2] + "/macos-fixture-full-\(n).png", model: model)
        model.showShortSessions = true
        render(ContentView(), s, w: 1300, h: 760, to: args[2] + "/macos-fixture-short-shown-\(n).png", model: model)
        model.showShortSessions = false
        model.timelineZoom = 4
        render(DetailPane(), s, w: 1000, h: 600, to: args[2] + "/macos-fixture-zoom4-\(n).png", model: model)
        model.timelineZoom = 1
      }
    }
  }
}
