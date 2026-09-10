import Foundation

struct FileItemInfo: Equatable, Sendable {
    let displayName: String
    let relativePath: String
    let kind: FileKind
    let byteCount: Int?
    let modificationDate: Date?
    let directChildCount: Int?
}
