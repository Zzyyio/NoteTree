import XCTest
import ImageIO
import UniformTypeIdentifiers
@testable import NoteTree

final class ImageRendererTests: XCTestCase {
    func testAllOrientationsAndCropRotationPreserveDecodableAlphaOutput() async throws {
        let renderer = ImageRenderer()
        for orientation in 1...8 {
            let data = try imageFixture(orientation: orientation)
            let rendered = try await renderer.render(data, recipe: .init(), preview: false)
            XCTAssertEqual(rendered.pixelWidth, orientation >= 5 ? 40 : 80)
            XCTAssertEqual(rendered.pixelHeight, orientation >= 5 ? 80 : 40)
            let source = try XCTUnwrap(CGImageSourceCreateWithData(rendered.data as CFData, nil))
            let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
            XCTAssertNotEqual(image.alphaInfo, .none)
        }
        var recipe = ImageEditRecipe()
        recipe.crop = CGRect(x: 0, y: 0, width: 0.5, height: 1)
        recipe.quarterTurns = 1
        recipe.flipHorizontal = true
        let result = try await renderer.render(imageFixture(), recipe: recipe, preview: false)
        XCTAssertEqual(result.pixelWidth, 40)
        XCTAssertEqual(result.pixelHeight, 40)
    }

    func testMultipleFramesRequireCopyAndPreviewIsDownsampled() async throws {
        let renderer = ImageRenderer()
        let multi = try await renderer.render(imageFixture(frames: 2), recipe: .init(), preview: true)
        XCTAssertFalse(multi.canOverwrite)
        let large = try await renderer.render(imageFixture(width: 3200, height: 2400), recipe: .init(), preview: true)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(large.data as CFData, nil))
        let bitmap = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertLessThanOrEqual(max(bitmap.width, bitmap.height), 1600)
        XCTAssertEqual(large.pixelWidth, 3200)
    }
}

@MainActor
final class ImageEditorSessionTests: XCTestCase {
    func testSaveUndoRedoAndCopyRoundTrip() async throws {
        let workspace = try TemporaryWorkspace()
        let url = workspace.url.appendingPathComponent("image.png")
        let original = try imageFixture()
        try original.write(to: url)
        let session = ImageEditorSession(url: url, fileSystem: LocalWorkspaceFileSystem(workspace: workspace.workspace()))
        await session.load()
        var recipe = session.recipe
        recipe.quarterTurns = 1
        session.edit(recipe)
        XCTAssertEqual(try Data(contentsOf: url), original)
        session.undo()
        XCTAssertFalse(session.isDirty)
        session.redo()
        XCTAssertTrue(session.isDirty)
        let saved = await session.save()
        XCTAssertTrue(saved)
        XCTAssertFalse(session.isDirty)
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let bitmap = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(bitmap.width, 40)
        XCTAssertEqual(bitmap.height, 80)
        session.undo()
        XCTAssertTrue(session.isDirty)
        session.redo()
        XCTAssertFalse(session.isDirty)
        let copy = await session.save(copyName: "copy.png")
        XCTAssertTrue(copy)
        let collision = await session.save(copyName: "copy.png")
        XCTAssertFalse(collision)
        XCTAssertEqual(session.error, .nameConflict)
    }

    func testExternalConflictRetainsRecipeAndOriginal() async throws {
        let workspace = try TemporaryWorkspace()
        let url = workspace.url.appendingPathComponent("image.png")
        try imageFixture().write(to: url)
        let session = ImageEditorSession(url: url, fileSystem: LocalWorkspaceFileSystem(workspace: workspace.workspace()))
        await session.load()
        var recipe = session.recipe
        recipe.exposure = 1
        session.edit(recipe)
        let external = try imageFixture(width: 24)
        try external.write(to: url, options: .atomic)
        let saved = await session.save()
        XCTAssertFalse(saved)
        XCTAssertTrue(session.hasConflict)
        XCTAssertEqual(session.recipe, recipe)
        XCTAssertEqual(try Data(contentsOf: url), external)
        let copied = await session.save(copyName: "local.png")
        XCTAssertTrue(copied)
        XCTAssertTrue(session.hasConflict)
    }

    func testPermissionFailureKeepsUnsavedImage() async throws {
        let workspace = try TemporaryWorkspace()
        let url = workspace.url.appendingPathComponent("image.png")
        let original = try imageFixture()
        try original.write(to: url)
        let session = ImageEditorSession(url: url, fileSystem: ImageFailureFileSystem(workspace: workspace.workspace()))
        await session.load()
        var recipe = session.recipe
        recipe.flipVertical = true
        session.edit(recipe)
        let result = await session.save()
        XCTAssertFalse(result)
        XCTAssertEqual(session.error, .permissionDenied)
        XCTAssertTrue(session.isDirty)
        XCTAssertEqual(try Data(contentsOf: url), original)
        let copy = await session.save(copyName: "copy.png")
        XCTAssertFalse(copy)
        XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.url.appendingPathComponent("copy.png").path))
    }
}

private func imageFixture(width: Int = 80, height: Int = 40, orientation: Int = 1, frames: Int = 1) throws -> Data {
    let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                        bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 1, alpha: 0.5))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let bitmap = try XCTUnwrap(context.makeImage())
    let data = NSMutableData()
    let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data,
        (frames == 1 ? UTType.png.identifier : UTType.tiff.identifier) as CFString, frames, nil))
    for _ in 0..<frames {
        CGImageDestinationAddImage(destination, bitmap, [kCGImagePropertyOrientation: orientation] as CFDictionary)
    }
    XCTAssertTrue(CGImageDestinationFinalize(destination))
    return data as Data
}

private actor ImageFailureFileSystem: WorkspaceFileSystem {
    private let backing: LocalWorkspaceFileSystem
    init(workspace: Workspace) { backing = LocalWorkspaceFileSystem(workspace: workspace) }
    func children(of directory: URL) async throws -> [FileNode] { try await backing.children(of: directory) }
    func matchingEntries(query: String) async throws -> [FileNode] { try await backing.matchingEntries(query: query) }
    func createMarkdown(named name: String, in directory: URL) async throws -> FileNode { throw WorkspaceError.permissionDenied }
    func createDirectory(named name: String, in directory: URL) async throws -> FileNode { throw WorkspaceError.permissionDenied }
    func renameItem(at url: URL, to name: String) async throws -> FileNode { throw WorkspaceError.permissionDenied }
    func moveItem(at url: URL, to destinationDirectory: URL) async throws -> FileNode { throw WorkspaceError.permissionDenied }
    func trashItem(at url: URL) async throws { throw WorkspaceError.permissionDenied }
    func itemInfo(at url: URL) async throws -> FileItemInfo { try await backing.itemInfo(at: url) }
    func readData(at url: URL) async throws -> VersionedFileData { try await backing.readData(at: url) }
    func writeData(_ data: Data, to url: URL, expectedVersion: FileVersion) async throws -> FileVersion { throw WorkspaceError.permissionDenied }
    func writeCopy(of data: Data, for url: URL, named name: String) async throws -> URL { throw WorkspaceError.permissionDenied }
}
