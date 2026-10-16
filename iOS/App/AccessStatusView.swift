import SwiftUI

/// Shared real unavailable state, also rendered by the offscreen QA harness.
struct AccessStatusView: View {
    let summary: String
    let note: String
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Live access unavailable").font(.headline)
            Text(summary).foregroundColor(.secondary)
            Text(note).font(.footnote).foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
    }
}
