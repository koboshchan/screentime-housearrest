// Offscreen render harness. NOT part of the shipped app. Real views (DetailPane only: List/NavigationSplitView render as a yellow placeholder in ImageRenderer), real backend status/read; never injects sessions or errors.
// Output is SwiftUI ImageRenderer, NOT a screenshot of a display.
import SwiftUI
import AppKit

@MainActor func render<V: View>(_ v: V, _ scheme: ColorScheme, w: CGFloat, h: CGFloat, to path: String, model: EditorModel) {
  let view = v.environment(model).environment(\.colorScheme, scheme)
    .frame(width: w, height: h).background(scheme == .dark ? Color(white: 0.118) : Color(white: 0.925))
  let r = ImageRenderer(content: view); r.scale = 2
  guard let img = r.nsImage, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
        let png = rep.representation(using: .png, properties: [:]) else { print("render failed"); exit(1) }
  try! png.write(to: URL(fileURLWithPath: path)); print("wrote", path)
}

@main struct Main {
  @MainActor static func main() async {
    let args = CommandLine.arguments
    let model = EditorModel(scriptURL: URL(fileURLWithPath: args[1]))
    await model.bootstrap()
    print("status:", model.status.map { "\($0.macOS) canApply=\($0.canApply)" } ?? "nil", "statusError:", model.statusError ?? "-")
    print("loadError:", model.loadError ?? "-", "permissionDenied:", model.permissionDenied, "sessions:", model.sessions.count)
    for (s, n) in [(ColorScheme.light, "light"), (.dark, "dark")] {
      render(VStack(alignment: .leading, spacing: 14) {
        AppIdentityLabel(bundleID: "com.apple.finder")
        AppIdentityLabel(bundleID: "com.apple.Safari")
        AppIdentityLabel(bundleID: "com.not.installed")
      }.padding(20), s, w: 300, h: 150, to: args[2] + "/app-identities-\(n).png", model: model)
      render(DetailPane(), s, w: 820, h: 600, to: args[2] + "/macos-real-\(n).png", model: model)
    }
  }
}
