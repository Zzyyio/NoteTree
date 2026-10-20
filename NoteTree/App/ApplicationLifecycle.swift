import AppKit

@MainActor
final class ApplicationLifecycle: NSObject, NSApplicationDelegate {
    private let workspaces = NSHashTable<WorkspaceStore>.weakObjects()
    private var terminating = false

    func register(_ store: WorkspaceStore) { workspaces.add(store) }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminating else { return .terminateLater }
        terminating = true
        Task {
            for store in workspaces.allObjects {
                guard await store.prepareForNavigation() else {
                    terminating = false
                    sender.reply(toApplicationShouldTerminate: false)
                    return
                }
            }
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
