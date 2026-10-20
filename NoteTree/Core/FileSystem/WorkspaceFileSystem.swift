import Foundation
import OSLog

protocol WorkspaceFileSystem: Sendable {
    func children(of directory: URL) async throws -> [FileNode]
    func matchingEntries(query: String) async throws -> [FileNode]
    func createMarkdown(named name: String, in directory: URL) async throws -> FileNode
    func createDirectory(named name: String, in directory: URL) async throws -> FileNode
    func renameItem(at url: URL, to name: String) async throws -> FileNode
    func moveItem(at url: URL, to destinationDirectory: URL) async throws -> FileNode
    func trashItem(at url: URL) async throws
    func itemInfo(at url: URL) async throws -> FileItemInfo
    func readData(at url: URL) async throws -> VersionedFileData
    func writeData(_ data: Data, to url: URL, expectedVersion: FileVersion) async throws -> FileVersion
    func writeCopy(of data: Data, for url: URL, named name: String) async throws -> URL
}

protocol WorkspaceItemTrashing: Sendable {
    func trashItem(at url: URL) throws
}

struct SystemWorkspaceTrash: WorkspaceItemTrashing {
    func trashItem(at url: URL) throws {
        var resultingItemURL: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &resultingItemURL)
    }
}

actor LocalWorkspaceFileSystem: WorkspaceFileSystem {
    private let rootURL: URL
    private let workspaceID: WorkspaceID
    private let workspaceDisplayName: String
    private let typeDetector: any FileTypeDetecting
    private let exclusionPolicy: FileTreeExclusionPolicy
    private let logger: Logger
    private let fileManager: FileManager
    private let trashProvider: any WorkspaceItemTrashing

    init(
        workspace: Workspace,
        typeDetector: any FileTypeDetecting = SystemFileTypeDetector(),
        exclusionPolicy: FileTreeExclusionPolicy = FileTreeExclusionPolicy(),
        logger: Logger = AppLog.fileSystem,
        fileManager: FileManager = .default,
        trashProvider: any WorkspaceItemTrashing = SystemWorkspaceTrash()
    ) {
        rootURL = workspace.rootURL.standardizedFileURL.resolvingSymlinksInPath()
        workspaceID = workspace.id
        workspaceDisplayName = workspace.displayName
        self.typeDetector = typeDetector
        self.exclusionPolicy = exclusionPolicy
        self.logger = logger
        self.fileManager = fileManager
        self.trashProvider = trashProvider
    }

    func children(of directory: URL) async throws -> [FileNode] {
        let validatedDirectory = try validatedDirectoryURL(directory)

        do {
            let urls = try fileManager.contentsOfDirectory(
                at: validatedDirectory,
                includingPropertiesForKeys: [.isDirectoryKey, .isHiddenKey, .isPackageKey, .fileSizeKey, .contentModificationDateKey],
                options: exclusionPolicy.showHidden ? [.skipsPackageDescendants] : [.skipsHiddenFiles, .skipsPackageDescendants]
            )

            let nodes = urls.compactMap { url -> FileNode? in
                guard !exclusionPolicy.shouldExclude(url), !isSymbolicLink(url) else {
                    return nil
                }

                return try? node(for: url)
            }

            return nodes.sorted(by: nodeSortOrder)
        } catch let error as CocoaError where error.code == .fileNoSuchFile {
            throw WorkspaceError.fileNotFound
        } catch let error as CocoaError where error.code == .fileReadNoPermission {
            throw WorkspaceError.permissionDenied
        } catch {
            logger.error("Could not read a workspace directory")
            throw WorkspaceError.readFailed
        }
    }

    func matchingEntries(query: String) async throws -> [FileNode] {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedQuery.isEmpty else {
            return []
        }

        guard let enumerator = fileManager.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey, .isHiddenKey, .isPackageKey, .fileSizeKey, .contentModificationDateKey],
            options: exclusionPolicy.showHidden ? [.skipsPackageDescendants] : [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            throw WorkspaceError.readFailed
        }

        var matches: [FileNode] = []
        while let url = enumerator.nextObject() as? URL {
            if Task.isCancelled {
                return []
            }

            if exclusionPolicy.shouldExclude(url) || isSymbolicLink(url) {
                let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                if isDirectory {
                    enumerator.skipDescendants()
                }
                continue
            }

            guard let node = try? node(for: url) else {
                continue
            }

            if node.displayName.localizedCaseInsensitiveContains(normalizedQuery)
                || node.relativePath.localizedCaseInsensitiveContains(normalizedQuery) {
                matches.append(node)
            }
        }

        return matches.sorted(by: nodeSortOrder)
    }

    func createMarkdown(named name: String, in directory: URL) async throws -> FileNode {
        let targetURL = try targetURL(named: name, in: directory)

        do {
            // A newly created empty note has no original to replace. `withoutOverwriting`
            // makes this single-file creation fail if another writer won the name race.
            try Data().write(to: targetURL, options: .withoutOverwriting)
            return try node(for: targetURL)
        } catch {
            throw mapOperationError(error, defaultError: .writeFailed)
        }
    }

    func createDirectory(named name: String, in directory: URL) async throws -> FileNode {
        let targetURL = try targetURL(named: name, in: directory)

        do {
            try fileManager.createDirectory(at: targetURL, withIntermediateDirectories: false)
            return try node(for: targetURL)
        } catch {
            throw mapOperationError(error, defaultError: .writeFailed)
        }
    }

    func renameItem(at url: URL, to name: String) async throws -> FileNode {
        let sourceURL = try validatedExistingURL(url)
        try ensureNotRoot(sourceURL)
        let parentURL = sourceURL.deletingLastPathComponent()
        return try moveExistingItem(at: sourceURL, named: name, to: parentURL)
    }

    func moveItem(at url: URL, to destinationDirectory: URL) async throws -> FileNode {
        let sourceURL = try validatedExistingURL(url)
        try ensureNotRoot(sourceURL)
        let destinationURL = try validatedDirectoryURL(destinationDirectory)

        guard sourceURL.deletingLastPathComponent() != destinationURL else {
            return try node(for: sourceURL)
        }

        return try moveExistingItem(
            at: sourceURL,
            named: sourceURL.lastPathComponent,
            to: destinationURL
        )
    }

    func trashItem(at url: URL) async throws {
        let sourceURL = try validatedExistingURL(url)
        try ensureNotRoot(sourceURL)

        do {
            try coordinateWriting(sourceURL, options: .forDeleting) { coordinatedSourceURL in
                try self.trashProvider.trashItem(at: coordinatedSourceURL)
            }
        } catch {
            throw mapOperationError(error, defaultError: .trashFailed)
        }
    }

    func itemInfo(at url: URL) async throws -> FileItemInfo {
        let itemURL = try validatedExistingURL(url)

        do {
            let values = try itemURL.resourceValues(forKeys: [
                .isDirectoryKey,
                .fileSizeKey,
                .contentModificationDateKey
            ])
            let isDirectory = values.isDirectory == true
            let directChildCount = isDirectory ? try visibleDirectChildCount(in: itemURL) : nil

            return FileItemInfo(
                displayName: itemURL == rootURL ? workspaceDisplayName : itemURL.lastPathComponent,
                relativePath: relativePath(for: itemURL),
                kind: isDirectory ? .folder : typeDetector.kind(for: itemURL),
                byteCount: values.fileSize,
                modificationDate: values.contentModificationDate,
                directChildCount: directChildCount
            )
        } catch {
            throw mapOperationError(error, defaultError: .readFailed)
        }
    }

    func readData(at url: URL) async throws -> VersionedFileData {
        let itemURL = try validatedExistingURL(url)
        do {
            var result: Result<VersionedFileData, Error>?
            var coordinationError: NSError?
            NSFileCoordinator().coordinate(readingItemAt: itemURL, options: [], error: &coordinationError) { coordinatedURL in
                do {
                    // A file presenter may redirect a coordinated read. Validate the
                    // final location too, so that a symlink or alias swap cannot turn
                    // an already-authorized read into an out-of-workspace access.
                    let safeCoordinatedURL = try self.validatedExistingURL(coordinatedURL)
                    result = .success(
                        VersionedFileData(
                            data: try Data(contentsOf: safeCoordinatedURL),
                            version: try self.fileVersion(for: safeCoordinatedURL)
                        )
                    )
                } catch {
                    result = .failure(error)
                }
            }
            if let coordinationError {
                throw coordinationError
            }
            guard let result else {
                throw WorkspaceError.readFailed
            }
            return try result.get()
        } catch {
            throw mapOperationError(error, defaultError: .readFailed)
        }
    }

    func writeData(_ data: Data, to url: URL, expectedVersion: FileVersion) async throws -> FileVersion {
        let itemURL = try validatedExistingURL(url)
        try ensureNotRoot(itemURL)

        do {
            var savedVersion: FileVersion?
            try coordinateWriting(itemURL, options: .forReplacing) { coordinatedURL in
                _ = try self.validatedExistingURL(coordinatedURL)
                guard try self.fileVersion(for: coordinatedURL) == expectedVersion else {
                    throw WorkspaceError.externalConflict
                }

                let temporaryURL = coordinatedURL.deletingLastPathComponent()
                    .appendingPathComponent(".notetree-\(UUID().uuidString).tmp")
                defer { try? self.fileManager.removeItem(at: temporaryURL) }

                try data.write(to: temporaryURL, options: .withoutOverwriting)
                _ = try self.fileManager.replaceItemAt(
                    coordinatedURL,
                    withItemAt: temporaryURL,
                    backupItemName: nil,
                    options: .usingNewMetadataOnly
                )
                savedVersion = try self.fileVersion(for: coordinatedURL)
            }
            guard let savedVersion else {
                throw WorkspaceError.writeFailed
            }
            return savedVersion
        } catch {
            throw mapOperationError(error, defaultError: .writeFailed)
        }
    }

    func writeCopy(of data: Data, for url: URL, named name: String) async throws -> URL {
        let itemURL = try validatedExistingURL(url)
        let destinationURL = try targetURL(named: name, in: itemURL.deletingLastPathComponent())
        do {
            try coordinateWriting(destinationURL, options: []) { coordinatedURL in
                let safeURL = try self.validatedURL(coordinatedURL)
                guard !self.fileManager.fileExists(atPath: safeURL.path) else { throw WorkspaceError.nameConflict }
                let temporaryURL = safeURL.deletingLastPathComponent()
                    .appendingPathComponent(".notetree-\(UUID().uuidString).tmp")
                defer { try? self.fileManager.removeItem(at: temporaryURL) }
                try data.write(to: temporaryURL, options: .withoutOverwriting)
                try self.fileManager.moveItem(at: temporaryURL, to: safeURL)
            }
            return destinationURL
        } catch {
            throw mapOperationError(error, defaultError: .writeFailed)
        }
    }

    private func node(for url: URL) throws -> FileNode {
        let validatedURL = try validatedURL(url)
        let values = try validatedURL.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let relativePath = relativePath(for: validatedURL)
        return FileNode(
            id: FileNodeID(workspaceID: workspaceID, relativePath: relativePath),
            url: validatedURL,
            displayName: validatedURL.lastPathComponent,
            relativePath: relativePath,
            kind: typeDetector.kind(for: validatedURL),
            metadata: FileMetadata(
                byteCount: values.fileSize,
                modificationDate: values.contentModificationDate
            ),
            children: nil
        )
    }

    private func fileVersion(for url: URL) throws -> FileVersion {
        let values = try url.resourceValues(forKeys: [
            .contentModificationDateKey,
            .fileSizeKey,
            .fileResourceIdentifierKey
        ])
        return FileVersion(
            modificationDate: values.contentModificationDate,
            byteCount: values.fileSize,
            resourceIdentifier: values.fileResourceIdentifier.map { String(describing: $0) }
        )
    }

    private func validatedDirectoryURL(_ url: URL) throws -> URL {
        let validatedURL = try validatedExistingURL(url)
        let isDirectory = try validatedURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory
        guard isDirectory == true else {
            throw WorkspaceError.notDirectory
        }
        return validatedURL
    }

    private func validatedExistingURL(_ url: URL) throws -> URL {
        let standardizedURL = url.standardizedFileURL
        guard !isSymbolicLink(standardizedURL) else {
            throw WorkspaceError.outOfWorkspace
        }

        let resolvedURL = try validatedURL(standardizedURL)
        guard fileManager.fileExists(atPath: resolvedURL.path) else {
            throw WorkspaceError.fileNotFound
        }
        return resolvedURL
    }

    private func validatedURL(_ url: URL) throws -> URL {
        let resolvedURL = url.standardizedFileURL.resolvingSymlinksInPath()
        guard isInsideRoot(resolvedURL) else {
            throw WorkspaceError.outOfWorkspace
        }
        return resolvedURL
    }

    private func isInsideRoot(_ url: URL) -> Bool {
        url.path == rootURL.path || url.path.hasPrefix(rootURL.path + "/")
    }

    private func relativePath(for url: URL) -> String {
        let rootPath = rootURL.path
        let path = url.path
        guard path.hasPrefix(rootPath) else {
            return ""
        }

        return String(path.dropFirst(rootPath.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private func isSymbolicLink(_ url: URL) -> Bool {
        (try? fileManager.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType) == .typeSymbolicLink
    }

    private func targetURL(named name: String, in directory: URL) throws -> URL {
        let validatedName = try validatedFileName(name)
        let parentURL = try validatedDirectoryURL(directory)
        let targetURL = parentURL.appendingPathComponent(validatedName, isDirectory: false)

        guard !fileManager.fileExists(atPath: targetURL.path) else {
            throw WorkspaceError.nameConflict
        }
        return targetURL
    }

    private func moveExistingItem(at sourceURL: URL, named name: String, to destinationDirectory: URL) throws -> FileNode {
        try ensureDestinationIsNotSourceOrDescendant(sourceURL, destinationDirectory: destinationDirectory)
        let targetName = try validatedFileName(name)
        let targetURL = destinationDirectory.appendingPathComponent(targetName, isDirectory: false)
        guard !fileManager.fileExists(atPath: targetURL.path) else {
            throw WorkspaceError.nameConflict
        }

        do {
            try coordinateMove(sourceURL, destinationDirectory: destinationDirectory, targetName: targetName)
            return try node(for: targetURL)
        } catch {
            throw mapOperationError(error, defaultError: .moveFailed)
        }
    }

    private func validatedFileName(_ name: String) throws -> String {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty,
              trimmedName != ".",
              trimmedName != "..",
              !trimmedName.contains("/"),
              !trimmedName.contains("\0") else {
            throw WorkspaceError.invalidFileName
        }
        return trimmedName
    }

    private func ensureNotRoot(_ url: URL) throws {
        guard url != rootURL else {
            throw WorkspaceError.rootOperationForbidden
        }
    }

    private func ensureDestinationIsNotSourceOrDescendant(_ sourceURL: URL, destinationDirectory: URL) throws {
        let sourceIsDirectory = (try? sourceURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        guard !sourceIsDirectory
            || (destinationDirectory != sourceURL && !destinationDirectory.path.hasPrefix(sourceURL.path + "/")) else {
            throw WorkspaceError.invalidMoveDestination
        }
    }

    private func visibleDirectChildCount(in directory: URL) throws -> Int {
        let urls = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey, .isHiddenKey, .isPackageKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        )
        return urls.reduce(into: 0) { count, url in
            if !exclusionPolicy.shouldExclude(url), !isSymbolicLink(url) {
                count += 1
            }
        }
    }

    private func coordinateMove(_ sourceURL: URL, destinationDirectory: URL, targetName: String) throws {
        var operationError: Error?
        var coordinationError: NSError?
        let coordinator = NSFileCoordinator()
        coordinator.coordinate(
            writingItemAt: sourceURL,
            options: .forMoving,
            writingItemAt: destinationDirectory,
            options: [],
            error: &coordinationError
        ) { coordinatedSourceURL, coordinatedDestinationDirectory in
            do {
                let coordinatedTargetURL = coordinatedDestinationDirectory.appendingPathComponent(targetName, isDirectory: false)
                guard !self.fileManager.fileExists(atPath: coordinatedTargetURL.path) else {
                    throw WorkspaceError.nameConflict
                }
                try self.fileManager.moveItem(at: coordinatedSourceURL, to: coordinatedTargetURL)
            } catch {
                operationError = error
            }
        }

        if let coordinationError {
            throw coordinationError
        }
        if let operationError {
            throw operationError
        }
    }

    private func coordinateWriting(
        _ url: URL,
        options: NSFileCoordinator.WritingOptions,
        operation: (URL) throws -> Void
    ) throws {
        var operationError: Error?
        var coordinationError: NSError?
        let coordinator = NSFileCoordinator()
        coordinator.coordinate(writingItemAt: url, options: options, error: &coordinationError) { coordinatedURL in
            do {
                try operation(coordinatedURL)
            } catch {
                operationError = error
            }
        }

        if let coordinationError {
            throw coordinationError
        }
        if let operationError {
            throw operationError
        }
    }

    private func mapOperationError(_ error: Error, defaultError: WorkspaceError) -> WorkspaceError {
        if let workspaceError = error as? WorkspaceError {
            return workspaceError
        }

        let error = error as NSError
        guard error.domain == NSCocoaErrorDomain else {
            return defaultError
        }

        switch error.code {
        case NSFileWriteFileExistsError:
            return .nameConflict
        case NSFileReadNoPermissionError, NSFileWriteNoPermissionError:
            return .permissionDenied
        case NSFileNoSuchFileError:
            return .fileNotFound
        default:
            return defaultError
        }
    }

    private func nodeSortOrder(_ left: FileNode, _ right: FileNode) -> Bool {
        if left.isFolder != right.isFolder {
            return left.isFolder
        }
        return left.displayName.localizedStandardCompare(right.displayName) == .orderedAscending
    }
}
