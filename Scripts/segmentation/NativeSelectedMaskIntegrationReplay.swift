import CoreGraphics
import Foundation

@main struct NativeSelectedMaskIntegrationReplay {
    static func source() throws -> CGImage {
        let provider = CGDataProvider(data: Data(repeating: 128, count: 64) as CFData)!
        return CGImage(width: 8, height: 8, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: 8,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0), provider: provider,
            decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }
    static func main() throws {
        let original = try source()
        let p = [CGPoint(x: 2, y: 2), CGPoint(x: 4, y: 2), CGPoint(x: 4, y: 4), CGPoint(x: 2, y: 4)]
        var own = [UInt8](repeating: 0, count: 25); own[0] = 255; own[12] = 255
        let entry = NativeSelectedSourceSegmentationMasks.Entry(ownerPolygon: p,
            crop: CGRect(x: 1, y: 1, width: 5, height: 5), mask: own)
        let selected = NativeSelectedSourceSegmentationMasks(original: original, entries: [entry])
        let valid = try selected.resolve(original: original, translatedPolygons: [p])
        precondition(valid.mask?[9] == 255 && valid.mask?[27] == 255) // Includes real predicted pixels outside owner box.
        precondition(valid.audit["executed"] as? Bool == true)
        let cyclic = [p[2], p[1], p[0], p[3]]
        let cycled = try selected.resolve(original: original, translatedPolygons: [cyclic])
        precondition(cycled.mask == valid.mask)
        let missing = try selected.resolve(original: original, translatedPolygons: [p, p.map { CGPoint(x: $0.x + 1, y: $0.y) }])
        precondition(missing.mask == nil && missing.audit["executed"] as? Bool == false)
        let duplicate = NativeSelectedSourceSegmentationMasks(original: original, entries: [entry, entry])
        let duplicated = try duplicate.resolve(original: original, translatedPolygons: [p])
        precondition(duplicated.mask == nil && duplicated.audit["executed"] as? Bool == false)
        do {
            _ = try selected.resolve(original: source(), translatedPolygons: [p])
            preconditionFailure("Stale source accepted")
        } catch NativeSelectedSourceSegmentationMasks.Failure.invalidSource { }
        print("{\"selectedMaskWiringChecks\":6,\"sourceBound\":true,\"bboxClipping\":false}")
    }
}
