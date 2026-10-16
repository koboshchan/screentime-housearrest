import SwiftUI
import AppKit

@main
struct StatusSnapshot {
    @MainActor static func main() throws {
        let out = CommandLine.arguments[1]
        for (name, scheme) in [("light", ColorScheme.light), ("dark", ColorScheme.dark)] {
            let content = AccessStatusView(
                summary: Capability.from(HelperReply(ok: false, code: "integration_unavailable",
                    message: "RootHide integration, authenticated caller transport, and consistent backup coordination are not implemented.")).summary,
                note: "Existing usage cannot be read yet. Composed sessions stay in memory only; closing the app discards them.")
                .padding(24).frame(width: 390)
                .background(scheme == .dark ? Color.black : Color.white)
                .foregroundColor(scheme == .dark ? .white : .black)
                .environment(\.colorScheme, scheme)
            let renderer = ImageRenderer(content: content)
            renderer.scale = 2
            guard let cg = renderer.cgImage else { fatalError("Offscreen rendering failed") }
            let image = NSBitmapImageRep(cgImage: cg)
            guard let png = image.representation(using: .png, properties: [:]) else { fatalError("PNG encoding failed") }
            try png.write(to: URL(fileURLWithPath: out).appendingPathComponent("access-status-\(name).png"))
        }
        print("PASS offscreen native SwiftUI shared unavailable-state snapshots, light and dark; not iOS simulator screenshots")
    }
}
