import Foundation
import Observation
import OSLog

enum WorkspaceState: Equatable {
    case welcome
    case loading
    case ready
    case needsReauthorization(RecentWorkspace)
    case failure(WorkspaceError)
}

@MainActor
@Observable
final class WorkspaceStore {
    private let bookmarkStore: WorkspaceBookmarkStore
    private let picker: any WorkspacePicking
    private let resourceAccess: any SecurityScopedResourceAccessing
    private let fileSystemFactory: @Sendable (Workspace) -> any WorkspaceFileSystem
    private let logger: Logger

    private var accessedWorkspaceURL: URL?
    private var didAttemptRestoration = false
    private var changeMonitor: WorkspaceChangeMonitor?

    private(set) var currentWorkspace: Workspace?
    private(set) var fileTree: FileTreeStore?
    private(set) var recents: [RecentWorkspace] = []
    private(set) var state: WorkspaceState = .welcome

    init(
        bookmarkStore: WorkspaceBookmarkStore = WorkspaceBookmarkStore(),
        picker: any WorkspacePicking = SystemWorkspacePicker(),
        resourceAccess: any SecurityScopedResourceAccessing = SystemSecurityScopedResourceAccess(),
        fileSystemFactory: @escaping @Sendable (Workspace) -> any WorkspaceFileSystem = { workspace in
            LocalWorkspaceFileSystem(workspace: workspace)
        },
        logger: Logger = AppLog.workspace
    ) {
        self.bookmarkStore = bookmarkStore
        self.picker = picker
        self.resourceAccess = resourceAccess
        self.fileSystemFactory = fileSystemFactory
        self.logger = logger
    }

    func restoreMostRecentWorkspace() async {
        guard !didAttemptRestoration else {
            return
        }
        didAttemptRestoration = true
        recents = await bookmarkStore.recents

        switch await bookmarkStore.restoreMostRecent() {
        case .none:
            state = .welcome
        case .workspace(let workspace):
            await activate(workspace)
        case .needsReauthorization(let recentWorkspace):
            state = .needsReauthorization(recentWorkspace)
        }
    }

    func chooseWorkspace() async {
        guard let url = picker.pickWorkspace() else {
            return
        }

        do {
            let workspace = try await bookmarkStore.saveWorkspace(at: url)
            recents = await bookmarkStore.recents
            await activate(workspace)
        } catch let error as WorkspaceError {
            state = .failure(error)
        } catch {
            logger.error("Could not save a workspace bookmark")
            state = .failure(.bookmarkUnavailable)
        }
    }

    func reauthorize(_ recentWorkspace: RecentWorkspace) async {
        guard let selectedURL = picker.pickWorkspace() else {
            return
        }

        do {
            let workspace = try await bookmarkStore.saveWorkspace(at: selectedURL)
            recents = await bookmarkStore.recents
            await activate(workspace)
        } catch let error as WorkspaceError {
            state = .failure(error)
        } catch {
            logger.error("Could not replace a workspace bookmark")
            state = .failure(.bookmarkUnavailable)
        }
    }

    func refreshFileTree() async {
        await fileTree?.refresh()
    }

    func openRecent(_ recentWorkspace: RecentWorkspace) async {
        state = .loading
        switch await bookmarkStore.resolve(recentWorkspace) {
        case .workspace(let workspace):
            await activate(workspace)
        case .needsReauthorization(let unavailableWorkspace):
            releaseCurrentWorkspaceAccess()
            fileTree = nil
            currentWorkspace = nil
            state = .needsReauthorization(unavailableWorkspace)
        case .none:
            releaseCurrentWorkspaceAccess()
            fileTree = nil
            currentWorkspace = nil
            state = .welcome
        }
    }

    private func activate(_ workspace: Workspace) async {
        releaseCurrentWorkspaceAccess()
        state = .loading

        guard resourceAccess.startAccessing(workspace.rootURL) else {
            state = .needsReauthorization(RecentWorkspace(workspace: workspace))
            return
        }
        accessedWorkspaceURL = workspace.rootURL

        let fileTree = FileTreeStore(workspace: workspace, fileSystem: fileSystemFactory(workspace))
        currentWorkspace = workspace
        self.fileTree = fileTree

        do {
            try await fileTree.loadRoot()
            changeMonitor = WorkspaceChangeMonitor(rootURL: workspace.rootURL) { [weak self] in
                self?.refreshFileTreeAfterExternalChange()
            }
            state = .ready
        } catch let error as WorkspaceError {
            releaseCurrentWorkspaceAccess()
            self.fileTree = nil
            currentWorkspace = nil
            state = .failure(error)
        } catch {
            releaseCurrentWorkspaceAccess()
            self.fileTree = nil
            currentWorkspace = nil
            state = .failure(.readFailed)
        }
    }

    private func releaseCurrentWorkspaceAccess() {
        changeMonitor?.stop()
        changeMonitor = nil
        guard let accessedWorkspaceURL else {
            return
        }
        resourceAccess.stopAccessing(accessedWorkspaceURL)
        self.accessedWorkspaceURL = nil
    }

    private func refreshFileTreeAfterExternalChange() {
        guard let fileTree else {
            return
        }
        Task {
            await fileTree.refresh()
        }
    }
}
