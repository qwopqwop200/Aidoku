import CoreGraphics
import Testing
@testable import Aidoku

struct NativeOCRShortFragmentRecoveryTests {
    private func read(_ id: Int, _ text: String, _ box: CGRect, score: Double) -> NativeCoreMLRecognizedRegion {
        .init(sourceIndex: id, polygon: [CGPoint(x: box.minX, y: box.minY), CGPoint(x: box.maxX, y: box.minY),
            CGPoint(x: box.maxX, y: box.maxY), CGPoint(x: box.minX, y: box.maxY)], text: text, confidence: score)
    }
    private var head: NativeCoreMLRecognizedRegion { read(1, "あ", CGRect(x: 120, y: 30, width: 42, height: 48), score: 0.48) }
    private var tail: NativeCoreMLRecognizedRegion { read(2, "6", CGRect(x: 116, y: 72, width: 50, height: 50), score: 0.96) }
    private var witness: NativeCoreMLRecognizedRegion { read(3, "いうえお", CGRect(x: 55, y: 25, width: 55, height: 210), score: 0.98) }

    @Test func joinedCropMustPreserveKanaAndConfirmTheNeighbor() throws {
        let proposal = try #require(NativeOCRShortFragmentRecovery.proposals([head, tail, witness], width: 300, height: 300).first)
        #expect(proposal.replaced == [1, 2])
        #expect(proposal.regions.map(\.sourceIndex) == [1, 3])
        let correct = NativeCoreMLRecognizedRegion(sourceIndex: 1, polygon: proposal.combined.polygon, text: "あの", confidence: 0.995)
        #expect(NativeOCRShortFragmentRecovery.replacement(proposal, reads: [correct, witness]) == correct)
        #expect(NativeOCRShortFragmentRecovery.replacement(proposal, reads: [correct]) == nil)
        #expect(NativeOCRShortFragmentRecovery.replacement(proposal, reads: [correct, witness, correct]) == nil)
        #expect(NativeOCRShortFragmentRecovery.replacement(proposal, reads: [correct, witness, witness]) == nil)
        for (text, score) in [("あの", 0.949), ("あの", 0.959), ("別の", 0.999), ("あ6", 0.999), ("あのね", 0.999)] {
            let bad = NativeCoreMLRecognizedRegion(sourceIndex: 1, polygon: proposal.combined.polygon, text: text, confidence: score)
            #expect(NativeOCRShortFragmentRecovery.replacement(proposal, reads: [bad, witness]) == nil)
        }
        let changedWitness = NativeCoreMLRecognizedRegion(sourceIndex: 3, polygon: witness.polygon, text: "別の文章", confidence: 0.999)
        #expect(NativeOCRShortFragmentRecovery.replacement(proposal, reads: [correct, changedWitness]) == nil)
        let weakWitness = NativeCoreMLRecognizedRegion(sourceIndex: 3, polygon: witness.polygon, text: witness.text, confidence: 0.94)
        #expect(NativeOCRShortFragmentRecovery.replacement(proposal, reads: [correct, weakWitness]) == nil)
        let moved = NativeCoreMLRecognizedRegion(sourceIndex: 1,
            polygon: proposal.combined.polygon.map { CGPoint(x: $0.x + 1, y: $0.y) }, text: correct.text, confidence: correct.confidence)
        #expect(NativeOCRShortFragmentRecovery.replacement(proposal, reads: [moved, witness]) == nil)
    }

    @Test func ordinaryNumbersArtworkAndConflictingColumnsCannotProposeRecovery() {
        func proposals(_ input: [NativeCoreMLRecognizedRegion]) -> [NativeOCRShortFragmentRecovery.Proposal] {
            NativeOCRShortFragmentRecovery.proposals(input, width: 300, height: 300)
        }
        // No kana context: ASCII artwork and a standalone numeral are untouched.
        #expect(proposals([tail]).isEmpty)
        #expect(proposals([head, tail]).isEmpty)
        let numericHead = read(1, "2", CGRect(x: 120, y: 30, width: 42, height: 48), score: 0.48)
        #expect(proposals([numericHead, tail, witness]).isEmpty)
        let confidentHead = read(1, "あ", CGRect(x: 120, y: 30, width: 42, height: 48), score: 0.9)
        #expect(proposals([confidentHead, tail, witness]).isEmpty)
        let outside = read(2, "6", CGRect(x: 300, y: 72, width: 50, height: 50), score: 0.96)
        #expect(proposals([head, outside, witness]).isEmpty)
        let separate = read(2, "6", CGRect(x: 170, y: 72, width: 50, height: 50), score: 0.96)
        #expect(proposals([head, separate, witness]).isEmpty)
        let distant = read(2, "6", CGRect(x: 116, y: 100, width: 50, height: 50), score: 0.96)
        #expect(proposals([head, distant, witness]).isEmpty)
        let secondTail = read(4, "8", CGRect(x: 117, y: 73, width: 50, height: 50), score: 0.98)
        #expect(proposals([head, tail, witness, secondTail]).isEmpty)
        let latinWitness = read(3, "ABCDE", CGRect(x: 55, y: 25, width: 55, height: 210), score: 0.99)
        #expect(proposals([head, tail, latinWitness]).isEmpty)
        let weakWitness = read(3, "いうえお", CGRect(x: 55, y: 25, width: 55, height: 210), score: 0.89)
        #expect(proposals([head, tail, weakWitness]).isEmpty)
        #expect(proposals([head, tail, witness, head]).isEmpty)
        var malformed = head.polygon
        malformed[0].x = .nan
        let invalid = NativeCoreMLRecognizedRegion(sourceIndex: 1, polygon: malformed, text: head.text, confidence: head.confidence)
        #expect(proposals([invalid, tail, witness]).isEmpty)
    }

    @Test func aStrongWitnessCanBeClaimedByOnlyOneProposal() {
        let shared = read(9, "いうえお", CGRect(x: 60, y: 25, width: 70, height: 310), score: 0.98)
        let first = [read(1, "あ", CGRect(x: 130, y: 30, width: 70, height: 80), score: 0.48),
            read(2, "6", CGRect(x: 126, y: 105, width: 80, height: 75), score: 0.96)]
        let second = [read(3, "か", CGRect(x: 185, y: 30, width: 70, height: 80), score: 0.48),
            read(4, "9", CGRect(x: 181, y: 105, width: 80, height: 75), score: 0.96)]
        #expect(NativeOCRShortFragmentRecovery.proposals(first + [shared], width: 600, height: 500).count == 1)
        #expect(NativeOCRShortFragmentRecovery.proposals(second + [shared], width: 600, height: 500).count == 1)
        let proposals = NativeOCRShortFragmentRecovery.proposals(first + second + [shared], width: 600, height: 500)
        #expect(proposals.count == 1)
        let ids = proposals.flatMap(\.regions).map(\.sourceIndex)
        #expect(Set(ids).count == ids.count)
    }

    @Test func multipleRepairsHaveAFixedEightCropBudget() {
        var input: [NativeCoreMLRecognizedRegion] = []
        for index in 0..<6 {
            let x = CGFloat(index * 220)
            input += [read(index * 3, "あ", CGRect(x: x + 120, y: 30, width: 42, height: 48), score: 0.48),
                read(index * 3 + 1, "6", CGRect(x: x + 116, y: 72, width: 50, height: 50), score: 0.96),
                read(index * 3 + 2, "いうえお", CGRect(x: x + 55, y: 25, width: 55, height: 210), score: 0.98)]
        }
        let proposals = NativeOCRShortFragmentRecovery.proposals(input, width: 1_500, height: 300)
        #expect(proposals.count == 4)
        #expect(proposals.flatMap(\.regions).count == 8)
        #expect(Set(proposals.flatMap(\.replaced)).count == 8)
    }
}
