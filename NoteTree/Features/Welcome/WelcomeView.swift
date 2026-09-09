import SwiftUI

@MainActor
struct WelcomeView: View {
    let openWorkspace: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("welcome.title", systemImage: "note.text")
                .accessibilityIdentifier("welcome.title")
        } description: {
            Text("welcome.description")
        } actions: {
            Button("welcome.openWorkspace", action: openWorkspace)
                .keyboardShortcut("o", modifiers: .command)
                .accessibilityIdentifier("welcome.openWorkspace")
        }
        .accessibilityIdentifier("welcome.screen")
    }
}

