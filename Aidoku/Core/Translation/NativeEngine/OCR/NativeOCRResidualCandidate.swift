import CoreGraphics
import Foundation

/// A source-derived geometric alternative. Keys identify a shared algorithm and
/// normalized parameters; they must never contain image IDs or GT coordinates.
@available(iOS 18.0, *)
struct NativeOCRResidualCandidate {
    let key: String
    let polygon: [CGPoint]
    var consumedIndices: [Int] = []
    var supportPoints: [CGPoint] = []
    /// Geometry refinements may retain an existing verified association without renaming it.
    var associationKey: String? = nil
}
