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
                        MarkdownPreview(text: session.text)
                    }
                case .preview:
                    MarkdownPreview(text: session.text)
                }
            }
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
                    isShowingFind.toggle()
                }
                Button("markdown.bold", systemImage: "bold") {
                    insert("****")
                }
                Button("markdown.italic", systemImage: "italic") {
                    insert("**")
                }
                Button("markdown.link", systemImage: "link") {
                    insert("[](https://)")
                }
                
            }
        }
        .sheet(isPresented: $isShowingDifference) {
            MarkdownDifferenceSheet(difference: session.difference())
        }
    }

    private func sourceEditor(text: Binding<String>) -> some View {
        TextEditor(text: text)
            .font(.body.monospaced())
            .padding(16)
            .disabled(session.isReadOnly || session.state == .conflict)
            .onChange(of: text.wrappedValue) { _, newValue in
                session.updateText(newValue)
            }
            .accessibilityIdentifier("markdown.editor")
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

    private func insert(_ snippet: String) {
        session.updateText(session.text + snippet)
    }
}

@MainActor
private struct MarkdownPreview: View {
    let text: String

    var body: some View {
        ScrollView {
            Group {
                if let rendered = try? AttributedString(
                    markdown: MarkdownPreviewFormatter.renderingSource(for: text),
                    options: .init(interpretedSyntax: .full)
                ) {
                    Text(rendered)
                } else {
                    Text(text)
                        .font(.body.monospaced())
                }
            }
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
            .textSelection(.enabled)
            .padding(24)
        }
        .accessibilityIdentifier("markdown.preview")
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
