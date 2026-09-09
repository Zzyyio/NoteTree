import Foundation

struct WorkspaceID: Codable, Hashable, Identifiable, Sendable {
    let rawValue: UUID

    init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }

    var id: UUID {
        rawValue
    }
}

struct Workspace: Codable, Equatable, Identifiable, Sendable {
    let id: WorkspaceID
    let rootURL: URL
    let displayName: String
    let lastOpenedAt: Date
}

struct RecentWorkspace: Codable, Equatable, Identifiable, Sendable {
    let workspace: Workspace

    var id: WorkspaceID {
        workspace.id
    }
}
