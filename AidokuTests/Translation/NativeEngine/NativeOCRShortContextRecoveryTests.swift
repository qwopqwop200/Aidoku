import CoreGraphics
import Testing
@testable import Aidoku

struct NativeOCRShortContextRecoveryTests {
    private func read(_ id: Int, _ text: String, _ box: CGRect, score: Double) -> NativeCoreMLRecognizedRegion {
        .init(sourceIndex: id, polygon: [CGPoint(x: box.minX, y: box.minY), CGPoint(x: box.maxX, y: box.minY),
            CGPoint(x: box.maxX, y: box.maxY), CGPoint(x: box.minX, y: box.maxY)], text: text, confidence: score)
    }
    private func frame(punctuationColor: [UInt8]? = nil, bodyColor: [UInt8]? = nil) throws -> NativeOCRRGBAFrame {
        let width = 300, height = 300
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        func stripe(x: Int, y0: Int, y1: Int, color: [UInt8]) {
            for y in y0..<y1 { for xx in x..<(x + 2) {
                let p = (y * width + xx) * 4
                for c in 0..<3 { bytes[p + c] = color[c] }
            } }
        }
        if let bodyColor {
            stripe(x: 55, y0: 30, y1: 170, color: bodyColor)
            stripe(x: 90, y0: 30, y1: 170, color: bodyColor)
        }
        if let punctuationColor {
            stripe(x: 70, y0: 174, y1: 209, color: punctuationColor)
            stripe(x: 93, y0: 175, y1: 210, color: punctuationColor)
        }
        return try #require(NativeOCRRGBAFrame(width: width, height: height, bytes: bytes))
    }
    private var columns: [NativeCoreMLRecognizedRegion] {
        [read(1, "ア工文", CGRect(x: 180, y: 20, width: 30, height: 90), score: 0.82),
         read(2, "見本字", CGRect(x: 145, y: 20, width: 30, height: 95), score: 0.98),
         read(3, "漢字", CGRect(x: 110, y: 20, width: 30, height: 80), score: 0.88)]
    }
    private func agreement(_ proposal: NativeOCRShortContextRecovery.Proposal, _ text: String,
                           scores: [Double] = [0.92, 0.91]) -> [NativeCoreMLRecognizedRegion] {
        zip(proposal.variants, scores).map {
            .init(sourceIndex: $0.sourceIndex, polygon: $0.polygon, text: text, confidence: $1)
        } + proposal.witnesses
    }

    @Test func kanaRepairRequiresTwoShapesAndUnchangedIndependentColumns() throws {
        let pixels = try frame()
        let proposal = try #require(NativeOCRShortContextRecovery.proposals(columns, frame: pixels, startingID: 10).first)
        #expect(proposal.regions.map(\.sourceIndex) == [10, 11, 2, 3])
        #expect(proposal.variants.map(\.minimumSequenceWidth) == [160, 192])
        let valid = agreement(proposal, "アエ文")
        let recovered = NativeOCRShortContextRecovery.replacement(proposal, reads: valid, frame: pixels)
        #expect(recovered?.sourceIndex == 1)
        #expect(recovered?.text == "アエ文")
        #expect(recovered?.polygon == columns[0].polygon)
        #expect(recovered?.confidence == 0.91)
        #expect(NativeOCRShortContextRecovery.replacement(proposal, reads: Array(valid.dropFirst()), frame: pixels) == nil)
        #expect(NativeOCRShortContextRecovery.replacement(proposal, reads: valid + [valid[0]], frame: pixels) == nil)
        for text in ["ア工文", "カエ文", "アエ字", "アえ文", "アエ文字", "ア2文"] {
            #expect(NativeOCRShortContextRecovery.replacement(proposal, reads: agreement(proposal, text), frame: pixels) == nil)
        }
        #expect(NativeOCRShortContextRecovery.replacement(proposal,
            reads: agreement(proposal, "アエ文", scores: [0.99, 0.849]), frame: pixels) == nil)
        var disagree = valid
        disagree[1] = .init(sourceIndex: valid[1].sourceIndex, polygon: valid[1].polygon, text: "ア工文", confidence: 0.99)
        #expect(NativeOCRShortContextRecovery.replacement(proposal, reads: disagree, frame: pixels) == nil)
        var changed = valid
        changed[2] = .init(sourceIndex: valid[2].sourceIndex, polygon: valid[2].polygon, text: "別文章", confidence: 0.99)
        #expect(NativeOCRShortContextRecovery.replacement(proposal, reads: changed, frame: pixels) == nil)
        var moved = valid
        moved[0] = .init(sourceIndex: valid[0].sourceIndex,
            polygon: valid[0].polygon.map { CGPoint(x: $0.x + 1, y: $0.y) }, text: valid[0].text, confidence: valid[0].confidence)
        #expect(NativeOCRShortContextRecovery.replacement(proposal, reads: moved, frame: pixels) == nil)
    }

    @Test func ordinaryScriptsAndMissingOrAmbiguousContextCannotEnter() throws {
        let pixels = try frame()
        #expect(NativeOCRShortContextRecovery.proposals(Array(columns.prefix(2)), frame: pixels, startingID: 10).isEmpty)
        #expect(NativeOCRShortContextRecovery.proposals(columns, frame: pixels, startingID: Int.max).isEmpty)
        #expect(NativeOCRShortContextRecovery.proposals(columns + [columns[0]], frame: pixels, startingID: 10).isEmpty)
        for text in ["ABC", "123", "あいう", "漢字文"] {
            var input = columns
            input[0] = read(1, text, CGRect(x: 180, y: 20, width: 30, height: 90), score: 0.82)
            #expect(NativeOCRShortContextRecovery.proposals(input, frame: pixels, startingID: 10).isEmpty)
        }
        var weak = columns
        weak[1] = read(2, "見本字", CGRect(x: 145, y: 20, width: 30, height: 95), score: 0.89)
        #expect(NativeOCRShortContextRecovery.proposals(weak, frame: pixels, startingID: 10).isEmpty)
        let extra = read(4, "別文章", CGRect(x: 120, y: 22, width: 30, height: 80), score: 0.99)
        #expect(NativeOCRShortContextRecovery.proposals(columns + [extra], frame: pixels, startingID: 10).isEmpty)
        let confident = read(1, "ア工文", CGRect(x: 180, y: 20, width: 30, height: 90), score: 0.99)
        #expect(NativeOCRShortContextRecovery.proposals([confident] + Array(columns.dropFirst()), frame: pixels, startingID: 10).isEmpty)
    }

    @Test func punctuationNeedsTheExistingSourcePixelOwnershipPredicate() throws {
        let pink: [UInt8] = [220, 20, 120], blue: [UInt8] = [20, 80, 220]
        let pixels = try frame(punctuationColor: pink, bodyColor: pink)
        let body = read(1, "あうえ", CGRect(x: 50, y: 20, width: 60, height: 180), score: 0.76)
        let mark = read(2, "27", CGRect(x: 60, y: 165, width: 48, height: 55), score: 0.4)
        let proposal = try #require(NativeOCRShortContextRecovery.proposals([body, mark], frame: pixels, startingID: 10).first)
        let reads = agreement(proposal, "!?", scores: [0.8, 0.79])
        #expect(NativeOCRShortContextRecovery.replacement(proposal, reads: reads, frame: pixels)?.text == "!?")
        #expect(try NativeOCRShortContextRecovery.replacement(proposal, reads: reads, frame: frame()) == nil)
        #expect(try NativeOCRShortContextRecovery.replacement(proposal, reads: reads,
            frame: frame(punctuationColor: blue, bodyColor: pink)) == nil)
        #expect(NativeOCRShortContextRecovery.replacement(proposal,
            reads: agreement(proposal, "!?", scores: [0.99, 0.69]), frame: pixels) == nil)
        #expect(NativeOCRShortContextRecovery.replacement(proposal, reads: agreement(proposal, "!?A"), frame: pixels) == nil)
        let outside = read(2, "27", CGRect(x: 150, y: 165, width: 48, height: 55), score: 0.4)
        #expect(NativeOCRShortContextRecovery.proposals([body, outside], frame: pixels, startingID: 10).isEmpty)
        let noKana = read(1, "ART", CGRect(x: 50, y: 20, width: 60, height: 180), score: 0.99)
        #expect(NativeOCRShortContextRecovery.proposals([noKana, mark], frame: pixels, startingID: 10).isEmpty)
    }

    @Test func contextualRereadsHaveAFixedEightCropBudgetAndUniqueIDs() throws {
        let pixels = try #require(NativeOCRRGBAFrame(width: 1_200, height: 300,
            bytes: [UInt8](repeating: 255, count: 1_200 * 300 * 4)))
        let input = (0..<4).flatMap { index in
            columns.map { source in
                NativeCoreMLRecognizedRegion(sourceIndex: source.sourceIndex + index * 3,
                    polygon: source.polygon.map { CGPoint(x: $0.x + CGFloat(index * 280), y: $0.y) },
                    text: source.text, confidence: source.confidence)
            }
        }
        let proposals = NativeOCRShortContextRecovery.proposals(input, frame: pixels, startingID: 20)
        #expect(proposals.count == 2)
        let ids = proposals.flatMap(\.regions).map(\.sourceIndex)
        #expect(ids.count == 8)
        #expect(Set(ids).count == ids.count)
    }

    @Test func contextualPaddingKeepsEverySampleBitAndAddsOnlyZeroColumns() throws {
        let width = 180, height = 180
        let bytes = (0..<(width * height * 4)).map { UInt8(($0 * 7) % 251) }
        let pixels = try #require(NativeOCRRGBAFrame(width: width, height: height, bytes: bytes))
        let polygon = [CGPoint(x: 12, y: 15), CGPoint(x: 60, y: 15), CGPoint(x: 60, y: 135), CGPoint(x: 12, y: 135)]
        let exact = try #require(NativeCoreMLRecognitionPreprocessor.plan(polygon: polygon, dynamicWidth: true))
        let source = try #require(NativeCoreMLRecognitionPreprocessor.prepare(frame: pixels, plan: exact))
        #expect(exact.bucket.width == 120)
        for minimum in [160, 192] {
            let plan = try #require(NativeCoreMLRecognitionPreprocessor.plan(polygon: polygon,
                dynamicWidth: true, minimumSequenceWidth: minimum))
            let padded = try #require(NativeCoreMLRecognitionPreprocessor.prepare(frame: pixels, plan: plan))
            #expect(plan.bucket.width == minimum)
            #expect(plan.resizedWidth == 120)
            var samplesMatch = true, marginsAreZero = true
            for channel in 0..<3 { for y in 0..<48 { for x in 0..<minimum {
                let value = padded.values[(channel * 48 + y) * minimum + x]
                if x < 120 { samplesMatch = samplesMatch && value.bitPattern == source.values[(channel * 48 + y) * 120 + x].bitPattern }
                else { marginsAreZero = marginsAreZero && value == 0 }
            } } }
            #expect(samplesMatch)
            #expect(marginsAreZero)
        }
        let staticPlan = try #require(NativeCoreMLRecognitionPreprocessor.plan(polygon: polygon))
        #expect(staticPlan.bucket.width == 320)
        let long = [CGPoint(x: 0, y: 0), CGPoint(x: 160, y: 0), CGPoint(x: 160, y: 48), CGPoint(x: 0, y: 48)]
        #expect(NativeCoreMLRecognitionPreprocessor.plan(polygon: long, dynamicWidth: true)?.bucket.width == 160)
        #expect(NativeCoreMLRecognitionPreprocessor.plan(polygon: long, dynamicWidth: true, minimumSequenceWidth: 192) == nil)
    }

    @Test func contextualPlansCannotPretendThatUnsupportedWidthsAreIndependent() throws {
        let polygon = [CGPoint(x: 12, y: 15), CGPoint(x: 60, y: 15), CGPoint(x: 60, y: 135), CGPoint(x: 12, y: 135)]
        for requested in [160, 192] {
            #expect(NativeCoreMLRecognitionPreprocessor.plan(polygon: polygon, minimumSequenceWidth: requested) == nil)
            #expect(NativeCoreMLRecognitionPreprocessor.plan(polygon: polygon, dynamicWidth: true,
                maximumWidth: 128, minimumSequenceWidth: requested) == nil)
            #expect(NativeCoreMLRecognitionPreprocessor.plan(polygon: polygon, dynamicWidth: true,
                maximumWidth: 192, minimumSequenceWidth: requested)?.bucket.width == requested)
        }
        // A model capped at160 supplies one valid variant, never an apparent pair.
        let supported = [160, 192].compactMap { requested in
            NativeCoreMLRecognitionPreprocessor.plan(polygon: polygon, dynamicWidth: true,
                maximumWidth: 160, minimumSequenceWidth: requested)?.bucket.width
        }
        #expect(supported == [160])
        #expect(NativeCoreMLRecognitionPreprocessor.plan(polygon: polygon, dynamicWidth: true,
            minimumSequenceWidth: Int.max) == nil)
        #expect(NativeCoreMLRecognitionPreprocessor.plan(polygon: polygon, dynamicWidth: true,
            minimumSequenceWidth: -1) == nil)
        // Ordinary low-cap/static operation remains available without a request.
        #expect(NativeCoreMLRecognitionPreprocessor.plan(polygon: polygon, dynamicWidth: true, maximumWidth: 64)?.bucket.width == 64)
    }
}
