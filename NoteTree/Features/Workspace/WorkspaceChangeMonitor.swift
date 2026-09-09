import Foundation

// NSFileCoordinator calls this presenter from its own serial queues, so the
// presenter itself must remain nonisolated and explicitly hop to MainActor.
final class WorkspaceChangeMonitor: NSObject, NSFilePresenter {
    let presentedItemURL: URL?
    let presentedItemOperationQueue: OperationQueue

    private let onChange: @MainActor @Sendable () -> Void
    private let debounceInterval: TimeInterval
    private let debounceQueue = DispatchQueue(
        label: "com.example.NoteTree.workspace-change-monitor",
        qos: .utility
    )
    private let lock = NSLock()
    private var pendingRefresh: DispatchWorkItem?
    private var isStopped = false

    init(
        rootURL: URL,
        debounceInterval: TimeInterval = 0.35,
        onChange: @escaping @MainActor @Sendable () -> Void
    ) {
        presentedItemURL = rootURL
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .utility
        presentedItemOperationQueue = queue
        self.debounceInterval = debounceInterval
        self.onChange = onChange
        super.init()
        NSFileCoordinator.addFilePresenter(self)
    }

    func stop() {
        lock.lock()
        isStopped = true
        pendingRefresh?.cancel()
        pendingRefresh = nil
        lock.unlock()
        NSFileCoordinator.removeFilePresenter(self)
    }

    func presentedItemDidChange() {
        scheduleRefresh()
    }

    func presentedSubitemDidChange(at url: URL) {
        scheduleRefresh()
    }

    func presentedSubitemDidAppear(at url: URL) {
        scheduleRefresh()
    }

    func presentedSubitemDidDisappear(at url: URL) {
        scheduleRefresh()
    }

    private func scheduleRefresh() {
        lock.lock()
        guard !isStopped else {
            lock.unlock()
            return
        }

        pendingRefresh?.cancel()
        let onChange = onChange
        let refresh = DispatchWorkItem {
            Task { @MainActor in
                onChange()
            }
        }
        pendingRefresh = refresh
        lock.unlock()

        debounceQueue.asyncAfter(
            deadline: .now() + debounceInterval,
            execute: refresh
        )
    }
}
