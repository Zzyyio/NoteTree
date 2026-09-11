import SwiftUI
import UniformTypeIdentifiers

enum FileTreeDragDrop {
    static let contentType = UTType.data

    @MainActor
    static func provider(for node: FileNode, fileTree: FileTreeStore) -> NSItemProvider {
        let token = fileTree.beginDragging(node)

        let provider = NSItemProvider()
        provider.registerDataRepresentation(
            forTypeIdentifier: contentType.identifier,
            visibility: .ownProcess
        ) { completion in
            completion(Data(token.uuidString.utf8), nil)
            return nil
        }
        return provider
    }
}

@MainActor
struct FileTreeDropDelegate: DropDelegate {
    let fileTree: FileTreeStore
    let destination: FileNode?

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [FileTreeDragDrop.contentType.identifier])
            && fileTree.canAcceptDrop(on: destination)
    }

    func dropEntered(info: DropInfo) {
        fileTree.updateDropTarget(destination)
    }

    func dropExited(info: DropInfo) {
        fileTree.clearDropTarget()
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        fileTree.canAcceptDrop(on: destination) ? DropProposal(operation: .move) : DropProposal(operation: .forbidden)
    }

    func performDrop(info: DropInfo) -> Bool {
        // The active drag token is already held by FileTreeStore. Starting the optimistic
        // move here, before returning from the drop callback, removes the visible gap that
        // waiting for NSItemProvider's asynchronous data loader creates.
        guard let token = fileTree.beginDrop(on: destination) else {
            return false
        }

        Task { @MainActor in
            await fileTree.finishDrop(with: token)
        }
        return true
    }
}
