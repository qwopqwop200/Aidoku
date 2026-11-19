import CoreGraphics
import CoreML
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

    /// The original quadratic rescan, kept as the reference for the cached-pair assembly.
    private func referenceAssemble(_ lines: [V2Line], balloons: [CGRect]) -> [V2Line] {
        let parameters = V2LineAssembly.Parameters.standard
        func coverage(_ box: CGRect, _ region: CGRect) -> CGFloat {
            guard box.width > 0, box.height > 0 else { return 0 }
            let width = max(0, min(box.maxX, region.maxX) - max(box.minX, region.minX))
            let height = max(0, min(box.maxY, region.maxY) - max(box.minY, region.minY))
            return width * height / (box.width * box.height)
        }
        func owner(_ box: CGRect) -> Int? {
            var best: Int?, bestCoverage: CGFloat = 0
            for (index, balloon) in balloons.enumerated() where coverage(box, balloon) > bestCoverage {
                bestCoverage = coverage(box, balloon)
                best = index
            }
            return bestCoverage >= parameters.balloonInside ? best : nil
        }
        func allows(_ a: (box: CGRect, owner: Int?), _ b: (box: CGRect, owner: Int?)) -> Bool {
            switch (a.owner, b.owner) {
            case let (x?, y?): x == y
            case let (x?, nil): coverage(b.box, balloons[x]) >= parameters.balloonOutside
            case let (nil, y?): coverage(a.box, balloons[y]) >= parameters.balloonOutside
            case (nil, nil): true
            }
        }
        var items = lines.map { (line: $0, box: $0.bounds, owner: owner($0.bounds)) }
        while true {
            var best: (gap: CGFloat, i: Int, j: Int)?
            for i in items.indices {
                for j in (i + 1)..<items.count {
                    guard let gap = V2LineAssembly.joinGap(items[i].box, items[j].box, parameters),
                          best.map({ gap < $0.gap }) ?? true,
                          allows((items[i].box, items[i].owner), (items[j].box, items[j].owner)) else { continue }
                    best = (gap, i, j)
                }
            }
            guard let best else { break }
            let a = items[best.i], b = items[best.j]
            let box = a.box.union(b.box)
            var merged = a.line
            merged.polygon = [
                CGPoint(x: box.minX, y: box.minY), CGPoint(x: box.maxX, y: box.minY),
                CGPoint(x: box.maxX, y: box.maxY), CGPoint(x: box.minX, y: box.maxY)
            ]
            merged.bounds = box
            merged.vertical = box.height >= box.width
            merged.detectionScore = max(a.line.detectionScore, b.line.detectionScore)
            items[best.i] = (merged, box, owner(box))
            items.remove(at: best.j)
        }
        return items.map(\.line)
    }

    /// Deterministic noisy page: jittered column fragments plus specks (no image pixels).
    private func noisyFragments(count: Int, seed: UInt64) -> [V2Line] {
        var state = seed
        func next(_ bound: Int) -> CGFloat {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return CGFloat(Int((state >> 33) % UInt64(bound)))
        }
        return (0..<count).map { index in
            if index % 3 == 0 { return line(next(1_600), next(2_400), 4 + next(12), 4 + next(12), score: 0.5) }
            let column = CGFloat(index % 40) * 45
            return line(column + next(4), next(2_300), 30 + next(10), 30 + next(90), score: 0.8)
        }
    }

    @Test func cachedPairAssemblyMatchesQuadraticRescan() {
        let balloons = [CGRect(x: 0, y: 0, width: 700, height: 900), CGRect(x: 800, y: 1_000, width: 600, height: 800)]
        let layout = balloons.map { V2LayoutRegion(kind: .balloon, bounds: $0, score: 0.9) }
        for seed in 1...6 as ClosedRange<UInt64> {
            let fragments = noisyFragments(count: 160, seed: seed)
            #expect(V2LineAssembly.assemble(fragments, layout: []) == referenceAssemble(fragments, balloons: []))
            #expect(V2LineAssembly.assemble(fragments, layout: layout) == referenceAssemble(fragments, balloons: balloons))
        }
    }

    /// The detector caps a page at 3,000 candidates; the old O(n^3) rescan hung on such pages.
    @Test func assemblyOfCandidateCapPageCompletes() {
        let fragments = noisyFragments(count: 3_000, seed: 42)
        let lines = V2LineAssembly.assemble(fragments, layout: [])
        #expect(!lines.isEmpty && lines.count <= fragments.count)
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

    @Test func imageAndFrameEntryPointsAgree() async throws {
        let detector = NativeCoreMLDetector()
        let image = Self.letteredPage()
        let frame = try #require(NativeOCRCGImageAdapter.makeRGBAFrame(from: image))
        let fromImage = try await detector.detectGeometry(image: image)
        let fromFrame = try await detector.detectGeometry(frame: frame)
        #expect(!fromImage.isEmpty)
        #expect(fromFrame == fromImage)
        let lines = try await V2Detection.detect(frame: frame, page: V2Page(id: "p", image: image), detector: detector)
        #expect(lines == fromImage.compactMap { V2Detection.line(polygon: $0.polygon, score: $0.score) })
    }
}
