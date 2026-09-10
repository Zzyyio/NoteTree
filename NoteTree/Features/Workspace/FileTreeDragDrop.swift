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
        guard fileTree.canAcceptDrop(on: destination) else {
            return false
        }

        guard let provider = info.itemProviders(for: [FileTreeDragDrop.contentType]).first else {
            return false
        }
        provider.loadDataRepresentation(forTypeIdentifier: FileTreeDragDrop.contentType.identifier) { data, _ in
            guard let data,
                  let tokenString = String(data: data, encoding: .utf8),
                  let token = UUID(uuidString: tokenString) else {
                return
            }
            Task { @MainActor in
                await fileTree.completeDrop(with: token, on: destination)
            }
        }
        return true
    }
}
