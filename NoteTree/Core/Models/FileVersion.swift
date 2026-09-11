import Foundation

/// A lightweight snapshot used to detect a competing writer before replacing a file.
struct FileVersion: Equatable, Sendable {
    let modificationDate: Date?
    let byteCount: Int?
    let resourceIdentifier: String?
}

struct VersionedFileData: Sendable {
    let data: Data
    let version: FileVersion
}
