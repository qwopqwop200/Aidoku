import Foundation
import CoreGraphics
import Testing
@testable import Aidoku

struct TilePaddingDuplicateRegressionTests {
    struct Fixture { let lines: [NativeCoreMLOCRLine]; let width: Int; let height: Int }
    // Actual recorded quads and tile bounds. No local image/JSON dependency.
    private func fixtures() -> [Fixture] {
        [
            Fixture(lines: [
                NativeCoreMLOCRLine(polygon: [CGPoint(x: 2408, y: 3644), CGPoint(x: 2549, y: 3649), CGPoint(x: 2549, y: 4382), CGPoint(x: 2390, y: 4377)], text: "生涯と呼ぶには", score: 0.9911925281797137, orientation: .vertical, orientationIsEstimated: true, sourceTileBounds: CGRect(x: 1305, y: 3425, width: 1536, height: 1536)),
                NativeCoreMLOCRLine(polygon: [CGPoint(x: 2435, y: 3667), CGPoint(x: 2557, y: 3666), CGPoint(x: 2562, y: 4361), CGPoint(x: 2440, y: 4362)], text: "生涯と呼ぶには", score: 0.9994640094893319, orientation: .vertical, orientationIsEstimated: true, sourceTileBounds: CGRect(x: 1960, y: 3425, width: 1536, height: 1536)),
            ], width: 3496, height: 4961),
            Fixture(lines: [
                NativeCoreMLOCRLine(polygon: [CGPoint(x: 1002, y: 1521), CGPoint(x: 1148, y: 1521), CGPoint(x: 1148, y: 1535), CGPoint(x: 1002, y: 1535)], text: "STUTTERING", score: 0.952090984582901, orientation: .horizontal, orientationIsEstimated: true, sourceTileBounds: CGRect(x: 0, y: 0, width: 1350, height: 1536)),
                NativeCoreMLOCRLine(polygon: [CGPoint(x: 1001, y: 1521), CGPoint(x: 1148, y: 1521), CGPoint(x: 1148, y: 1542), CGPoint(x: 1001, y: 1542)], text: "STUTTERING", score: 0.9999838829040527, orientation: .horizontal, orientationIsEstimated: true, sourceTileBounds: CGRect(x: 0, y: 384, width: 1350, height: 1536)),
            ], width: 1350, height: 1920),
            Fixture(lines: [
                NativeCoreMLOCRLine(polygon: [CGPoint(x: 757, y: 1519), CGPoint(x: 901, y: 1519), CGPoint(x: 901, y: 1536), CGPoint(x: 757, y: 1536)], text: "SPEAK THE", score: 0.9937626984384325, orientation: .horizontal, orientationIsEstimated: true, sourceTileBounds: CGRect(x: 0, y: 0, width: 1350, height: 1536)),
                NativeCoreMLOCRLine(polygon: [CGPoint(x: 757, y: 1520), CGPoint(x: 903, y: 1520), CGPoint(x: 903, y: 1544), CGPoint(x: 757, y: 1544)], text: "SPEAK THE", score: 0.9996946056683859, orientation: .horizontal, orientationIsEstimated: true, sourceTileBounds: CGRect(x: 0, y: 384, width: 1350, height: 1536)),
            ], width: 1350, height: 1920),
        ]
    }
    private func occurrences(_ lines: [NativeCoreMLOCRLine], of text: String, width: Int, height: Int) -> Int {
        NativeOCRTextLineMerger.merge(lines, imageWidth: width, imageHeight: height)
            .reduce(0) { $0 + $1.text.components(separatedBy: text).count - 1 }
    }
    private func changed(_ line: NativeCoreMLOCRLine, text: String? = nil, tile: CGRect?, dx: CGFloat = 0, dy: CGFloat = 0) -> NativeCoreMLOCRLine {
        NativeCoreMLOCRLine(polygon: line.polygon.map { CGPoint(x: $0.x + dx, y: $0.y + dy) },
            text: text ?? line.text, score: line.score, orientation: line.orientation,
            orientationIsEstimated: true, sourceTileBounds: tile)
    }
    @Test func actualDoujinPaddedColumnDeduplicates() {
        let fixture = fixtures()[0], text = fixture.lines[0].text
        for lines in [fixture.lines, Array(fixture.lines.reversed())] {
            #expect(occurrences(lines, of: text, width: fixture.width, height: fixture.height) == 1)
        }
    }
    @Test func actualRenaiStutteringDeduplicates() {
        let f = fixtures()[1]
        #expect(occurrences(f.lines, of: "STUTTERING", width: f.width, height: f.height) == 1)
    }
    @Test func actualRenaiSpeakTheDeduplicates() {
        let f = fixtures()[2]
        #expect(occurrences(f.lines, of: "SPEAK THE", width: f.width, height: f.height) == 1)
    }
    @Test func sameTileDoesNotEnablePaddingFallback() {
        let f = fixtures()[0]
        let lines = [f.lines[0], changed(f.lines[1], tile: f.lines[0].sourceTileBounds)]
        #expect(occurrences(lines, of: f.lines[0].text, width: f.width, height: f.height) == 2)
    }
    @Test func adjacentColumnWithRepeatedSentenceRemainsPresent() {
        let f = fixtures()[0]
        let lines = [f.lines[0], changed(f.lines[1], tile: f.lines[1].sourceTileBounds, dx: 200)]
        #expect(occurrences(lines, of: f.lines[0].text, width: f.width, height: f.height) == 2)
    }
    @Test func shortRepeatedUtteranceDoesNotEnablePaddingFallback() {
        let f = fixtures()[0]
        let lines = f.lines.map { changed($0, text: "はい", tile: $0.sourceTileBounds) }
        #expect(occurrences(lines, of: "はい", width: f.width, height: f.height) == 2)
    }
    @Test func disjointTilesDoNotEnablePaddingFallback() {
        let f = fixtures()[0]
        let lines = [changed(f.lines[0], tile: CGRect(x: 0, y: 0, width: 100, height: 100)),
                     changed(f.lines[1], tile: CGRect(x: 200, y: 0, width: 100, height: 100))]
        #expect(occurrences(lines, of: f.lines[0].text, width: f.width, height: f.height) == 2)
    }
}
