import SwiftUI

@MainActor
struct WorkspaceWindowView: View {
    let lifecycle: ApplicationLifecycle
    @State private var dependencies = DependencyContainer.makeDefault()
    @AppStorage("settings.appearance") private var appearance = "system"
    @Environment(\.scenePhase) private var scenePhase
    @SceneStorage("window.workspaceID") private var restoredWorkspaceID = ""
    @SceneStorage("window.selectedPath") private var restoredPath = ""

    var body: some View {
        NavigationSplitView {
            WorkspaceSidebar(workspaceStore: dependencies.workspaceStore)
            .navigationSplitViewColumnWidth(min: 200, ideal: 260, max: 420)
        } detail: {
            WorkspaceDetailView(workspaceStore: dependencies.workspaceStore)
        }
        .frame(minWidth: 820, minHeight: 560)
        .preferredColorScheme(appearance == "light" ? .light : appearance == "dark" ? .dark : nil)
        .focusedSceneValue(\.workspaceStore, dependencies.workspaceStore)
        .background(WindowCloseGuard(store: dependencies.workspaceStore))
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button("navigation.back", systemImage: "chevron.left") {
                    dependencies.workspaceStore.fileTree?.navigateHistory(back: true)
                }.keyboardShortcut("[", modifiers: .command)
                    .disabled(dependencies.workspaceStore.fileTree?.backHistory.isEmpty != false)
                Button("navigation.forward", systemImage: "chevron.right") {
                    dependencies.workspaceStore.fileTree?.navigateHistory(back: false)
                }.keyboardShortcut("]", modifiers: .command)
                    .disabled(dependencies.workspaceStore.fileTree?.forwardHistory.isEmpty != false)
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active {
                Task { _ = await dependencies.workspaceStore.flushCurrentMarkdown() }
            }
        }
        .task {
            lifecycle.register(dependencies.workspaceStore)
            let selectedPath = restoredPath
            await dependencies.workspaceStore.restoreMostRecentWorkspace(preferredID: restoredWorkspaceID)
            await dependencies.workspaceStore.fileTree?.restorePath(selectedPath)
        }
        .onChange(of: dependencies.workspaceStore.currentWorkspace?.id) { _, id in
            restoredWorkspaceID = id?.rawValue.uuidString ?? ""
        }
        .onChange(of: dependencies.workspaceStore.fileTree?.selectedNodeID) { _, id in
            restoredPath = id?.relativePath ?? ""
        }
    }
}
