import CryptoKit
import Foundation

@MainActor
protocol MarkdownDraftStoring: AnyObject {
    func draft(for workspaceID: WorkspaceID, fileURL: URL) -> String?
    func saveDraft(_ text: String, for workspaceID: WorkspaceID, fileURL: URL)
    func removeDraft(for workspaceID: WorkspaceID, fileURL: URL)
}

@MainActor
final class MarkdownDraftStore: MarkdownDraftStoring {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func draft(for workspaceID: WorkspaceID, fileURL: URL) -> String? {
        defaults.string(forKey: key(for: workspaceID, fileURL: fileURL))
    }

    func saveDraft(_ text: String, for workspaceID: WorkspaceID, fileURL: URL) {
        defaults.set(text, forKey: key(for: workspaceID, fileURL: fileURL))
    }

    func removeDraft(for workspaceID: WorkspaceID, fileURL: URL) {
        defaults.removeObject(forKey: key(for: workspaceID, fileURL: fileURL))
    }

    private func key(for workspaceID: WorkspaceID, fileURL: URL) -> String {
        let input = "\(workspaceID.rawValue.uuidString)|\(fileURL.standardizedFileURL.path)"
        let digest = SHA256.hash(data: Data(input.utf8))
        return "markdownDraft.\(digest.map { String(format: "%02x", $0) }.joined())"
    }
}
