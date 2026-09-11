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
    private var workspaceFileSystem: (any WorkspaceFileSystem)?
    private let markdownDraftStore: any MarkdownDraftStoring

    private(set) var currentWorkspace: Workspace?
    private(set) var fileTree: FileTreeStore?
    private(set) var markdownSession: MarkdownDocumentSession?
    private(set) var recents: [RecentWorkspace] = []
    private(set) var state: WorkspaceState = .welcome

    init(
        bookmarkStore: WorkspaceBookmarkStore = WorkspaceBookmarkStore(),
        picker: any WorkspacePicking = SystemWorkspacePicker(),
        resourceAccess: any SecurityScopedResourceAccessing = SystemSecurityScopedResourceAccess(),
        fileSystemFactory: @escaping @Sendable (Workspace) -> any WorkspaceFileSystem = { workspace in
            LocalWorkspaceFileSystem(workspace: workspace)
        },
        markdownDraftStore: any MarkdownDraftStoring = MarkdownDraftStore(),
        logger: Logger = AppLog.workspace
    ) {
        self.bookmarkStore = bookmarkStore
        self.picker = picker
        self.resourceAccess = resourceAccess
        self.fileSystemFactory = fileSystemFactory
        self.markdownDraftStore = markdownDraftStore
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

    func openMarkdown(_ node: FileNode) async {
        guard node.kind == .markdown,
              let workspace = currentWorkspace,
              let workspaceFileSystem else {
            return
        }
        guard markdownSession?.url != node.url else {
            return
        }
        guard await markdownSession?.prepareForFileSwitch() ?? true else {
            return
        }

        let session = MarkdownDocumentSession(
            workspace: workspace,
            url: node.url,
            fileSystem: workspaceFileSystem,
            draftStore: markdownDraftStore
        )
        markdownSession = session
        await session.load()
    }

    func saveCurrentMarkdown() async {
        _ = await markdownSession?.saveNow()
    }

    func flushCurrentMarkdown() async -> Bool {
        await markdownSession?.prepareForFileSwitch() ?? true
    }

    func openRecent(_ recentWorkspace: RecentWorkspace) async {
        state = .loading
        switch await bookmarkStore.resolve(recentWorkspace) {
        case .workspace(let workspace):
            await activate(workspace)
        case .needsReauthorization(let unavailableWorkspace):
            releaseCurrentWorkspaceAccess()
            fileTree = nil
            markdownSession = nil
            self.workspaceFileSystem = nil
            currentWorkspace = nil
            state = .needsReauthorization(unavailableWorkspace)
        case .none:
            releaseCurrentWorkspaceAccess()
            fileTree = nil
            markdownSession = nil
            self.workspaceFileSystem = nil
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

        let workspaceFileSystem = fileSystemFactory(workspace)
        let fileTree = FileTreeStore(workspace: workspace, fileSystem: workspaceFileSystem)
        currentWorkspace = workspace
        self.workspaceFileSystem = workspaceFileSystem
        self.fileTree = fileTree
        markdownSession = nil

        do {
            try await fileTree.loadRoot()
            changeMonitor = WorkspaceChangeMonitor(rootURL: workspace.rootURL) { [weak self] in
                self?.refreshFileTreeAfterExternalChange()
            }
            state = .ready
        } catch let error as WorkspaceError {
            releaseCurrentWorkspaceAccess()
            self.fileTree = nil
            self.workspaceFileSystem = nil
            markdownSession = nil
            currentWorkspace = nil
            state = .failure(error)
        } catch {
            releaseCurrentWorkspaceAccess()
            self.fileTree = nil
            self.workspaceFileSystem = nil
            markdownSession = nil
            currentWorkspace = nil
            state = .failure(.readFailed)
        }
    }

    private func releaseCurrentWorkspaceAccess() {
        changeMonitor?.stop()
        changeMonitor = nil
        workspaceFileSystem = nil
        markdownSession = nil
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
            await fileTree.refreshAfterExternalChange()
            await markdownSession?.checkForExternalChange()
        }
    }
}
