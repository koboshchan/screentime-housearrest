import SwiftUI

struct ContentView: View {
    @StateObject private var store = Store()
    @State private var showingAdd = false

    var body: some View {
        NavigationView {
            List {
                Section {
                    Text(store.capability.summary).foregroundColor(.secondary)
                    if store.sessions.isEmpty { Text(store.loadNote).font(.footnote).foregroundColor(.secondary) }
                }
                if !store.sessions.isEmpty {
                    Section(header: Text("Timeline")) {
                        TimelineView(store: store).frame(height: 120).listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
                    }
                    Section(header: Text("Sessions"), footer: Text("Total \(formatDuration(SessionRules.rawTotal(store.sessions))), screen on \(formatDuration(SessionRules.screenOnTotal(store.sessions)))")) {
                        ForEach(store.sessions) { s in
                            NavigationLink(destination: SessionEditor(store: store, session: s)) {
                                HStack { Text(s.bundleID).lineLimit(1); Spacer(); Text("\(formatHM(s.start)) to \(formatHM(s.end))").foregroundColor(.secondary).monospacedDigit() }
                            }
                        }.onDelete { for i in $0 { store.delete(store.sessions[i].id) } }
                    }
                }
                if let e = store.error { Section { Text(e).foregroundColor(.red) } }
                Section {
                    Button("Apply") { store.apply() }.disabled(!store.capability.canApply || store.sessions.isEmpty)
                }
            }
            .navigationTitle("Usage")
            .toolbar { Button { showingAdd = true } label: { Image(systemName: "plus") } }
            .sheet(isPresented: $showingAdd) { SessionEditor(store: store, session: nil) }
        }
        .navigationViewStyle(StackNavigationViewStyle())
        .onAppear { store.refreshCapability() }
    }
}

struct SessionEditor: View {
    @ObservedObject var store: Store
    var session: UsageSession?
    @Environment(\.presentationMode) private var presentation
    @State private var bundleID = ""
    @State private var start = Date(timeIntervalSinceReferenceDate: 0)
    @State private var end = Date(timeIntervalSinceReferenceDate: 3600)

    private func secs(_ d: Date) -> TimeInterval {
        let c = Calendar.current.dateComponents([.hour, .minute], from: d)
        return TimeInterval((c.hour ?? 0) * 3600 + (c.minute ?? 0) * 60)
    }
    private func date(_ t: TimeInterval) -> Date { Calendar.current.startOfDay(for: Date()).addingTimeInterval(t) }

    var body: some View {
        Form {
            Section(header: Text("App bundle identifier")) {
                TextField("com.apple.mobilesafari", text: $bundleID).autocapitalization(.none).disableAutocorrection(true)
            }
            Section {
                DatePicker("Start", selection: $start, displayedComponents: .hourAndMinute)
                DatePicker("End", selection: $end, displayedComponents: .hourAndMinute)
            }
            if let e = store.error { Text(e).foregroundColor(.red) }
        }
        .navigationBarTitle(session == nil ? "New session" : "Session", displayMode: .inline)
        .navigationBarItems(trailing: Button("Save") {
            if var s = session { s.bundleID = bundleID; s.start = secs(start); s.end = secs(end); store.update(s) }
            else { store.add(bundleID: bundleID, start: secs(start), end: secs(end)) }
            if store.error == nil { presentation.wrappedValue.dismiss() }
        })
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
        GeometryReader { geo in
            let w = geo.size.width
            let lanes = laneAssignments(store.sessions)
            ZStack(alignment: .topLeading) {
                ForEach([0, 6, 12, 18, 24], id: \.self) { h in
                    Rectangle().fill(Color.secondary.opacity(0.25)).frame(width: 1).offset(x: w * CGFloat(h) / 24)
                    Text("\(h)").font(.caption2).foregroundColor(.secondary).offset(x: min(w * CGFloat(h) / 24 + 2, w - 14), y: 100)
                }
                ForEach(store.sessions) { s in
                    Bar(store: store, s: s, width: w, lane: lanes[s.id] ?? 0)
                }
            }
        }
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
    @State private var origin: UsageSession?
    private enum Mode { case move, left, right }
    @State private var mode: Mode = .move
    var body: some View {
        let x = width * CGFloat(s.start / 86_400), w = max(width * CGFloat(s.duration / 86_400), 6)
        RoundedRectangle(cornerRadius: 3)
            .fill(store.selected == s.id ? Color.accentColor : Color.accentColor.opacity(0.55))
            .frame(width: w, height: 22)
            .offset(x: x, y: CGFloat(lane) * 26)
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
