import PDFKit
import SwiftUI

@MainActor
struct PDFReaderView: View {
    let controller: PDFEditorController
    @State private var sidebar: Sidebar = .hidden
    @State private var isShowingFind = false
    @State private var pageInput = "1"
    @FocusState private var findIsFocused: Bool

    private enum Sidebar {
        case hidden
        case outline
        case thumbnails
    }

    var body: some View {
        Group {
            switch controller.state {
            case .loading:
                ProgressView("pdf.loading")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .locked:
                passwordView
            case .failed(let error):
                ContentUnavailableView {
                    Label("pdf.error.title", systemImage: "doc.badge.exclamationmark")
                } description: {
                    Text(error.localizedDescription)
                } actions: {
                    Button("pdf.retry") {
                        Task { await controller.load() }
                    }
                }
            case .ready:
                reader
            }
        }
        .accessibilityIdentifier("pdf.reader")
        .onChange(of: controller.currentPageNumber, initial: true) { _, page in
            pageInput = String(page)
        }
    }

    private var reader: some View {
        VStack(spacing: 0) {
            if isShowingFind {
                findBar
                Divider()
            }
            HSplitView {
                if sidebar != .hidden {
                    navigationSidebar
                        .frame(minWidth: 170, idealWidth: 210, maxWidth: 320)
                }
                PDFViewRepresentable(controller: controller)
                    .frame(minWidth: 280, maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityIdentifier("pdf.canvas")
            }
            Divider()
            statusBar
        }
        .toolbar {
            ToolbarItemGroup {
                sidebarMenu
                pageControls
                zoomMenu
                displayModeMenu
                editingTools
                Button("pdf.undo", systemImage: "arrow.uturn.backward") { controller.undo() }
                    .disabled(!controller.canUndo)
                    .help("pdf.undo")
                Button("pdf.redo", systemImage: "arrow.uturn.forward") { controller.redo() }
                    .disabled(!controller.canRedo)
                    .help("pdf.redo")
                Button("pdf.save", systemImage: "square.and.arrow.down") {
                    Task { await controller.save() }
                }
                .disabled(!controller.isDirty || controller.isSaving || !controller.editingAllowed)
                .help("pdf.save")
                Button("pdf.find", systemImage: "magnifyingglass") {
                    isShowingFind = true
                    findIsFocused = true
                }
                .keyboardShortcut("f", modifiers: .command)
                .help("pdf.find")
                Button("pdf.copy", systemImage: "doc.on.doc") {
                    controller.pdfView.copy(nil)
                }
                .disabled(!controller.copyingAllowed)
                .help("pdf.copy")
            }
        }
    }

    private var sidebarMenu: some View {
        Menu {
            Picker("pdf.navigation", selection: $sidebar) {
                Text("pdf.navigation.hidden").tag(Sidebar.hidden)
                Text("pdf.outline").tag(Sidebar.outline)
                Text("pdf.thumbnails").tag(Sidebar.thumbnails)
            }
        } label: {
            Label("pdf.navigation", systemImage: "sidebar.leading")
        }
        .help("pdf.navigation")
    }

    private var navigationSidebar: some View {
        VStack(spacing: 0) {
            Picker("pdf.navigation", selection: $sidebar) {
                Text("pdf.outline").tag(Sidebar.outline)
                Text("pdf.thumbnails").tag(Sidebar.thumbnails)
            }
            .pickerStyle(.segmented)
            .padding(8)
            Divider()
            if sidebar == .outline {
                PDFOutlineView(controller: controller)
            } else {
                PDFThumbnailViewRepresentable(controller: controller)
                    .accessibilityIdentifier("pdf.thumbnails")
            }
        }
    }

    private var pageControls: some View {
        HStack(spacing: 6) {
            Button("pdf.page.previous", systemImage: "chevron.up") {
                controller.previousPage()
            }
            .disabled(controller.currentPageNumber <= 1)
            .help("pdf.page.previous")
            TextField("pdf.page.number", text: $pageInput)
                .multilineTextAlignment(.trailing)
                .textFieldStyle(.roundedBorder)
                .frame(width: 48)
                .onSubmit {
                    if let page = Int(pageInput) {
                        controller.goToPage(page)
                    }
                    pageInput = String(controller.currentPageNumber)
                }
                .accessibilityLabel("pdf.page.number")
                .accessibilityIdentifier("pdf.pageNumber")
            Text("pdf.page.total \(controller.pageCount)")
                .foregroundStyle(.secondary)
            Button("pdf.page.next", systemImage: "chevron.down") {
                controller.nextPage()
            }
            .disabled(controller.currentPageNumber >= controller.pageCount)
            .help("pdf.page.next")
        }
        .labelStyle(.iconOnly)
    }

    private var zoomMenu: some View {
        Menu {
            Button("pdf.zoom.in", systemImage: "plus.magnifyingglass") {
                controller.zoomIn()
            }
            Button("pdf.zoom.out", systemImage: "minus.magnifyingglass") {
                controller.zoomOut()
            }
            Divider()
            Button("pdf.zoom.fitPage") { controller.fitPage() }
                .keyboardShortcut("0", modifiers: .command)
            Button("pdf.zoom.fitWidth") { controller.fitWidth() }
            Button("pdf.zoom.actualSize") { controller.actualSize() }
                .keyboardShortcut("1", modifiers: .command)
        } label: {
            Text(controller.scaleFactor, format: .percent.precision(.fractionLength(0)))
                .monospacedDigit()
        }
        .accessibilityLabel("pdf.zoom")
        .help("pdf.zoom")
    }

    private var displayModeMenu: some View {
        Menu {
            Picker("pdf.displayMode", selection: Binding(
                get: { controller.displayMode },
                set: { controller.setDisplayMode($0) }
            )) {
                Text("pdf.displayMode.continuous").tag(PDFReaderDisplayMode.continuous)
                Text("pdf.displayMode.singlePage").tag(PDFReaderDisplayMode.singlePage)
                Text("pdf.displayMode.twoUp").tag(PDFReaderDisplayMode.twoUp)
            }
        } label: {
            Label("pdf.displayMode", systemImage: "rectangle.split.2x1")
        }
        .help("pdf.displayMode")
    }

    private var editingTools: some View {
        Picker("pdf.editing.tools", selection: Binding(
            get: { controller.editingTool },
            set: { controller.setEditingTool($0) }
        )) {
            Label("pdf.tool.browse", systemImage: "cursorarrow")
                .tag(PDFEditingTool.browse)
            Label("pdf.tool.text", systemImage: "textbox")
                .tag(PDFEditingTool.text)
            Label("pdf.tool.ink", systemImage: "pencil.tip")
                .tag(PDFEditingTool.ink)
            Label("pdf.tool.eraser", systemImage: "eraser")
                .tag(PDFEditingTool.eraser)
        }
        .pickerStyle(.segmented)
        .frame(width: 156)
        .disabled(!controller.editingAllowed)
        .help("pdf.editing.tools")
    }

    private var findBar: some View {
        @Bindable var controller = controller

        return HStack(spacing: 8) {
            TextField("pdf.find.placeholder", text: $controller.searchQuery)
                .textFieldStyle(.roundedBorder)
                .focused($findIsFocused)
                .onChange(of: controller.searchQuery) { _, _ in controller.startSearch() }
                .onSubmit { controller.nextSearchResult() }
                .accessibilityIdentifier("pdf.find.field")
            if controller.isSearching {
                ProgressView().controlSize(.small)
            } else if !controller.searchQuery.isEmpty {
                Text("pdf.find.matches \(controller.results.count)")
                    .foregroundStyle(.secondary)
                    .fixedSize()
                    .accessibilityIdentifier("pdf.find.matches")
            }
            Button("pdf.find.previous", systemImage: "chevron.up") {
                controller.previousSearchResult()
            }
            .help("pdf.find.previous")
            .disabled(controller.results.isEmpty)
            Button("pdf.find.next", systemImage: "chevron.down") {
                controller.nextSearchResult()
            }
            .help("pdf.find.next")
            .disabled(controller.results.isEmpty)
            Button("pdf.find.close", systemImage: "xmark") {
                controller.cancelSearch()
                isShowingFind = false
            }
            .help("pdf.find.close")
        }
        .labelStyle(.iconOnly)
        .padding(8)
        .background(.bar)
    }

    private var statusBar: some View {
        HStack(spacing: 12) {
            if controller.editingAllowed {
                Label("pdf.editable", systemImage: "pencil")
            } else {
                Label("pdf.readOnly", systemImage: "eye")
            }
            if controller.isSaving {
                ProgressView().controlSize(.small)
                Text("pdf.saving")
            } else if let saveError = controller.saveError {
                Text(saveError.localizedDescription)
                    .foregroundStyle(.red)
            } else if controller.isDirty {
                Text("pdf.unsavedChanges")
                    .foregroundStyle(.orange)
            }
            if !controller.copyingAllowed {
                Label("pdf.copy.restricted", systemImage: "lock")
            } else if controller.currentPageHasText == false {
                Text("pdf.page.noText")
            }
            Spacer(minLength: 0)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.bar)
    }

    private var passwordView: some View {
        @Bindable var controller = controller

        return ContentUnavailableView {
            Label("pdf.password.title", systemImage: "lock.doc")
        } description: {
            Text("pdf.password.description")
        } actions: {
            SecureField("pdf.password.placeholder", text: $controller.password)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 260)
                .onSubmit { unlock() }
                .accessibilityIdentifier("pdf.password")
            if controller.passwordRejected {
                Text("pdf.password.incorrect")
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("pdf.password.incorrect")
            }
            Button("pdf.password.unlock") { unlock() }
                .buttonStyle(.borderedProminent)
                .disabled(controller.password.isEmpty)
        }
    }

    private func unlock() {
        Task { await controller.unlock() }
    }
}
