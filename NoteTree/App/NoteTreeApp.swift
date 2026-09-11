import SwiftUI

@main
@MainActor
struct NoteTreeApp: App {
    private let dependencies = DependencyContainer.makeDefault()

    var body: some Scene {
        WindowGroup {
            WorkspaceWindowView(dependencies: dependencies)
        }
        .defaultSize(width: 1_100, height: 720)
        .commands {
            AppCommands {
                Task {
                    await dependencies.workspaceStore.chooseWorkspace()
                }
            } saveMarkdown: {
                Task {
                    await dependencies.workspaceStore.saveCurrentMarkdown()
                }
            }
        }

        Settings {
            SettingsView(productInfo: dependencies.productInfo)
        }
    }
}
