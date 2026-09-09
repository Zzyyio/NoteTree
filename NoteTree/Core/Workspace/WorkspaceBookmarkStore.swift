import Foundation

struct ResolvedBookmark: Sendable {
    let url: URL
    let isStale: Bool
}

protocol SecurityScopedBookmarkProviding: Sendable {
    func makeBookmark(for url: URL) throws -> Data
    func resolveBookmark(_ data: Data) throws -> ResolvedBookmark
}

struct SystemSecurityScopedBookmarkProvider: SecurityScopedBookmarkProviding {
    func makeBookmark(for url: URL) throws -> Data {
        try url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
    }

    func resolveBookmark(_ data: Data) throws -> ResolvedBookmark {
        var isStale = false
        let url = try URL(
            resolvingBookmarkData: data,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
        return ResolvedBookmark(url: url, isStale: isStale)
    }
}

actor WorkspaceBookmarkStore {
    private struct Record: Codable, Sendable {
        let workspace: Workspace
        let bookmarkData: Data
    }

    private let defaultsSuiteName: String?
    private let defaultsKey: String
    private let provider: any SecurityScopedBookmarkProviding

    init(
        defaultsSuiteName: String? = nil,
        defaultsKey: String = "recentWorkspaces",
        provider: any SecurityScopedBookmarkProviding = SystemSecurityScopedBookmarkProvider()
    ) {
        self.defaultsSuiteName = defaultsSuiteName
        self.defaultsKey = defaultsKey
        self.provider = provider
    }

    var recents: [RecentWorkspace] {
        records().map { RecentWorkspace(workspace: $0.workspace) }
    }

    func saveWorkspace(at rootURL: URL, now: Date = .now) throws -> Workspace {
        let normalizedURL = rootURL.standardizedFileURL
        let values = try normalizedURL.resourceValues(forKeys: [.isDirectoryKey, .nameKey])
        guard values.isDirectory == true else {
            throw WorkspaceError.notDirectory
        }

        let bookmarkData = try provider.makeBookmark(for: normalizedURL)
        let displayName = values.name ?? normalizedURL.lastPathComponent
        let existingWorkspace = records().first { record in
            record.workspace.rootURL.standardizedFileURL == normalizedURL
        }?.workspace
        let workspace = Workspace(
            id: existingWorkspace?.id ?? WorkspaceID(),
            rootURL: normalizedURL,
            displayName: displayName,
            lastOpenedAt: now
        )
        var updatedRecords = records().filter {
            $0.workspace.rootURL.standardizedFileURL != normalizedURL
        }
        updatedRecords.insert(Record(workspace: workspace, bookmarkData: bookmarkData), at: 0)
        save(updatedRecords)
        return workspace
    }

    func restoreMostRecent() -> WorkspaceBookmarkResolution {
        guard let record = records().first else {
            return .none
        }
        return resolve(record)
    }

    func resolve(_ recentWorkspace: RecentWorkspace) -> WorkspaceBookmarkResolution {
        guard let record = records().first(where: { $0.workspace.id == recentWorkspace.id }) else {
            return .needsReauthorization(recentWorkspace)
        }
        return resolve(record)
    }

    private func resolve(_ record: Record) -> WorkspaceBookmarkResolution {
        do {
            let resolvedBookmark = try provider.resolveBookmark(record.bookmarkData)
            let normalizedURL = resolvedBookmark.url.standardizedFileURL
            let values = try normalizedURL.resourceValues(forKeys: [.isDirectoryKey, .nameKey])
            guard values.isDirectory == true else {
                return .needsReauthorization(RecentWorkspace(workspace: record.workspace))
            }

            var workspace = record.workspace
            workspace = Workspace(
                id: workspace.id,
                rootURL: normalizedURL,
                displayName: values.name ?? normalizedURL.lastPathComponent,
                lastOpenedAt: workspace.lastOpenedAt
            )

            if resolvedBookmark.isStale {
                let refreshedData = try provider.makeBookmark(for: normalizedURL)
                replace(Record(workspace: workspace, bookmarkData: refreshedData))
            }
            return .workspace(workspace)
        } catch {
            return .needsReauthorization(RecentWorkspace(workspace: record.workspace))
        }
    }

    private func records() -> [Record] {
        guard let data = defaults().data(forKey: defaultsKey) else {
            return []
        }
        return (try? JSONDecoder().decode([Record].self, from: data)) ?? []
    }

    private func replace(_ record: Record) {
        var updatedRecords = records().filter { $0.workspace.id != record.workspace.id }
        updatedRecords.insert(record, at: 0)
        save(updatedRecords)
    }

    private func save(_ records: [Record]) {
        guard let data = try? JSONEncoder().encode(records) else {
            return
        }
        defaults().set(data, forKey: defaultsKey)
    }

    private func defaults() -> UserDefaults {
        guard let defaultsSuiteName else {
            return .standard
        }
        return UserDefaults(suiteName: defaultsSuiteName) ?? .standard
    }
}

enum WorkspaceBookmarkResolution: Sendable {
    case none
    case workspace(Workspace)
    case needsReauthorization(RecentWorkspace)
}
