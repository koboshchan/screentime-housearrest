import SwiftUI

@main
struct ScreenTimeEditorApp: App {
  @State private var model = EditorModel()
  var body: some Scene {
    WindowGroup("Surface") {
      ContentView().environment(model)
        .frame(minWidth: 980, minHeight: 620)
        .task {
          await model.bootstrap()
          if ReadCheck.requested { _ = try? ReadCheck.write(model) }
        }
    }
    .commands {
      CommandGroup(replacing: .undoRedo) {
        Button("Undo") { model.undo() }.keyboardShortcut("z").disabled(!model.canUndo || model.locked)
        Button("Redo") { model.redo() }.keyboardShortcut("z", modifiers: [.command, .shift]).disabled(!model.canRedo || model.locked)
      }
      CommandMenu("Day") {
        Button("Previous Day") { model.shiftDay(-1) }.keyboardShortcut(.leftArrow, modifiers: .command).disabled(model.locked)
        Button("Next Day") { model.shiftDay(1) }.keyboardShortcut(.rightArrow, modifiers: .command).disabled(model.locked)
        Button("Today") { model.goToday() }.keyboardShortcut("t").disabled(model.locked)
        Divider()
        Button("Apply Changes…") { model.confirmingApply = true }.keyboardShortcut("s").disabled(!model.canApply)
      }
    }
  }
}
