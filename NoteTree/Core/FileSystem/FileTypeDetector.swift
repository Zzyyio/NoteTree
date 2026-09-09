import Foundation
import UniformTypeIdentifiers

protocol FileTypeDetecting: Sendable {
    func kind(for url: URL) -> FileKind
}

struct SystemFileTypeDetector: FileTypeDetecting {
    func kind(for url: URL) -> FileKind {
        let resourceValues = try? url.resourceValues(forKeys: [.isDirectoryKey, .contentTypeKey])

        if resourceValues?.isDirectory == true {
            return .folder
        }

        if let contentType = resourceValues?.contentType {
            if contentType.conforms(to: .pdf) {
                return .pdf
            }

            if contentType.conforms(to: .image) {
                return .image(imageFormat(for: url.pathExtension))
            }
        }

        let fileExtension = url.pathExtension.lowercased()
        if ["md", "markdown", "mdown", "mkdn"].contains(fileExtension) {
            return .markdown
        }
        if fileExtension == "pdf" {
            return .pdf
        }
        if ["jpg", "jpeg", "png", "gif", "tif", "tiff", "heic", "heif", "webp", "bmp", "ico"].contains(fileExtension) {
            return .image(imageFormat(for: fileExtension))
        }

        return .unsupported
    }

    private func imageFormat(for fileExtension: String) -> ImageFormat {
        switch fileExtension.lowercased() {
        case "jpg", "jpeg":
            .jpeg
        case "png":
            .png
        case "gif":
            .gif
        case "tif", "tiff":
            .tiff
        case "heic", "heif":
            .heic
        case "webp":
            .webp
        default:
            .other
        }
    }
}
