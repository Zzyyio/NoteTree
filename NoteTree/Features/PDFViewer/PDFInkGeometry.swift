import AppKit

/// Geometry helpers deliberately use page coordinates. PDFKit Ink paths are
/// stored relative to an annotation's bounds, while pointer input is not.
enum PDFInkGeometry {
    static func tightBounds(for points: [CGPoint], lineWidth: CGFloat) -> CGRect? {
        guard let first = points.first else { return nil }
        var bounds = CGRect(origin: first, size: .zero)
        for point in points.dropFirst() {
            bounds = bounds.union(CGRect(origin: point, size: .zero))
        }
        let inset = max(lineWidth / 2, 1)
        return bounds.insetBy(dx: -inset, dy: -inset)
    }

    static func localPath(points: [CGPoint], in bounds: CGRect) -> NSBezierPath? {
        guard let first = points.first else { return nil }
        let path = NSBezierPath()
        path.move(to: CGPoint(x: first.x - bounds.minX, y: first.y - bounds.minY))
        for point in points.dropFirst() {
            path.line(to: CGPoint(x: point.x - bounds.minX, y: point.y - bounds.minY))
        }
        return path
    }

    static func pagePoints(from path: NSBezierPath, annotationBounds: CGRect) -> [CGPoint] {
        // PDFKit returns annotation-local paths for in-memory annotations, but
        // returns page-space paths for some annotations reloaded from disk.
        // Detect the latter by comparing with the local annotation extent.
        let pathBounds = path.bounds
        let appearsLocal = pathBounds.minX >= -1
            && pathBounds.minY >= -1
            && pathBounds.maxX <= annotationBounds.width + 1
            && pathBounds.maxY <= annotationBounds.height + 1
        let offset = appearsLocal ? annotationBounds.origin : .zero
        var points: [CGPoint] = []
        for index in 0..<path.elementCount {
            var elementPoints = [NSPoint](repeating: .zero, count: 3)
            let element = path.element(at: index, associatedPoints: &elementPoints)
            switch element {
            case .moveTo, .lineTo:
                points.append(CGPoint(
                    x: elementPoints[0].x + offset.x,
                    y: elementPoints[0].y + offset.y
                ))
            case .quadraticCurveTo, .cubicCurveTo:
                // Ink written by PDFKit can contain curves from other apps.
                // Keeping the endpoint is safe; the eraser below subdivides it.
                points.append(CGPoint(
                    x: elementPoints[2].x + offset.x,
                    y: elementPoints[2].y + offset.y
                ))
            case .closePath:
                break
            @unknown default:
                break
            }
        }
        return points
    }

    /// Returns the pieces which remain after removing the swept circular
    /// eraser from a polyline. Subdivision avoids deleting a complete long
    /// segment merely because its middle was touched.
    static func erase(
        points: [CGPoint],
        with eraserPoints: [CGPoint],
        radius: CGFloat
    ) -> [[CGPoint]] {
        guard points.count >= 2, !eraserPoints.isEmpty else { return [points] }
        guard polylinesIntersect(points, eraserPoints, radius: radius) else { return [points] }
        let step = max(radius / 2, 1)
        var samples: [CGPoint] = [points[0]]
        for pair in zip(points, points.dropFirst()) {
            let distance = hypot(pair.1.x - pair.0.x, pair.1.y - pair.0.y)
            let count = max(Int(ceil(distance / step)), 1)
            for index in 1...count {
                let progress = CGFloat(index) / CGFloat(count)
                samples.append(
                    CGPoint(
                        x: pair.0.x + (pair.1.x - pair.0.x) * progress,
                        y: pair.0.y + (pair.1.y - pair.0.y) * progress
                    )
                )
            }
        }

        var pieces: [[CGPoint]] = []
        var current: [CGPoint] = []
        for pair in zip(samples, samples.dropFirst()) {
            let midpoint = CGPoint(x: (pair.0.x + pair.1.x) / 2, y: (pair.0.y + pair.1.y) / 2)
            if distance(from: midpoint, to: eraserPoints) <= radius {
                if current.count >= 2 { pieces.append(current) }
                current = []
            } else {
                if current.isEmpty { current.append(pair.0) }
                current.append(pair.1)
            }
        }
        if current.count >= 2 { pieces.append(current) }
        return pieces
    }

    private static func distance(from point: CGPoint, to eraserPoints: [CGPoint]) -> CGFloat {
        if eraserPoints.count == 1 {
            return hypot(point.x - eraserPoints[0].x, point.y - eraserPoints[0].y)
        }
        return zip(eraserPoints, eraserPoints.dropFirst()).map {
            distance(from: point, toSegmentFrom: $0.0, to: $0.1)
        }.min() ?? .greatestFiniteMagnitude
    }

    private static func polylinesIntersect(_ source: [CGPoint], _ eraser: [CGPoint], radius: CGFloat) -> Bool {
        let sourceDistance = source.map { distance(from: $0, to: eraser) }.min() ?? .greatestFiniteMagnitude
        let eraserDistance = eraser.map { distance(from: $0, to: source) }.min() ?? .greatestFiniteMagnitude
        return min(sourceDistance, eraserDistance) <= radius
    }

    private static func distance(from point: CGPoint, toSegmentFrom start: CGPoint, to end: CGPoint) -> CGFloat {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0 else {
            return hypot(point.x - start.x, point.y - start.y)
        }
        let projection = min(max(((point.x - start.x) * dx + (point.y - start.y) * dy) / lengthSquared, 0), 1)
        let nearest = CGPoint(x: start.x + projection * dx, y: start.y + projection * dy)
        return hypot(point.x - nearest.x, point.y - nearest.y)
    }
}
