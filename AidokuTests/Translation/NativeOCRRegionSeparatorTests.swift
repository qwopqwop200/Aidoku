import CoreGraphics
import Foundation
import Testing
@testable import Aidoku

struct NativeOCRRegionSeparatorTests {
    private let left = CGRect(x: 10, y: 10, width: 12, height: 100)
    private let right = CGRect(x: 28, y: 10, width: 12, height: 100)

    private func map(background: UInt8 = 255, ink: (Int, Int) -> UInt8?) -> NativeOCRRegionSeparator {
        let width = 140, height = 140
        var bytes = [UInt8](repeating: background, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                if let value = ink(x, y) { bytes[y * width + x] = value }
            }
        }
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8,
            bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue), provider: provider,
            decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        return NativeOCRRegionSeparator(image: image)!
    }

    @Test func longThinVerticalRuleSeparatesBothInputOrders() {
        let separator = map { x, _ in x == 25 ? 0 : nil }
        #expect(separator.separates(left, right, orientation: .vertical))
        #expect(separator.separates(right, left, orientation: .vertical))
    }

    @Test func horizontalRuleUsesOriginalImageAxes() {
        let separator = map { _, y in y == 25 ? 0 : nil }
        let upper = CGRect(x: 10, y: 10, width: 100, height: 12)
        let lower = CGRect(x: 10, y: 28, width: 100, height: 12)
        #expect(separator.separates(upper, lower, orientation: .horizontal))
        #expect(!separator.separates(left, right, orientation: .vertical))
    }

    @Test func darkCGBackgroundIsNotASeparator() {
        let separator = map(background: 0) { _, _ in nil }
        #expect(!separator.separates(left, right, orientation: .vertical))
    }

    @Test func broadInkAndOneSidedBoundaryRemainUncertain() {
        let broad = map { x, _ in (23...27).contains(x) ? 0 : nil }
        let oneSided = map { x, _ in x >= 25 ? 0 : nil }
        #expect(!broad.separates(left, right, orientation: .vertical))
        #expect(!oneSided.separates(left, right, orientation: .vertical))
    }

    @Test func shortGlyphStrokeIsNotASeparator() {
        let separator = map { x, y in x == 25 && (45...65).contains(y) ? 0 : nil }
        #expect(!separator.separates(left, right, orientation: .vertical))
    }

    @Test func ruleMustLieBetweenTheActualSourceBoxes() {
        let separator = map { x, _ in x == 80 ? 0 : nil }
        #expect(!separator.separates(left, right, orientation: .vertical))
    }

    @Test func unknownOrientationAndOverlappingColumnsStayUnchanged() {
        let separator = map { x, _ in x == 25 ? 0 : nil }
        #expect(!separator.separates(left, right, orientation: .unknown))
        #expect(!separator.separates(left, left.offsetBy(dx: 5, dy: 0), orientation: .vertical))
    }

    @Test func horizontalFrameSeparatesVerticalContinuationAcrossPanels() {
        let upper = CGRect(x: 40, y: 10, width: 20, height: 40)
        let lower = CGRect(x: 40, y: 66, width: 20, height: 50)
        let separator = map { _, y in (56...58).contains(y) ? 0 : nil }
        #expect(separator.separates(upper, lower, orientation: .vertical))
        #expect(separator.separates(lower, upper, orientation: .vertical))
        let lines = [upper, lower].enumerated().map { index, box in
            NativeCoreMLOCRLine(polygon: [CGPoint(x: box.minX, y: box.minY), CGPoint(x: box.maxX, y: box.minY),
                CGPoint(x: box.maxX, y: box.maxY), CGPoint(x: box.minX, y: box.maxY)],
                text: index == 0 ? "強盗みたい" : "あったかな", score: 0.99, orientation: .vertical)
        }
        #expect(NativeOCRTextLineMerger.merge(lines, imageWidth: 140, imageHeight: 140).count == 1)
        let guarded = NativeOCRTextLineMerger.merge(lines, imageWidth: 140, imageHeight: 140,
            separationCheck: { separator.separates($0, $1, orientation: $2) })
        #expect(guarded.map(\.text) == lines.map(\.text))
    }

    @Test func verticalContinuationWithoutFullBrightSidedRuleStaysConnected() {
        let upper = CGRect(x: 40, y: 10, width: 20, height: 40)
        let lower = CGRect(x: 40, y: 66, width: 20, height: 50)
        let blank = map { _, _ in nil }
        let stroke = map { x, y in y == 56 && x < 47 ? 0 : nil }
        let broad = map { _, y in (51...64).contains(y) ? 0 : nil }
        let dark = map(background: 0) { _, _ in nil }
        for separator in [blank, stroke, broad, dark] {
            #expect(!separator.separates(upper, lower, orientation: .vertical))
        }
    }

    @Test func cancelledQueryDoesNotAddSeparationEvidence() async {
        let separator = map { x, _ in x == 25 ? 0 : nil }
        let first = left, second = right
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return separator.separates(first, second, orientation: .vertical)
        }
        #expect(await task.value == false)
    }

    @Test func separatorVetoPreservesTextAndDefaultMergeContract() {
        let lines = [left, right].enumerated().map { index, box in
            NativeCoreMLOCRLine(polygon: [CGPoint(x: box.minX, y: box.minY), CGPoint(x: box.maxX, y: box.minY),
                CGPoint(x: box.maxX, y: box.maxY), CGPoint(x: box.minX, y: box.maxY)],
                text: index == 0 ? "左側の文章" : "右側の文章", score: 0.99,
                orientation: .vertical, orientationIsEstimated: false, sourceTileBounds: nil)
        }
        let separator = map { x, _ in x == 25 ? 0 : nil }
        let baseline = NativeOCRTextLineMerger.merge(lines, imageWidth: 140, imageHeight: 140)
        let guarded = NativeOCRTextLineMerger.merge(lines, imageWidth: 140, imageHeight: 140,
            separationCheck: { separator.separates($0, $1, orientation: $2) })
        #expect(baseline.count == 1)
        #expect(guarded.count == 2)
        #expect(Set(guarded.map(\.text)) == Set(lines.map(\.text)))
    }
}
