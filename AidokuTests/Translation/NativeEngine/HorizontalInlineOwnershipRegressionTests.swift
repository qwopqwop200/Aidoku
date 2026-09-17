import CoreGraphics
import Foundation
import Testing
@testable import Aidoku

/// Recorded PP-OCR coordinates from four source-reviewed works. These tests
/// exercise native geometry directly; they need no image, network or OCR model.
struct HorizontalInlineOwnershipRegressionTests {
    private var outlinedChoiceRows: [NativeCoreMLOCRLine] { [
        row("- I Probably say you at", [CGPoint(x: 447, y: 504), CGPoint(x: 913, y: 505), CGPoint(x: 913, y: 542), CGPoint(x: 447, y: 541)], score: 0.9349497789921968),
        row("the store", [CGPoint(x: 478, y: 536), CGPoint(x: 667, y: 536), CGPoint(x: 667, y: 570), CGPoint(x: 478, y: 570)], score: 0.9987015856636895),
        row("e yesterday.", [CGPoint(x: 649, y: 538), CGPoint(x: 875, y: 538), CGPoint(x: 875, y: 572), CGPoint(x: 649, y: 572)], score: 0.9540747652451197),
        row("0", [CGPoint(x: 521, y: 628), CGPoint(x: 542, y: 628), CGPoint(x: 542, y: 644), CGPoint(x: 521, y: 644)], score: 0.9738354682922363),
        row("Are", [CGPoint(x: 554, y: 620), CGPoint(x: 638, y: 622), CGPoint(x: 637, y: 655), CGPoint(x: 553, y: 653)], score: 0.9895539879798889),
        row("you alone?", [CGPoint(x: 632, y: 622), CGPoint(x: 842, y: 619), CGPoint(x: 842, y: 653), CGPoint(x: 633, y: 656)], score: 0.9943566739559173)
    ] }

    private var fullNameRows: [NativeCoreMLOCRLine] { [
        row("KABURAGI", [CGPoint(x: 593, y: 142), CGPoint(x: 789, y: 141), CGPoint(x: 789, y: 158), CGPoint(x: 594, y: 160)], score: 0.9817402884364128),
        row("SARA", [CGPoint(x: 782, y: 141), CGPoint(x: 894, y: 141), CGPoint(x: 894, y: 158), CGPoint(x: 782, y: 158)], score: 0.8044062256813049)
    ] }

    private var toolbarRows: [NativeCoreMLOCRLine] { [
        row("BACK", [CGPoint(x: 628, y: 693), CGPoint(x: 680, y: 695), CGPoint(x: 679, y: 718), CGPoint(x: 627, y: 716)], score: 0.9998156875371933),
        row("HISTORY", [CGPoint(x: 696, y: 696), CGPoint(x: 781, y: 696), CGPoint(x: 781, y: 716), CGPoint(x: 696, y: 716)], score: 0.9998281853539603),
        row("SKIP", [CGPoint(x: 777, y: 694), CGPoint(x: 835, y: 694), CGPoint(x: 835, y: 716), CGPoint(x: 777, y: 716)], score: 0.9999119639396667),
        row("AUTO", [CGPoint(x: 849, y: 693), CGPoint(x: 910, y: 696), CGPoint(x: 909, y: 717), CGPoint(x: 848, y: 715)], score: 0.9992758482694626),
        row("Save", [CGPoint(x: 906, y: 694), CGPoint(x: 972, y: 694), CGPoint(x: 972, y: 716), CGPoint(x: 906, y: 716)], score: 0.9176491498947144),
        row("OPTIONS", [CGPoint(x: 986, y: 694), CGPoint(x: 1064, y: 694), CGPoint(x: 1064, y: 717), CGPoint(x: 986, y: 717)], score: 0.9999711683818272)
    ] }

    private var twoParagraphRows: [NativeCoreMLOCRLine] { [
        row("I WENT", [CGPoint(x: 567, y: 171), CGPoint(x: 649, y: 169), CGPoint(x: 649, y: 194), CGPoint(x: 568, y: 195)], score: 0.9421421488126119),
        row("TO A", [CGPoint(x: 577, y: 194), CGPoint(x: 630, y: 194), CGPoint(x: 630, y: 218), CGPoint(x: 577, y: 218)], score: 0.9974595606327057),
        row("MIXER", [CGPoint(x: 571, y: 219), CGPoint(x: 636, y: 219), CGPoint(x: 636, y: 241), CGPoint(x: 571, y: 241)], score: 0.9999679088592529),
        row("I THOUGHT", [CGPoint(x: 453, y: 245), CGPoint(x: 561, y: 245), CGPoint(x: 561, y: 265), CGPoint(x: 453, y: 265)], score: 0.9995297259754605),
        row("YES-", [CGPoint(x: 557, y: 242), CGPoint(x: 630, y: 242), CGPoint(x: 630, y: 266), CGPoint(x: 557, y: 266)], score: 0.9989086240530014),
        row("I'D SEE", [CGPoint(x: 469, y: 267), CGPoint(x: 545, y: 267), CGPoint(x: 545, y: 286), CGPoint(x: 469, y: 286)], score: 0.9989556159291949),
        row("TERDAY,", [CGPoint(x: 559, y: 267), CGPoint(x: 644, y: 267), CGPoint(x: 644, y: 290), CGPoint(x: 559, y: 290)], score: 0.9999518053872245),
        row("HOW SHE'D", [CGPoint(x: 454, y: 288), CGPoint(x: 559, y: 288), CGPoint(x: 559, y: 308), CGPoint(x: 454, y: 308)], score: 0.999924553765191),
        row("REACT TO", [CGPoint(x: 460, y: 310), CGPoint(x: 553, y: 310), CGPoint(x: 553, y: 330), CGPoint(x: 460, y: 330)], score: 0.9999222308397293),
        row("THE NEWS.", [CGPoint(x: 456, y: 333), CGPoint(x: 556, y: 333), CGPoint(x: 556, y: 351), CGPoint(x: 456, y: 351)], score: 0.9849395155906677)
    ] }

    @Test func actualOutlinedChoicesUniteRowsWithoutJoiningSeparateChoices() {
        for input in [outlinedChoiceRows, Array(outlinedChoiceRows.reversed())] {
            let output = merge(input, width: 1366, height: 768)
            #expect(Set(output.map(\.text)) == [
                "- I Probably say you at the store yesterday.", "0", "Are you alone?"
            ])
            #expect(output.count == 3)
            let sentence = output.first { $0.text.hasPrefix("- I Probably") }
            #expect(sentence?.boundingRect == CGRect(x: 447, y: 504, width: 466, height: 68))
            #expect(sentence?.sourceOrientation == .horizontal)
            #expect(sentence?.singleVerticalColumn == false)
            // Preserve recognizer output; merging must not silently correct say/0.
            #expect(output.first { $0.text == "0" }?.score == outlinedChoiceRows[3].score)
        }
    }

    @Test func actualSharedGlyphIsReconciledButPaddingKeepsEveryLetter() {
        let source = outlinedChoiceRows
        #expect(merge([source[1], source[2]]).map(\.text) == ["the store yesterday."])
        #expect(merge([source[4], source[5]]).map(\.text) == ["Are you alone?"])
    }

    @Test func actualRomanizedFullNameSharesOneInlineRegion() {
        for input in [fullNameRows, Array(fullNameRows.reversed())] {
            let output = merge(input, width: 2000, height: 723)
            #expect(output.map(\.text) == ["KABURAGI SARA"])
            #expect(output.first?.boundingRect == CGRect(x: 593, y: 141, width: 301, height: 19))
        }
    }

    @Test func actualToolbarActionsStayIndependentDespitePaddedOverlaps() {
        for input in [toolbarRows, Array(toolbarRows.reversed())] {
            let output = merge(input, width: 1280, height: 720)
            #expect(output.count == 6)
            #expect(Set(output.map(\.text)) == ["BACK", "HISTORY", "SKIP", "AUTO", "Save", "OPTIONS"])
            for original in input {
                let retained = output.first { $0.text == original.text }
                #expect(retained?.score == original.score)
                #expect(retained?.sourceOrientation == .horizontal)
            }
        }
    }

    @Test func actualAdjacentWrappedColumnsDoNotCrossWithinOneBalloon() {
        for input in [twoParagraphRows, Array(twoParagraphRows.reversed())] {
            let output = merge(input, width: 1350, height: 1920)
            #expect(Set(output.map(\.text)) == [
                "I WENT TO A MIXER YES- TERDAY,",
                "I THOUGHT I'D SEE HOW SHE'D REACT TO THE NEWS."
            ])
            #expect(output.count == 2)
        }
    }

    @Test func sourceBoundaryStillVetoesNewInlineEdge() {
        let input = [outlinedChoiceRows[4], outlinedChoiceRows[5]]
        let output = NativeOCRTextLineMerger.merge(input, imageWidth: 1366, imageHeight: 768,
            separationCheck: { _, _, _ in true })
        #expect(output.map(\.text) == ["Are", "you alone?"])
    }

    @Test func repeatedWordsAndStutterAreNotOneGlyphDuplicates() {
        let repeated = [rectangle("here", 100, 100, 84, 34), rectangle("here", 178, 100, 84, 34)]
        #expect(merge(repeated).map(\.text) == ["here here"])
        let stutter = [rectangle("I", 100, 100, 21, 34), rectangle("I am here", 115, 100, 189, 34)]
        #expect(merge(stutter).map(\.text) == ["I", "I am here"])
    }

    @Test func nonLatinAndExplicitVerticalSourcesDoNotEnterLatinPaddingRule() {
        let japanese = [rectangle("これは", 100, 100, 85, 35), rectangle("あなたです", 179, 100, 210, 37)]
        #expect(merge(japanese).map(\.text) == ["これは", "あなたです"])
        let vertical = [rectangle("Are", 100, 100, 85, 35, orientation: .vertical),
                        rectangle("you alone?", 179, 100, 210, 37, orientation: .vertical)]
        let output = merge(vertical)
        #expect(output.map(\.text) == ["Are", "you alone?"])
        #expect(output.allSatisfy { $0.sourceOrientation == .vertical })
    }

    private func merge(_ input: [NativeCoreMLOCRLine], width: Int = 1366, height: Int = 768) -> [PaddleOCRLine] {
        NativeOCRTextLineMerger.merge(input, imageWidth: width, imageHeight: height)
    }

    private func row(_ text: String, _ polygon: [CGPoint], score: Double) -> NativeCoreMLOCRLine {
        NativeCoreMLOCRLine(polygon: polygon, text: text, score: score,
            orientation: .horizontal, orientationIsEstimated: true)
    }

    private func rectangle(_ text: String, _ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat,
                           orientation: BrowserOCRSourceOrientation = .horizontal) -> NativeCoreMLOCRLine {
        NativeCoreMLOCRLine(polygon: [CGPoint(x: x, y: y), CGPoint(x: x + w, y: y),
            CGPoint(x: x + w, y: y + h), CGPoint(x: x, y: y + h)], text: text, score: 0.99,
            orientation: orientation, orientationIsEstimated: false)
    }
}
