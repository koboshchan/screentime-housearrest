// Offscreen render harness. NOT part of the shipped app. Renders the real views with the real backend's
// real result on this machine (status + read). It never injects sessions or errors.
// Output is SwiftUI ImageRenderer, NOT a screenshot of an actual display.
import SwiftUI
import AppKit

@MainActor func render(_ scheme: ColorScheme, to path: String, model: EditorModel) {
  let view = DetailPane().environment(model).environment(\.colorScheme, scheme)
    .frame(width: 820, height: 600).background(scheme == .dark ? Color(white: 0.118) : Color(white: 0.925))
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
    render(.light, to: args[2] + "/macos-real-light.png", model: model)
    render(.dark, to: args[2] + "/macos-real-dark.png", model: model)
  }
}
