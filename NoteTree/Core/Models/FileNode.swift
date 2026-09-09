import Foundation

struct FileNodeID: Codable, Hashable, Identifiable, Sendable {
    let workspaceID: WorkspaceID
    let relativePath: String

    var id: String {
        "\(workspaceID.rawValue.uuidString):\(relativePath)"
    }
}

enum ImageFormat: String, Codable, Equatable, Sendable {
    case jpeg
    case png
    case gif
    case tiff
    case heic
    case webp
    case other
}

enum FileKind: Codable, Equatable, Sendable {
    case folder
    case markdown
    case pdf
    case image(ImageFormat)
    case unsupported

    var systemImage: String {
        switch self {
        case .folder:
            "folder"
        case .markdown:
            "doc.text"
        case .pdf:
            "doc.richtext"
        case .image:
            "photo"
        case .unsupported:
            "doc"
        }
    }
}

struct FileMetadata: Codable, Equatable, Sendable {
    let byteCount: Int?
    let modificationDate: Date?
}

struct FileNode: Codable, Equatable, Identifiable, Sendable {
    let id: FileNodeID
    let url: URL
    let displayName: String
    let relativePath: String
    let kind: FileKind
    let metadata: FileMetadata
    var children: [FileNode]?

    var isFolder: Bool {
        kind == .folder
    }
}
