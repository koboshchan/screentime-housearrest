import SwiftUI
import STCore

/// 24h timeline: one lane per app. Drag a block to move, drag its edges to resize, double-click to split.
struct TimelineEditor: View {
  @Environment(EditorModel.self) private var model
  private let laneH: CGFloat = 42, labelW: CGFloat = 170, axisH: CGFloat = 28

  var body: some View {
    let lanes = model.bundles
    let len = model.dayLength
    let ticks = Int((len / 3600).rounded())
    @Bindable var m = model
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Text("Timeline").font(.headline)
        Spacer()
        Picker("Zoom", selection: $m.timelineZoom) {
          Text("1×").tag(1.0)
          Text("2×").tag(2.0)
          Text("4×").tag(4.0)
        }.labelsHidden().pickerStyle(.segmented).frame(width: 150).help("Zoom the timeline, then scroll horizontally")
      }
      if lanes.isEmpty {
        ContentUnavailableView("No minute-long sessions", systemImage: "clock",
          description: Text("Turn on Show sub-minute sessions in the sidebar to see the short records."))
      } else {
      GeometryReader { geo in
      let w = max(1, geo.size.width - labelW) * model.timelineZoom
      ScrollView([.horizontal, .vertical]) {
        ZStack(alignment: .topLeading) {
          Canvas { ctx, size in
            for h in 0...ticks {
              let x = labelW + w * CGFloat(h) / CGFloat(ticks)
              let tickDate = Date(timeIntervalSinceReferenceDate: model.dayStart + Double(h) * 3600)
              let hour = Calendar.current.component(.hour, from: tickDate)
              var p = Path(); p.move(to: .init(x: x, y: axisH)); p.addLine(to: .init(x: x, y: size.height))
              ctx.stroke(p, with: .color(.primary.opacity(hour % 6 == 0 ? 0.28 : 0.12)), lineWidth: 1)
              if (hour % 3 == 0 || model.timelineZoom > 1) && h < ticks { ctx.draw(Text(String(format: "%02d", hour)).font(.caption2).foregroundStyle(.secondary), at: .init(x: x + 2, y: 8), anchor: .leading) }
            }
          }.frame(height: axisH + CGFloat(lanes.count) * laneH).allowsHitTesting(false)
          ForEach(Array(lanes.enumerated()), id: \.element) { i, b in
            AppIdentityLabel(bundleID: b).font(.callout).frame(width: labelW - 8, height: laneH, alignment: .leading)
              .offset(y: axisH + CGFloat(i) * laneH)
          }
          ForEach(model.visibleSessions) { s in
            if let lane = lanes.firstIndex(of: s.bundle) {
              Block(session: s, width: w, labelW: labelW, height: laneH - 8, dayLength: len)
                .offset(x: labelW + w * (s.start - model.dayStart) / len, y: axisH + CGFloat(lane) * laneH + 4)
            }
          }
        }.frame(width: labelW + w, height: axisH + CGFloat(lanes.count) * laneH, alignment: .topLeading)
      }
      }
      }
    }
    .accessibilityElement(children: .contain).accessibilityLabel("Timeline. Use the session list to edit with the keyboard.")
  }
}

struct Block: View {
  @Environment(EditorModel.self) private var model
  let session: Session, width: CGFloat, labelW: CGFloat, height: CGFloat, dayLength: Double
  @State private var base: Session?
  var body: some View {
    let selected = model.selection == session.id
    let bad = model.overlapping.contains(session.id)
    let bw = max(10, width * session.duration / dayLength)
    let secPerPt = dayLength / Double(width)
    RoundedRectangle(cornerRadius: 5)
      .fill(Color.accentColor.opacity(selected ? 0.9 : 0.55))
      .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(bad ? Color.orange : .clear, lineWidth: 2))
      .frame(width: bw, height: height)
      .overlay(alignment: .leading) { handle(.leading, secPerPt) }
      .overlay(alignment: .trailing) { handle(.trailing, secPerPt) }
      .contentShape(Rectangle())
      .help("\(AppIdentityResolver.shared.resolve(session.bundle).name)  \(clock(session.start))–\(clock(session.end))")
      .gesture(DragGesture(minimumDistance: 2).onChanged { v in
        if base == nil { model.checkpoint(); base = session; model.selection = session.id }
        guard let b = base else { return }
        let d = DayMath.snap(Double(v.translation.width) * secPerPt, step: 60)
        var n = b; n.start = b.start + d; n.end = b.end + d
        if n.start < model.dayStart { n.end += model.dayStart - n.start; n.start = model.dayStart }
        if n.end > model.dayEnd { n.start -= n.end - model.dayEnd; n.end = model.dayEnd }
        model.update(n)
      }.onEnded { _ in base = nil })
      .onTapGesture(count: 2) {
        let t = DayMath.snap((session.start + session.end) / 2); model.slice(session.id, at: t)
      }
      .onTapGesture { model.selection = session.id }
      .accessibilityLabel("\(AppIdentityResolver.shared.resolve(session.bundle).name), \(clock(session.start)) to \(clock(session.end))")
      .accessibilityAddTraits(selected ? .isSelected : [])
  }

  private func handle(_ edge: HorizontalAlignment, _ secPerPt: Double) -> some View {
    Color.white.opacity(0.001).frame(width: 8)
      .contentShape(Rectangle()).onHover { if $0 { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
      .gesture(DragGesture(minimumDistance: 1).onChanged { v in
        if base == nil { model.checkpoint(); base = session; model.selection = session.id }
        guard let b = base else { return }
        let d = DayMath.snap(Double(v.translation.width) * secPerPt, step: 60)
        var n = b
        if edge == .leading { n.start = min(b.start + d, b.end - 60) } else { n.end = max(b.end + d, b.start + 60) }
        model.update(n)
      }.onEnded { _ in base = nil })
  }
}
