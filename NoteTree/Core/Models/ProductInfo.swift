struct ProductInfo: Equatable, Sendable {
    let name: String
    let minimumSystemVersion: String

    static let noteTree = ProductInfo(
        name: "NoteTree",
        minimumSystemVersion: "macOS 14"
    )
}

