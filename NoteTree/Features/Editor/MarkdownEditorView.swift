import SwiftUI

enum MarkdownViewMode: String, CaseIterable, Identifiable {
    case editor
    case split
    case preview

    var id: Self { self }
}

@MainActor
struct MarkdownEditorHost: View {
    let node: FileNode
    let workspaceStore: WorkspaceStore

    var body: some View {
        Group {
            if let session = workspaceStore.markdownSession, session.url == node.url {
                MarkdownEditorView(session: session)
            } else {
                ProgressView("markdown.loading")
            }
        }
        .task(id: node.id) {
            await workspaceStore.openMarkdown(node)
        }
        .onDisappear {
            Task {
                _ = await workspaceStore.flushCurrentMarkdown()
            }
        }
    }
}

@MainActor
private struct MarkdownEditorView: View {
    let session: MarkdownDocumentSession
    @State private var viewMode: MarkdownViewMode = .editor
    @State private var isShowingFind = false
    @State private var findText = ""
    @State private var isShowingDifference = false
    @State private var editor: NSTextView?
    @AppStorage("editor.fontSize") private var fontSize = 14.0
    @AppStorage("editor.wrap") private var wraps = true

    var body: some View {
        @Bindable var session = session

        VStack(spacing: 0) {
            if case .conflict = session.state {
                conflictBanner
            }
            if case .failed(let error) = session.state {
                errorBanner(error)
            }
            if case .readOnly(let error) = session.state {
                errorBanner(error)
            }
            if isShowingFind {
                findBar
            }

            Group {
                switch viewMode {
                case .editor:
                    sourceEditor(text: $session.text)
                case .split:
                    HSplitView {
                        sourceEditor(text: $session.text)
                        MarkdownDocumentPreview(session: session)
                    }
                case .preview:
                    MarkdownDocumentPreview(session: session)
                }
            }
            HStack {
                Text(session.url.lastPathComponent)
                Spacer()
                if session.state == .saving {
                    ProgressView().controlSize(.small)
                    Text("markdown.saving")
                } else {
                    Text(session.isDirty ? "image.unsaved" : "image.saved")
                }
            }.font(.caption).foregroundStyle(.secondary).padding(8)
        }
        .navigationTitle(session.url.lastPathComponent)
        .toolbar {
            ToolbarItemGroup {
                Picker("markdown.viewMode", selection: $viewMode) {
                    Text("markdown.mode.editor").tag(MarkdownViewMode.editor)
                    Text("markdown.mode.split").tag(MarkdownViewMode.split)
                    Text("markdown.mode.preview").tag(MarkdownViewMode.preview)
                }
                .pickerStyle(.segmented)
                .frame(width: 190)

                Button("markdown.find", systemImage: "magnifyingglass") {
                    let item = NSMenuItem()
                    item.tag = NSTextFinder.Action.showFindInterface.rawValue
                    editor?.performFindPanelAction(item)
                }.keyboardShortcut("f", modifiers: .command)
                Button("markdown.bold", systemImage: "bold") {
                    wrapSelection(prefix: "**", suffix: "**")
                }.keyboardShortcut("b", modifiers: .command)
                Button("markdown.italic", systemImage: "italic") {
                    wrapSelection(prefix: "*", suffix: "*")
                }.keyboardShortcut("i", modifiers: .command)
                Button("markdown.link", systemImage: "link") {
                    wrapSelection(prefix: "[", suffix: "](https://)")
                }.keyboardShortcut("k", modifiers: .command)
                
            }
        }
        .sheet(isPresented: $isShowingDifference) {
            MarkdownDifferenceSheet(difference: session.difference())
        }
    }

    private func sourceEditor(text: Binding<String>) -> some View {
        MarkdownSourceEditor(session: session, fontSize: fontSize, wraps: wraps, editor: $editor)
    }

    private var findBar: some View {
        HStack {
            TextField("markdown.find.placeholder", text: $findText)
                .textFieldStyle(.roundedBorder)
            Text("markdown.find.matches \(matchCount)")
                .foregroundStyle(.secondary)
            Button("markdown.find.close") {
                isShowingFind = false
            }
        }
        .padding(8)
        .background(.bar)
    }

    private var conflictBanner: some View {
        HStack(spacing: 12) {
            Label("markdown.conflict.title", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text("markdown.conflict.description")
                .foregroundStyle(.secondary)
            Spacer()
            Button("markdown.conflict.difference") {
                isShowingDifference = true
            }
            Button("markdown.conflict.keepCopy") {
                Task {
                    if await session.saveLocalCopy() != nil {
                        await session.reloadExternalVersion()
                    }
                }
            }
            Button("markdown.conflict.reload") {
                Task {
                    await session.reloadExternalVersion()
                }
            }
        }
        .font(.callout)
        .padding(10)
        .background(Color.orange.opacity(0.14))
        .accessibilityIdentifier("markdown.conflict")
    }

    private func errorBanner(_ error: WorkspaceError) -> some View {
        HStack {
            Label(error.localizedDescription, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.red)
            Spacer()
            if !session.isReadOnly {
                Button("markdown.retrySave") {
                    Task {
                        _ = await session.saveNow()
                    }
                }
            }
        }
        .font(.callout)
        .padding(10)
        .background(Color.red.opacity(0.12))
    }

    private var matchCount: Int {
        let needle = findText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else {
            return 0
        }
        return session.text.lowercased().components(separatedBy: needle.lowercased()).count - 1
    }

    private func wrapSelection(prefix: String, suffix: String) {
        guard let editor, editor.isEditable else { return }
        let range = editor.selectedRange()
        let selected = (editor.string as NSString).substring(with: range)
        guard editor.shouldChangeText(in: range, replacementString: prefix + selected + suffix) else { return }
        editor.textStorage?.replaceCharacters(in: range, with: prefix + selected + suffix)
        editor.didChangeText()
        editor.setSelectedRange(NSRange(location: range.location + (prefix as NSString).length, length: range.length))
        editor.window?.makeFirstResponder(editor)
    }
}

@MainActor
private struct MarkdownDifferenceSheet: View {
    let difference: MarkdownTextDifference?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("markdown.conflict.difference")
                    .font(.headline)
                Spacer()
                Button("markdown.done") {
                    dismiss()
                }
            }
            .padding()

            if let difference {
                HSplitView {
                    differenceColumn(title: "markdown.conflict.local", text: difference.localText)
                    differenceColumn(title: "markdown.conflict.external", text: difference.externalText)
                }
            } else {
                ContentUnavailableView("markdown.conflict.noDifference", systemImage: "doc.text")
            }
        }
        .frame(minWidth: 680, minHeight: 420)
    }

    private func differenceColumn(title: LocalizedStringKey, text: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            ScrollView {
                Text(text)
                    .font(.body.monospaced())
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
        }
        .padding()
    }
}
