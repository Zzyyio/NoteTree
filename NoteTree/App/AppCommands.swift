import SwiftUI

@MainActor
struct AppCommands: Commands {
    let openWorkspace: () -> Void

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("command.openWorkspace", action: openWorkspace)
                .keyboardShortcut("o", modifiers: .command)
        }
    }
}

