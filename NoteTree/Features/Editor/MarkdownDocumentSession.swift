import Foundation
import Observation

enum MarkdownDocumentState: Equatable {
    case loading
    case clean
    case dirty
    case saving
    case conflict
    case failed(WorkspaceError)
    case readOnly(WorkspaceError)
}

@MainActor
@Observable
final class MarkdownDocumentSession {
    let workspace: Workspace
    let url: URL

    private let fileSystem: any WorkspaceFileSystem
    private let saveDelay: any MarkdownSaveDelaying
    private let draftStore: any MarkdownDraftStoring
    private var loadedVersion: FileVersion?
    private var diskText = ""
    private var saveTask: Task<Void, Never>?
    private var hasUnsavedChanges = false

    var text = ""
    private(set) var state: MarkdownDocumentState = .loading
    private(set) var externalText: String?

    init(
        workspace: Workspace,
        url: URL,
        fileSystem: any WorkspaceFileSystem,
        saveDelay: any MarkdownSaveDelaying = SystemMarkdownSaveDelay(),
        draftStore: any MarkdownDraftStoring = MarkdownDraftStore()
    ) {
        self.workspace = workspace
        self.url = url
        self.fileSystem = fileSystem
        self.saveDelay = saveDelay
        self.draftStore = draftStore
    }

    var isDirty: Bool {
        hasUnsavedChanges
    }

    var canSave: Bool {
        loadedVersion != nil && !isReadOnly && state != .conflict
    }

    var isReadOnly: Bool {
        if case .readOnly = state {
            return true
        }
        return false
    }

    func load() async {
        state = .loading
        externalText = nil

        do {
            let contents = try await fileSystem.readData(at: url)
            guard let decodedText = String(data: contents.data, encoding: .utf8) else {
                state = .readOnly(.decodeFailed)
                return
            }

            loadedVersion = contents.version
            diskText = decodedText
            if let recoveredDraft = draftStore.draft(for: workspace.id, fileURL: url) {
                text = recoveredDraft
                hasUnsavedChanges = true
                state = .dirty
            } else {
                text = decodedText
                hasUnsavedChanges = false
                state = .clean
            }
        } catch let error as WorkspaceError {
            state = .failed(error)
        } catch {
            state = .failed(.readFailed)
        }
    }

    func updateText(_ updatedText: String) {
        guard !isReadOnly, state != .conflict else {
            return
        }

        text = updatedText
        hasUnsavedChanges = true
        state = .dirty
        draftStore.saveDraft(updatedText, for: workspace.id, fileURL: url)
        scheduleAutoSave()
    }

    func saveNow() async -> Bool {
        saveTask?.cancel()
        saveTask = nil
        return await saveCurrentText()
    }

    func prepareForFileSwitch() async -> Bool {
        guard isDirty else {
            return true
        }
        return await saveNow()
    }

    func checkForExternalChange() async {
        guard loadedVersion != nil, !isReadOnly else {
            return
        }

        do {
            let contents = try await fileSystem.readData(at: url)
            guard contents.version != loadedVersion else {
                return
            }
            guard let updatedDiskText = String(data: contents.data, encoding: .utf8) else {
                state = .readOnly(.decodeFailed)
                return
            }

            if isDirty {
                saveTask?.cancel()
                externalText = updatedDiskText
                state = .conflict
            } else {
                loadedVersion = contents.version
                diskText = updatedDiskText
                text = updatedDiskText
                hasUnsavedChanges = false
                state = .clean
            }
        } catch let error as WorkspaceError {
            state = .failed(error)
        } catch {
            state = .failed(.readFailed)
        }
    }

    func reloadExternalVersion() async {
        saveTask?.cancel()
        externalText = nil
        draftStore.removeDraft(for: workspace.id, fileURL: url)
        await load()
    }

    func saveLocalCopy() async -> URL? {
        let sourceName = url.deletingPathExtension().lastPathComponent
        let extensionName = url.pathExtension
        let copyName = extensionName.isEmpty
            ? "\(sourceName) Local Copy"
            : "\(sourceName) Local Copy.\(extensionName)"

        do {
            let copyURL = try await fileSystem.writeCopy(
                of: Data(text.utf8),
                for: url,
                named: copyName
            )
            return copyURL
        } catch let error as WorkspaceError {
            state = .failed(error)
        } catch {
            state = .failed(.writeFailed)
        }
        return nil
    }

    func difference() -> MarkdownTextDifference? {
        guard let externalText else {
            return nil
        }
        return MarkdownTextDifference(localText: text, externalText: externalText)
    }

    private func scheduleAutoSave() {
        saveTask?.cancel()
        let saveDelay = saveDelay
        saveTask = Task { [weak self, saveDelay] in
            do {
                try await saveDelay.wait()
                guard !Task.isCancelled else {
                    return
                }
                _ = await self?.saveCurrentText()
            } catch {
                // Cancellation is the normal way a newer edit replaces this debounce task.
            }
        }
    }

    private func saveCurrentText() async -> Bool {
        guard let loadedVersion, canSave else {
            return false
        }

        let textToSave = text
        state = .saving
        do {
            let savedVersion = try await fileSystem.writeData(
                Data(textToSave.utf8),
                to: url,
                expectedVersion: loadedVersion
            )
            self.loadedVersion = savedVersion
            diskText = textToSave
            if text == textToSave {
                hasUnsavedChanges = false
                state = .clean
                draftStore.removeDraft(for: workspace.id, fileURL: url)
            } else {
                state = .dirty
                scheduleAutoSave()
            }
            return true
        } catch WorkspaceError.externalConflict {
            await loadConflictVersion()
        } catch let error as WorkspaceError {
            state = .failed(error)
        } catch {
            state = .failed(.writeFailed)
        }
        return false
    }

    private func loadConflictVersion() async {
        do {
            let contents = try await fileSystem.readData(at: url)
            externalText = String(data: contents.data, encoding: .utf8)
            state = .conflict
        } catch let error as WorkspaceError {
            state = .failed(error)
        } catch {
            state = .failed(.readFailed)
        }
    }
}

struct MarkdownTextDifference: Equatable {
    let localText: String
    let externalText: String
}
