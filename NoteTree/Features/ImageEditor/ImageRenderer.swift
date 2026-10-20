import CoreImage
import ImageIO
import UniformTypeIdentifiers

struct ImagePreview: Sendable {
    let data: Data
    let pixelWidth: Int
    let pixelHeight: Int
    let canOverwrite: Bool
}

/// All decoding, full-resolution rendering and encoding stay off the main actor.
actor ImageRenderer {
    private let context = CIContext()

    func render(_ data: Data, recipe: ImageEditRecipe, preview: Bool,
                outputType: String? = nil, quality: Double = 0.9) throws -> ImagePreview {
        try Task.checkCancellation()
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let type = CGImageSourceGetType(source) as String?,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] else {
            throw WorkspaceError.decodeFailed
        }
        let width = properties[kCGImagePropertyPixelWidth as String] as? Int ?? 0
        let height = properties[kCGImagePropertyPixelHeight as String] as? Int ?? 0
        let orientation = properties[kCGImagePropertyOrientation as String] as? Int32 ?? 1
        let safeTypes = [UTType.png.identifier, UTType.jpeg.identifier, UTType.heic.identifier, UTType.tiff.identifier]
        let canOverwrite = CGImageSourceGetCount(source) == 1 && safeTypes.contains(type)
        let bitmap: CGImage?
        if preview {
            bitmap = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 1600,
                kCGImageSourceShouldCacheImmediately: true
            ] as CFDictionary)
        } else {
            bitmap = CGImageSourceCreateImageAtIndex(source, 0, nil)
        }
        guard let bitmap else { throw WorkspaceError.decodeFailed }
        var image = CIImage(cgImage: bitmap)
        if !preview { image = image.oriented(forExifOrientation: orientation) }
        image = normalized(image)
        let crop = recipe.crop.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard !crop.isNull, crop.width > 0, crop.height > 0 else { throw WorkspaceError.decodeFailed }
        image = normalized(image.cropped(to: CGRect(
            x: crop.minX * image.extent.width, y: crop.minY * image.extent.height,
            width: crop.width * image.extent.width, height: crop.height * image.extent.height
        ).integral.intersection(image.extent)))
        for _ in 0..<((recipe.quarterTurns % 4 + 4) % 4) {
            image = normalized(image.transformed(by: CGAffineTransform(rotationAngle: -.pi / 2)))
        }
        if recipe.flipHorizontal { image = normalized(image.transformed(by: CGAffineTransform(scaleX: -1, y: 1))) }
        if recipe.flipVertical { image = normalized(image.transformed(by: CGAffineTransform(scaleX: 1, y: -1))) }
        image = image.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: recipe.exposure])
            .applyingFilter("CIColorControls", parameters: [
                kCIInputContrastKey: recipe.contrast, kCIInputSaturationKey: recipe.saturation
            ])
        let outputSpace = bitmap.colorSpace?.model == .rgb ? bitmap.colorSpace : CGColorSpace(name: CGColorSpace.sRGB)
        try Task.checkCancellation()
        guard let rendered = context.createCGImage(image, from: image.extent, format: .RGBA8, colorSpace: outputSpace) else {
            throw WorkspaceError.decodeFailed
        }
        var output = rendered
        if !recipe.strokes.isEmpty {
            guard let canvas = CGContext(data: nil, width: rendered.width, height: rendered.height,
                                         bitsPerComponent: 8, bytesPerRow: 0,
                                         space: rendered.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                throw WorkspaceError.decodeFailed
            }
            canvas.draw(rendered, in: CGRect(x: 0, y: 0, width: rendered.width, height: rendered.height))
            canvas.setStrokeColor(CGColor(red: 0.1, green: 0.4, blue: 1, alpha: 1))
            canvas.setLineWidth(CGFloat(max(rendered.width, rendered.height)) * 0.003)
            canvas.setLineCap(.round)
            for stroke in recipe.strokes where stroke.count > 1 {
                canvas.beginPath()
                canvas.addLines(between: stroke.map { CGPoint(x: $0.x * CGFloat(rendered.width), y: $0.y * CGFloat(rendered.height)) })
                canvas.strokePath()
            }
            guard let marked = canvas.makeImage() else { throw WorkspaceError.decodeFailed }
            output = marked
        }
        let destinationType = preview ? UTType.png.identifier : (outputType ?? type)
        let result = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(result, destinationType as CFString, 1, nil) else {
            throw WorkspaceError.writeFailed
        }
        // Remove stale dimensions, orientation and embedded thumbnails; retain safe EXIF and color metadata.
        var metadata = preview ? [:] : properties
        metadata[kCGImagePropertyOrientation as String] = 1
        metadata[kCGImagePropertyPixelWidth as String] = output.width
        metadata[kCGImagePropertyPixelHeight as String] = output.height
        metadata[kCGImagePropertyThumbnailImages as String] = nil
        metadata[kCGImageDestinationLossyCompressionQuality as String] = min(1, max(0, quality))
        if var exif = metadata[kCGImagePropertyExifDictionary as String] as? [String: Any] {
            exif[kCGImagePropertyExifPixelXDimension as String] = output.width
            exif[kCGImagePropertyExifPixelYDimension as String] = output.height
            metadata[kCGImagePropertyExifDictionary as String] = exif
        }
        if var tiff = metadata[kCGImagePropertyTIFFDictionary as String] as? [String: Any] {
            tiff[kCGImagePropertyTIFFOrientation as String] = 1
            metadata[kCGImagePropertyTIFFDictionary as String] = tiff
        }
        CGImageDestinationAddImage(destination, output, metadata as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw WorkspaceError.writeFailed }
        let normalizedWidth = (5...8).contains(orientation) ? height : width
        let normalizedHeight = (5...8).contains(orientation) ? width : height
        let rotated = recipe.quarterTurns % 2 != 0
        return ImagePreview(data: result as Data,
                            pixelWidth: preview ? Int(Double(rotated ? normalizedHeight : normalizedWidth) * (rotated ? crop.height : crop.width)) : output.width,
                            pixelHeight: preview ? Int(Double(rotated ? normalizedWidth : normalizedHeight) * (rotated ? crop.width : crop.height)) : output.height,
                            canOverwrite: canOverwrite)
    }

    private func normalized(_ image: CIImage) -> CIImage {
        image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
    }
}
