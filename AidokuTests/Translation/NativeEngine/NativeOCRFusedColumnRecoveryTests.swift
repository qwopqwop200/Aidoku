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
        let lowerConfidence = read(2, source.text, CGRect(x: 20, y: 20, width: 125, height: 290), score: 0.63)
        let lowerProposal = try #require(NativeOCRFusedColumnRecovery.proposals(
            [lowerConfidence], frame: frame(), startingID: 20).first)
        #expect(NativeOCRFusedColumnRecovery.replacements(lowerProposal, reads: confirmed)?.count == 2)
        #expect(NativeOCRFusedColumnRecovery.replacements(lowerProposal, reads: wrong) == nil)
        #expect(NativeOCRFusedColumnRecovery.replacements(lowerProposal, reads: weak) == nil)
        let uncertain = read(2, source.text, CGRect(x: 20, y: 20, width: 125, height: 290), score: 0.59)
        #expect(try NativeOCRFusedColumnRecovery.proposals([uncertain], frame: frame(), startingID: 20).isEmpty)
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
        #expect(try NativeOCRFusedColumnRecovery.proposals([source], frame: frame(), startingID: Int.max).isEmpty)
        let invalidID = read(Int.max, source.text, CGRect(x: 20, y: 20, width: 125, height: 290))
        #expect(try NativeOCRFusedColumnRecovery.proposals([invalidID], frame: frame(), startingID: 20).isEmpty)
        let exterior = read(2, source.text, CGRect(x: 1_000_000, y: 20, width: 125, height: 290))
        #expect(try NativeOCRFusedColumnRecovery.proposals([exterior], frame: frame(), startingID: 20).isEmpty)
    }

    @Test func missingColumnRequiresPixelsAndTwoUnchangedWitnesses() throws {
        let width = 220, height = 360
        func frame(rule: Bool = false, darkPaper: Bool = false) throws -> NativeOCRRGBAFrame {
            var bytes = [UInt8](repeating: darkPaper ? 160 : 255, count: width * height * 4)
            for y in 45..<285 where rule || (y - 45) % 50 < 12 {
                for x in 90..<115 {
                    let offset = (y * width + x) * 4
                    bytes[offset] = 20; bytes[offset + 1] = 20; bytes[offset + 2] = 20
                }
            }
            return try #require(NativeOCRRGBAFrame(width: width, height: height, bytes: bytes))
        }
        let source = read(0, "混同", CGRect(x: 20, y: 20, width: 170, height: 300), score: 0.36)
        let left = read(1, "左の文章", CGRect(x: 30, y: 40, width: 40, height: 240), score: 0.96)
        let right = read(2, "右の文章", CGRect(x: 130, y: 40, width: 40, height: 240), score: 0.97)
        let proposal = try #require(NativeOCRFusedColumnRecovery.anchoredProposals(
            [source, left, right], frame: frame(), startingID: 20).first)
        #expect(proposal.regions.count == 3)
        #expect(proposal.original.sourceIndex == source.sourceIndex)
        let duplicate = read(3, source.text, CGRect(x: 20, y: 20, width: 170, height: 300), score: 0.4)
        #expect(try NativeOCRFusedColumnRecovery.anchoredProposals(
            [source, duplicate, left, right], frame: frame(), startingID: 20).count == 1)
        let missing = NativeCoreMLRecognizedRegion(sourceIndex: proposal.missing.sourceIndex,
            polygon: proposal.missing.polygon, text: "新しい文字", confidence: 0.99)
        let witnesses = proposal.witnesses.map {
            NativeCoreMLRecognizedRegion(sourceIndex: $0.region.sourceIndex, polygon: $0.region.polygon,
                text: $0.original.text, confidence: $0.original.confidence)
        }
        #expect(NativeOCRFusedColumnRecovery.anchoredReplacement(proposal, reads: [missing] + witnesses)?.text == missing.text)
        let unwitnessed = NativeOCRFusedColumnRecovery.AnchoredProposal(original: source, missing: proposal.missing, witnesses: [])
        #expect(NativeOCRFusedColumnRecovery.anchoredReplacement(unwitnessed, reads: [missing]) == nil)
        #expect(NativeOCRFusedColumnRecovery.anchoredReplacement(proposal, reads: [missing] + Array(witnesses.prefix(1))) == nil)
        let unrelated = witnesses.map {
            NativeCoreMLRecognizedRegion(sourceIndex: $0.sourceIndex, polygon: $0.polygon, text: "別の文章", confidence: 0.99)
        }
        #expect(NativeOCRFusedColumnRecovery.anchoredReplacement(proposal, reads: [missing] + unrelated) == nil)
        let uncertain = NativeCoreMLRecognizedRegion(sourceIndex: missing.sourceIndex, polygon: missing.polygon,
            text: missing.text, confidence: 0.94)
        #expect(NativeOCRFusedColumnRecovery.anchoredReplacement(proposal, reads: [uncertain] + witnesses) == nil)
        let moved = NativeCoreMLRecognizedRegion(sourceIndex: missing.sourceIndex,
            polygon: missing.polygon.map { CGPoint(x: $0.x + 20, y: $0.y) }, text: missing.text, confidence: 0.99)
        #expect(NativeOCRFusedColumnRecovery.anchoredReplacement(proposal, reads: [moved] + witnesses) == nil)
        #expect(try NativeOCRFusedColumnRecovery.anchoredProposals([source, left], frame: frame(), startingID: 20).isEmpty)
        #expect(try NativeOCRFusedColumnRecovery.anchoredProposals(
            [source, left, right], frame: frame(rule: true), startingID: 20).isEmpty)
        #expect(try NativeOCRFusedColumnRecovery.anchoredProposals(
            [source, left, right], frame: frame(darkPaper: true), startingID: 20).isEmpty)
        let weakRight = read(2, right.text, CGRect(x: 130, y: 40, width: 40, height: 240), score: 0.89)
        #expect(try NativeOCRFusedColumnRecovery.anchoredProposals(
            [source, left, weakRight], frame: frame(), startingID: 20).isEmpty)
        #expect(try NativeOCRFusedColumnRecovery.anchoredProposals(
            [source, left, right], frame: frame(), startingID: Int.max).isEmpty)
        let invalidID = read(Int.max, source.text, CGRect(x: 20, y: 20, width: 170, height: 300), score: 0.36)
        #expect(try NativeOCRFusedColumnRecovery.anchoredProposals(
            [invalidID, left, right], frame: frame(), startingID: 20).isEmpty)
    }
}
