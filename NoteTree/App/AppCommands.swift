import SwiftUI

@MainActor
struct AppCommands: Commands {
    let openWorkspace: () -> Void
    let saveMarkdown: () -> Void

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("command.openWorkspace", action: openWorkspace)
                .keyboardShortcut("o", modifiers: .command)
        }

        CommandGroup(replacing: .saveItem) {
            Button("markdown.save", action: saveMarkdown)
                .keyboardShortcut("s", modifiers: .command)
        }
    }
}
