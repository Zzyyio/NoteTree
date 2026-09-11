import Foundation

protocol MarkdownSaveDelaying: Sendable {
    func wait() async throws
}

struct SystemMarkdownSaveDelay: MarkdownSaveDelaying {
    func wait() async throws {
        try await Task.sleep(for: .milliseconds(600))
    }
}
