import SwiftUI

@MainActor
struct ImageEditorHost: View {
    let node: FileNode
    let workspaceStore: WorkspaceStore
    var body: some View {
        Group {
            if let session = workspaceStore.imageSession, session.url == node.url {
                ImageEditorView(session: session)
            } else {
                ProgressView("image.loading")
            }
        }
        .task(id: node.id) { await workspaceStore.openImage(node) }
    }
}

@MainActor
struct ImageEditorView: View {
    let session: ImageEditorSession
    @State private var tool = ImageCanvasTool.pan
    @State private var zoom: CGFloat = 0
    @State private var background = 0
    @State private var copyName = ""
    @State private var showCopy = false
    @State private var showAdjustments = false
    @State private var cropRatio = 0.0
    @State private var cropCommit = 0
    @AppStorage("image.jpegQuality") private var quality = 0.9

    var body: some View {
        VStack(spacing: 0) {
            if let error = session.error {
                HStack {
                    Text(error.localizedDescription).foregroundStyle(.red)
                    Button("image.reload") { Task { await session.load() } }
                    Button("image.saveCopy") { beginCopy() }
                }.padding(8)
            }
            if !session.canOverwrite && !session.isLoading {
                Text("image.copyOnly").font(.caption).padding(8)
            }
            if tool == .crop {
                HStack {
                    Text("image.crop.instructions").font(.caption)
                    Picker("image.crop.ratio", selection: $cropRatio) {
                        Text("image.crop.free").tag(0.0)
                        Text("1:1").tag(1.0)
                        Text("4:3").tag(4.0 / 3)
                        Text("16:9").tag(16.0 / 9)
                        Text("image.crop.original").tag(session.pixelSize.width / max(1, session.pixelSize.height))
                    }.frame(width: 170)
                    Button("image.crop.apply") { cropCommit += 1 }
                    Button("image.cancel") { tool = .pan }
                }.padding(8)
            }
            if session.isLoading {
                ProgressView("image.loading").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let image = session.preview {
                ImageCanvas(image: image, pixelSize: session.pixelSize, tool: tool,
                            zoom: zoom, background: background, cropRatio: cropRatio, cropCommit: cropCommit) { points in
                    var recipe = session.recipe
                    if tool == .mark {
                        recipe.strokes.append(points)
                    } else if tool == .crop, let first = points.first, let last = points.last {
                        // Map the displayed crop back through flips/rotation into source space.
                        let mapped = [first, last].map { point -> CGPoint in
                            var p = point
                            if recipe.flipVertical { p.y = 1 - p.y }
                            if recipe.flipHorizontal { p.x = 1 - p.x }
                            for _ in 0..<((recipe.quarterTurns % 4 + 4) % 4) {
                                p = CGPoint(x: 1 - p.y, y: p.x)
                            }
                            return p
                        }
                        let a = mapped[0], b = mapped[1]
                        guard abs(a.x - b.x) > 0.01, abs(a.y - b.y) > 0.01 else { return }
                        let cropX = min(first.x, last.x), cropY = min(first.y, last.y)
                        let cropWidth = abs(first.x - last.x), cropHeight = abs(first.y - last.y)
                        recipe.strokes = recipe.strokes.map { stroke in
                            stroke.map { CGPoint(x: ($0.x - cropX) / cropWidth, y: ($0.y - cropY) / cropHeight) }
                        }
                        recipe.crop = CGRect(x: recipe.crop.minX + min(a.x, b.x) * recipe.crop.width,
                                             y: recipe.crop.minY + min(a.y, b.y) * recipe.crop.height,
                                             width: abs(a.x - b.x) * recipe.crop.width,
                                             height: abs(a.y - b.y) * recipe.crop.height)
                        tool = .pan
                    }
                    session.edit(recipe)
                }
            } else {
                ContentUnavailableView("image.unavailable", systemImage: "photo")
            }
            HStack {
                Text("\(Int(session.pixelSize.width)) × \(Int(session.pixelSize.height))")
                Spacer()
                Text(session.isDirty ? "image.unsaved" : "image.saved")
                if session.isSaving { ProgressView().controlSize(.small) }
            }.font(.caption).padding(8)
        }
        .navigationTitle(session.url.lastPathComponent)
        .toolbar {
            ToolbarItemGroup {
                Menu {
                    Button("image.fit") { zoom = 0 }.keyboardShortcut("0", modifiers: .command)
                    Button("image.actual") { zoom = 1 }.keyboardShortcut("1", modifiers: .command)
                    Button("image.zoomIn") { zoom = zoom == 0 ? 1 : min(8, zoom * 1.25) }
                    Button("image.zoomOut") { zoom = zoom == 0 ? 0.5 : max(0.05, zoom / 1.25) }
                    Picker("image.background", selection: $background) {
                        Text("image.background.system").tag(0)
                        Text("image.background.light").tag(1)
                        Text("image.background.dark").tag(2)
                    }
                } label: { Label("image.zoom", systemImage: "magnifyingglass") }
                Menu {
                    Button("image.rotate") {
                        change {
                            $0.quarterTurns += 1
                            // Flips are applied after rotation; swap axes to rotate the displayed result.
                            let horizontal = $0.flipHorizontal
                            $0.flipHorizontal = $0.flipVertical
                            $0.flipVertical = horizontal
                            $0.strokes = $0.strokes.map { $0.map { CGPoint(x: $0.y, y: 1 - $0.x) } }
                        }
                    }
                    Button("image.flipHorizontal") {
                        change {
                            $0.flipHorizontal.toggle()
                            $0.strokes = $0.strokes.map { $0.map { CGPoint(x: 1 - $0.x, y: $0.y) } }
                        }
                    }
                    Button("image.flipVertical") {
                        change {
                            $0.flipVertical.toggle()
                            $0.strokes = $0.strokes.map { $0.map { CGPoint(x: $0.x, y: 1 - $0.y) } }
                        }
                    }
                } label: { Label("image.transform", systemImage: "rotate.right") }
                .disabled(session.isSaving)
                Picker("image.tools", selection: $tool) {
                    Label("image.pan", systemImage: "hand.draw").tag(ImageCanvasTool.pan)
                    Label("image.crop", systemImage: "crop").tag(ImageCanvasTool.crop)
                    Label("image.mark", systemImage: "pencil.tip").tag(ImageCanvasTool.mark)
                }.pickerStyle(.segmented)
                    .disabled(session.isSaving)
                Button("image.adjustments", systemImage: "slider.horizontal.3") { showAdjustments.toggle() }
                    .popover(isPresented: $showAdjustments) {
                        VStack(spacing: 16) {
                            adjustment("image.exposure", value: session.recipe.exposure, range: -2...2, initial: 0) { $0.exposure = $1 }
                            adjustment("image.contrast", value: session.recipe.contrast, range: 0.5...2, initial: 1) { $0.contrast = $1 }
                            adjustment("image.saturation", value: session.recipe.saturation, range: 0...2, initial: 1) { $0.saturation = $1 }
                        }.padding().frame(width: 320)
                    }.disabled(session.isSaving)
                Button("image.undo", systemImage: "arrow.uturn.backward") { session.undo() }
                    .disabled(!session.canUndo).keyboardShortcut("z", modifiers: .command)
                Button("image.redo", systemImage: "arrow.uturn.forward") { session.redo() }
                    .disabled(!session.canRedo).keyboardShortcut("z", modifiers: [.command, .shift])
                Button("image.restore", systemImage: "arrow.counterclockwise") { session.edit(.init()) }
                    .disabled(session.isSaving)
                Button("image.save", systemImage: "square.and.arrow.down") {
                    Task { _ = await session.save(quality: quality) }
                }.disabled(!session.isDirty || !session.canOverwrite || session.isSaving || session.hasConflict)
                Button("image.saveCopy", systemImage: "doc.on.doc") { beginCopy() }
                    .disabled(session.isLoading || session.isSaving)
                    .keyboardShortcut("s", modifiers: [.command, .shift])
            }
        }
        .sheet(isPresented: $showCopy) {
            VStack(spacing: 16) {
                Text("image.saveCopy").font(.headline)
                TextField("image.copyName", text: $copyName)
                Text("image.copyLocation").font(.caption)
                HStack {
                    Button("image.cancel") { showCopy = false }
                    Button("image.save") {
                        Task {
                            if await session.save(copyName: copyName, quality: quality) { showCopy = false }
                        }
                    }.disabled(session.isSaving)
                }
                if let error = session.error { Text(error.localizedDescription).foregroundStyle(.red) }
            }.padding(24).frame(width: 380)
        }
    }

    private func beginCopy() {
        copyName = session.url.deletingPathExtension().lastPathComponent + " Copy.png"
        showCopy = true
    }

    private func change(_ mutate: (inout ImageEditRecipe) -> Void) {
        var recipe = session.recipe
        mutate(&recipe)
        session.edit(recipe)
    }

    private func adjustment(_ title: LocalizedStringKey, value: Double, range: ClosedRange<Double>, initial: Double,
                            mutate: @escaping (inout ImageEditRecipe, Double) -> Void) -> some View {
        let binding = Binding(get: { value }, set: { amount in
            guard amount.isFinite else { return }
            change { mutate(&$0, min(range.upperBound, max(range.lowerBound, amount))) }
        })
        return VStack(alignment: .leading) {
            HStack {
                Text(title)
                Spacer()
                TextField(title, value: binding, format: .number.precision(.fractionLength(2))).frame(width: 64)
                Button("image.restore") { change { mutate(&$0, initial) } }
            }
            Slider(value: binding, in: range, onEditingChanged: { editing in
                if editing { session.beginAdjustment() } else { session.endAdjustment() }
            }).accessibilityLabel(Text(title))
        }
    }
}

enum ImageCanvasTool: Hashable { case pan, crop, mark }

@MainActor
private struct ImageCanvas: NSViewRepresentable {
    let image: NSImage
    let pixelSize: CGSize
    let tool: ImageCanvasTool
    let zoom: CGFloat
    let background: Int
    let cropRatio: Double
    let cropCommit: Int
    let onGesture: ([CGPoint]) -> Void

    func makeNSView(context: Context) -> ImageCanvasView { ImageCanvasView() }
    func updateNSView(_ view: ImageCanvasView, context: Context) {
        view.image = image
        view.pixelSize = pixelSize
        if view.tool != tool { view.clearSelection() }
        view.tool = tool
        view.onGesture = onGesture
        view.cropRatio = cropRatio
        if view.cropCommit != cropCommit {
            view.cropCommit = cropCommit
            DispatchQueue.main.async { view.commitCrop() }
        }
        view.fill = background == 1 ? .white : background == 2 ? .darkGray : .windowBackgroundColor
        if view.requestedZoom != zoom { view.requestedZoom = zoom; view.scale = zoom; view.offset = .zero }
        view.needsDisplay = true
    }
}

@MainActor
private final class ImageCanvasView: NSView {
    var image: NSImage?
    var pixelSize = CGSize.zero
    var tool = ImageCanvasTool.pan
    var onGesture: (([CGPoint]) -> Void)?
    var fill = NSColor.windowBackgroundColor
    var requestedZoom: CGFloat = -1
    var scale: CGFloat = 0
    var cropRatio = 0.0
    var cropCommit = 0
    var offset = CGPoint.zero
    private var points: [CGPoint] = []
    private var lastPoint = CGPoint.zero
    private var spacePressed = false
    private var cropRect: CGRect? {
        guard tool == .crop, let a = points.first, let b = points.last, points.count > 1 else { return nil }
        return CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }
    override var acceptsFirstResponder: Bool { true }
    private var displayScale: CGFloat {
        if scale > 0 { return scale }
        return min(bounds.width / max(1, pixelSize.width), bounds.height / max(1, pixelSize.height)) * 0.95
    }
    private var imageRect: CGRect {
        let size = CGSize(width: pixelSize.width * displayScale, height: pixelSize.height * displayScale)
        return CGRect(x: bounds.midX - size.width / 2 + offset.x, y: bounds.midY - size.height / 2 + offset.y,
                      width: size.width, height: size.height)
    }
    override func draw(_ dirtyRect: NSRect) {
        fill.setFill()
        bounds.fill()
        image?.draw(in: imageRect)
        NSColor.controlAccentColor.setStroke()
        let path = NSBezierPath()
        path.lineWidth = 2
        if let rect = cropRect {
            path.appendRect(rect)
            NSColor.controlAccentColor.setFill()
            for corner in corners(rect) {
                CGRect(x: corner.x - 4, y: corner.y - 4, width: 8, height: 8).fill()
            }
        } else if let first = points.first {
            path.move(to: first)
            for point in points.dropFirst() { path.line(to: point) }
        }
        path.stroke()
    }
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        lastPoint = convert(event.locationInWindow, from: nil)
        if let rect = cropRect, let index = corners(rect).firstIndex(where: { hypot($0.x - lastPoint.x, $0.y - lastPoint.y) < 12 }) {
            points = [corners(rect)[(index + 2) % 4], lastPoint]
            return
        }
        points = imageRect.contains(lastPoint) ? [lastPoint] : []
    }
    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if tool == .pan || spacePressed {
            offset.x += point.x - lastPoint.x
            offset.y += point.y - lastPoint.y
        } else if !points.isEmpty {
            var bounded = CGPoint(x: min(imageRect.maxX, max(imageRect.minX, point.x)),
                                  y: min(imageRect.maxY, max(imageRect.minY, point.y)))
            if tool == .crop, cropRatio > 0, let start = points.first {
                let width = min(abs(bounded.x - start.x), abs(bounded.y - start.y) * cropRatio)
                bounded = CGPoint(x: start.x + (bounded.x >= start.x ? width : -width),
                                  y: start.y + (bounded.y >= start.y ? width / cropRatio : -width / cropRatio))
            }
            if tool == .crop { points = [points[0], bounded] } else { points.append(bounded) }
        }
        lastPoint = point
        needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) {
        if tool == .crop { needsDisplay = true; return }
        if tool != .pan && points.count > 1 {
            let rect = imageRect
            onGesture?(points.map { CGPoint(x: ($0.x - rect.minX) / rect.width, y: ($0.y - rect.minY) / rect.height) })
        }
        points = []
        needsDisplay = true
    }
    func clearSelection() { points = []; needsDisplay = true }
    func commitCrop() {
        guard tool == .crop, points.count > 1 else { return }
        let rect = imageRect
        onGesture?(points.map { CGPoint(x: ($0.x - rect.minX) / rect.width, y: ($0.y - rect.minY) / rect.height) })
        clearSelection()
    }
    private func corners(_ rect: CGRect) -> [CGPoint] {
        [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
         CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.maxY)]
    }
    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 49: spacePressed = true
        case 36: commitCrop()
        case 53: clearSelection()
        case 123: offset.x -= 24
        case 124: offset.x += 24
        case 125: offset.y -= 24
        case 126: offset.y += 24
        default: super.keyDown(with: event)
        }
        needsDisplay = true
    }
    override func keyUp(with event: NSEvent) {
        if event.keyCode == 49 { spacePressed = false } else { super.keyUp(with: event) }
    }
    override func scrollWheel(with event: NSEvent) {
        zoom(by: exp(event.scrollingDeltaY * 0.01), at: convert(event.locationInWindow, from: nil))
    }
    override func magnify(with event: NSEvent) {
        zoom(by: 1 + event.magnification, at: convert(event.locationInWindow, from: nil))
    }
    private func zoom(by factor: CGFloat, at point: CGPoint) {
        let old = displayScale
        scale = min(8, max(0.02, old * factor))
        let ratio = scale / old
        offset = CGPoint(x: point.x - bounds.midX - (point.x - bounds.midX - offset.x) * ratio,
                         y: point.y - bounds.midY - (point.y - bounds.midY - offset.y) * ratio)
        needsDisplay = true
    }
}
