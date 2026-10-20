import AppKit
import Observation
import UniformTypeIdentifiers

@MainActor
@Observable
final class ImageEditorSession {
    let url: URL
    private let fileSystem: any WorkspaceFileSystem
    private let renderer = ImageRenderer()
    private var source = Data()
    private var version: FileVersion?
    private var savedRecipe = ImageEditRecipe()
    private var undoStack: [ImageEditRecipe] = []
    private var redoStack: [ImageEditRecipe] = []
    private var previewTask: Task<Void, Never>?
    private var revision = 0
    private var adjustmentStart: ImageEditRecipe?
    private(set) var recipe = ImageEditRecipe()
    private(set) var preview: NSImage?
    private(set) var pixelSize = CGSize.zero
    private(set) var canOverwrite = false
    private(set) var isSaving = false
    private(set) var isLoading = true
    private(set) var error: WorkspaceError?
    private(set) var hasConflict = false
    var isDirty: Bool { recipe != savedRecipe }
    var canUndo: Bool { !undoStack.isEmpty && !isSaving }
    var canRedo: Bool { !redoStack.isEmpty && !isSaving }

    init(url: URL, fileSystem: any WorkspaceFileSystem) {
        self.url = url
        self.fileSystem = fileSystem
    }

    func load() async {
        guard !isSaving else { return }
        previewTask?.cancel()
        revision += 1
        isLoading = true
        defer { isLoading = false }
        do {
            let contents = try await fileSystem.readData(at: url)
            let rendered = try await renderer.render(contents.data, recipe: .init(), preview: true)
            source = contents.data
            version = contents.version
            recipe = .init()
            savedRecipe = recipe
            undoStack = []
            redoStack = []
            hasConflict = false
            error = nil
            apply(rendered)
        } catch { self.error = error as? WorkspaceError ?? .decodeFailed }
    }

    func edit(_ updated: ImageEditRecipe) {
        guard !isSaving, !isLoading, preview != nil, updated != recipe else { return }
        if adjustmentStart == nil { undoStack.append(recipe) }
        redoStack.removeAll()
        recipe = updated
        renderPreview()
    }

    func beginAdjustment() {
        guard adjustmentStart == nil else { return }
        adjustmentStart = recipe
    }

    func endAdjustment() {
        if let start = adjustmentStart, start != recipe { undoStack.append(start) }
        adjustmentStart = nil
    }

    func undo() {
        guard canUndo, let previous = undoStack.popLast() else { return }
        redoStack.append(recipe)
        recipe = previous
        renderPreview()
    }

    func redo() {
        guard canRedo, let next = redoStack.popLast() else { return }
        undoStack.append(recipe)
        recipe = next
        renderPreview()
    }

    func save(copyName: String? = nil, quality: Double = 0.9) async -> Bool {
        guard let version, !isSaving, copyName != nil || (canOverwrite && !hasConflict) else { return false }
        if let copyName, URL(fileURLWithPath: copyName).pathExtension.lowercased() != "png" {
            error = .invalidFileName
            return false
        }
        isSaving = true
        defer { isSaving = false }
        do {
            let rendered = try await renderer.render(source, recipe: recipe, preview: false,
                                                     outputType: copyName == nil ? nil : UTType.png.identifier,
                                                     quality: quality)
            if let copyName {
                _ = try await fileSystem.writeCopy(of: rendered.data, for: url, named: copyName)
            } else {
                self.version = try await fileSystem.writeData(rendered.data, to: url, expectedVersion: version)
                // Keep the original source for non-destructive undo, even after a checkpoint save.
                savedRecipe = recipe
            }
            error = nil
            return true
        } catch {
            self.error = error as? WorkspaceError ?? .writeFailed
            if self.error == .externalConflict { hasConflict = true }
            return false
        }
    }

    func checkForExternalChange() async {
        guard !isSaving, let version else { return }
        do {
            let current = try await fileSystem.readData(at: url)
            guard current.version != version else { return }
            if isDirty { hasConflict = true; error = .externalConflict }
            else { await load() }
        } catch { self.error = error as? WorkspaceError ?? .readFailed }
    }

    private func renderPreview() {
        previewTask?.cancel()
        revision += 1
        let requestedRevision = revision
        let recipe = recipe
        let source = source
        previewTask = Task {
            do {
                let rendered = try await renderer.render(source, recipe: recipe, preview: true)
                guard !Task.isCancelled, requestedRevision == revision else { return }
                apply(rendered)
            } catch {
                if !Task.isCancelled { self.error = error as? WorkspaceError ?? .decodeFailed }
            }
        }
    }

    private func apply(_ rendered: ImagePreview) {
        preview = NSImage(data: rendered.data)
        pixelSize = CGSize(width: rendered.pixelWidth, height: rendered.pixelHeight)
        canOverwrite = rendered.canOverwrite
    }
}
