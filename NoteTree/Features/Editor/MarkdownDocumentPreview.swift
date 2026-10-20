import SwiftUI

enum MarkdownBlock: Equatable {
    case prose(String)
    case heading(String, Int)
    case code(String)
    case table([[String]])
    case image(String, String)

    static func parse(_ source: String) -> [MarkdownBlock] {
        let lines = source.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var result: [MarkdownBlock] = []
        var index = 0
        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                let fence = String(trimmed.prefix(3))
                index += 1
                var code: [String] = []
                while index < lines.count && !lines[index].trimmingCharacters(in: .whitespaces).hasPrefix(fence) {
                    code.append(lines[index]); index += 1
                }
                result.append(.code(code.joined(separator: "\n")))
            } else if trimmed.hasPrefix("!["), let split = trimmed.range(of: "]("), trimmed.hasSuffix(")") {
                result.append(.image(String(trimmed.dropFirst(2).prefix(upTo: split.lowerBound)),
                                     String(trimmed[split.upperBound...].dropLast())))
            } else if trimmed.hasPrefix("#") && trimmed.contains(" ") {
                let level = trimmed.prefix(while: { $0 == "#" }).count
                if level <= 6 { result.append(.heading(String(trimmed.dropFirst(level)).trimmingCharacters(in: .whitespaces), level)) }
                else { result.append(.prose(line)) }
            } else if index + 1 < lines.count, line.contains("|"), isTableSeparator(lines[index + 1]) {
                var rows = [cells(line)]
                index += 2
                while index < lines.count && lines[index].contains("|") {
                    rows.append(cells(lines[index])); index += 1
                }
                result.append(.table(rows))
                continue
            } else if !trimmed.isEmpty {
                result.append(.prose(line))
            } else {
                result.append(.prose(""))
            }
            index += 1
        }
        return result
    }

    private static func cells(_ line: String) -> [String] {
        var value = line.trimmingCharacters(in: .whitespaces)
        if value.hasPrefix("|") { value.removeFirst() }
        if value.hasSuffix("|") { value.removeLast() }
        return value.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }
    private static func isTableSeparator(_ line: String) -> Bool {
        let values = cells(line)
        return !values.isEmpty && values.allSatisfy {
            let value = $0.replacingOccurrences(of: ":", with: "")
            return value.count >= 3 && value.allSatisfy { $0 == "-" }
        }
    }
}

@MainActor
struct MarkdownDocumentPreview: View {
    let session: MarkdownDocumentSession
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 6) {
                ForEach(Array(MarkdownBlock.parse(session.text).enumerated()), id: \.offset) { _, block in
                    switch block {
                    case .prose(let source):
                        if source.hasPrefix(">") {
                            HStack {
                                Rectangle().fill(.secondary).frame(width: 3)
                                inline(String(source.dropFirst()).trimmingCharacters(in: .whitespaces))
                            }.padding(.leading, 8)
                        } else if source.hasPrefix("- ") || source.hasPrefix("* ") {
                            HStack(alignment: .top) { Text("•"); inline(String(source.dropFirst(2))) }
                        } else {
                            inline(source.isEmpty ? " " : source)
                        }
                    case .heading(let source, let level):
                        inline(source).font(.system(size: CGFloat(30 - level * 2), weight: .bold)).padding(.top, 8)
                    case .code(let code):
                        ScrollView(.horizontal) {
                            Text(code).font(.body.monospaced()).padding(12)
                        }.background(.quaternary.opacity(0.5))
                    case .table(let rows):
                        ScrollView(.horizontal) {
                            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                                ForEach(rows.indices, id: \.self) { row in
                                    GridRow {
                                        ForEach(rows[row].indices, id: \.self) { column in
                                            inline(rows[row][column]).fontWeight(row == 0 ? .bold : .regular)
                                                .padding(6)
                                        }
                                    }
                                    Divider()
                                }
                            }
                        }
                    case .image(let alt, let path):
                        MarkdownLocalImage(session: session, alt: alt, path: path)
                    }
                }
            }.frame(maxWidth: 760, alignment: .leading).frame(maxWidth: .infinity).padding(24)
                .textSelection(.enabled)
        }.accessibilityIdentifier("markdown.preview")
    }
    private func inline(_ text: String) -> Text {
        Text((try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text))
    }
}

@MainActor
private struct MarkdownLocalImage: View {
    let session: MarkdownDocumentSession
    let alt: String
    let path: String
    @State private var image: NSImage?
    var body: some View {
        Group {
            if let image { Image(nsImage: image).resizable().scaledToFit().accessibilityLabel(alt) }
            else { Label(alt.isEmpty ? String(localized: "markdown.imageUnavailable") : alt, systemImage: "photo") }
        }.task(id: path) {
            image = nil
            if let data = await session.localImagePreview(path), !Task.isCancelled { image = NSImage(data: data) }
        }
    }
}
