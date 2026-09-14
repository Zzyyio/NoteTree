import Foundation

enum MarkdownPreviewFormatter {
    /// NoteTree treats a single source newline as a visible line break in prose while
    /// preserving CommonMark's original source and every line inside fenced code blocks.
    static func renderingSource(for text: String) -> String {
        let normalizedText = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let lines = normalizedText.components(separatedBy: "\n")
        guard lines.count > 1 else {
            return normalizedText
        }

        var renderedLines: [String] = []
        var activeFence: Character?

        for index in lines.indices {
            let line = lines[index]
            let fence = fenceCharacter(in: line)
            let isInsideFencedCode = activeFence != nil || fence != nil
            renderedLines.append(line)

            if let currentFence = activeFence, fence == currentFence {
                activeFence = nil
            } else if activeFence == nil, let fence {
                activeFence = fence
            }

            guard index < lines.index(before: lines.endIndex) else {
                continue
            }

            let nextLineIsEmpty = lines[index + 1]
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty
            if !isInsideFencedCode,
               !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               !nextLineIsEmpty {
                renderedLines[renderedLines.count - 1] += "  "
            }
        }

        return renderedLines.joined(separator: "\n")
    }

    private static func fenceCharacter(in line: String) -> Character? {
        let trimmedLine = line.drop(while: { $0 == " " || $0 == "\t" })
        guard let firstCharacter = trimmedLine.first,
              firstCharacter == "`" || firstCharacter == "~" else {
            return nil
        }
        let prefixLength = trimmedLine.prefix { $0 == firstCharacter }.count
        return prefixLength >= 3 ? firstCharacter : nil
    }
}
