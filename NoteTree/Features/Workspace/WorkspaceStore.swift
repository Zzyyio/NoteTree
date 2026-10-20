import AppKit
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
    private(set) var pdfController: PDFEditorController?
    private(set) var imageSession: ImageEditorSession?
    private(set) var recents: [RecentWorkspace] = []
    var filterFocusRequest = 0
    private(set) var state: WorkspaceState = .welcome

    init(
        bookmarkStore: WorkspaceBookmarkStore = WorkspaceBookmarkStore(),
        picker: any WorkspacePicking = SystemWorkspacePicker(),
        resourceAccess: any SecurityScopedResourceAccessing = SystemSecurityScopedResourceAccess(),
        fileSystemFactory: @escaping @Sendable (Workspace) -> any WorkspaceFileSystem = { workspace in
            LocalWorkspaceFileSystem(workspace: workspace, exclusionPolicy: FileTreeExclusionPolicy(
                showHidden: UserDefaults.standard.bool(forKey: "files.showHidden"),
                patterns: (UserDefaults.standard.string(forKey: "files.exclusions") ?? "")
                    .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            ))
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

    func restoreMostRecentWorkspace(preferredID: String? = nil) async {
        guard !didAttemptRestoration else {
            return
        }
        didAttemptRestoration = true
        recents = await bookmarkStore.recents
        if let preferredID, let recent = recents.first(where: { $0.id.rawValue.uuidString == preferredID }) {
            await openRecent(recent)
            return
        }

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
        guard await prepareForNavigation() else { return }
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
        guard await prepareForNavigation() else { return }
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

    func openPDF(_ node: FileNode) async {
        guard node.kind == .pdf,
              let workspace = currentWorkspace,
              let workspaceFileSystem else {
            return
        }
        guard pdfController?.url != node.url else {
            return
        }
        guard await markdownSession?.prepareForFileSwitch() ?? true else {
            return
        }

        if let currentPDF = pdfController, currentPDF.isDirty {
            guard await currentPDF.save() else {
                return
            }
        }
        pdfController?.close()
        let controller = PDFEditorController(
            workspace: workspace,
            url: node.url,
            fileSystem: workspaceFileSystem
        )
        pdfController = controller
        await controller.load()
    }

    func saveCurrentMarkdown() async {
        _ = await markdownSession?.saveNow()
    }

    func saveCurrentDocument() async {
        if let imageSession, fileTree?.selectedNode()?.url == imageSession.url {
            _ = await imageSession.save(quality: UserDefaults.standard.object(forKey: "image.jpegQuality") as? Double ?? 0.9)
        } else if let pdfController, pdfController.isDirty {
            _ = await pdfController.save()
        } else {
            await saveCurrentMarkdown()
        }
    }

    func flushCurrentMarkdown() async -> Bool {
        await markdownSession?.prepareForFileSwitch() ?? true
    }

    func openRecent(_ recentWorkspace: RecentWorkspace) async {
        guard await prepareForNavigation() else { return }
        state = .loading
        switch await bookmarkStore.resolve(recentWorkspace) {
        case .workspace(let workspace):
            await activate(workspace)
        case .needsReauthorization(let unavailableWorkspace):
            releaseCurrentWorkspaceAccess()
            fileTree = nil
            markdownSession = nil
            pdfController = nil
            self.workspaceFileSystem = nil
            currentWorkspace = nil
            state = .needsReauthorization(unavailableWorkspace)
        case .none:
            releaseCurrentWorkspaceAccess()
            fileTree = nil
            markdownSession = nil
            pdfController = nil
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
        fileTree.beforeSelection = { [weak self] in
            await self?.prepareForNavigation() ?? false
        }
        fileTree.canMutate = { [weak self] node in
            guard let self else { return false }
            let dirtyURLs = [
                self.imageSession?.isDirty == true || self.imageSession?.isSaving == true ? self.imageSession?.url : nil,
                self.markdownSession?.isDirty == true ? self.markdownSession?.url : nil
            ].compactMap { $0 }
            return !dirtyURLs.contains { $0 == node.url || $0.path.hasPrefix(node.url.path + "/") }
        }
        markdownSession = nil
        imageSession = nil
        pdfController = nil

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
            pdfController = nil
            currentWorkspace = nil
            state = .failure(error)
        } catch {
            releaseCurrentWorkspaceAccess()
            self.fileTree = nil
            self.workspaceFileSystem = nil
            markdownSession = nil
            pdfController = nil
            currentWorkspace = nil
            state = .failure(.readFailed)
        }
    }

    private func releaseCurrentWorkspaceAccess() {
        changeMonitor?.stop()
        changeMonitor = nil
        pdfController?.close()
        pdfController = nil
        workspaceFileSystem = nil
        markdownSession = nil
        imageSession = nil
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
            await imageSession?.checkForExternalChange()
        }
    }

    func openImage(_ node: FileNode) async {
        guard let workspaceFileSystem, imageSession?.url != node.url else { return }
        let session = ImageEditorSession(url: node.url, fileSystem: workspaceFileSystem)
        imageSession = session
        await session.load()
    }

    func prepareForNavigation() async -> Bool {
        guard await flushCurrentMarkdown() else { return false }
        guard let imageSession, imageSession.isDirty else { return true }
        guard !imageSession.isSaving else { return false }
        let alert = NSAlert()
        alert.messageText = String(localized: "image.unsaved")
        alert.informativeText = String(localized: "image.leave.description")
        alert.addButton(withTitle: String(localized: "image.save"))
        alert.addButton(withTitle: String(localized: "image.discard"))
        alert.addButton(withTitle: String(localized: "image.cancel"))
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            return await imageSession.save()
        }
        if response == .alertSecondButtonReturn {
            self.imageSession = nil
            return true
        }
        return false
    }
}
