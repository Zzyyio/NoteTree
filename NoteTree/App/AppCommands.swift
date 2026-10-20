import SwiftUI

@MainActor
struct AppCommands: Commands {
    @FocusedValue(\.workspaceStore) private var workspaceStore
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("command.newWindow") { openWindow(id: "workspace") }
                .keyboardShortcut("n", modifiers: [.command, .option])
            Button("fileAction.newMarkdown") { workspaceStore?.fileTree?.beginCreation(.markdown) }
                .keyboardShortcut("n", modifiers: .command)
                .disabled(workspaceStore?.fileTree == nil)
            Button("fileAction.newFolder") { workspaceStore?.fileTree?.beginCreation(.folder) }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(workspaceStore?.fileTree == nil)
            Button("command.openWorkspace") {
                Task { await workspaceStore?.chooseWorkspace() }
            }
                .keyboardShortcut("o", modifiers: .command)
        }

        CommandGroup(replacing: .saveItem) {
            Button("command.save") {
                Task { await workspaceStore?.saveCurrentDocument() }
            }
                .keyboardShortcut("s", modifiers: .command)
        }
        CommandGroup(after: .textEditing) {
            Button("sidebar.filter") { workspaceStore?.filterFocusRequest += 1 }
                .keyboardShortcut("f", modifiers: [.command, .option])
                .disabled(workspaceStore?.fileTree == nil)
        }
    }
}

struct WorkspaceStoreFocusKey: FocusedValueKey {
    typealias Value = WorkspaceStore
}

extension FocusedValues {
    var workspaceStore: WorkspaceStore? {
        get { self[WorkspaceStoreFocusKey.self] }
        set { self[WorkspaceStoreFocusKey.self] = newValue }
    }
}
