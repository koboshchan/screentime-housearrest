import SwiftUI
import STCore

struct ContentView: View {
  @Environment(EditorModel.self) private var model
  @State private var showingAdd = false

  var body: some View {
    @Bindable var m = model
    NavigationSplitView {
      SessionList().navigationSplitViewColumnWidth(min: 260, ideal: 300, max: 380)
    } detail: {
      DetailPane()
    }
    .toolbar {
      ToolbarItemGroup {
        Button { model.shiftDay(-1) } label: { Image(systemName: "chevron.left") }.help("Previous day").disabled(model.locked)
        DatePicker("Day", selection: Binding(get: { model.date }, set: { model.requestDay($0) }), displayedComponents: .date).labelsHidden().disabled(model.locked)
        Button { model.shiftDay(1) } label: { Image(systemName: "chevron.right") }.help("Next day").disabled(model.locked)
        Button("Today") { model.goToday() }.disabled(model.locked)
      }
      ToolbarItemGroup {
        Button { model.undo() } label: { Image(systemName: "arrow.uturn.backward") }.disabled(!model.canUndo || model.locked).help("Undo")
        Button { model.redo() } label: { Image(systemName: "arrow.uturn.forward") }.disabled(!model.canRedo || model.locked).help("Redo")
        Button("Add") { showingAdd = true }.disabled(model.loadError != nil || model.stale || model.locked)
      }
    }
    .sheet(isPresented: $showingAdd) { AddSheet() }
    .confirmationDialog("Discard unapplied changes?", isPresented: $m.confirmingDiscard) {
      Button("Discard Changes", role: .destructive) { model.confirmPendingDay() }
      Button("Keep Editing", role: .cancel) { model.cancelPendingDay() }
    } message: { Text("Switching days or reloading replaces your edits with what is on disk.") }
    .alert("Screen Time data changed since you loaded it", isPresented: $m.confirmingSourceChanged) {
      Button("Cancel", role: .cancel) { model.cancelSourceOverride() }
      Button("Reload") { Task { await model.reloadChangedSource() } }
      Button("Override", role: .destructive) { Task { await model.overrideChangedSource() } }
    } message: {
      Text("Reload to replace your edits with the current data, or override with your edits. Override makes a fresh verified backup of the current data before applying.")
    }
    .confirmationDialog("Apply changes to Screen Time?", isPresented: $m.confirmingApply) {
      Button("Back Up and Apply") { Task { await model.apply() } }
      Button("Cancel", role: .cancel) {}
    } message: { Text("A verified backup is made before anything is written.") }
  }
}

struct Header: View {
  @Environment(EditorModel.self) private var model
  var body: some View {
    HStack(alignment: .firstTextBaseline) {
      VStack(alignment: .leading, spacing: 2) {
        Text(model.date.formatted(.dateTime.weekday(.wide))).font(.subheadline).foregroundStyle(.secondary)
        Text(model.date.formatted(.dateTime.month(.wide).day().year())).font(.largeTitle.weight(.semibold))
      }
      Spacer()
      StatusLine()
    }.padding(.horizontal, 24).padding(.vertical, 16)
  }
}

struct StatusLine: View {
  @Environment(EditorModel.self) private var model
  var body: some View {
    VStack(alignment: .trailing, spacing: 2) {
      if let s = model.status {
        Text("macOS \(s.macOS) (\(s.build))").font(.callout)
        Text("SIP \(s.sip)").font(.caption).foregroundStyle(s.sip.lowercased().contains("disabled") ? Color.primary : Color.secondary)
          .help(s.sipDetails ?? "")
      } else {
        Text(model.statusError ?? "Checking system…").font(.callout).foregroundStyle(.secondary)
      }
    }
  }
}

struct Footer: View {
  @Environment(EditorModel.self) private var model
  var body: some View {
    HStack {
      if let msg = model.applyMessage { Text(msg).font(.callout).lineLimit(3) }
      else if let why = model.applyBlockedReason { Text(why).font(.callout).foregroundStyle(.secondary).lineLimit(3) }
      else if model.dirty { Text("Unapplied changes").font(.callout).foregroundStyle(.secondary) }
      Spacer()
      if model.applying { ProgressView().controlSize(.small) }
      Button("Discard") { model.discard() }.disabled(!model.dirty)
      Button("Apply…") { model.confirmingApply = true }.keyboardShortcut(.defaultAction).disabled(!model.canApply)
    }.padding(.horizontal, 24).padding(.vertical, 12)
  }
}

struct FDAPanel: View {
  @Environment(EditorModel.self) private var model
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Screen Time data is protected").font(.title2.weight(.semibold))
      Text("macOS denied this read. Allow access for this signed app in System Settings, then quit and reopen it.")
        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      Text("Privacy & Security › Full Disk Access").font(.callout.weight(.medium))
      Text("Use + to add this exact Screen Time Editor app and enable it. The app never asks for your password.").font(.callout)
      if let e = model.loadError {
        DisclosureGroup("Details") {
          Text(e).font(.caption.monospaced()).foregroundStyle(.primary).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
      }
      HStack {
        Button("Open Full Disk Access Settings") {
          if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") { NSWorkspace.shared.open(u) }
        }
        Button("Try Again") { Task { await model.refreshStatus(); await model.load() } }
      }
    }
    .frame(maxWidth: 480, alignment: .leading).padding(32).frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

struct PermissionView: View {
  @Environment(EditorModel.self) private var model
  var body: some View {
    ContentUnavailableView {
      Label("Full Disk Access needed", systemImage: "lock")
    } description: {
      Text("macOS blocked reading Screen Time data. Open System Settings, go to Privacy & Security, Full Disk Access, switch on Screen Time Editor, then quit and reopen the app. Nothing is shown until the real data can be read.")
    } actions: {
      Button("Open Full Disk Access Settings") {
        if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") { NSWorkspace.shared.open(u) }
      }
      Button("Try Again") { Task { await model.bootstrap() } }
    }
  }
}

/// The detail column, separate so the offscreen harness can render it without AppKit-backed split views.
struct DetailPane: View {
  @Environment(EditorModel.self) private var model
  var body: some View {
      VStack(alignment: .leading, spacing: 0) {
        Header()
        Divider()
        Group {
          if model.stale, let e = model.loadError {
            ContentUnavailableView("Draft is stale", systemImage: "exclamationmark.triangle", description: Text("Couldn't re-read Screen Time: \(e) Your edits are kept but can't be applied until a read succeeds."))
          } else if model.needsFullDiskAccess { FDAPanel()
          } else if model.permissionDenied {
            PermissionView()
          } else if let e = model.loadError { ContentUnavailableView("Can't read Screen Time", systemImage: "exclamationmark.triangle", description: Text(e)) }
          else if model.loading && model.sessions.isEmpty { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
          else if model.sessions.isEmpty { ContentUnavailableView("No sessions", systemImage: "clock", description: Text("Nothing recorded for this day. Use Add to create a session.")) }
          else { TimelineEditor().padding(24) }
        }
        if let w = model.warnings.first { Text(w).font(.footnote).foregroundStyle(.primary).padding(.horizontal, 24).padding(.bottom, 8) }
        Divider()
        Footer()
      }
  }
}
