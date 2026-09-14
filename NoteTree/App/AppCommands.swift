import SwiftUI

@MainActor
struct AppCommands: Commands {
    let openWorkspace: () -> Void
    let saveCurrentDocument: () -> Void

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("command.openWorkspace", action: openWorkspace)
                .keyboardShortcut("o", modifiers: .command)
        }

        CommandGroup(replacing: .saveItem) {
            Button("command.save", action: saveCurrentDocument)
                .keyboardShortcut("s", modifiers: .command)
        }
    }
}
