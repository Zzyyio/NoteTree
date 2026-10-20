import SwiftUI

@main
@MainActor
struct NoteTreeApp: App {
    @NSApplicationDelegateAdaptor(ApplicationLifecycle.self) private var lifecycle
    var body: some Scene {
        WindowGroup(id: "workspace") {
            WorkspaceWindowView(lifecycle: lifecycle)
        }
        .defaultSize(width: 1_100, height: 720)
        .commands {
            AppCommands()
        }

        Settings {
            SettingsView(productInfo: .noteTree)
        }
    }
}
