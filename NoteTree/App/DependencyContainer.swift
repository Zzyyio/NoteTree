import Foundation

@MainActor
final class DependencyContainer {
    let productInfo: ProductInfo
    let workspaceStore: WorkspaceStore

    static func makeDefault() -> DependencyContainer {
        let isUITesting = ProcessInfo.processInfo.environment["NOTE_TREE_UI_TESTING"] == "1"
        return DependencyContainer(
            productInfo: .noteTree,
            workspaceStore: WorkspaceStore(
                bookmarkStore: isUITesting
                    ? WorkspaceBookmarkStore(defaultsSuiteName: "NoteTree.UITesting.\(UUID().uuidString)")
                    : WorkspaceBookmarkStore()
            )
        )
    }

    init(productInfo: ProductInfo, workspaceStore: WorkspaceStore) {
        self.productInfo = productInfo
        self.workspaceStore = workspaceStore
    }
}
