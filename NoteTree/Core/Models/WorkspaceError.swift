import Foundation

enum WorkspaceError: Error, Equatable, Sendable {
    case invalidWorkspace
    case outOfWorkspace
    case notDirectory
    case permissionDenied
    case bookmarkUnavailable
    case bookmarkStale
    case fileNotFound
    case readFailed
    case invalidFileName
    case nameConflict
    case rootOperationForbidden
    case writeFailed
    case moveFailed
    case trashFailed
}

extension WorkspaceError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .invalidWorkspace:
            String(localized: "error.workspace.invalid")
        case .outOfWorkspace:
            String(localized: "error.workspace.outOfBounds")
        case .notDirectory:
            String(localized: "error.workspace.notDirectory")
        case .permissionDenied:
            String(localized: "error.workspace.permissionDenied")
        case .bookmarkUnavailable, .bookmarkStale:
            String(localized: "error.workspace.reauthorize")
        case .fileNotFound:
            String(localized: "error.workspace.fileNotFound")
        case .readFailed:
            String(localized: "error.workspace.readFailed")
        case .invalidFileName:
            String(localized: "error.file.invalidName")
        case .nameConflict:
            String(localized: "error.file.nameConflict")
        case .rootOperationForbidden:
            String(localized: "error.file.rootProtected")
        case .writeFailed:
            String(localized: "error.file.writeFailed")
        case .moveFailed:
            String(localized: "error.file.moveFailed")
        case .trashFailed:
            String(localized: "error.file.trashFailed")
        }
    }
}
