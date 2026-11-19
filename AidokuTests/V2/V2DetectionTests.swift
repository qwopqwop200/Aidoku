import CoreGraphics
import CoreText
import Foundation
import Testing
@testable import Aidoku

struct V2DetectionTests {
    private func line(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat, score: Double = 0.9) -> V2Line {
        V2Detection.line(polygon: [
            CGPoint(x: x + width, y: y), CGPoint(x: x + width, y: y + height),
            CGPoint(x: x, y: y + height), CGPoint(x: x, y: y)
        ], score: score)!
    }

    @Test func detectorPolygonIsOrderedTopLeftClockwise() {
        let value = line(10, 20, 30, 90)
        #expect(value.polygon == [CGPoint(x: 10, y: 20), CGPoint(x: 40, y: 20), CGPoint(x: 40, y: 110), CGPoint(x: 10, y: 110)])
        #expect(value.vertical)
        #expect(value.bounds == CGRect(x: 10, y: 20, width: 30, height: 90))
    }

    @Test func splitColumnFragmentsJoinIntoOneVerticalLine() {
        let fragments = [line(100, 100, 40, 120), line(102, 250, 38, 90), line(101, 360, 40, 40)]
        let lines = V2LineAssembly.assemble(fragments, layout: [])
        #expect(lines.count == 1)
        #expect(lines[0].bounds == CGRect(x: 100, y: 100, width: 41, height: 300))
        #expect(lines[0].vertical)
    }

    @Test func splitRowFragmentsJoinIntoOneHorizontalLine() {
        let lines = V2LineAssembly.assemble([line(100, 100, 120, 30), line(240, 101, 60, 30)], layout: [])
        #expect(lines.count == 1)
        #expect(!lines[0].vertical)
    }

    @Test func adjacentColumnsAndFarFragmentsStaySeparate() {
        // Side-by-side columns overlap along the axis; a fragment 3 widths below is another line.
        let lines = V2LineAssembly.assemble([line(100, 100, 40, 200), line(150, 100, 40, 200), line(100, 420, 40, 80)], layout: [])
        #expect(lines.count == 3)
    }

    @Test func stackedHorizontalRowsDoNotJoinAsColumn() {
        let lines = V2LineAssembly.assemble([line(100, 100, 200, 30), line(100, 140, 200, 30)], layout: [])
        #expect(lines.count == 2)
    }

    @Test func fragmentsInDifferentBalloonsStaySeparate() {
        let fragments = [line(100, 100, 40, 120), line(100, 240, 40, 120)]
        let balloons = [
            V2LayoutRegion(kind: .balloon, bounds: CGRect(x: 80, y: 80, width: 80, height: 150), score: 0.9),
            V2LayoutRegion(kind: .balloon, bounds: CGRect(x: 80, y: 232, width: 80, height: 150), score: 0.9)
        ]
        #expect(V2LineAssembly.assemble(fragments, layout: balloons).count == 2)
        #expect(V2LineAssembly.assemble(fragments, layout: []).count == 1)
    }

    /// Synthetic page: black Japanese lettering on white (pixels generated in code).
    static func letteredPage() -> CGImage {
        let width = 640, height = 480
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let font = CTFontCreateWithName("HiraginoSans-W6" as CFString, 40, nil)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(red: 0, green: 0, blue: 0, alpha: 1)
        ]
        for (index, text) in ["今日はいい天気ですね", "明日も晴れるといいな", "テスト用の文字列です"].enumerated() {
            context.textPosition = CGPoint(x: 60, y: 360 - CGFloat(index) * 110)
            CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes)), context)
        }
        return context.makeImage()!
    }

    @Test func geometryEntryPointMatchesLegacyDetectionAndLegacyKeepsEvidence() async throws {
        let detector = NativeCoreMLDetector()
        let image = Self.letteredPage()
        let legacy = try await detector.detect(image: image, requestID: "legacy")
        let fast = try await detector.detectGeometry(image: image, requestID: "geometry")
        let again = try await detector.detect(image: image, requestID: "legacy-again")
        #expect(!legacy.boxes.isEmpty)
        #expect(fast.boxes.map(\.polygon) == legacy.boxes.map(\.polygon))
        #expect(fast.boxes.map(\.score) == legacy.boxes.map(\.score))
        #expect(fast.boxes.map(\.erasurePolygons) == legacy.boxes.map(\.erasurePolygons))
        // Legacy evidence is still produced and unaffected by an interleaved geometry-only call.
        #expect(legacy.boxes.contains { $0.detectorSeedEvidence != nil })
        #expect(fast.boxes.allSatisfy { $0.detectorSeedEvidence == nil && $0.recognitionColumnEvidence == nil })
        #expect(again.boxes == legacy.boxes)
    }
}
