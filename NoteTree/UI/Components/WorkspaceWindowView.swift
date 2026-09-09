import SwiftUI

@MainActor
struct WorkspaceWindowView: View {
    let dependencies: DependencyContainer

    var body: some View {
        NavigationSplitView {
            WorkspaceSidebar(workspaceStore: dependencies.workspaceStore)
            .navigationSplitViewColumnWidth(min: 200, ideal: 260, max: 420)
        } detail: {
            WorkspaceDetailView(workspaceStore: dependencies.workspaceStore)
        }
        .frame(minWidth: 820, minHeight: 560)
        .task {
            await dependencies.workspaceStore.restoreMostRecentWorkspace()
        }
    }
}
