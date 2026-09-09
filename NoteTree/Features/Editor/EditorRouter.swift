import Foundation

enum EditorKind: Equatable, Sendable {
    case folder
    case markdown
    case pdf
    case image
    case unsupported
}

enum EditorRouter {
    static func route(for kind: FileKind) -> EditorKind {
        switch kind {
        case .folder:
            .folder
        case .markdown:
            .markdown
        case .pdf:
            .pdf
        case .image:
            .image
        case .unsupported:
            .unsupported
        }
    }
}
