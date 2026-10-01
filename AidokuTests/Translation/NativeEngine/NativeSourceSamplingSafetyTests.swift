import CoreGraphics
import Foundation
import Testing
@testable import Aidoku

@Suite struct NativeSourceSamplingSafetyTests {
    @Test @MainActor func cancelledSampleDoesNotPoisonTheNextRender() async throws {
        let image = try image()
        let bounds = [0.25, 0.25, 0.5, 0.5]
        let cancelled = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            let stage = NativeSourceColorSamplingStage(image: image, enabled: true)
            let result = stage.sample(bounds: bounds)
            return (result == nil, stage.stats.samples, stage.stats.pixels)
        }
        let (discarded, samples, pixels) = await cancelled.value
        #expect(discarded && samples == 0 && pixels == 0)

        let next = NativeSourceColorSamplingStage(image: image, enabled: true)
        #expect(next.sample(bounds: bounds) != nil)
        #expect(next.stats.hits == 0 && next.stats.samples == 1)
        let repeated = NativeSourceColorSamplingStage(image: image, enabled: true)
        #expect(repeated.sample(bounds: bounds) != nil)
        #expect(repeated.stats.hits == 1 && repeated.stats.samples == 0)
    }

    @Test func derivedSourceCoordinatesMustRemainFiniteAndInsideACrop() throws {
        let image = try image()
        let crop = NativeSpatialSourceCrop(image: image, reader: NativeSourcePixelReader(image: image), eligibleCount: 1)
        #expect(crop.pixelRect([0.25, 0.25, 0.5, 0.5]) == CGRect(x: 8, y: 8, width: 16, height: 16))
        #expect(crop.pixelRect([.greatestFiniteMagnitude, 0.25, 0.5, 0.5]) == nil)
        let value: [String: Any] = ["id": "off-page", "text": "검증", "sourceBounds": [1e20, 0.25, 0.25, 0.25],
            "sourceFrame": [0, 0, 32, 32], "fontSize": 8, "lineHeight": 10,
            "x": 0, "y": 0, "width": 8, "height": 8, "rotation": 0.1]
        let item = try JSONDecoder().decode(NativeTranslationLayoutItem.self,
            from: JSONSerialization.data(withJSONObject: value))
        var budget = 524_288
        #expect(crop.prepareSlanted(item: item, palette: nil, excluded: [],
            frame: CGRect(x: 0, y: 0, width: 32, height: 32), uprightBudget: &budget) == nil)
        #expect(budget == 524_288)
    }

    @Test func finiteMarginsAreClampedBeforeIntegerConversion() throws {
        let polygon = [[[12.0, 12], [20, 12], [20, 20], [12, 20]]]
        let maximum = try #require(NativeSourceColorSamplingStage.geometryMask(
            width: 32, height: 32, polygons: polygon, margin: 12))
        let minimum = try #require(NativeSourceColorSamplingStage.geometryMask(
            width: 32, height: 32, polygons: polygon, margin: 0))
        #expect(NativeSourceColorSamplingStage.geometryMask(width: 32, height: 32,
            polygons: polygon, margin: .greatestFiniteMagnitude) == maximum)
        #expect(NativeSourceColorSamplingStage.geometryMask(width: 32, height: 32,
            polygons: polygon, margin: -.greatestFiniteMagnitude) == minimum)
    }

    private func image() throws -> CGImage {
        let size = 32
        let bytes = Array(repeating: UInt8(255), count: size * size * 4)
        let provider = try #require(CGDataProvider(data: Data(bytes) as CFData))
        return try #require(CGImage(width: size, height: size, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: size * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    }
}
