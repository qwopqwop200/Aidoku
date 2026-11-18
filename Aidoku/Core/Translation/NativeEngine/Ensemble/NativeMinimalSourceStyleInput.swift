import CoreGraphics
import Foundation

/// Actual p-only source observations. No absent boundary/RF/OCR arrays exist in
/// this ABI, and no rich SourceNativeInput can be manufactured from it.
struct NativeMinimalSourceStyleInput {
    static let revision = "actual-m1-source-style-observations-v1"
    let width: Int
    let height: Int
    let rgb: [UInt8]
    let ownMask: [UInt8]
    let primary: [Float]
    let fontPriorSourcePixels: Double
    let bbox: CGRect
    let sourceIdentity: String
    let sourceText: String
    let memberPolygons: [[CGPoint]]

    enum Failure: Error { case dimensions, invalidObservation, invalidGeometry }

    func validate() throws {
        guard width > 0, height > 0, width <= 1_500_000 / height,
              rgb.count == width * height * 3, ownMask.count == width * height,
              primary.count == width * height else { throw Failure.dimensions }
        guard fontPriorSourcePixels.isFinite, fontPriorSourcePixels > 0,
              !sourceIdentity.isEmpty, !sourceText.isEmpty,
              primary.allSatisfy({ $0.isFinite && (0...1).contains($0) }),
              ownMask.allSatisfy({ $0 == 0 || $0 == 1 || $0 == 255 }) else { throw Failure.invalidObservation }
        guard bbox.minX.isFinite, bbox.minY.isFinite, bbox.width.isFinite, bbox.height.isFinite,
              bbox.width > 0, bbox.height > 0, !memberPolygons.isEmpty,
              memberPolygons.allSatisfy({ $0.count >= 3 && $0.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) }) else {
            throw Failure.invalidGeometry
        }
    }
}

/// Arithmetic-only base35 adapter. Rich and minimal callers both provide real
/// RGB/mask/prior; the richer feature producers are not dependencies of this type.
struct NativeSourcePhysicalPaletteInput {
    let width: Int
    let height: Int
    let rgb: [UInt8]
    let ownMask: [UInt8]
    let fontPriorSourcePixels: Double

    func validate() throws {
        guard width > 0, height > 0, width <= 1_500_000 / height,
              rgb.count == width * height * 3, ownMask.count == width * height else {
            throw NativeMinimalSourceStyleInput.Failure.dimensions
        }
        guard fontPriorSourcePixels.isFinite, fontPriorSourcePixels > 0 else {
            throw NativeMinimalSourceStyleInput.Failure.invalidObservation
        }
    }
}
