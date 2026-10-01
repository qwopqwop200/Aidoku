import CoreGraphics
import Testing
@testable import Aidoku

struct NativeOCRFusedColumnRecoveryTests {
    private func read(_ id: Int, _ text: String, _ box: CGRect, score: Double = 0.95) -> NativeCoreMLRecognizedRegion {
        .init(sourceIndex: id, polygon: [CGPoint(x: box.minX, y: box.minY), CGPoint(x: box.maxX, y: box.minY),
            CGPoint(x: box.maxX, y: box.maxY), CGPoint(x: box.minX, y: box.maxY)], text: text, confidence: score)
    }

    @Test func requiresSeparateGlyphBandsAndConfirmedReads() throws {
        let width = 180, height = 360
        func frame(rule: Bool = false, darkPaper: Bool = false) throws -> NativeOCRRGBAFrame {
            var bytes = [UInt8](repeating: darkPaper ? 160 : 255, count: width * height * 4)
            for x0 in [40, 90] {
                for y in 35..<285 where rule || (y - 35) % 50 < 12 {
                    for x in x0..<(x0 + 26) {
                        let offset = (y * width + x) * 4
                        bytes[offset] = 20; bytes[offset + 1] = 20; bytes[offset + 2] = 20
                    }
                }
            }
            return try #require(NativeOCRRGBAFrame(width: width, height: height, bytes: bytes))
        }
        let source = read(2, "チェリ", CGRect(x: 20, y: 20, width: 125, height: 290), score: 0.73)
        let proposal = try #require(NativeOCRFusedColumnRecovery.proposals([source], frame: frame(), startingID: 20).first)
        #expect(proposal.regions.count == 2)
        #expect(proposal.regions.map(\.sourceIndex) == [20, 21])
        let confirmed = zip(proposal.regions, ["チェリノに", "会ったら"]).map {
            NativeCoreMLRecognizedRegion(sourceIndex: $0.sourceIndex, polygon: $0.polygon, text: $1, confidence: 0.98)
        }
        #expect(NativeOCRFusedColumnRecovery.replacements(proposal, reads: confirmed)?.count == 2)
        #expect(NativeOCRFusedColumnRecovery.replacements(proposal, reads: Array(confirmed.prefix(1))) == nil)
        let wrong = proposal.regions.map {
            NativeCoreMLRecognizedRegion(sourceIndex: $0.sourceIndex, polygon: $0.polygon, text: "別の文章", confidence: 0.99)
        }
        #expect(NativeOCRFusedColumnRecovery.replacements(proposal, reads: wrong) == nil)
        let weak = confirmed.map {
            NativeCoreMLRecognizedRegion(sourceIndex: $0.sourceIndex, polygon: $0.polygon, text: $0.text, confidence: 0.89)
        }
        #expect(NativeOCRFusedColumnRecovery.replacements(proposal, reads: weak) == nil)
        let anchorSource = read(3, "よろしくね", CGRect(x: 20, y: 20, width: 125, height: 290), score: 0.99)
        var anchor = NativeOCRFusedColumnRecovery.Proposal(original: anchorSource, regions: [proposal.regions[0]])
        anchor.fusedOwner = source.sourceIndex
        let identical = NativeCoreMLRecognizedRegion(sourceIndex: proposal.regions[0].sourceIndex,
            polygon: proposal.regions[0].polygon, text: anchorSource.text, confidence: 0.99)
        #expect(NativeOCRFusedColumnRecovery.replacements(anchor, reads: [identical])?.count == 1)
        #expect(NativeOCRFusedColumnRecovery.replacements(anchor, reads: [confirmed[0]]) == nil)

        #expect(try NativeOCRFusedColumnRecovery.proposals([source], frame: frame(rule: true), startingID: 20).isEmpty)
        #expect(try NativeOCRFusedColumnRecovery.proposals([source], frame: frame(darkPaper: true), startingID: 20).isEmpty)
        let single = read(2, "よろしくね", CGRect(x: 30, y: 20, width: 46, height: 290))
        #expect(try NativeOCRFusedColumnRecovery.proposals([single], frame: frame(), startingID: 20).isEmpty)
    }
}
