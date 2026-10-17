import SwiftUI

struct ContentView: View {
    @StateObject private var store = Store()
    @State private var showingAdd = false

    var body: some View {
        NavigationView {
            List {
                Section {
                    AccessStatusView(summary: store.capability.summary, note: store.loadNote, available: store.capability.canApply)
                }
                if !store.sessions.isEmpty {
                    Section(header: Text("Timeline")) {
                        TimelineView(store: store).frame(height: 230).listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
                    }
                    Section(header: Text("Sessions"), footer: Text("Total \(formatDuration(SessionRules.rawTotal(store.sessions))), screen on \(formatDuration(SessionRules.screenOnTotal(store.sessions)))")) {
                        ForEach(store.sessions) { s in
                            NavigationLink(destination: SessionEditor(store: store, session: s)) {
                                HStack { AppLabel(bundleID: s.bundleID); Spacer(); Text("\(formatHM(s.start)) to \(formatHM(s.end))").foregroundColor(.secondary).monospacedDigit() }
                            }
                        }.onDelete { for i in $0 { store.delete(store.sessions[i].id) } }
                    }
                }
                if let b = store.blocked { Section { Text(b).foregroundColor(.orange) } }
                if let e = store.error { Section { Text(e).foregroundColor(.red) } }
                if let m = store.status { Section { Text(m) } }
                if !store.warnings.isEmpty {
                    Section(header: Text("Notes")) { ForEach(store.warnings, id: \.self) { Text($0).font(.footnote).foregroundColor(.secondary) } }
                }
                Section {
                    Button("Reload from device") { store.reload() }.disabled(store.busy || !store.capability.canApply)
                    Button("Apply") { store.apply() }.disabled(!store.canApply)
                }
            }
            .navigationTitle("Usage")
            .toolbar { Button { showingAdd = true } label: { Image(systemName: "plus") } }
            .sheet(isPresented: $showingAdd) { NavigationStack { SessionEditor(store: store, session: nil) } }
        }
        .navigationViewStyle(StackNavigationViewStyle())
        .alert("Screen Time changed", isPresented: $store.showStale) {
            Button("Cancel", role: .cancel) {}
            Button("Reload") { store.reload() }
            Button("Override", role: .destructive) { store.apply(override: true) }
        } message: {
            Text("Usage on this device changed after you loaded it. Cancel keeps your edits unsaved. Reload discards them and reads the current usage. Override writes your edits over the newer changes, after a fresh verified backup of the current data.")
        }
        .onAppear { store.refreshCapability() }
    }
}

struct SessionEditor: View {
    @ObservedObject var store: Store
    var session: UsageSession?
    @Environment(\.presentationMode) private var presentation
    @State private var bundleID = ""
    @State private var showingPicker = false
    @State private var start = Date(timeIntervalSinceReferenceDate: 0)
    @State private var end = Date(timeIntervalSinceReferenceDate: 3600)

    private func secs(_ d: Date) -> TimeInterval {
        let c = Calendar.current.dateComponents([.hour, .minute], from: d)
        return TimeInterval((c.hour ?? 0) * 3600 + (c.minute ?? 0) * 60)
    }
    private func date(_ t: TimeInterval) -> Date { Calendar.current.startOfDay(for: Date()).addingTimeInterval(t) }

    var body: some View {
        Form {
            Section(header: Text("App")) {
                Button { showingPicker = true } label: {
                    HStack {
                        if bundleID.isEmpty { Text("Choose app") }
                        else { AppLabel(bundleID: bundleID) }
                        Spacer()
                        Image(systemName: "chevron.right").foregroundStyle(.secondary)
                    }
                }
            }
            Section {
                DatePicker("Start", selection: $start, displayedComponents: .hourAndMinute)
                DatePicker("End", selection: $end, displayedComponents: .hourAndMinute)
            }
            if let e = store.error { Text(e).foregroundColor(.red) }
        }
        .sheet(isPresented: $showingPicker) { InstalledAppPicker(selection: $bundleID) }
        .navigationBarTitle(session == nil ? "New session" : "Session", displayMode: .inline)
        .navigationBarItems(trailing: Button("Save") {
            if var s = session { s.bundleID = bundleID; s.start = secs(start); s.end = secs(end); store.update(s) }
            else { store.add(bundleID: bundleID, start: secs(start), end: secs(end)) }
            if store.error == nil { presentation.wrappedValue.dismiss() }
        }.disabled(bundleID.isEmpty))
        .onAppear {
            store.error = nil
            if let s = session { bundleID = s.bundleID; start = date(s.start); end = date(s.end) }
            else { start = date(9 * 3600); end = date(9 * 3600 + 1800) }
        }
    }
}

/// 24 hour bar timeline. Tap a bar to select; drag its edges or body to move/resize, snapping to minutes.
struct TimelineView: View {
    @ObservedObject var store: Store
    var body: some View {
        let lanes = laneAssignments(store.sessions)
        let laneCount = (lanes.values.max() ?? 0) + 1
        ScrollView([.horizontal, .vertical]) {
            ZStack(alignment: .topLeading) {
                ForEach([0, 3, 6, 9, 12, 15, 18, 21, 24], id: \.self) { h in
                    Rectangle().fill(Color.secondary.opacity(0.18))
                        .frame(width: 1, height: CGFloat(laneCount) * 44)
                        .offset(x: 60 * CGFloat(h), y: 24)
                    Text("\(h):00").font(.caption2).foregroundColor(.secondary)
                        .offset(x: min(60 * CGFloat(h) + 2, 1408), y: 0)
                }
                ForEach(store.sessions) { s in
                    Bar(store: store, s: s, width: 1440, lane: lanes[s.id] ?? 0)
                }
            }
            .frame(width: 1440, height: max(190, CGFloat(laneCount) * 44 + 24), alignment: .topLeading)
        }
        .defaultScrollAnchor(.topLeading)
    }
    func laneAssignments(_ ss: [UsageSession]) -> [UUID: Int] {
        var ends: [TimeInterval] = []; var out: [UUID: Int] = [:]
        for s in ss.sorted(by: { $0.start < $1.start }) {
            if let i = ends.firstIndex(where: { $0 <= s.start }) { ends[i] = s.end; out[s.id] = i }
            else { ends.append(s.end); out[s.id] = ends.count - 1 }
        }
        return out
    }
}

struct Bar: View {
    @ObservedObject var store: Store
    let s: UsageSession; let width: CGFloat; let lane: Int
    private var sessionColor: Color {
        let palette: [Color] = [.blue, .teal, .indigo, .orange, .pink, .green]
        let index = s.bundleID.utf8.reduce(0) { ($0 * 31 + Int($1)) % palette.count }
        return palette[index]
    }
    @State private var origin: UsageSession?
    private enum Mode { case move, left, right }
    @State private var mode: Mode = .move
    var body: some View {
        let x = width * CGFloat(s.start / 86_400), w = max(width * CGFloat(s.duration / 86_400), 12)
        RoundedRectangle(cornerRadius: 6)
            .fill(sessionColor)
            .overlay(alignment: .leading) {
                if w > 60 {
                    Text(AppIdentity.shared.name(s.bundleID)).font(.caption2.weight(.medium))
                        .foregroundStyle(.white).lineLimit(1).padding(.horizontal, 5)
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(store.selected == s.id ? Color.primary : .clear, lineWidth: 2))
            .frame(width: w, height: 36)
            .accessibilityLabel("\(AppIdentity.shared.name(s.bundleID)), \(formatHM(s.start)) to \(formatHM(s.end))")
            .offset(x: x, y: CGFloat(lane) * 44 + 24)
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { v in
                    if origin == nil {
                        origin = s; store.selected = s.id
                        let rel = v.startLocation.x - x
                        mode = rel < 10 ? .left : (rel > w - 10 ? .right : .move)
                    }
                    guard let o = origin else { return }
                    let dt = TimeInterval(v.translation.width / width) * 86_400
                    var n = o
                    switch mode {
                    case .move: n.start = o.start + dt; n.end = o.end + dt
                    case .left: n.start = o.start + dt
                    case .right: n.end = o.end + dt
                    }
                    n.start = SessionRules.snap(n.start); n.end = SessionRules.snap(n.end)
                    if (try? SessionRules.validate(n)) != nil, let i = store.sessions.firstIndex(where: { $0.id == s.id }) { store.sessions[i] = n }
                }
                .onEnded { _ in origin = nil })
    }
}
