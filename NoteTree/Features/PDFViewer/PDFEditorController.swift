import AppKit
import Foundation
import Observation
import PDFKit

enum PDFReaderState: Equatable { case loading, locked, ready, failed(WorkspaceError) }
enum PDFReaderDisplayMode: Hashable { case continuous, singlePage, twoUp }
enum PDFEditingTool: Hashable { case browse, text, ink, eraser }

struct PDFSearchResult: Equatable, Sendable {
    let pageIndex: Int
    let bounds: CGRect
}

@MainActor
private final class PDFSearchNotificationObserver: NSObject {
    weak var controller: PDFEditorController?
    init(controller: PDFEditorController) { self.controller = controller }
    @objc func didFindMatch(_ notification: Notification) {
        guard let selection = notification.userInfo?[PDFDocumentFoundSelectionKey] as? PDFSelection else { return }
        controller?.appendSearchSelection(selection)
    }
    @objc func didEndFind(_ notification: Notification) { controller?.finishSearch() }
}

@MainActor
private final class PDFEditCommand {
    let pages: [PDFPage]
    let undoAction: () -> Void
    let redoAction: () -> Void
    init(pages: [PDFPage], undo: @escaping () -> Void, redo: @escaping () -> Void) {
        self.pages = pages; undoAction = undo; redoAction = redo
    }
    static func copies(of annotations: [PDFAnnotation]) -> [PDFAnnotation] {
        annotations.compactMap { $0.copy() as? PDFAnnotation }
    }
    static func hasSubtype(_ annotation: PDFAnnotation, _ subtype: PDFAnnotationSubtype) -> Bool {
        let rawValue = subtype.rawValue
        let typeName = rawValue.first == "/" ? String(rawValue.dropFirst()) : rawValue
        return annotation.type == typeName
    }
    static func installInk(_ annotations: [PDFAnnotation], on page: PDFPage) {
        for annotation in page.annotations where hasSubtype(annotation, .ink) { page.removeAnnotation(annotation) }
        for annotation in copies(of: annotations) { page.addAnnotation(annotation) }
    }
}

@MainActor
@Observable
final class PDFEditorController {
    private struct ActiveStroke { let page: PDFPage; var pagePoints: [CGPoint]; var viewPoints: [CGPoint] }
    private struct ActiveTextEditor { let page: PDFPage; let bounds: CGRect; let annotation: PDFAnnotation?; let originalContents: String? }
    private struct SelectedAnnotation { let page: PDFPage; let annotation: PDFAnnotation }
    private enum AnnotationGesture {
        case move(PDFPage, PDFAnnotation, CGPoint, CGRect)
        case resize(PDFPage, PDFAnnotation, CGPoint, CGRect, ResizeHandle)
    }
    private enum ResizeHandle { case topLeft, topRight, bottomLeft, bottomRight }
    private struct ActiveEraser { let page: PDFPage; let before: [PDFAnnotation]; var pagePoints: [CGPoint]; var changed = false }

    let workspace: Workspace
    let url: URL
    let pdfView: PDFEditingView
    private let fileSystem: any WorkspaceFileSystem
    private var document: PDFDocument?
    private var pageChangedObserver: NSObjectProtocol?
    private var searchObserver: PDFSearchNotificationObserver?
    private var activeStroke: ActiveStroke?
    private var activeTextDrag: (page: PDFPage, start: CGPoint)?
    private var activeTextEditor: ActiveTextEditor?
    private var selectedAnnotation: SelectedAnnotation?
    private var annotationGesture: AnnotationGesture?
    private var activeEraser: ActiveEraser?
    private var editHistory: [PDFEditCommand] = []
    private var historyIndex = 0
    private var savedHistoryIndex: Int? = 0
    private var loadedVersion: FileVersion?

    private(set) var state: PDFReaderState = .loading
    private(set) var currentPageNumber = 1
    private(set) var scaleFactor: CGFloat = 1
    private(set) var pageCount = 0
    private(set) var outlineRoot: PDFOutline?
    private(set) var currentPageHasText: Bool?
    private(set) var results: [PDFSearchResult] = []
    private(set) var isSearching = false
    private(set) var passwordRejected = false
    private(set) var isDirty = false
    private(set) var isSaving = false
    private(set) var saveError: WorkspaceError?
    private(set) var editingTool: PDFEditingTool = .browse
    private(set) var canUndo = false
    private(set) var canRedo = false
    var password = ""
    var searchQuery = ""
    var displayMode: PDFReaderDisplayMode = .continuous
    private var currentSearchResultIndex: Int?

    init(workspace: Workspace, url: URL, fileSystem: any WorkspaceFileSystem) {
        self.workspace = workspace; self.url = url; self.fileSystem = fileSystem
        let view = PDFEditingView()
        view.autoScales = true; view.displayDirection = .vertical; view.displaysPageBreaks = true
        view.displayMode = .singlePageContinuous; view.backgroundColor = .windowBackgroundColor
        pdfView = view; view.editingController = self
        pageChangedObserver = NotificationCenter.default.addObserver(forName: .PDFViewPageChanged, object: view, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refreshVisiblePageState() }
        }
    }

    var copyingAllowed: Bool { document?.allowsCopying ?? false }
    var editingAllowed: Bool { guard let document else { return false }; return !document.isLocked && document.allowsDocumentChanges }

    func load() async {
        cancelSearch(); resetEditingState(); state = .loading; password = ""; passwordRejected = false; isSaving = false; saveError = nil
        do {
            let contents = try await fileSystem.readData(at: url)
            guard !Task.isCancelled, let document = PDFDocument(url: url) else { state = .failed(.readFailed); return }
            self.document = document; loadedVersion = contents.version
            if document.isLocked { state = .locked } else { configure(document) }
        } catch let error as WorkspaceError { state = .failed(error) }
        catch { state = .failed(.readFailed) }
    }

    func unlock() async {
        guard let document else { await load(); return }; guard !password.isEmpty else { return }
        passwordRejected = false
        if document.unlock(withPassword: password) { password = ""; configure(document) }
        else { passwordRejected = true; state = .locked }
    }

    func close() {
        finishActiveTextEditor(commit: true); cancelSearch()
        if let pageChangedObserver { NotificationCenter.default.removeObserver(pageChangedObserver); self.pageChangedObserver = nil }
        document = nil; pdfView.document = nil; outlineRoot = nil; pageCount = 0; currentPageNumber = 1; currentPageHasText = nil; loadedVersion = nil
        resetEditingState()
    }

    func previousPage() { pdfView.goToPreviousPage(nil); refreshVisiblePageState() }
    func nextPage() { pdfView.goToNextPage(nil); refreshVisiblePageState() }
    func goToPage(_ number: Int) {
        guard let document, number >= 1, number <= document.pageCount, let page = document.page(at: number - 1) else { return }
        pdfView.go(to: page); refreshVisiblePageState()
    }
    func goToOutline(_ outline: PDFOutline) { guard let page = outline.destination?.page else { return }; pdfView.go(to: page); refreshVisiblePageState() }
    func setDisplayMode(_ mode: PDFReaderDisplayMode) {
        displayMode = mode
        switch mode { case .continuous: pdfView.displayMode = .singlePageContinuous; case .singlePage: pdfView.displayMode = .singlePage; case .twoUp: pdfView.displayMode = .twoUpContinuous }
        refreshVisiblePageState(); refreshSelectionOverlay()
    }
    func zoomIn() { setScaleFactor(scaleFactor * 1.2) }
    func zoomOut() { setScaleFactor(scaleFactor / 1.2) }
    func actualSize() { setScaleFactor(1) }
    func fitPage() { pdfView.autoScales = true; scaleFactor = pdfView.scaleFactor; refreshSelectionOverlay() }
    func fitWidth() {
        guard let page = pdfView.currentPage, page.bounds(for: .cropBox).width > 0 else { return }
        setScaleFactor(max(pdfView.bounds.width - 32, 1) / page.bounds(for: .cropBox).width)
    }
    func setEditingTool(_ tool: PDFEditingTool) { finishActiveTextEditor(commit: true); editingTool = tool; if tool != .browse { clearSelection() } }

    func undo() {
        guard historyIndex > 0 else { return }; let command = editHistory[historyIndex - 1]
        command.undoAction(); historyIndex -= 1; redraw(command.pages); updateHistoryState()
    }
    func redo() {
        guard historyIndex < editHistory.count else { return }; let command = editHistory[historyIndex]
        command.redoAction(); historyIndex += 1; redraw(command.pages); updateHistoryState()
    }

    func startSearch() {
        document?.cancelFindString(); cancelSearchObservers(); results = []
        guard let document, !searchQuery.isEmpty else { isSearching = false; return }
        isSearching = true; let observer = PDFSearchNotificationObserver(controller: self); searchObserver = observer
        NotificationCenter.default.addObserver(observer, selector: #selector(PDFSearchNotificationObserver.didFindMatch(_:)), name: .PDFDocumentDidFindMatch, object: document)
        NotificationCenter.default.addObserver(observer, selector: #selector(PDFSearchNotificationObserver.didEndFind(_:)), name: .PDFDocumentDidEndFind, object: document)
        document.beginFindString(searchQuery, withOptions: .caseInsensitive)
    }
    func nextSearchResult() { moveSearchResult(forward: true) }
    func previousSearchResult() { moveSearchResult(forward: false) }
    func cancelSearch() { document?.cancelFindString(); cancelSearchObservers(); isSearching = false; results = []; currentSearchResultIndex = nil; searchQuery = ""; pdfView.clearSelection() }

    func beginEditing(with event: NSEvent, at viewPoint: CGPoint) -> Bool {
        guard state == .ready, editingAllowed else { return false }
        if activeTextEditor != nil { finishActiveTextEditor(commit: true); return false }
        guard let page = pdfView.page(for: viewPoint, nearest: false) else { return false }
        let pagePoint = pdfView.convert(viewPoint, to: page)
        switch editingTool {
        case .browse: return beginBrowseInteraction(event: event, page: page, pagePoint: pagePoint, viewPoint: viewPoint)
        case .text: activeTextDrag = (page, pagePoint); pdfView.showSelection(rect: CGRect(origin: viewPoint, size: .zero)); return true
        case .ink: activeStroke = ActiveStroke(page: page, pagePoints: [pagePoint], viewPoints: [viewPoint]); pdfView.showInkPreview(points: [viewPoint]); return true
        case .eraser:
            var eraser = ActiveEraser(page: page, before: PDFEditCommand.copies(of: inkAnnotations(on: page)), pagePoints: [pagePoint])
            eraser.changed = applyEraser(on: page, points: [pagePoint])
            activeEraser = eraser
            return true
        }
    }

    func continueEditing(with event: NSEvent, at viewPoint: CGPoint) -> Bool {
        if var stroke = activeStroke {
            for sample in pointerSamples(for: event, fallback: viewPoint) { stroke.pagePoints.append(pdfView.convert(sample, to: stroke.page)); stroke.viewPoints.append(sample) }
            activeStroke = stroke; pdfView.showInkPreview(points: stroke.viewPoints); return true
        }
        if let drag = activeTextDrag {
            let bounds = normalizedTextBounds(from: drag.start, to: pdfView.convert(viewPoint, to: drag.page), in: drag.page)
            pdfView.showSelection(rect: pdfView.convert(bounds, from: drag.page)); return true
        }
        if var eraser = activeEraser {
            let samples = pointerSamples(for: event, fallback: viewPoint).map { pdfView.convert($0, to: eraser.page) }
            let segment = [eraser.pagePoints.last].compactMap { $0 } + samples
            if applyEraser(on: eraser.page, points: segment) { eraser.changed = true }
            eraser.pagePoints.append(contentsOf: samples); activeEraser = eraser; return true
        }
        if let gesture = annotationGesture { updateAnnotationGesture(gesture, to: viewPoint); return true }
        return false
    }

    func finishEditing(with event: NSEvent, at viewPoint: CGPoint) -> Bool {
        if var stroke = activeStroke {
            for sample in pointerSamples(for: event, fallback: viewPoint) { stroke.pagePoints.append(pdfView.convert(sample, to: stroke.page)) }
            activeStroke = nil; pdfView.clearInkPreview(); if stroke.pagePoints.count >= 2 { addInkStroke(on: stroke.page, points: stroke.pagePoints) }; return true
        }
        if let drag = activeTextDrag {
            activeTextDrag = nil; let bounds = normalizedTextBounds(from: drag.start, to: pdfView.convert(viewPoint, to: drag.page), in: drag.page)
            pdfView.clearSelection(); beginTextEditor(on: drag.page, bounds: bounds, annotation: nil); return true
        }
        if let eraser = activeEraser {
            activeEraser = nil
            if eraser.changed { let after = PDFEditCommand.copies(of: inkAnnotations(on: eraser.page)); record(pages: [eraser.page], undo: { PDFEditCommand.installInk(eraser.before, on: eraser.page) }, redo: { PDFEditCommand.installInk(after, on: eraser.page) }) }
            return true
        }
        if let gesture = annotationGesture { annotationGesture = nil; finishAnnotationGesture(gesture); return true }
        return false
    }

    func handleDelete() -> Bool {
        guard let selectedAnnotation else { return false }
        let page = selectedAnnotation.page; let annotation = selectedAnnotation.annotation
        page.removeAnnotation(annotation); clearSelection()
        record(pages: [page], undo: { page.addAnnotation(annotation) }, redo: { page.removeAnnotation(annotation) }); return true
    }
    func viewLayoutDidChange() { refreshSelectionOverlay() }

    func save() async -> Bool {
        finishActiveTextEditor(commit: true)
        guard let document, let loadedVersion, editingAllowed, isDirty else { return false }
        guard let data = document.dataRepresentation() else { saveError = .writeFailed; return false }
        isSaving = true; saveError = nil; defer { isSaving = false }
        do { let version = try await fileSystem.writeData(data, to: url, expectedVersion: loadedVersion); self.loadedVersion = version; savedHistoryIndex = historyIndex; updateHistoryState(); return true }
        catch let error as WorkspaceError { saveError = error }
        catch { saveError = .writeFailed }
        return false
    }

    func addTextBox(at point: CGPoint, onPageNumber pageNumber: Int, text: String = "Text") -> Bool {
        guard editingAllowed, let page = document?.page(at: pageNumber - 1) else { return false }
        addTextBox(on: page, bounds: normalizedTextBounds(from: point, to: CGPoint(x: point.x + 180, y: point.y - 48), in: page), text: text); return true
    }
    func addInkStroke(points: [CGPoint], onPageNumber pageNumber: Int) -> Bool {
        guard editingAllowed, points.count >= 2, let page = document?.page(at: pageNumber - 1) else { return false }
        addInkStroke(on: page, points: points); return true
    }
    func eraseInk(at point: CGPoint, onPageNumber pageNumber: Int) -> Bool {
        guard editingAllowed, let page = document?.page(at: pageNumber - 1) else { return false }
        let before = PDFEditCommand.copies(of: inkAnnotations(on: page)); guard applyEraser(on: page, points: [point]) else { return false }
        let after = PDFEditCommand.copies(of: inkAnnotations(on: page)); record(pages: [page], undo: { PDFEditCommand.installInk(before, on: page) }, redo: { PDFEditCommand.installInk(after, on: page) }); return true
    }

    private func configure(_ document: PDFDocument) { pdfView.document = document; outlineRoot = document.outlineRoot; pageCount = document.pageCount; setDisplayMode(displayMode); refreshVisiblePageState(); state = .ready }
    private func beginBrowseInteraction(event: NSEvent, page: PDFPage, pagePoint: CGPoint, viewPoint: CGPoint) -> Bool {
        guard let annotation = freeTextAnnotation(on: page, at: pagePoint) else { clearSelection(); return false }
        selectedAnnotation = SelectedAnnotation(page: page, annotation: annotation); refreshSelectionOverlay()
        if event.clickCount >= 2 { beginTextEditor(on: page, bounds: annotation.bounds, annotation: annotation); return true }
        let viewBounds = pdfView.convert(annotation.bounds, from: page)
        if let handle = resizeHandle(at: viewPoint, in: viewBounds) { annotationGesture = .resize(page, annotation, pagePoint, annotation.bounds, handle) }
        else { annotationGesture = .move(page, annotation, pagePoint, annotation.bounds) }
        return true
    }
    private func updateAnnotationGesture(_ gesture: AnnotationGesture, to viewPoint: CGPoint) {
        switch gesture {
        case let .move(page, annotation, start, original): let point = pdfView.convert(viewPoint, to: page); annotation.bounds = original.offsetBy(dx: point.x - start.x, dy: point.y - start.y)
        case let .resize(page, annotation, start, original, handle): annotation.bounds = resizedBounds(original, start: start, current: pdfView.convert(viewPoint, to: page), handle: handle, cropBox: page.bounds(for: .cropBox))
        }
        refreshSelectionOverlay()
    }
    private func finishAnnotationGesture(_ gesture: AnnotationGesture) {
        let page: PDFPage; let annotation: PDFAnnotation; let old: CGRect
        switch gesture { case let .move(p, a, _, b), let .resize(p, a, _, b, _): page = p; annotation = a; old = b }
        let new = annotation.bounds; guard new != old else { return }
        record(pages: [page], undo: { annotation.bounds = old }, redo: { annotation.bounds = new })
    }
    private func beginTextEditor(on page: PDFPage, bounds: CGRect, annotation: PDFAnnotation?) {
        activeTextEditor = ActiveTextEditor(page: page, bounds: bounds, annotation: annotation, originalContents: annotation?.contents)
        pdfView.beginTextEditing(frame: pdfView.convert(bounds, from: page), text: annotation?.contents ?? "", onCommit: { [weak self] text in self?.finishActiveTextEditor(commit: true, text: text) }, onCancel: { [weak self] in self?.finishActiveTextEditor(commit: false) })
    }
    private func finishActiveTextEditor(commit: Bool, text: String? = nil) {
        guard let editor = activeTextEditor else { return }; activeTextEditor = nil
        let final = text ?? pdfView.endTextEditing(commit: commit)
        guard commit, let final, !final.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { pdfView.clearSelection(); return }
        if let annotation = editor.annotation {
            let old = editor.originalContents ?? ""; guard old != final else { return }; annotation.contents = final
            record(pages: [editor.page], undo: { annotation.contents = old }, redo: { annotation.contents = final }); selectedAnnotation = SelectedAnnotation(page: editor.page, annotation: annotation); refreshSelectionOverlay()
        } else { addTextBox(on: editor.page, bounds: editor.bounds, text: final) }
    }
    private func addTextBox(on page: PDFPage, bounds: CGRect, text: String) {
        let annotation = PDFAnnotation(bounds: bounds, forType: .freeText, withProperties: nil)
        annotation.contents = text; annotation.font = .systemFont(ofSize: 16); annotation.fontColor = .labelColor; annotation.color = .clear
        let border = PDFBorder(); border.lineWidth = 0; annotation.border = border; page.addAnnotation(annotation)
        selectedAnnotation = SelectedAnnotation(page: page, annotation: annotation)
        record(pages: [page], undo: { page.removeAnnotation(annotation) }, redo: { page.addAnnotation(annotation) }); refreshSelectionOverlay()
    }
    private func addInkStroke(on page: PDFPage, points: [CGPoint]) {
        guard let annotation = makeInkAnnotation(points: points, color: .systemBlue, border: defaultInkBorder()) else { return }
        page.addAnnotation(annotation); record(pages: [page], undo: { page.removeAnnotation(annotation) }, redo: { page.addAnnotation(annotation) })
    }
    private func applyEraser(on page: PDFPage, points: [CGPoint]) -> Bool {
        guard let first = points.first else { return false }
        let displayedScale = pdfView.scaleFactor
        let stableScale = displayedScale.isFinite ? max(displayedScale, 1) : 1
        let radius = 12 / stableScale
        let dirty = points.dropFirst().reduce(
            CGRect(x: first.x - radius, y: first.y - radius, width: radius * 2, height: radius * 2)
        ) { partial, point in
            partial.union(CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2))
        }
        var changed = false
        for annotation in inkAnnotations(on: page) where annotation.bounds.intersects(dirty) {
            var pieces: [[CGPoint]] = []; var changedAnnotation = false
            for original in pagePaths(for: annotation) {
                let remaining = PDFInkGeometry.erase(points: original, with: points, radius: radius)
                if remaining.count != 1 || remaining.first != original { changedAnnotation = true }; pieces.append(contentsOf: remaining)
            }
            guard changedAnnotation else { continue }; page.removeAnnotation(annotation)
            for piece in pieces { if let replacement = makeInkAnnotation(points: piece, color: annotation.color, border: annotation.border) { page.addAnnotation(replacement) } }
            changed = true
        }
        if changed { redraw([page]) }; return changed
    }
    private func makeInkAnnotation(points: [CGPoint], color: NSColor, border: PDFBorder?) -> PDFAnnotation? {
        let width = border?.lineWidth ?? 3
        guard let bounds = PDFInkGeometry.tightBounds(for: points, lineWidth: width), let path = PDFInkGeometry.localPath(points: points, in: bounds) else { return nil }
        let annotation = PDFAnnotation(bounds: bounds, forType: .ink, withProperties: nil)
        annotation.color = color; annotation.border = copiedBorder(border) ?? defaultInkBorder(); annotation.add(path); return annotation
    }
    private func defaultInkBorder() -> PDFBorder { let border = PDFBorder(); border.lineWidth = 3; return border }
    private func copiedBorder(_ border: PDFBorder?) -> PDFBorder? { guard let border else { return nil }; let copy = PDFBorder(); copy.lineWidth = border.lineWidth; copy.style = border.style; copy.dashPattern = border.dashPattern; return copy }
    private func inkAnnotations(on page: PDFPage) -> [PDFAnnotation] { page.annotations.filter { PDFEditCommand.hasSubtype($0, .ink) } }
    private func freeTextAnnotation(on page: PDFPage, at point: CGPoint) -> PDFAnnotation? {
        page.annotations.reversed().first {
            $0.type == PDFAnnotationSubtype.freeText.rawValue.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                && $0.bounds.contains(point)
        }
    }
    private func pagePaths(for annotation: PDFAnnotation) -> [[CGPoint]] {
        if let paths = annotation.paths, !paths.isEmpty {
            return paths.map { PDFInkGeometry.pagePoints(from: $0, annotationBounds: annotation.bounds) }
        }
        guard let inkList = annotation.value(forAnnotationKey: .inklist) as? [[NSNumber]] else { return [] }
        return inkList.compactMap { coordinates in
            guard coordinates.count >= 4 else { return nil }
            return stride(from: 0, to: coordinates.count - 1, by: 2).map {
                CGPoint(x: coordinates[$0].doubleValue, y: coordinates[$0 + 1].doubleValue)
            }
        }
    }

    private func record(pages: [PDFPage], undo: @escaping () -> Void, redo: @escaping () -> Void) {
        if historyIndex < editHistory.count { editHistory.removeSubrange(historyIndex...); if let savedHistoryIndex, savedHistoryIndex > historyIndex { self.savedHistoryIndex = nil } }
        editHistory.append(PDFEditCommand(pages: pages, undo: undo, redo: redo)); historyIndex += 1; redraw(pages); updateHistoryState()
    }
    private func redraw(_ pages: [PDFPage]) { for page in pages { pdfView.annotationsChanged(on: page) } }
    private func updateHistoryState() { canUndo = historyIndex > 0; canRedo = historyIndex < editHistory.count; isDirty = savedHistoryIndex != historyIndex; if !isDirty { saveError = nil } }
    private func resetEditingState() {
        activeStroke = nil; activeTextDrag = nil; activeTextEditor = nil; selectedAnnotation = nil; annotationGesture = nil; activeEraser = nil
        editHistory = []; historyIndex = 0; savedHistoryIndex = 0; canUndo = false; canRedo = false; isDirty = false; pdfView.clearInteractionOverlays()
    }
    private func clearSelection() { selectedAnnotation = nil; annotationGesture = nil; pdfView.clearSelection() }
    private func refreshSelectionOverlay() { guard let selectedAnnotation, activeTextEditor == nil else { return }; pdfView.showSelection(rect: pdfView.convert(selectedAnnotation.annotation.bounds, from: selectedAnnotation.page)) }
    private func normalizedTextBounds(from start: CGPoint, to end: CGPoint, in page: PDFPage) -> CGRect {
        var bounds = CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x), height: abs(end.y - start.y))
        if bounds.width < 80 { bounds.size.width = 180 }; if bounds.height < 32 { bounds.size.height = 48 }
        let crop = page.bounds(for: .cropBox); bounds.origin.x = min(max(bounds.minX, crop.minX), max(crop.maxX - bounds.width, crop.minX)); bounds.origin.y = min(max(bounds.minY, crop.minY), max(crop.maxY - bounds.height, crop.minY)); return bounds.intersection(crop)
    }
    private func resizeHandle(at point: CGPoint, in bounds: CGRect) -> ResizeHandle? {
        let candidates: [(ResizeHandle, CGPoint)] = [(.topLeft, CGPoint(x: bounds.minX, y: bounds.maxY)), (.topRight, CGPoint(x: bounds.maxX, y: bounds.maxY)), (.bottomLeft, CGPoint(x: bounds.minX, y: bounds.minY)), (.bottomRight, CGPoint(x: bounds.maxX, y: bounds.minY))]
        return candidates.first { hypot(point.x - $0.1.x, point.y - $0.1.y) <= 10 }?.0
    }
    private func resizedBounds(_ old: CGRect, start: CGPoint, current: CGPoint, handle: ResizeHandle, cropBox: CGRect) -> CGRect {
        let dx = current.x - start.x, dy = current.y - start.y; var bounds = old
        switch handle { case .topLeft: bounds.origin.x += dx; bounds.size.width -= dx; bounds.size.height += dy; case .topRight: bounds.size.width += dx; bounds.size.height += dy; case .bottomLeft: bounds.origin.x += dx; bounds.size.width -= dx; bounds.origin.y += dy; bounds.size.height -= dy; case .bottomRight: bounds.size.width += dx; bounds.origin.y += dy; bounds.size.height -= dy }
        bounds.size.width = max(bounds.width, 80); bounds.size.height = max(bounds.height, 32)
        if bounds.minX < cropBox.minX { bounds.origin.x = cropBox.minX }; if bounds.minY < cropBox.minY { bounds.origin.y = cropBox.minY }; if bounds.maxX > cropBox.maxX { bounds.origin.x = cropBox.maxX - bounds.width }; if bounds.maxY > cropBox.maxY { bounds.origin.y = cropBox.maxY - bounds.height }; return bounds
    }
    private func pointerSamples(for event: NSEvent, fallback: CGPoint) -> [CGPoint] {
        // AppKit does not expose mouse coalescing like UIKit. Updating the
        // preview for every delivered drag event still avoids PDFKit redraws
        // until the stroke is committed on mouse-up.
        _ = event
        return [fallback]
    }
    private func cancelSearchObservers() { if let searchObserver { NotificationCenter.default.removeObserver(searchObserver); self.searchObserver = nil } }
    fileprivate func appendSearchSelection(_ selection: PDFSelection) { guard let document, let page = selection.pages.first else { return }; results.append(PDFSearchResult(pageIndex: document.index(for: page), bounds: selection.bounds(for: page))) }
    fileprivate func finishSearch() { isSearching = false; if !results.isEmpty { showSearchResult(at: 0) } }
    private func refreshVisiblePageState() {
        guard let document, let page = pdfView.currentPage else { currentPageNumber = 1; currentPageHasText = nil; scaleFactor = pdfView.scaleFactor; return }
        currentPageNumber = document.index(for: page) + 1; currentPageHasText = !(page.string?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true); scaleFactor = pdfView.scaleFactor
    }
    private func setScaleFactor(_ value: CGFloat) { pdfView.autoScales = false; pdfView.scaleFactor = min(max(value, 0.1), 8); scaleFactor = pdfView.scaleFactor; refreshSelectionOverlay() }
    private func moveSearchResult(forward: Bool) { guard !results.isEmpty else { return }; let index = currentSearchResultIndex ?? 0; showSearchResult(at: forward ? (index + 1) % results.count : (index - 1 + results.count) % results.count) }
    private func showSearchResult(at index: Int) {
        guard let document, results.indices.contains(index), let page = document.page(at: results[index].pageIndex), let selection = page.selection(for: results[index].bounds) else { return }
        pdfView.setCurrentSelection(selection, animate: true); pdfView.go(to: selection); currentSearchResultIndex = index; refreshVisiblePageState()
    }
}
