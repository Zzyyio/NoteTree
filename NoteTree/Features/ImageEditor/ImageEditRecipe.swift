import Foundation

struct ImageEditRecipe: Codable, Equatable, Sendable {
    /// Crop is normalized in the orientation-corrected source, before rotation.
    var crop = CGRect(x: 0, y: 0, width: 1, height: 1)
    var quarterTurns = 0
    var flipHorizontal = false
    var flipVertical = false
    var exposure = 0.0
    var contrast = 1.0
    var saturation = 1.0
    /// Markup points use normalized coordinates in the final output.
    var strokes: [[CGPoint]] = []
}
