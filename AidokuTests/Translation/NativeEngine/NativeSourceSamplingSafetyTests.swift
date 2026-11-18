import CoreGraphics
import CoreText
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

extension NativeSourceSamplingSafetyTests {
    @Test(arguments: ["outlined", "flat", "lowContrast"])
    @MainActor
    func directRGBComparisonsPreserveObservedRolesAndUnknowns(_ kind: String) throws {
        // Authored pixels avoid font rasterization differences between macOS and iOS.
        let width = 96, height = 64
        let background: [UInt8] = kind == "outlined" ? [227, 241, 236] : [255, 255, 255]
        var rgba = [UInt8](repeating: 255, count: width * height * 4)
        for index in 0..<(width * height) {
            for channel in 0..<3 { rgba[index * 4 + channel] = background[channel] }
        }
        func fill(_ left: Int, _ top: Int, _ right: Int, _ bottom: Int, _ color: [UInt8]) {
            for y in top..<bottom { for x in left..<right {
                for channel in 0..<3 { rgba[(y * width + x) * 4 + channel] = color[channel] }
            } }
        }
        for x in [20, 40, 60] {
            if kind == "outlined" {
                fill(x, 18, x + 12, 46, [230, 110, 20])
                fill(x + 2, 20, x + 10, 44, [255, 255, 255])
            } else if kind == "lowContrast" {
                fill(x, 18, x + 8, 46, [240, 240, 240])
            }
        }
        let provider = try #require(CGDataProvider(data: Data(rgba) as CFData))
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let image = try #require(CGImage(width: width, height: height,
            bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4, space: space,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let bounds = [0.0, 0, 1, 1]
        let geometry: [String: Any] = ["polygon": [[0.0, 0], [1.0, 0], [1.0, 1], [0.0, 1]],
                                      "excluded": [[[Double]]]()]
        let budget = NativeSourceColorSamplingStage.Budget(remainingSamples: 1)
        budget.roleRetryPixels = 0
        let stage = NativeSourceColorSamplingStage(image: image, enabled: true, budget: budget)
        let raw = try #require(stage.sample(bounds: bounds, geometry: geometry))
        #expect(NativeSourceColorSamplingStage.verifiedStyle(raw) == nil)
        if kind == "outlined" {
            #expect(raw["foreground"] as? [Double] == [230, 110, 20])
            #expect(raw["background"] as? [Double] == [227, 241, 236])
            #expect(raw["stroke"] as? [Double] == [255, 255, 255])
        }
        let samples = stage.stats.samples, pixels = stage.stats.pixels
        let allowance = [budget.pixels, budget.detailPixels, budget.roleRetryPixels, budget.roleExtraPixels]
        let repeated = try #require(stage.sample(bounds: bounds, geometry: geometry))
        #expect(try styleRetryBytes(raw) == styleRetryBytes(repeated))
        #expect(stage.sampleVerifiedStyle(bounds: bounds, geometry: geometry) == nil)
        #expect(stage.stats.hits == 2 && stage.stats.samples == samples && stage.stats.pixels == pixels)
        #expect(allowance == [budget.pixels, budget.detailPixels, budget.roleRetryPixels, budget.roleExtraPixels])
    }

    @Test(arguments: ["ocr", "translation"])
    @MainActor
    func renderRetryKeepsPrimaryCacheAndHonorsPhase(_ phase: String) throws {
        let expectedImage = try styleRetryImage()
        let expectedBudget = NativeSourceColorSamplingStage.Budget(remainingSamples: 1)
        expectedBudget.roleRetryPixels = 0
        let expected = NativeSourceColorSamplingStage(image: expectedImage, enabled: true, phase: phase, budget: expectedBudget)
        let primary = try #require(expected.sample(bounds: styleRetryBounds, geometry: styleRetryGeometry))
        #expect(NativeSourceColorSamplingStage.verifiedStyle(primary) == nil)

        let image = try styleRetryImage()
        let budget = NativeSourceColorSamplingStage.Budget(remainingSamples: 1)
        budget.roleRetryPixels = 0
        let stage = NativeSourceColorSamplingStage(image: image, enabled: true, phase: phase, budget: budget)
        let observed = stage.sampleVerifiedStyle(bounds: styleRetryBounds, geometry: styleRetryGeometry)
        if phase == "translation" {
            let style = try #require(observed)
            #expect(zip(style.foreground, [255.0, 255, 255]).allSatisfy { abs($0 - $1) <= 8 })
            #expect(zip(style.stroke, [230.0, 110, 20]).allSatisfy { abs($0 - $1) <= 8 })
            #expect(style.sourceStrokeWidthPixels == nil)
            #expect(budget.roleExtraPixels < 98_304 && budget.roleExtraPixels >= 0)
        } else {
            #expect(observed == nil && budget.roleExtraPixels == 98_304)
        }
        #expect(stage.stats.samples == expected.stats.samples && stage.stats.pixels == expected.stats.pixels)
        #expect(budget.pixels == expectedBudget.pixels && budget.detailPixels == expectedBudget.detailPixels)
        #expect(budget.roleRetryPixels == expectedBudget.roleRetryPixels && budget.remainingSamples == expectedBudget.remainingSamples)
        let captured = stage.stats.pixels, samples = stage.stats.samples, extra = budget.roleExtraPixels
        let raw = try #require(stage.sample(bounds: styleRetryBounds, geometry: styleRetryGeometry))
        #expect(try styleRetryBytes(raw) == styleRetryBytes(primary))
        #expect(raw["styleBudgetRetry"] == nil)
        let again = stage.sampleVerifiedStyle(bounds: styleRetryBounds, geometry: styleRetryGeometry)
        #expect(again?.foreground == observed?.foreground && again?.stroke == observed?.stroke)
        #expect(stage.stats.pixels == captured && stage.stats.samples == samples && budget.roleExtraPixels == extra)
        #expect(stage.stats.hits == 2)
    }

    @Test @MainActor func primaryCacheBeforeStyleDoesNotRecaptureOrSpendExtra() throws {
        let image = try styleRetryImage()
        let budget = NativeSourceColorSamplingStage.Budget(remainingSamples: 1)
        budget.roleRetryPixels = 0
        let stage = NativeSourceColorSamplingStage(image: image, enabled: true, phase: "translation", budget: budget)
        let raw = try #require(stage.sample(bounds: styleRetryBounds, geometry: styleRetryGeometry))
        let bytes = try styleRetryBytes(raw), captured = stage.stats.pixels, samples = stage.stats.samples
        #expect(stage.sampleVerifiedStyle(bounds: styleRetryBounds, geometry: styleRetryGeometry) == nil)
        let repeated = try #require(stage.sample(bounds: styleRetryBounds, geometry: styleRetryGeometry))
        #expect(try styleRetryBytes(repeated) == bytes)
        #expect(repeated["styleBudgetRetry"] == nil)
        #expect(stage.stats.pixels == captured && stage.stats.samples == samples)
        #expect(budget.roleExtraPixels == 98_304 && budget.roleRetryPixels == 0 && stage.stats.hits == 2)
    }

    @Test @MainActor func renderStyleCacheCannotAnswerOCRPhase() throws {
        let image = try styleRetryImage()
        let renderBudget = NativeSourceColorSamplingStage.Budget(remainingSamples: 1)
        renderBudget.roleRetryPixels = 0
        let render = NativeSourceColorSamplingStage(image: image, enabled: true, phase: "translation", budget: renderBudget)
        _ = try #require(render.sampleVerifiedStyle(bounds: styleRetryBounds, geometry: styleRetryGeometry))
        let ocrBudget = NativeSourceColorSamplingStage.Budget(remainingSamples: 1)
        ocrBudget.roleRetryPixels = 0
        let ocr = NativeSourceColorSamplingStage(image: image, enabled: true, phase: "ocr", budget: ocrBudget)
        let value = try #require(ocr.sample(bounds: styleRetryBounds, geometry: styleRetryGeometry))
        #expect(ocr.stats.hits == 0 && ocr.stats.samples > 0)
        #expect(NativeSourceColorSamplingStage.verifiedStyle(value) == nil && value["styleBudgetRetry"] == nil)
        #expect(ocrBudget.roleExtraPixels == 98_304 && ocrBudget.roleRetryPixels == 0)
        #expect(ocr.sampleVerifiedStyle(bounds: styleRetryBounds, geometry: styleRetryGeometry) == nil)
        #expect(ocr.stats.hits == 1 && ocrBudget.roleExtraPixels == 98_304)
    }

    @Test @MainActor func renderRetryCannotPartiallySpendAnInsufficientQueryAllowance() throws {
        let image = try styleRetryImage()
        let budget = NativeSourceColorSamplingStage.Budget(remainingSamples: 1)
        budget.roleRetryPixels = 0
        // Full initial crop: (80 + 2*16) * (60 + 2*16) = 10,304.
        // Each alternative must reserve its complete inference area.
        budget.roleExtraPixels = 10_303
        let stage = NativeSourceColorSamplingStage(image: image, enabled: true, phase: "translation", budget: budget)
        #expect(stage.sampleVerifiedStyle(bounds: styleRetryBounds, geometry: styleRetryGeometry) == nil)
        #expect(budget.roleExtraPixels == 10_303 && budget.roleRetryPixels == 0)
    }

    private var styleRetryBounds: [Double] { [80.0 / 400, 40.0 / 200, 80.0 / 400, 60.0 / 200] }
    private var styleRetryGeometry: [String: Any] {
        ["polygon": [[0.2, 0.2], [0.4, 0.2], [0.4, 0.5], [0.2, 0.5]], "excluded": [[[Double]]]()]
    }
    private func styleRetryBytes(_ value: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    }
    private func styleRetryImage() throws -> CGImage {
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(CGContext(data: nil, width: 400, height: 200, bitsPerComponent: 8,
            bytesPerRow: 1600, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        func color(_ rgb: [Double]) -> CGColor {
            CGColor(colorSpace: space, components: rgb.map { CGFloat($0 / 255) } + [1])!
        }
        context.setFillColor(color([227, 241, 236]))
        context.fill(CGRect(x: 0, y: 0, width: 400, height: 200))
        context.textMatrix = .identity; context.textPosition = CGPoint(x: 85, y: 142)
        let attributes: [CFString: Any] = [
            kCTFontAttributeName: CTFontCreateWithName("Helvetica-Bold" as CFString, 20, nil),
            kCTForegroundColorAttributeName: color([255, 255, 255]),
            kCTStrokeColorAttributeName: color([230, 110, 20]),
            kCTStrokeWidthAttributeName: -5
        ]
        let string = try #require(CFAttributedStringCreate(nil, "HHO" as CFString, attributes as CFDictionary))
        CTLineDraw(CTLineCreateWithAttributedString(string), context)
        return try #require(context.makeImage())
    }
}
