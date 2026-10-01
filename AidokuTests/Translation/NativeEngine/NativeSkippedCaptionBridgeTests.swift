import CoreGraphics
import Testing
@testable import Aidoku

@Suite struct NativeSkippedCaptionBridgeTests {
    @Test func foreignSourceAndTranslatedInkBothRemainInTheBoundedEnvelope() throws {
        let required = NativeSkippedCaptionBridge.required([
            .init(bounds: [CGRect(x: 10, y: 10, width: 10, height: 10)], font: 5, sourceFont: 8),
            .init(bounds: [CGRect(x: 70, y: 10, width: 10, height: 10)], font: 5, sourceFont: 8)
        ], inks: [CGRect(x: 40, y: 55, width: 10, height: 10)])
        let layer = CGRect(x: 0, y: 0, width: 100, height: 80)
        let pieces = try #require(NativeSkippedCaptionBridge.coverage(layer: layer, original: [layer], required: required))
        #expect(pieces.count == 1)
        #expect(pieces.contains { $0.contains(CGPoint(x: 75, y: 15)) })
        #expect(pieces.contains { $0.contains(CGPoint(x: 45, y: 60)) })
        #expect(pieces.contains { $0.contains(CGPoint(x: 50, y: 30)) })
    }

    @Test func priorClipBoundsRestrictTheNewEnvelope() throws {
        let layer = CGRect(x: 0, y: 0, width: 100, height: 80)
        let original = [CGRect(x: 5, y: 5, width: 10, height: 20), CGRect(x: 80, y: 5, width: 10, height: 20)]
        let pieces = try #require(NativeSkippedCaptionBridge.coverage(layer: layer, original: original, required: [layer]))
        #expect(pieces == [CGRect(x: 5, y: 5, width: 85, height: 20)])
        #expect(pieces.allSatisfy { $0.minY == 5 && $0.maxY == 25 })
    }

    @Test func emptyAndOverBudgetCoveragePreserveTheOriginalLayer() {
        let layer = CGRect(x: 0, y: 0, width: 10, height: 10)
        #expect(NativeSkippedCaptionBridge.coverage(layer: layer, original: [layer], required: [.init(x: 20, y: 20, width: 10, height: 10)]) == nil)
        #expect(NativeSkippedCaptionBridge.coverage(layer: layer, original: [layer], required: Array(repeating: layer, count: 513)) == nil)
        #expect(NativeSkippedCaptionBridge.coverage(layer: layer, original: [layer], required: Array(repeating: layer, count: 512)) == [layer])
    }

    @Test func sourceOrientationAndRememberedPaddingFollowTheFrozenMargins() {
        let bounds = CGRect(x: 20, y: 30, width: 10, height: 20)
        let source = NativeSkippedCaptionBridge.Source(bounds: [bounds], font: 5, sourceFont: 12, priorPadding: 4, vertical: true)
        let required = NativeSkippedCaptionBridge.required([source], inks: [])
        #expect(required.count == 1)
        #expect(abs(Double(required[0].minX) - 7.96) < 1e-10 && abs(Double(required[0].minY) - 25.96) < 1e-10)
        #expect(abs(Double(required[0].width) - 34.08) < 1e-10 && abs(Double(required[0].height) - 28.08) < 1e-10)
        var preserved = source; preserved.oversizedUnrestored = true
        #expect(NativeSkippedCaptionBridge.required([preserved], inks: []).isEmpty)
    }
}
