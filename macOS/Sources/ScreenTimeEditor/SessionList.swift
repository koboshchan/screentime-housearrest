import SwiftUI
import STCore

func clock(_ t: Double) -> String {
  Date(timeIntervalSinceReferenceDate: t).formatted(.dateTime.hour().minute())
}

struct SessionList: View {
  @Environment(EditorModel.self) private var model
  var body: some View {
    @Bindable var m = model
    List(selection: $m.selection) {
      ForEach(model.sessions) { s in
        VStack(alignment: .leading, spacing: 2) {
          Text(s.bundle).lineLimit(1)
          Text("\(clock(s.start)) – \(clock(s.end))  ·  \(DayMath.format(s.duration))")
            .font(.caption).foregroundStyle(.secondary).monospacedDigit()
        }
        .tag(s.id)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(s.bundle), \(clock(s.start)) to \(clock(s.end))")
        .contextMenu { Button("Delete", role: .destructive) { model.delete(s.id) } }
      }
    }
    .onDeleteCommand { if let id = model.selection { model.delete(id) } }
    .safeAreaInset(edge: .bottom) {
      if let id = model.selection, let s = model.sessions.first(where: { $0.id == id }) { Inspector(session: s).id(s.id) }
    }
    .disabled(model.locked)
    .navigationTitle("Sessions")
  }
}

struct Inspector: View {
  @Environment(EditorModel.self) private var model
  @State var session: Session
  init(session: Session) { _session = State(initialValue: session) }
  var body: some View {
    let startB = Binding(get: { Date(timeIntervalSinceReferenceDate: session.start) }, set: { session.start = $0.timeIntervalSinceReferenceDate })
    let endB = Binding(get: { Date(timeIntervalSinceReferenceDate: session.end) }, set: { session.end = $0.timeIntervalSinceReferenceDate })
    Form {
      TextField("App", text: $session.bundle)
      DatePicker("Start", selection: startB, displayedComponents: .hourAndMinute)
      DatePicker("End", selection: endB, displayedComponents: .hourAndMinute)
      HStack {
        Button("Split at Midpoint") { model.slice(session.id, at: DayMath.snap((session.start + session.end) / 2)) }
        Spacer()
        Button("Delete", role: .destructive) { model.delete(session.id) }
        Button("Save") { model.commitEdit(session) }
      }
    }
    .padding(12).background(.bar)
    .onChange(of: model.sessions) { _, new in if let s = new.first(where: { $0.id == session.id }) { session = s } }
  }
}

struct AddSheet: View {
  @Environment(EditorModel.self) private var model
  @Environment(\.dismiss) private var dismiss
  @State private var bundle = ""
  @State private var start = Date()
  @State private var minutes = 15
  var body: some View {
    Form {
      TextField("App bundle ID", text: $bundle, prompt: Text("com.apple.Safari"))
      DatePicker("Start", selection: $start)
      Stepper("Length \(minutes) min", value: $minutes, in: 1...720, step: 5)
    }
    .formStyle(.grouped).frame(width: 380).padding(.bottom, 8)
    .toolbar {
      ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
      ToolbarItem(placement: .confirmationAction) {
        Button("Add") {
          let s = DayMath.snap(start.timeIntervalSinceReferenceDate)
          model.add(bundle: bundle.trimmingCharacters(in: .whitespaces), start: s, end: s + Double(minutes) * 60); dismiss()
        }.disabled(bundle.trimmingCharacters(in: .whitespaces).isEmpty)
      }
    }
  }
}
