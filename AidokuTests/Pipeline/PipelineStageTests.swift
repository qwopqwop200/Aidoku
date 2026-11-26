import CoreGraphics
import CoreML
import Foundation
import Testing
@testable import Aidoku

/// Model-free contracts of the pipeline stages (S1-S10).
struct PipelineStageTests {
    private func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> [CGPoint] {
        [CGPoint(x: x, y: y), CGPoint(x: x + w, y: y), CGPoint(x: x + w, y: y + h), CGPoint(x: x, y: y + h)]
    }

    private func line(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat) -> PipelineLine {
        PipelineDetection.line(polygon: [
            CGPoint(x: x + width, y: y), CGPoint(x: x + width, y: y + height),
            CGPoint(x: x, y: y + height), CGPoint(x: x, y: y)
        ], score: 0.9)!
    }

    private func column(_ x: CGFloat, _ y: CGFloat, _ height: CGFloat, _ text: String) -> PipelineLine {
        let bounds = CGRect(x: x, y: y, width: 40, height: height)
        return PipelineLine(polygon: rect(x, y, 40, height), bounds: bounds, vertical: true, detectionScore: 0.9,
                      text: text, confidence: 0.95)
    }

    private func placedBlock(_ id: Int, _ bounds: CGRect, _ text: String) -> PipelineBlock {
        PipelineBlock(
            id: id, lines: [], bounds: bounds, polygon: [], vertical: false, readingOrder: id, sourceText: "",
            balloon: nil, role: .dialogue, translation: text, style: styled(40, width: 2)
        )
    }

    private func maskBlock(_ polygon: [CGPoint], bounds: CGRect, role: PipelineRole = .dialogue) -> PipelineBlock {
        let line = PipelineLine(polygon: polygon, bounds: bounds, vertical: false, detectionScore: 1)
        return PipelineBlock(id: 0, lines: [line], bounds: bounds, polygon: polygon, vertical: false, readingOrder: 0,
                       sourceText: "", balloon: nil, role: role)
    }

    // MARK: S1-S3 detection and grouping

    @Test func lineKeepFeaturesMatchThePythonReference() throws {
        let text = PipelineLineKeep.textFeatures("\u{3042}\u{3042}\u{FF01}\u{FF01} AB12\u{6F22}")
        let two: Double = 2.0 / 9, one: Double = 1.0 / 9, seven: Double = 7.0 / 9
        let shares: [Double] = [9, two, one, two, two, two, two, two, seven, 1]
        #expect(text == shares)
        let first = column(100, 100, 200, "\u{3042}\u{3044}\u{3046}")
        var second = column(150, 100, 160, "\u{3048}\u{304A}")
        second.confidence = 0.7
        let layout = [PipelineLayoutRegion(kind: .text, bounds: CGRect(x: 90, y: 90, width: 110, height: 230), score: 0.8)]
        let rows = PipelineLineKeep.features([first, second], layout: layout, pageSize: CGSize(width: 1000, height: 1500))
        let expected: [Double] = [0.9, 0.7, 0.5, 2, 1, 0, 0, 0, 0, 0, 0.5, 1, 1, 0.8, 1, 0, 0, 0, 0, 0, 0, 0.026667,
                                  0.106667, 4, 0.004267, 1, 1, 0.17, 0.12, 0.066667, 0, 0, 1, 2]
        #expect(rows[1].count == expected.count)
        for (value, want) in zip(rows[1], expected) { #expect(abs(value - want) < 1e-6) }
        if let model = PipelineLineKeep.shared { #expect(model.features.count == expected.count) }
    }

    @Test func learnedResourcesLoadWithTheFittedConstants() throws {
        let join = try #require(PipelineLineAssembly.model)
        #expect(join.features.count == 22 && join.mean.count == 22 && join.scale.count == 22 && join.weights.count == 22)
        #expect(join.threshold == 0.4)
        let grouping = try #require(PipelineParagraphGrouping.Model.shared)
        #expect(grouping.features.count == grouping.weights.count)
        // Retrained thresholds move (tools/retrain/grouping): check their order, not their values.
        #expect(grouping.cutBelow > 0 && grouping.cutBelow < grouping.joinAbove && grouping.joinAbove < 1)
        #expect(grouping.pitchRatio.map { $0 > 1 } ?? true)
        let font = try #require(PipelineFontCorrection.model)
        #expect(font.bias.isFinite && font.cellOffset.isFinite && font.n0 >= 0 && font.maxSpread > 0)
        #expect(font.cellWeights.count == 12)
        #expect(PipelineStyleParameters.outlinePage == [0.4094924613695863, 0.19954881908897934, -0.9404877504298349])
        #expect(PipelineStyleParameters.outlineWidthRing == 0.49653723604023625)
        #expect(PipelineStyleParameters.outlineWidthFont == 0.042260916827793475)
        #expect(PipelineStyleParameters.outlineWidthBias == -0.04776139182973868)
        let boxes = try #require(PipelineLineBoxes.shared)
        #expect(boxes.classes.count == 6)
        #expect(PipelineLineKeep.shared != nil && PipelineInteriorModel.shared != nil)
    }

    @Test func lineBoxRefineKeepsLinesWithoutARaster() {
        let lines = [column(100, 100, 200, "\u{3042}\u{3044}"), column(150, 100, 160, "\u{3046}")]
        let refined = PipelineLineBoxes.refine(lines, fragments: lines, layout: [], gray: nil,
                                               pageSize: CGSize(width: 1000, height: 1500))
        #expect(refined == lines)
        #expect(PipelineLineBoxes.refine([], fragments: [], layout: [], gray: nil, pageSize: .zero).isEmpty)
    }

    @Test func lineKeepForestGoesLeftAtOrBelowTheSplit() throws {
        let json = #"{"features":["a"],"threshold":0.5,"roots":[0],"feature":[0,-1,-1],"split":[1.0,0,0],"#
            + #""left":[1,-1,-1],"right":[2,-1,-1],"value":[0,-1,1]}"#
        let model = try JSONDecoder().decode(PipelineLineKeep.self, from: Data(json.utf8))
        #expect(abs(model.probability([1.0]) - 1 / (1 + exp(1.0))) < 1e-12)
        #expect(model.probability([1.5]) > model.threshold)
    }

    @Test func detectionJoinsSplitColumnsButNotAcrossBalloons() {
        let fragments = [line(100, 100, 40, 120), line(102, 250, 38, 90), line(101, 360, 40, 40)]
        let joined = PipelineLineAssembly.assemble(fragments, layout: [])
        #expect(joined.count == 1)
        #expect(joined[0].bounds == CGRect(x: 100, y: 100, width: 41, height: 300))
        #expect(joined[0].vertical)
        let split = [line(100, 100, 40, 120), line(100, 240, 40, 120)]
        let balloons = [
            PipelineLayoutRegion(kind: .balloon, bounds: CGRect(x: 80, y: 80, width: 80, height: 150), score: 0.9),
            PipelineLayoutRegion(kind: .balloon, bounds: CGRect(x: 80, y: 232, width: 80, height: 150), score: 0.9)
        ]
        #expect(PipelineLineAssembly.assemble(split, layout: balloons).count == 2)
        // A tilted column whose two leftmost corners are its top edge keeps that edge on top.
        let tilted = PipelineDetection.line(polygon: [
            CGPoint(x: 74, y: 313), CGPoint(x: 143, y: 850), CGPoint(x: 90, y: 857), CGPoint(x: 20, y: 320)
        ], score: 0.9)!
        #expect(tilted.polygon == [
            CGPoint(x: 20, y: 320), CGPoint(x: 74, y: 313), CGPoint(x: 143, y: 850), CGPoint(x: 90, y: 857)
        ])
    }

    /// The pair model joins a narrow glyph centred under its column (thickness ratio 2.2, past the hand rule)
    /// and keeps apart two long columns stacked 1.4 thicknesses apart but offset across.
    @Test func assemblyJoinsNarrowGlyphsButNotOffsetColumns() {
        let glyph = PipelineLineAssembly.assemble([line(100, 100, 40, 200), line(108, 302, 18, 30)], layout: [])
        #expect(glyph.count == 1)
        #expect(glyph[0].bounds == CGRect(x: 100, y: 100, width: 40, height: 232))
        #expect(PipelineLineAssembly.assemble([line(100, 100, 40, 240), line(112, 396, 40, 240)], layout: []).count == 2)
        #expect(PipelineLineAssembly.joinGap(CGRect(x: 100, y: 100, width: 40, height: 240),
                                             CGRect(x: 112, y: 396, width: 40, height: 240)) != nil)
    }

    @Test func groupingReadsBalloonColumnsRightToLeft() {
        let balloon = PipelineLayoutRegion(kind: .balloon, bounds: CGRect(x: 380, y: 80, width: 200, height: 400), score: 0.95)
        let lines = [column(420, 100, 300, "左"), column(470, 100, 300, "右"), column(100, 900, 200, "下")]
        let blocks = PipelineGrouping.group(lines, layout: [balloon], pageSize: CGSize(width: 1000, height: 1400))
        #expect(blocks.count == 2)
        #expect(blocks[0].sourceText == "右左")
        #expect(blocks[0].balloon == balloon.bounds)
        #expect(blocks.map(\.readingOrder) == [0, 1])
    }

    /// Cascade stage 1: a next column 0.25 glyph away joins whatever its text; lines of two orientations never join.
    @Test func groupingJoinsTightColumnsButNotAcrossOrientations() {
        let size = CGSize(width: 1000, height: 1400)
        let quoted = [column(470, 100, 200, "「はい」"), column(420, 100, 200, "「いいえ」")]
        #expect(PipelineGrouping.group(quoted, layout: [], pageSize: size).count == 1)
        let glyph = PipelineLine(polygon: rect(470, 310, 40, 40), bounds: CGRect(x: 470, y: 310, width: 40, height: 40),
                           vertical: false, detectionScore: 0.9, text: "！", confidence: 0.95)
        #expect(PipelineGrouping.group([column(470, 100, 200, "あいうえ"), glyph], layout: [], pageSize: size).count == 2)
    }

    /// Cascade stage 2 (resolver): columns 0.7 glyph apart join only inside one RF text box.
    @Test func groupingJoinsLooseColumnsOnlyInsideOneTextBox() {
        let size = CGSize(width: 1000, height: 1400)
        let lines = [column(470, 100, 300, "ことばです"), column(402, 100, 300, "つづきです")]
        #expect(PipelineGrouping.group(lines, layout: [], pageSize: size).count == 2)
        let text = PipelineLayoutRegion(kind: .text, bounds: CGRect(x: 392, y: 90, width: 138, height: 320), score: 0.9)
        #expect(PipelineGrouping.group(lines, layout: [text], pageSize: size).count == 1)
    }

    /// A wide low-confidence column under an RF SFX box is junk: it stays out of the speech next to it.
    @Test func groupingKeepsSFXOutOfSpeech() {
        let size = CGSize(width: 1000, height: 1400)
        let speech = [column(470, 100, 300, "ことばです"), column(420, 100, 300, "つづきです")]
        let sfx = PipelineLine(polygon: rect(300, 80, 90, 340), bounds: CGRect(x: 300, y: 80, width: 90, height: 340),
                               vertical: true, detectionScore: 0.9, text: "ドン", confidence: 0.5)
        let layout = [PipelineLayoutRegion(kind: .text, bounds: CGRect(x: 410, y: 90, width: 110, height: 320), score: 0.9),
                      PipelineLayoutRegion(kind: .sfx, bounds: CGRect(x: 295, y: 75, width: 100, height: 350), score: 0.9)]
        let blocks = PipelineGrouping.group(speech + [sfx], layout: layout, pageSize: size)
        #expect(blocks.map(\.sourceText).sorted() == ["ことばですつづきです", "ドン"])
    }

    /// Page 0001: RF boxes each of two adjacent paragraphs strongly and both weakly as one; the columns 0.85 glyph
    /// apart stay two paragraphs with the boxes and without any.
    @Test func groupingKeepsAdjacentParagraphsApartUnderAMergedTextBox() {
        let size = CGSize(width: 1000, height: 1400)
        let right = [column(600, 100, 300, "みぎの"), column(555, 100, 300, "ことば"), column(510, 100, 300, "です")]
        let left = [column(436, 100, 300, "ひだり"), column(391, 100, 300, "のことば")]
        let strong = [PipelineLayoutRegion(kind: .text, bounds: CGRect(x: 500, y: 90, width: 150, height: 320), score: 0.66),
                      PipelineLayoutRegion(kind: .text, bounds: CGRect(x: 381, y: 90, width: 105, height: 320), score: 0.66)]
        let merged = PipelineLayoutRegion(kind: .text, bounds: CGRect(x: 375, y: 85, width: 280, height: 330), score: 0.28)
        for layout in [strong + [merged], []] {
            let split = PipelineGrouping.group(right + left, layout: layout, pageSize: size)
            #expect(split.map(\.sourceText).sorted() == ["ひだりのことば", "みぎのことばです"])
        }
    }

    /// Page 0666: big display lettering, a two-glyph piece at its end and a credit line under that piece; the
    /// lettering and the credit line never share a block.
    @Test func groupingKeepsDisplayLetteringApartFromSmallText() {
        func row(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat, _ text: String) -> PipelineLine {
            PipelineLine(polygon: rect(x, y, width, height), bounds: CGRect(x: x, y: y, width: width, height: height),
                         vertical: false, detectionScore: 0.9, text: text, confidence: 0.99)
        }
        let lettering = row(131, 2394, 1415, 269, "おおきなじ"), piece = row(1532, 2571, 161, 70, "小字")
        let credit = row(176, 2699, 1476, 62, "ちいさなもじのいちぎょうです")
        let blocks = PipelineGrouping.group([lettering, piece, credit], layout: [], pageSize: CGSize(width: 2160, height: 2880))
        #expect(blocks.contains { $0.sourceText == "ちいさなもじのいちぎょうです" })
        #expect(!blocks.contains { $0.sourceText.contains("おおきなじ") && $0.sourceText.contains("ちいさな") })
    }

    /// Page 0064: two paragraphs side by side, columns 0-4 px apart inside each and 20 px (0.9 glyph) between them.
    @Test func groupingSplitsAtAGutterWiderThanTheParagraphsColumnGaps() {
        let size = CGSize(width: 1000, height: 1400)
        func col(_ x: CGFloat, _ text: String) -> PipelineLine {
            PipelineLine(polygon: rect(x, 100, 22, 180), bounds: CGRect(x: x, y: 100, width: 22, height: 180), vertical: true,
                         detectionScore: 0.9, text: text, confidence: 0.99)
        }
        let paired = [col(600, "みぎのぶん"), col(576, "つづきです"), col(534, "ひだりのぶ"), col(510, "んつづきで")]
        #expect(PipelineGrouping.group(paired, layout: [], pageSize: size).map(\.sourceText).sorted()
                == ["ひだりのぶんつづきで", "みぎのぶんつづきです"])
    }

    /// Legacy intercolumn ruby: a narrow kana rail just right of one kanji column is erased with it, never translated.
    @Test func groupingErasesRubyWithItsHostColumn() {
        let ruby = PipelineLine(polygon: rect(442, 120, 20, 120), bounds: CGRect(x: 442, y: 120, width: 20, height: 120),
                          vertical: true, detectionScore: 0.9, text: "かんじ", confidence: 0.95)
        let blocks = PipelineGrouping.group([column(400, 100, 200, "漢字です"), ruby], layout: [], pageSize: CGSize(width: 1000, height: 1400))
        #expect(blocks.count == 1)
        #expect(blocks.first?.sourceText == "漢字です" && blocks.first?.lines.count == 2)
    }

    private func textLine(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ text: String, vertical: Bool) -> PipelineLine {
        PipelineLine(polygon: rect(x, y, w, h), bounds: CGRect(x: x, y: y, width: w, height: h), vertical: vertical,
                     detectionScore: 0.9, text: text, confidence: 0.95)
    }

    /// A column the detector cut in two (1.3 thicknesses apart) joins only inside one RF text box.
    @Test func groupingJoinsStackedPiecesOfOneTextBox() {
        let size = CGSize(width: 1000, height: 1400)
        let pieces = [textLine(400, 100, 40, 200, "漢字の文章です", vertical: true), textLine(402, 352, 40, 150, "続きの文章", vertical: true)]
        let box = PipelineLayoutRegion(kind: .text, bounds: CGRect(x: 380, y: 80, width: 100, height: 450), score: 0.9)
        #expect(PipelineGrouping.group(pieces, layout: [box], pageSize: size).count == 1)
        #expect(PipelineGrouping.group(pieces, layout: [], pageSize: size).count == 2)
    }

    /// Horizontal CJK lines of one balloon: a title over a smaller-pitch subtitle stays apart, equal pitch joins.
    @Test func groupingKeepsHorizontalTitleApartFromSubtitle() {
        let size = CGSize(width: 1000, height: 1400)
        let layout = [PipelineLayoutRegion(kind: .text, bounds: CGRect(x: 90, y: 90, width: 320, height: 130), score: 0.9),
                      PipelineLayoutRegion(kind: .balloon, bounds: CGRect(x: 80, y: 80, width: 340, height: 150), score: 0.9)]
        let title = [textLine(100, 100, 300, 60, "大きな題名", vertical: false), textLine(100, 170, 245, 40, "小さな副題です", vertical: false)]
        #expect(PipelineGrouping.group(title, layout: layout, pageSize: size).count == 2)
        let text = [textLine(100, 100, 300, 40, "同じ大きさの文", vertical: false), textLine(100, 150, 260, 40, "次の行の文章", vertical: false)]
        #expect(PipelineGrouping.group(text, layout: layout, pageSize: size).count == 1)
    }

    /// Two columns of one RF text box with the middle columns read as rows (page 0528) form one paragraph.
    @Test func groupingBridgesColumnsAcrossMisorientedRows() {
        let lines = [textLine(600, 100, 40, 300, "右の列の文章です", vertical: true), textLine(440, 100, 40, 300, "左の列の文章です", vertical: true),
                     textLine(490, 150, 100, 30, "横の行", vertical: false), textLine(490, 250, 100, 30, "横の文", vertical: false)]
        let box = PipelineLayoutRegion(kind: .text, bounds: CGRect(x: 420, y: 80, width: 240, height: 340), score: 0.9)
        #expect(PipelineGrouping.group(lines, layout: [box], pageSize: CGSize(width: 1000, height: 1400)).count == 1)
    }

    /// Finite but overflowing coordinates give a NaN axis; grouping must fall back, not trap.
    @Test func overflowingPolygonDoesNotTrapGrouping() {
        let huge = CGFloat.greatestFiniteMagnitude
        let line = PipelineLine(polygon: [CGPoint(x: 0, y: 0), CGPoint(x: huge, y: 0), CGPoint(x: huge, y: 10), CGPoint(x: 0, y: 10)],
                          bounds: CGRect(x: 0, y: 0, width: huge, height: 10), vertical: false, detectionScore: 0.9,
                          text: "x", confidence: 0.9)
        #expect(PipelineGrouping.group([line], layout: [], pageSize: CGSize(width: 1000, height: 1400)).count == 1)
    }

    // MARK: S4 layout detection decode, S5 recognition plan

    @Test func rfDecodeKeepsConfidentQueries() throws {
        let boxes = try MLMultiArray(shape: [1, 300, 4], dataType: .float32)
        let logits = try MLMultiArray(shape: [1, 300, 5], dataType: .float32)
        let box = boxes.dataPointer.assumingMemoryBound(to: Float.self)
        let logit = logits.dataPointer.assumingMemoryBound(to: Float.self)
        for i in 0..<(300 * 4) { box[i] = 0.1 }
        for i in 0..<(300 * 5) { logit[i] = -10 }
        // Query 3: a balloon centered at (0.5, 0.5), 0.2 x 0.4 of the page; query 10: a weaker frame.
        box[12] = 0.5; box[13] = 0.5; box[14] = 0.2; box[15] = 0.4
        logit[3 * 5 + 2] = 4
        box[40] = 0.3; box[41] = 0.6; box[42] = 0.5; box[43] = 0.3
        logit[10 * 5 + 3] = 2
        let regions = try PipelineLayoutDetection.decode(PipelineRFDETRModel.RawOutput(boxes: boxes, logits: logits),
                                                   width: 1000, height: 2000)
        #expect(regions.map(\.kind) == [.balloon, .frame])
        let bounds = regions[0].bounds
        #expect(abs(bounds.minX - 400) <= 1 && abs(bounds.minY - 600) <= 1)
        #expect(abs(bounds.width - 200) <= 2 && abs(bounds.height - 800) <= 2)
    }

    @Test func recognitionPlanRotatesColumnsAndRejectsDegenerateQuads() throws {
        let tall = try #require(PipelineRecognition.plan(rect(10, 10, 50, 400)))
        #expect(tall.rotatedCounterClockwise)
        // Text lines are padded by 5% of the short side: 55 x 405, so 48 * 405 / 55 rounds to 353.
        #expect(tall.bucket.width == 353)
        let long = try #require(PipelineRecognition.plan(rect(0, 0, 1200, 40)))
        #expect(!long.rotatedCounterClockwise)
        #expect(long.bucket.width == 640)
        #expect(PipelineRecognition.plan(rect(0, 0, 0, 0)) == nil)
    }

    // MARK: S6 removal mask, S7 inpaint

    /// A white 400 x `height` RGBA page with black `strokes`.
    private func inkPage(_ strokes: [CGRect], height: Int = 200) -> [UInt8] {
        var rgba = [UInt8](repeating: 255, count: 400 * height * 4)
        for stroke in strokes {
            for y in Int(stroke.minY)..<Int(stroke.maxY) {
                for x in Int(stroke.minX)..<Int(stroke.maxX) {
                    let i = (y * 400 + x) * 4
                    rgba[i] = 0; rgba[i + 1] = 0; rgba[i + 2] = 0
                }
            }
        }
        return rgba
    }

    @Test func removalMaskErasesInkButNotTheBalloonOrBackgroundRole() {
        let width = 400, height = 200
        let strokes = [CGRect(x: 110, y: 82, width: 6, height: 36), CGRect(x: 130, y: 97, width: 40, height: 6)]
        let rgba = inkPage(strokes)
        let region = CGRect(x: 100, y: 75, width: 170, height: 50)
        let mask = PipelineRemovalMask.build(rgba: rgba, width: width, height: height,
                                       blocks: [maskBlock(rect(100, 75, 170, 50), bounds: region)], layout: [])
        #expect(mask.count == width * height)
        for stroke in strokes {
            for y in Int(stroke.minY)..<Int(stroke.maxY) {
                for x in Int(stroke.minX)..<Int(stroke.maxX) { #expect(mask[y * width + x] == 255) }
            }
        }
        #expect(mask[30 * width + 30] == 0 && mask[160 * width + 350] == 0)
        let background = PipelineRemovalMask.build(rgba: rgba, width: width, height: height,
            blocks: [maskBlock(rect(100, 75, 170, 50), bounds: region, role: .background)], layout: [])
        #expect(background.allSatisfy { $0 == 0 })
    }

    /// A glyph 18-24 px past the end of a 50 px thick line is outside the 15 px ROI square but inside
    /// the 0.5-thickness line-end extension, so the bundled classifier erases it (the polygon fallback would not).
    @Test func removalMaskSearchesPastTheLineEnd() {
        #expect(PipelineMaskNet.bundled != nil)
        let width = 400, height = 200
        let stroke = CGRect(x: 288, y: 85, width: 6, height: 30)
        let mask = PipelineRemovalMask.build(rgba: inkPage([stroke]), width: width, height: height,
                                       blocks: [maskBlock(rect(100, 75, 170, 50), bounds: CGRect(x: 100, y: 75, width: 170, height: 50))],
                                       layout: [])
        var erased = 0
        for y in Int(stroke.minY)..<Int(stroke.maxY) {
            for x in Int(stroke.minX)..<Int(stroke.maxX) where mask[y * width + x] == 255 { erased += 1 }
        }
        #expect(erased * 4 >= 3 * 180)
        #expect(mask[100 * width + 340] == 0)
    }

    /// A glyph 12-44 px past a 50 px column's box end moves that end out (and only that end).
    @Test func lineEndsFollowInkPastTheDetectorBox() throws {
        let width = 400, height = 400
        var glyphs: [CGRect] = []
        for k in 0..<4 {
            glyphs += [CGRect(x: 105, y: 55 + k * 50, width: 40, height: 6), CGRect(x: 122, y: 55 + k * 50, width: 6, height: 40)]
        }
        let extra = [CGRect(x: 105, y: 262, width: 40, height: 6), CGRect(x: 122, y: 258, width: 6, height: 36)]
        let forest = try #require(PipelineRemovalMaskWeights.lineEnds)
        let line = PipelineLine(polygon: rect(100, 50, 50, 200), bounds: CGRect(x: 100, y: 50, width: 50, height: 200),
                          vertical: true, detectionScore: 0.9)
        let plain = try #require(inkPage(glyphs, height: height).withUnsafeBufferPointer {
            PipelineLineEnds.offsets(line, pixels: $0, width: width, height: height, regions: [], forest: forest)
        })
        #expect(abs(plain.0) < 0.1 && abs(plain.1) < 0.1)
        let refined = inkPage(glyphs + extra, height: height).withUnsafeBufferPointer {
            PipelineLineEnds.refined([line], pixels: $0, width: width, height: height, layout: [], forest: forest)
        }
        let bare = inkPage(glyphs, height: height).withUnsafeBufferPointer {
            PipelineLineEnds.refined([line], pixels: $0, width: width, height: height, layout: [], forest: forest)
        }
        // Ink past the end reaches further than none (how far is the retrained regressor's call).
        #expect(refined[0].bounds.minY == 50 && refined[0].bounds.maxY > bare[0].bounds.maxY)
    }

    /// Inside a text region a flagged end reaches along the ink run (a glyph 8-44 px past the end of a 50 px column:
    /// 44 px = 0.88 T, plus 0.1 T), capped at the region's edge; an end without ink past it gains nothing, and
    /// outside any text region the classifier is not asked.
    @Test func lineEndClassifierExtendsAlongTheInkRun() throws {
        let width = 400, height = 400
        var glyphs: [CGRect] = []
        for k in 0..<4 {
            glyphs += [CGRect(x: 105, y: 55 + k * 50, width: 40, height: 6), CGRect(x: 122, y: 55 + k * 50, width: 6, height: 40)]
        }
        glyphs += [CGRect(x: 105, y: 262, width: 40, height: 6), CGRect(x: 122, y: 258, width: 6, height: 36)]
        let forest = try #require(PipelineRemovalMaskWeights.lineEnds)
        let shared = try #require(PipelineLineEndClassifier.shared)
        #expect(shared.trees.count == 100 && shared.features == PipelineLineEndClassifier.featureCount)
        let leaf = PipelineOutlineWidthModel.Tree(f: [0], t: [0], l: [-1], r: [-1], v: [0])
        let always = PipelineLineEndClassifier(features: 45, threshold: -1, trees: [leaf])
        let never = PipelineLineEndClassifier(features: 45, threshold: 1, trees: [leaf])
        let line = PipelineLine(polygon: rect(100, 50, 50, 200), bounds: CGRect(x: 100, y: 50, width: 50, height: 200),
                          vertical: true, detectionScore: 0.9)
        let page = inkPage(glyphs, height: height)
        func offsets(_ classifier: PipelineLineEndClassifier?, _ regions: [PipelineLayoutRegion]) throws -> (Double, Double) {
            try #require(page.withUnsafeBufferPointer {
                PipelineLineEnds.offsets(line, pixels: $0, width: width, height: height, regions: regions,
                                         forest: forest, classifier: classifier)
            })
        }
        func text(_ height: CGFloat) -> [PipelineLayoutRegion] {
            [PipelineLayoutRegion(kind: .text, bounds: CGRect(x: 90, y: 40, width: 70, height: height), score: 0.9)]
        }
        let margin = PipelineLineEnds.margin
        let open = try offsets(nil, text(360)), quiet = try offsets(never, text(360)), fired = try offsets(always, text(360))
        #expect(quiet.0 == open.0 && quiet.1 == open.1)
        #expect(abs(fired.1 - max(open.1, 0.88 + 0.1 - margin)) < 1e-9)
        #expect(abs(fired.0 - max(open.0, 0.1 - margin)) < 1e-9)
        let near = try offsets(nil, text(220)), capped = try offsets(always, text(220))
        #expect(abs(capped.1 - max(near.1, 0.2 + 0.1 - margin)) < 1e-9)
        let bare = try offsets(nil, []), ungated = try offsets(always, [])
        #expect(ungated.0 == bare.0 && ungated.1 == bare.1)
    }

    /// `Int(floor(-1e300))` used to trap while computing the block frame.
    @Test func removalMaskIgnoresHugeAndNonFinitePolygons() {
        let width = 300, height = 200
        let rgba = [UInt8](repeating: 255, count: width * height * 4)
        let blocks = [
            maskBlock([CGPoint(x: -1e300, y: 50), CGPoint(x: 1e300, y: 50), CGPoint(x: 1e300, y: 150)],
                      bounds: CGRect(x: 0, y: 0, width: 1e300, height: 1e300)),
            maskBlock([CGPoint(x: CGFloat.nan, y: 1), CGPoint(x: 2, y: 3), CGPoint(x: 4, y: 9)], bounds: .null)
        ]
        let mask = PipelineRemovalMask.build(rgba: rgba, width: width, height: height, blocks: blocks, layout: [])
        #expect(mask.count == width * height && mask.allSatisfy { $0 == 0 })
        #expect(PipelineRemovalMask.build(rgba: [], width: -3, height: 5, blocks: blocks, layout: []).isEmpty)
    }

    @Test func aotFitsTheWholePageIntoTheModelSide() throws {
        let width = 3000, height = 2000
        var mask = [UInt8](repeating: 0, count: width * height)
        mask[1000 * width + 1500] = 255
        let patch = try #require(PipelineAOTModel.wholePage(mask, width: width, height: height))
        #expect(patch.rect == (0, 0, width, height) && patch.origin == (0, 0) && patch.size == (1024, 683))
        let small = try #require(PipelineAOTModel.wholePage([UInt8](repeating: 1, count: 100), width: 10, height: 10))
        #expect(small.size == (10, 10))
        #expect(PipelineAOTModel.wholePage([UInt8](repeating: 0, count: 100), width: 10, height: 10) == nil)
    }

    @Test func aotScatterChangesOnlyMaskPixels() throws {
        let width = 37, height = 23
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        for i in 0..<(width * height) {
            rgba[i * 4] = UInt8(i % 251); rgba[i * 4 + 1] = UInt8((i * 7) % 253); rgba[i * 4 + 2] = 9; rgba[i * 4 + 3] = 255
        }
        var mask = [UInt8](repeating: 0, count: width * height)
        for y in 5..<12 { for x in 10..<20 { mask[y * width + x] = 255 } }
        let image = try MLMultiArray(shape: [1, 3, 1024, 1024], dataType: .float16)
        let maskTensor = try MLMultiArray(shape: [1, 1, 1024, 1024], dataType: .float16)
        let content = PipelineAOTModel.fill(rgba: rgba, mask: mask, width: width, height: height, image: image, maskTensor: maskTensor)
        #expect(content.0 == width && content.1 == height)
        // A constant mid-gray prediction stands in for the model output.
        let raw = try MLMultiArray(shape: [1, 3, 1024, 1024], dataType: .float16)
        let values = raw.dataPointer.assumingMemoryBound(to: Float16.self)
        for i in 0..<(3 * 1024 * 1024) { values[i] = 0 }
        var restored = rgba
        try restored.withUnsafeMutableBufferPointer {
            try PipelineAOTModel.scatter(into: $0, mask: mask, width: width, height: height, raw: raw, content: content)
        }
        for p in 0..<(width * height) {
            if mask[p] == 0 {
                #expect(Array(restored[(p * 4)..<(p * 4 + 4)]) == Array(rgba[(p * 4)..<(p * 4 + 4)]))
            } else {
                #expect(restored[p * 4] == 128 && restored[p * 4 + 1] == 128 && restored[p * 4 + 2] == 128)
            }
        }
    }

    // MARK: S8 style

    @Test func styleDetectsWhiteOutlineOnGrey() throws {
        let width = 240, height = 320
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(gray: 0.45, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let bars = (0..<3).map { CGRect(x: 100 + $0 * 18, y: height - 255, width: 8, height: 190) }
        context.setFillColor(gray: 1, alpha: 1)
        for bar in bars { context.fill(bar.insetBy(dx: -4, dy: -4)) }
        context.setFillColor(gray: 0, alpha: 1)
        for bar in bars { context.fill(bar) }
        let page = PipelinePage(id: "synthetic", image: try #require(context.makeImage()))
        let polygon = rect(90, 60, 60, 200)
        let block = PipelineBlock(id: 0, lines: [PipelineLine(polygon: polygon, bounds: CGRect(x: 90, y: 60, width: 60, height: 200),
                                                  vertical: true, detectionScore: 1)],
                            bounds: CGRect(x: 90, y: 60, width: 60, height: 200), polygon: [], vertical: true,
                            readingOrder: 0, sourceText: "あいうえお", balloon: nil)
        let style = try #require(PipelineStyle.estimate(page, blocks: [block]).first?.style)
        #expect(style.fontPixels > 0)
        #expect(max(style.textColor.r, style.textColor.g, style.textColor.b) < 40)
        let stroke = try #require(style.strokeColor)
        #expect(min(stroke.r, stroke.g, stroke.b) > 215)
        #expect(style.strokeWidth > 1)
        #expect(PipelineStyle.estimate(page, blocks: []).isEmpty)
    }

    @Test func sourceSizeGroupFollowsTheLongerText() {
        func block(_ id: Int, _ line: PipelineLine, _ text: String) -> PipelineBlock {
            PipelineBlock(id: id, lines: [line], bounds: line.bounds, polygon: line.polygon, vertical: true,
                    readingOrder: id, sourceText: text, balloon: nil)
        }
        func mark(_ x: CGFloat) -> PipelineLine {
            PipelineLine(polygon: rect(x, 100, 30, 34), bounds: CGRect(x: x, y: 100, width: 30, height: 34),
                   vertical: true, detectionScore: 0.9)
        }
        let dialogue = block(1, column(200, 100, 400, ""), "あいうえおかきくけこさしすせそた")
        let alone = PipelineSimpleFont.estimate([dialogue])[0]
        // Two short marks and one dialogue share a group; the group takes the dialogue's size.
        let sizes = PipelineSimpleFont.estimate([block(0, mark(100), "ッ!"), dialogue, block(2, mark(300), "ッ!")])
        #expect(sizes.allSatisfy { abs($0 - alone) < 0.001 })
    }

    @Test func sourceSizeCellsCountRunsOnce() {
        let kana = PipelineFontCorrection.cellCount("あいう")
        #expect(abs(kana - (3 * PipelineFontCorrection.cellWeights[0] + PipelineFontCorrection.cellOffset)) < 1e-12)
        // A !? run sets as one cell however many marks it holds (tate-chu-yoko).
        #expect(abs(PipelineFontCorrection.cellCount("!!") - PipelineFontCorrection.cellCount("!")) < 0.05)
        #expect(PipelineFontCorrection.cellCount("あ あ") == PipelineFontCorrection.cellCount("ああ"))
        // Ink rows 10..89 of a 40 x 100 column, the rest paper.
        var gray = [UInt8](repeating: 250, count: 40 * 100)
        for y in 10..<90 { for x in 12..<28 { gray[y * 40 + x] = 10 } }
        #expect(PipelineFontCorrection.inkExtent(gray: gray, width: 40, height: 100, vertical: true) == 80)
        #expect(PipelineFontCorrection.inkExtent(gray: gray, width: 40, height: 100, vertical: false) == 16)
    }

    @Test func sourceSizeFollowsCharacterPitch() throws {
        let width = 400, height = 400
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(gray: 0, alpha: 1)
        // Five 30 px glyphs at a 40 px pitch (page y 20..210) in a 60 px wide, loosely detected column.
        for k in 0..<5 { context.fill(CGRect(x: 105, y: height - (20 + 40 * k) - 30, width: 30, height: 30)) }
        let image = try #require(context.makeImage())
        let column = PipelineLine(polygon: rect(90, 10, 60, 210), bounds: CGRect(x: 90, y: 10, width: 60, height: 210),
                                  vertical: true, detectionScore: 1, text: "あいうえお", confidence: 1)
        let block = PipelineBlock(id: 0, lines: [column], bounds: column.bounds, polygon: column.polygon, vertical: true,
                                  readingOrder: 0, sourceText: "あいうえお", balloon: nil)
        var groups: [Int] = []
        let fonts = PipelineSimpleFont.estimate([block], groups: &groups)
        let drawn = PipelineFontCorrection.corrected([block], fonts: fonts, groups: groups, image: image)
        let raster = try PipelinePageRaster(image)
        // The raster bytes and a 1:1 draw of the image measure the same ink.
        #expect(drawn == PipelineFontCorrection.corrected([block], fonts: fonts, groups: groups, image: image, raster: raster))
        // Pitch 190 px of ink / 4.94 cells pulls the geometric size toward ~38 px.
        let geometric = Double(fonts[0]) * exp(PipelineFontCorrection.level - PipelineFontCorrection.bias)
        let pitch = 190 / PipelineFontCorrection.cellCount("あいうえお") * exp(PipelineFontCorrection.level)
        let size = Double(drawn[0])
        #expect(min(geometric, pitch) < size && size < max(geometric, pitch))
        // Without pixels the geometric size stands.
        let blind = PipelineFontCorrection.corrected([block], fonts: fonts, groups: groups, image: nil)
        #expect(abs(Double(blind[0]) - geometric) < 1e-9)
    }

    // MARK: S9 layout and paint, S10 replay

    @Test func layoutFitsTextInsideBoxAndStaysInsidePage() {
        let block = placedBlock(0, CGRect(x: 100, y: 100, width: 400, height: 300), "안녕 하세요")
        let placed = PipelineLayout.place([block], pageSize: CGSize(width: 1000, height: 1400))
        #expect(placed.count == 1)
        #expect(placed[0].fontPixels == 40)  // outside a balloon the cap is the source size
        #expect(CGRect(x: 80, y: 80, width: 440, height: 340).contains(placed[0].frame))
        #expect(placed[0].lines.joined(separator: " ") == "안녕 하세요")
        // The frame holds the painted ink: line advances between lines, one 0.94 em ink height for the last.
        let ink = (CGFloat(placed[0].lines.count - 1) * 1.18 + 0.94) * 40
        #expect(abs(placed[0].frame.height - 2 * PipelineLayout.strokeWidth(for: block, fontPixels: 40) - ink) < 0.01)
        let page = CGSize(width: 300, height: 300)
        let long = String(repeating: "아주 긴 번역 문장입니다 ", count: 30)
        let edge = PipelineLayout.place([placedBlock(0, CGRect(x: 280, y: 280, width: 15, height: 15), long)], pageSize: page)
        #expect(edge.count == 1 && CGRect(origin: .zero, size: page).contains(edge[0].frame))
    }

    private func verticalBlock(_ bounds: CGRect, _ text: String, balloon: CGRect? = nil) -> PipelineBlock {
        var block = placedBlock(0, bounds, text)
        block.vertical = true
        block.balloon = balloon
        return block
    }

    @Test func layoutKeepsPunctuationWithItsWord() {
        let closing = PipelineLayout.MeasuredText.closing, opening = PipelineLayout.MeasuredText.opening
        for width: CGFloat in [70, 120, 200, 320] {
            let block = placedBlock(0, CGRect(x: 100, y: 100, width: width, height: 900), "「앗! 싫어, 하지 마세요…… 아윽!」")
            let placed = PipelineLayout.place([block], pageSize: CGSize(width: 1000, height: 1400))
            let lines = placed[0].lines
            #expect(lines.dropFirst().allSatisfy { !($0.first.map(closing.contains) ?? false) }, "\(width): \(lines)")
            #expect(lines.dropLast().allSatisfy { !($0.last.map(opening.contains) ?? false) }, "\(width): \(lines)")
        }
        // A space-separated run of marks joins its neighbour instead of standing alone.
        #expect(PipelineLayout.MeasuredText.glued(["그래", "……", "「", "가자"]) == ["그래 ……", "「 가자"])
    }

    @Test func layoutPrefersWholeWordsWhenTheSizeCostIsSmall() {
        // At the 48 px cap "말하지" would be split; a slightly smaller size keeps every word whole.
        let placed = PipelineLayout.place([placedBlock(0, CGRect(x: 100, y: 100, width: 130, height: 400), "말하지 마 바보")],
                                    pageSize: CGSize(width: 1000, height: 1400))
        #expect(placed[0].lines.allSatisfy { ["말하지", "마", "바보", "마 바보"].contains($0) }, "\(placed[0].lines)")
    }

    @Test func stackedVerticalSourceSwitchesToColumns() {
        let page = CGSize(width: 1000, height: 1400)
        let narrow = PipelineLayout.place([verticalBlock(CGRect(x: 100, y: 100, width: 60, height: 600), "「날뛰지 마! 뭐야」")],
                                    pageSize: page)
        #expect(narrow[0].vertical)
        #expect(narrow[0].frame.width <= 64 && narrow[0].frame.height <= 604)
        // A wide box keeps horizontal Korean.
        let wide = PipelineLayout.place([verticalBlock(CGRect(x: 100, y: 100, width: 300, height: 600), "「날뛰지 마! 뭐야」")],
                                  pageSize: page)
        #expect(!wide[0].vertical)
        #expect(PipelinePainter.verticalForms("「아...…」") == "﹁아︙︙﹂")
    }

    @Test func displayTextDropsProviderLineMarkup() {
        #expect(PipelineLayout.displayText("안 돼...っ<br>더 이상은") == "안 돼... 더 이상은")
        #expect(PipelineLayout.displayText("저 유두…!|탱글탱글해서") == "저 유두…! 탱글탱글해서")
        #expect(PipelineLayout.displayText("알고 있다니까!\u{200B}\u{200B} 그보다") == "알고 있다니까! 그보다")
        #expect(PipelineLayout.displayText("두근  두근\n  둘째 줄") == "두근 두근\n둘째 줄")
        #expect(PipelineLayout.displayText("검사 중에/숨기고\u{2800}있잖아") == "검사 중에 숨기고 있잖아")
        #expect(PipelineLayout.displayText("1/2 남았어") == "1/2 남았어")
        // Real kana and non-Hangul text are left alone.
        #expect(PipelineLayout.displayText("メイド喫茶っ") == "メイド喫茶っ")
        #expect(PipelineLayout.displayText("a|b") == "a|b")
        #expect(PipelineLayout.displayText("plain text") == "plain text")
    }

    @Test func interiorGrowsByLegacyReachAndSkipsBackground() {
        // 300x300 gray raster (page 1200x1200): white page, a black 4-cell outline box
        // around x 100...200, y 60...240, a striped text column at x 140...160 inside it.
        // Legacy exterior growth: other text, balloons, frames and the 8 x 4 line reach bound it;
        // past 3 x the source area an inked strip (the outline rows) stops it too.
        let size = 300
        var pixels = [UInt8](repeating: 255, count: size * size)
        func fill(_ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int, _ value: UInt8) {
            for y in y0..<y1 { for x in x0..<x1 { pixels[y * size + x] = value } }
        }
        fill(96, 56, 204, 60, 0); fill(96, 240, 204, 244, 0); fill(96, 56, 100, 244, 0); fill(200, 56, 204, 244, 0)
        for y in stride(from: 100, to: 200, by: 6) { fill(142, y, 158, y + 2, 0) }
        let raster = PipelineGrayRaster(pixels: pixels, width: size, height: size)
        let bounds = CGRect(x: 560, y: 400, width: 80, height: 400)
        let line = PipelineLine(polygon: rect(560, 400, 80, 400), bounds: bounds, vertical: true, detectionScore: 1)
        let block = PipelineBlock(id: 0, lines: [line], bounds: bounds, polygon: [], vertical: true, readingOrder: 0,
                            sourceText: "あいうえお")
        let interior = PipelineInterior.ruleApply([block], raster: raster, pageSize: CGSize(width: 1200, height: 1200))[0].balloon
        #expect(interior.map { $0.width > bounds.width * 1.5 } == true)
        #expect(interior.map { CGRect(x: 0, y: 236, width: 1200, height: 728).contains($0) } == true)
        // Tone (mid-gray paper) still grows but gets no row spans; background blocks are skipped.
        let gray = PipelineGrayRaster(pixels: [UInt8](repeating: 128, count: size * size), width: size, height: size)
        let toned = PipelineInterior.ruleApply([block], raster: gray, pageSize: CGSize(width: 1200, height: 1200))[0]
        #expect(toned.balloon != nil && toned.rows == nil)
        var background = block
        background.role = .background
        #expect(PipelineInterior.ruleApply([background], raster: raster, pageSize: CGSize(width: 1200, height: 1200))[0].balloon == nil)
        #expect(PipelineInterior.apply([background], raster: raster, pageSize: CGSize(width: 1200, height: 1200))[0].balloon == nil)
    }

    /// 300x300 raster (page 1200x1200): white, a 4-cell black ring around x 100...200, y 60...240, and a
    /// striped text column at x 140...160; the block is that column.
    private func ringPage() -> (PipelineGrayRaster, PipelineBlock) {
        let size = 300
        var pixels = [UInt8](repeating: 255, count: size * size)
        func fill(_ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int, _ value: UInt8) {
            for y in y0..<y1 { for x in x0..<x1 { pixels[y * size + x] = value } }
        }
        fill(96, 56, 204, 60, 0); fill(96, 240, 204, 244, 0); fill(96, 56, 100, 244, 0); fill(200, 56, 204, 244, 0)
        for y in stride(from: 100, to: 200, by: 6) { fill(142, y, 158, y + 2, 0) }
        let bounds = CGRect(x: 560, y: 400, width: 80, height: 400)
        let line = PipelineLine(polygon: rect(560, 400, 80, 400), bounds: bounds, vertical: true, detectionScore: 1)
        return (PipelineGrayRaster(pixels: pixels, width: size, height: size),
                PipelineBlock(id: 0, lines: [line], bounds: bounds, polygon: [], vertical: true, readingOrder: 0, sourceText: "あいうえお"))
    }

    @Test func interiorComponentFindsTheEnclosedBalloon() {
        let (raster, block) = ringPage()
        let grid = PipelineLearnedInterior.Grid(raster: raster, sx: 0.25, sy: 0.25)
        let text = [grid.cells(block.bounds)]
        let (paper, toned) = PipelineLearnedInterior.paper(grid, text[0]!)
        #expect(paper > 200 && !toned)
        // Line thickness 20 cells: the 14-line window covers the page; the ring encloses the paper.
        let pass = PipelineLearnedInterior.component(0, blocks: [block], text: text, grid: grid, em: 20, paper: paper,
                                                     toned: false, panel: nil)
        #expect(pass?.path == .enclosed)
        #expect(pass.map { $0.box == (100, 60, 200, 240) } == true)
        #expect(pass.map { PipelineLearnedInterior.rows($0.mask, box: (140, 100, 160, 200), grid: grid) != nil } == true)
        // Without the ring the paper reaches the window: clipped to the text box +- 3 lines (no RF balloon).
        let white = PipelineGrayRaster(pixels: [UInt8](repeating: 255, count: 300 * 300), width: 300, height: 300)
        let open = PipelineLearnedInterior.component(0, blocks: [block], text: text, grid: PipelineLearnedInterior.Grid(raster: white, sx: 0.25, sy: 0.25),
                                                     em: 20, paper: 255, toned: false, panel: nil)
        #expect(open?.path == .open)
        #expect(open.map { $0.box == (80, 40, 220, 260) } == true)
    }

    @Test func interiorMaskHelpers() {
        // 6x5 mask: a 4x3 block with a hole, and a stray cell.
        var mask = PipelineLearnedInterior.Mask(x0: 10, y0: 20, width: 6, height: 5, on: [Bool](repeating: false, count: 30))
        for y in 1..<4 { for x in 1..<5 { mask.on[y * 6 + x] = true } }
        mask.on[2 * 6 + 2] = false
        mask.on[0 * 6 + 5] = true
        let bounds = PipelineLearnedInterior.extent(mask, within: (0, 0, 6, 5))
        #expect(bounds.map { $0 == (1, 0, 6, 4) } == true)
        PipelineLearnedInterior.fillHoles(&mask, bounds!)
        #expect(mask.on[2 * 6 + 2])
        #expect(PipelineLearnedInterior.maxRect(mask, bounds!) == (1, 1, 5, 4))
        // A second text box splits the mask by nearest box.
        var shared = PipelineLearnedInterior.Mask(x0: 0, y0: 0, width: 10, height: 2, on: [Bool](repeating: true, count: 20))
        PipelineLearnedInterior.share(&shared, (0, 0, 10, 2), index: 0, text: [(0, 0, 2, 2), (8, 0, 10, 2)], s0: (0, 0, 2, 2))
        #expect(shared.on[4] && !shared.on[6])
    }

    @Test func interiorModelBoxAndGate() {
        let (raster, block) = ringPage()
        let leaf = { (value: Double) in PipelineInteriorModel.Forest(trees: [.init(f: [0], t: [0], l: [-1], r: [-1], v: [value])]) }
        // Gate open, every side one line out: the text cells +- 20.
        let model = PipelineInteriorModel(threshold: 0.5, joint: leaf(1), gate: leaf(10))
        let page = CGSize(width: 1200, height: 1200)
        let out = PipelineInterior.apply([block], raster: raster, pageSize: page, model: model)[0]
        #expect(out.balloon == CGRect(x: 480, y: 320, width: 240, height: 560))
        // Gate closed: the rule box.
        let closed = PipelineInteriorModel(threshold: 0.5, joint: leaf(1), gate: leaf(-10))
        #expect(PipelineInterior.apply([block], raster: raster, pageSize: page, model: closed)[0].balloon
                == PipelineInterior.ruleApply([block], raster: raster, pageSize: page)[0].balloon)
        // A tree routes on its feature threshold; the bundled model loads.
        let tree = PipelineInteriorModel.Forest(trees: [.init(f: [1], t: [0.5], l: [-1], r: [-2], v: [1, 2])])
        #expect(tree.sum([0, 0.4]) == 1 && tree.sum([0, 0.6]) == 2)
        #expect(PipelineInteriorModel.shared != nil)
    }

    @Test func balloonLobeLeavesTheTailOut() {
        // Paper: a disc of radius 30 about (50, 50) with a 4-cell tail to x 110; the rest is ink.
        func dirty(_ x: Int, _ y: Int) -> Bool {
            !((x - 50) * (x - 50) + (y - 50) * (y - 50) <= 900 || (x >= 50 && x < 110 && y >= 48 && y < 52))
        }
        let lobe = PipelineInterior.lobeRect((0, 0, 130, 100), source: (40, 40, 60, 60), dirty: dirty)
        #expect(lobe.map { $0.x0 >= 19 && $0.x1 <= 81 && $0.y0 >= 19 && $0.y1 <= 81 && $0.x1 - $0.x0 >= 30 } == true)
        // Paper reaching the growth limit is open lettering space, not a balloon.
        #expect(PipelineInterior.lobeRect((30, 30, 70, 70), source: (40, 40, 60, 60), dirty: dirty) == nil)
    }

    private func styled(_ px: CGFloat, fill: PipelineRGB = PipelineRGB(r: 0, g: 0, b: 0), stroke: PipelineRGB? = PipelineRGB(r: 255, g: 255, b: 255),
                        width: CGFloat = 3) -> PipelineStyle {
        PipelineStyle(fontPixels: px, bold: false, textColor: fill, strokeColor: stroke, strokeWidth: width)
    }

    @Test func outlineWidthTakesTheMostProbableCandidateNearestTheCentre() throws {
        typealias M = PipelineOutlineWidthModel
        // Candidates 2, 4, 6: 4 and 6 tie on the hit model (split on the candidate, feature 2); the centre breaks it.
        let hit = [M.Tree(f: [2, 2], t: [3, 5], l: [-1, -2], r: [1, -3], v: [-2, 2, 2])]
        let centre = { (value: Double) in [M.Tree(f: [0], t: [1e300], l: [-1], r: [-1], v: [value])] }
        #expect(M(grid: [2, 4, 6], tie: 0.02, hit: hit, centre: centre(5.9)).width(ring: 5, font: 40, line: 4) == 6)
        #expect(M(grid: [2, 4, 6], tie: 0.02, hit: hit, centre: centre(4.2)).width(ring: 5, font: 40, line: 4) == 4)
        // Without a model the ring line stays.
        let line = PipelineStyleParameters.outlineWidthRing * 6 + PipelineStyleParameters.outlineWidthFont * 50
            + PipelineStyleParameters.outlineWidthBias
        #expect(abs(PipelineStyleEstimator.outlineWidth(ring: 6, font: 50, model: nil) - line) < 1e-12)
        // The shipped model (TRAIN fit) against its Python reference (`tools/retrain/outline/train.py` width()).
        let model = try #require(M.shared)
        #expect(model.grid.count == 23 && model.hit.count == 150 && model.centre.count == 50)
        for (ring, font, width) in [(0.0, 30.0, 2.0), (3, 40, 4.5), (6, 50, 5), (8, 60, 7), (12, 80, 8), (20, 120, 8)] {
            #expect(PipelineStyleEstimator.outlineWidth(ring: ring, font: font) == width)
        }
    }

    @Test func fillPeakRankerMovesPastTheBlendAwayFromTheOutline() throws {
        // A blue pick blended with a white outline, and a darker blue peak further along the outline -> pick axis.
        var f = PipelineStyleFeatures(font: 40)
        var cluster = PipelineStyleFeatures.Cluster()
        cluster.count = 100; cluster.coreCount = 50; cluster.inLines = 0.3; cluster.strokeWidth = 4; cluster.core = [110, 110, 170]
        f.clusters = [cluster]
        f.modes = [.init(rgb: [255, 255, 255], share: 0.3), .init(rgb: [60, 60, 140], share: 0.2)]
        let white: [Double] = [255, 255, 255]
        let options = PipelineStyleEstimator.peakFeatures(f, pick: cluster.core, pickLogit: 1, outline: white)
        let axis = PipelineStyleEstimator.axisFeatures(f, fill: 0, colours: options.colours, outline: white)
        #expect(abs(axis[0][0] - 1) < 1e-6 && axis[0][1] < 1e-6)
        #expect(abs(axis[1][0]) < 1e-6)
        #expect(axis[2][0] > 1 && axis[2][6] == 0.1 && axis[2][8] == 0.5 && axis[2][9] == 1)
        // A stub ranker that prefers t > 1.05 (feature 16) moves to the darker peak; without a ranker the pick stays.
        typealias T = PipelineOutlineWidthModel.Tree
        let stub = PipelineFillPeakRanker(features: 26, trees: [T(f: [16], t: [1.05], l: [-1], r: [-2], v: [0, 1])])
        #expect(PipelineStyleEstimator.peakChoice(f, fill: 0, pickLogit: 1, outline: white, ranker: stub) == [60, 60, 140])
        #expect(PipelineStyleEstimator.peakChoice(f, fill: 0, pickLogit: 1, outline: white, ranker: nil) == nil)
        // The shipped ranker (TRAIN fit): option vectors (pick, then a peak) with their scores from the LightGBM fit.
        let ranker = try #require(PipelineFillPeakRanker.shared)
        #expect(ranker.trees.count == 300 && ranker.features == PipelineFillPeakRanker.featureCount)
        let fixtures: [([Double], Double)] = [
            ([1, 0, -1, 0, 96.8961, 98.9366, 0.3922, 0.9848, 0, 0, 96.8961, 98.9366, 1.1097, 0.648, 2, 0, 1, 0, 98.9366, 98.9203, 0, -1.7656, 0.079,
             0.1846, 0.3738, 0.8027], 5.002126962612887),
            ([0, 0.6343, 0, 98.577, 2.2491, 0.6304, 98.9425, 3.2281, 98.5503, 2.2433, 96.8961, 98.9366, 1.1097, 0.648, 2, -94.647, 0.0036, 0.5168,
             98.9366, 0.37, 98.5503, 0.4777, 0.079, 0.1846, 0.3738, 0.8027], -10.49954961876545),
            ([1, 0, -1, 0, 96.478, 98.4576, 0.7048, 1.2446, 0, 0, 96.478, 98.4576, 2.5338, 0.5042, 4, 0, 1, 0, 98.4576, 98.4571, 0, -0.3125, 0.0749,
             0.1761, 0.3237, 0.9708], 6.287208883754404),
            ([0, 0.5618, 0, 98.1119, 1.7469, 0.3457, 98.8162, 1.5583, 98.1114, 0.3137, 96.478, 98.4576, 2.5338, 0.5042, 4, -94.7311, 0.0035, 0.0023,
             98.4576, 0.3457, 98.1114, 0.0012, 0.0749, 0.1761, 0.3237, 0.9708], -11.264573289423746),
            ([1, 0, -1, 0, 71.7949, 99.9421, 100, 0.0117, 0, 0, 71.7949, 99.9421, 3.1088, 0.4579, 5, 0, 1, 0, 99.9421, 99.9417, 0, -0.2656, 0.0893,
             0.1744, 0.3912, 1], 5.617907918305052),
            ([0, 0.2586, 0, 99.7258, 30.2586, 0.3514, 0.2742, 0.0001, -99.7258, -0.0116, 71.7949, 99.9421, 3.1088, 0.4579, 5, -41.5363, 0.0022,
             0.2767, 99.9421, 0.2159, -99.7258, -0.2772, 0.0893, 0.1744, 0.3912, 1], -8.945545499428905),
        ]
        for (x, score) in fixtures {
            #expect(abs(ranker.score(x) - score) < 1e-9)
        }
    }

    @Test func pageStylesUnifyWithinTheDistance() {
        let indigo = PipelineRGB(r: 72, g: 70, b: 126), drift = PipelineRGB(r: 78, g: 78, b: 118), black = PipelineRGB(r: 2, g: 2, b: 2)
        let styles = [
            styled(30, fill: indigo, width: 3), styled(30, fill: indigo, width: 3), styled(60, fill: drift, width: 9),
            styled(30, fill: black, stroke: nil, width: 0), styled(30, fill: black, width: 3),
        ]
        let unified = PipelineStyleConsistency.unify(styles)
        // The drifted fill joins the indigo group and takes its medoid colour and width per px.
        #expect(unified[2].textColor == indigo)
        #expect(unified[2].strokeWidth == 6)
        #expect(unified[0].textColor == indigo && unified[1].textColor == indigo)
        // Black is far from indigo; an outline mismatch keeps the two black blocks apart.
        #expect(unified[3].textColor == black && unified[3].strokeColor == nil)
        #expect(unified[4].strokeColor != nil)
        #expect(PipelineStyleConsistency.unify([styles[0]]) == [styles[0]])
        // Short text (SFX, ruby) neither joins nor moves.
        let gated = PipelineStyleConsistency.unify(styles, characters: [5, 5, 2, 5, 5])
        #expect(gated[2] == styles[2])
        #expect(gated[0].textColor == indigo)
        // Complete linkage: a chain of close colours whose ends are more than 15 apart does not merge whole.
        let ends = [PipelineRGB(r: 72, g: 70, b: 126), PipelineRGB(r: 84, g: 80, b: 126), PipelineRGB(r: 96, g: 90, b: 126)]
        let chain = PipelineStyleConsistency.unify(ends.map { styled(30, fill: $0) })
        #expect(chain[0].textColor == ends[0] && chain[1].textColor == chain[2].textColor)
    }

    @Test func densityPeaksFindThinInkBesideItsOutline() {
        // 60% ink, 25% white outline, 15% blend: the ink is its own peak; the blend is not.
        let ink: [UInt8] = [71, 71, 133], white: [UInt8] = [255, 255, 255], blend: [UInt8] = [163, 163, 194]
        let pixels = (0..<400).flatMap { i in i % 20 < 12 ? ink : i % 20 < 17 ? white : blend }
        let crop = PipelineStyleEstimator.Crop(width: 20, height: 20, rgb: pixels, lines: [Bool](repeating: true, count: 400))
        let peaks = PipelineStyleEstimator.densityPeaks(crop)
        #expect(peaks.first.map { $0.rgb == [71, 71, 133] && abs($0.share - 0.6) < 1e-9 } == true)
        #expect(peaks.contains { $0.rgb == [255, 255, 255] })
        #expect(PipelineStyleEstimator.deltaE([71, 71, 133], [71, 71, 133]) == 0)
    }

    @Test func pageStylesTakeTheMajorityOutline() {
        let a = PipelineRGB(r: 10, g: 10, b: 10), b = PipelineRGB(r: 14, g: 12, b: 10)
        var styles = [styled(30, fill: a), styled(30, fill: b), styled(30, fill: a, stroke: nil, width: 0)]
        // Within 20 of each outlined member only through fill: mismatch costs 40, so no join.
        #expect(PipelineStyleConsistency.unify(styles)[2].strokeColor == nil)
        styles[2].strokeColor = PipelineRGB(r: 250, g: 250, b: 250)
        let unified = PipelineStyleConsistency.unify(styles)
        #expect(Set(unified.map { $0.textColor.r }).count == 1)
        #expect(unified.allSatisfy { $0.strokeColor != nil })
    }

    @Test func cohortsSnapSourcesAndShareOneSize() {
        func block(_ id: Int, _ px: CGFloat) -> PipelineBlock {
            var block = placedBlock(id, CGRect(x: CGFloat(id) * 200, y: 0, width: 100, height: 100), "가")
            // Colour is not part of the key (legacy families mix colours).
            block.style = styled(px, fill: id == 1 ? PipelineRGB(r: 220, g: 30, b: 30) : PipelineRGB(r: 0, g: 0, b: 0))
            return block
        }
        var plain = block(4, 43)
        plain.style?.strokeColor = nil                       // outline is not part of the key
        let blocks = [block(0, 40), block(1, 41), block(2, 47), block(3, 80), plain]
        let plan = PipelineCohort.plan(blocks, sources: [40, 41, 47, 80, 43], capRatio: { _ in 1.2 }, floor: 10)
        #expect(plan.sources[0] == plan.sources[1])          // snapped within 1.08x
        #expect(plan.cohorts.map { $0.sorted() } == [[0, 1, 2, 4]])  // 80 px is its own size
        #expect(plan.caps[0] == plan.caps[1] && plan.caps[0] == plan.caps[2])  // one family cap
        // The family takes the largest cap step every member reached (members below 0.65 keep theirs).
        #expect(PipelineCohort.familySize(cap: 50, fits: [50, 46, 20]) == 45)
        #expect(PipelineCohort.familySize(cap: 50, fits: [20, 21]) == nil)
    }

    @Test func cohortsJoinOrientationsAndGuardVerticalMembers() {
        var tall = placedBlock(1, CGRect(x: 200, y: 0, width: 100, height: 300), "가")
        tall.vertical = true
        let blocks = [placedBlock(0, CGRect(x: 0, y: 0, width: 300, height: 100), "가"), tall]
        // One source size: vertical and horizontal text share a family.
        let plan = PipelineCohort.plan(blocks, sources: [40, 40], capRatio: { _ in 1 }, floor: 10)
        #expect(plan.cohorts.map { $0.sorted() } == [[0, 1]])
        // A horizontal fit pulls vertical members down to no less than 0.95x their smallest fit.
        #expect(PipelineCohort.lowestFit([30, 40], vertical: [false, true]) == 38)
        #expect(PipelineCohort.lowestFit([39, 40], vertical: [false, true]) == 39)
        #expect(PipelineCohort.lowestFit([30, 40], vertical: [false, false]) == 30)
        // Re-fit rounds guard against the first fits: a vertical member already at 38 is not pulled to 30.
        #expect(PipelineCohort.lowestFit([30, 38], vertical: [false, true], firstFits: [30, 40]) == 38)
        // A vertical re-fit that itself landed lower still leads.
        #expect(PipelineCohort.lowestFit([30, 35], vertical: [false, true], firstFits: [30, 40]) == 35)
        #expect(PipelineCohort.familySize(cap: 40, fits: [30, 40], vertical: [false, true]) == 38)
        #expect(PipelineCohort.familySize(cap: 40, fits: [30, 40]) == 30)
    }

    @Test func alignedStartsShareTheMedianCentredTop() {
        let sources = [CGRect(x: 0, y: 100, width: 100, height: 200), CGRect(x: 150, y: 110, width: 100, height: 100),
                       CGRect(x: 300, y: 105, width: 100, height: 300), CGRect(x: 900, y: 100, width: 100, height: 100)]
        func alignedTops(tilting tilted: Int? = nil) -> [CGFloat] {
            var placed = sources.enumerated().map { index, rect in
                PipelinePlacedText(blockID: index, frame: CGRect(x: rect.minX, y: rect.minY + CGFloat(index) * 7, width: 100, height: 60),
                                   fontPixels: 40, vertical: false, lines: ["가"], angle: index == tilted ? 0.1 : nil)
            }
            PipelineLayout.alignStarts(&placed, sources.enumerated().map { placedBlock($0.offset, $0.element, "가") },
                                       sources: [40, 40, 40, 40], page: CGRect(x: 0, y: 0, width: 1000, height: 1000))
            return placed.map(\.frame.minY)
        }
        // Median of the centred tops 170, 130 and 225; the block 12.5 em away keeps its frame.
        #expect(alignedTops() == [170, 170, 170, 121])
        // A tilted member keeps its frame; the upright rest still share one top.
        #expect(alignedTops(tilting: 1) == [197.5, 117, 197.5, 121])
    }

    @Test func rotationFollowsTiltedLineQuads() {
        func quad(_ angle: CGFloat) -> PipelineLine {
            let c = cos(angle), s = sin(angle), w: CGFloat = 200, h: CGFloat = 40
            let points = [(-w / 2, -h / 2), (w / 2, -h / 2), (w / 2, h / 2), (-w / 2, h / 2)].map {
                CGPoint(x: 300 + $0.0 * c - $0.1 * s, y: 300 + $0.0 * s + $0.1 * c)
            }
            return PipelineLine(polygon: points, bounds: CGRect(x: 180, y: 240, width: 240, height: 120), vertical: false, detectionScore: 1)
        }
        func block(_ lines: [PipelineLine]) -> PipelineBlock {
            PipelineBlock(id: 0, lines: lines, bounds: CGRect(x: 180, y: 240, width: 240, height: 120), polygon: [], vertical: false,
                    readingOrder: 0, sourceText: "")
        }
        #expect(abs(PipelineRotation.angle(block([quad(0.2), quad(0.21)])) - 0.205) < 0.01)
        #expect(PipelineRotation.angle(block([quad(0.03)])) == 0)   // under 2.5 degrees: upright
        #expect(PipelineRotation.angle(block([quad(0.2), quad(-0.2)])) == 0)   // no consensus
        let tilted = PipelineRotation.bounds(CGRect(x: 0, y: 0, width: 100, height: 20), angle: .pi / 6)
        #expect(abs(tilted.width - (100 * cos(.pi / 6) + 20 * sin(.pi / 6))) < 0.01)
        #expect(abs(tilted.height - (100 * sin(.pi / 6) + 20 * cos(.pi / 6))) < 0.01)
        #expect(PipelineRotation.inscribed(CGSize(width: 20, height: 400), angle: .pi / 6) == nil)
    }

    @Test func painterAddsAHaloOnlyWhenTextWouldVanish() {
        var block = placedBlock(0, CGRect(x: 0, y: 0, width: 100, height: 100), "가")
        block.style = styled(40, fill: PipelineRGB(r: 20, g: 20, b: 20), stroke: nil, width: 0)
        let dark = PipelinePainter.legible(block: block, fontPixels: 40, background: PipelineRGB(r: 30, g: 30, b: 30))
        #expect(dark.stroke != nil && dark.strokeWidth > 0)
        #expect(dark.stroke?.components?.first == 1)       // white halo on dark text and background
        let light = PipelinePainter.legible(block: block, fontPixels: 40, background: PipelineRGB(r: 250, g: 250, b: 250))
        #expect(light.stroke == nil)
        // Orange text with a white source outline on skin tone (page 0002): the outline barely stands out from
        // the background (1.47) but separates the text (3.57), so the source outline stays instead of a black halo.
        block.style = styled(50, fill: PipelineRGB(r: 222, g: 96, b: 68), stroke: PipelineRGB(r: 254, g: 255, b: 252), width: 5.3)
        let skin = PipelinePainter.legible(block: block, fontPixels: 50, background: PipelineRGB(r: 237, g: 208, b: 178))
        #expect(skin.stroke?.components?.first ?? 0 > 0.9 && skin.strokeWidth > 4)
        // A source outline too close to its own fill does not count: a halo is added.
        block.style = styled(50, fill: PipelineRGB(r: 222, g: 96, b: 68), stroke: PipelineRGB(r: 200, g: 90, b: 60), width: 5)
        let weak = PipelinePainter.legible(block: block, fontPixels: 50, background: PipelineRGB(r: 237, g: 208, b: 178))
        #expect(weak.stroke?.components?.first == 0)
    }

    @Test func layoutKeepsKoreanPhrasesAndSitsOverTheSource() {
        // "할 수" must not break between 할 and the dependent noun 수 when the pair fits a line.
        let text = PipelineLayout.MeasuredText("그건 할 수 있어", font: PipelineLayout.font(size: PipelineLayout.referenceSize))
        let probe = text.wrap(limits: { _ in text.paragraphs[0][0].width + text.spaceWidth + text.paragraphs[0][1].width + 1 })
        #expect(!probe.lines.contains { $0.hasPrefix("수") }, "\(probe.lines)")
        #expect(PipelineLayout.MeasuredText.couples("할", "수") && PipelineLayout.MeasuredText.couples("몇", "번"))
        // Compaction counts lone graphemes and split phrases when it picks among wraps.
        #expect(PipelineLayout.badBreaks(["있을", "수", "있어"]) == 2 && PipelineLayout.badBreaks(["있을 수", "있어"]) == 0)
        // A grown box keeps the text centred on its source, not on the box.
        var block = placedBlock(0, CGRect(x: 500, y: 200, width: 80, height: 60), "안녕")
        block.balloon = CGRect(x: 100, y: 100, width: 800, height: 300)
        let placed = PipelineLayout.place([block], pageSize: CGSize(width: 1000, height: 1000))
        #expect(abs(placed[0].frame.midX - 540) < 1 && abs(placed[0].frame.midY - 230) < 1, "\(placed[0].frame)")
    }

    @Test func rowSpansWidenTheMiddleLinesOfARoundBalloon() {
        // A diamond-like balloon: rows are widest at the centre (half-width 150 px there).
        let halves = (0..<60).map { CGFloat(150 - abs($0 - 30) * 4) }
        let rows = PipelineRowSpans(top: 100, step: 5, centre: 500, halfWidths: halves)
        #expect(rows.halfWidth(240, 260) == 142 && rows.halfWidth(90, 110) == 0)   // rows 28...31
        let text = PipelineLayout.MeasuredText("가나다라 마바사 아자차카 타파하 가나다 라마바사", font: PipelineLayout.font(size: PipelineLayout.referenceSize))
        let found = PipelineLayout.spanFit(text, size: 30, rows: rows, centreY: 250, stroke: 0, whole: true)
        #expect(found != nil)
        if let found {
            #expect(found.fit.lines.count >= 2)
            #expect(found.top >= rows.top && found.top + found.fit.extent.height <= rows.bottom)
            // The widest line lies within the widest span.
            #expect(found.fit.extent.width <= 2 * 150 + 0.5)
        }
        // Too big for the spans: no fit.
        #expect(PipelineLayout.spanFit(text, size: 200, rows: rows, centreY: 250, stroke: 0, whole: true) == nil)
    }

    @Test func lowConfidenceFragmentsOutsideBalloonsKeepTheirSource() {
        func block(_ text: String, confidence: Float, balloon: CGRect? = nil) -> PipelineBlock {
            let line = PipelineLine(polygon: rect(0, 0, 40, 40), bounds: CGRect(x: 0, y: 0, width: 40, height: 40), vertical: true,
                              detectionScore: 1, text: text, confidence: confidence)
            return PipelineBlock(id: 0, lines: [line], bounds: line.bounds, polygon: [], vertical: true, readingOrder: 0,
                           sourceText: text, balloon: balloon)
        }
        #expect(PipelineRoleFilter.isFragment(block("6", confidence: 0.4)))
        #expect(!PipelineRoleFilter.isFragment(block("6", confidence: 0.8)))
        #expect(!PipelineRoleFilter.isFragment(block("ン", confidence: 0.4, balloon: CGRect(x: 0, y: 0, width: 80, height: 80))))
        #expect(!PipelineRoleFilter.isFragment(block("なにこれ本当", confidence: 0.4)))
        #expect(PipelineRoleFilter.classify([block("6", confidence: 0.4)], layout: [])[0].role == .background)
    }

    @Test func shortLatinAndKanaFragmentsOutsideBalloonsKeepTheirSource() {
        func block(_ text: String, confidence: Float, balloon: CGRect? = nil) -> PipelineBlock {
            let line = PipelineLine(polygon: rect(0, 0, 40, 40), bounds: CGRect(x: 0, y: 0, width: 40, height: 40), vertical: true,
                              detectionScore: 1, text: text, confidence: confidence)
            return PipelineBlock(id: 0, lines: [line], bounds: line.bounds, polygon: [], vertical: true, readingOrder: 0,
                           sourceText: text, balloon: balloon)
        }
        let inBalloon = CGRect(x: 0, y: 0, width: 80, height: 80)
        // Latin-only: below 0.9 mean confidence, outside balloons, at most four characters.
        #expect(PipelineRoleFilter.isFragment(block("ABC", confidence: 0.85)))
        #expect(!PipelineRoleFilter.isFragment(block("ABC", confidence: 0.95)))
        #expect(!PipelineRoleFilter.isFragment(block("ABC", confidence: 0.85, balloon: inBalloon)))
        #expect(!PipelineRoleFilter.isFragment(block("ABCDE", confidence: 0.85)))
        // Kana-only, no kanji or punctuation, without RF text or balloon evidence.
        #expect(PipelineRoleFilter.isFragment(block("ドド", confidence: 0.99)))
        #expect(!PipelineRoleFilter.isFragment(block("ドド!", confidence: 0.99)))
        #expect(!PipelineRoleFilter.isFragment(block("ドー", confidence: 0.99)))
        #expect(!PipelineRoleFilter.isFragment(block("本ド", confidence: 0.99)))
        let text = PipelineLayoutRegion(kind: .text, bounds: CGRect(x: 0, y: 0, width: 40, height: 40), score: 0.9)
        #expect(!PipelineRoleFilter.isFragment(block("ドド", confidence: 0.99), layout: [text]))
        #expect(PipelineRoleFilter.classify([block("ドド", confidence: 0.99)], layout: [])[0].role == .background)
        #expect(PipelineRoleFilter.classify([block("ドド", confidence: 0.99)], layout: [text])[0].role != .background)
    }

    @Test func shortSFXInsideAnRFBalloonIsSpeech() {
        var block = placedBlock(0, CGRect(x: 100, y: 100, width: 40, height: 80), "あっ")
        block.sourceText = "あっ"
        block.role = .sfx
        let balloon = PipelineLayoutRegion(kind: .balloon, bounds: CGRect(x: 80, y: 80, width: 120, height: 160), score: 0.9)
        let sfx = PipelineLayoutRegion(kind: .sfx, bounds: CGRect(x: 90, y: 90, width: 80, height: 120), score: 0.9)
        #expect(PipelineRoleFilter.keepsSource(block))
        #expect(PipelineRoleFilter.rescuingSpeech([block], layout: [balloon])[0].role == .dialogue)
        // RF also sees an SFX region there, or no balloon at all: the LLM's SFX stands.
        #expect(PipelineRoleFilter.rescuingSpeech([block], layout: [balloon, sfx])[0].role == .sfx)
        #expect(PipelineRoleFilter.rescuingSpeech([block], layout: [])[0].role == .sfx)
    }

    @Test func uprightShortSFXOrBackgroundInsideItsBalloonUnderRFTextIsSpeech() {
        let bounds = CGRect(x: 100, y: 100, width: 40, height: 80)
        func block(_ role: PipelineRole, polygon: [CGPoint]) -> PipelineBlock {
            var block = placedBlock(0, bounds, "아")
            block.sourceText = "あっ"
            block.role = role
            block.balloon = CGRect(x: 80, y: 80, width: 120, height: 160)
            block.lines = [PipelineLine(polygon: polygon, bounds: bounds, vertical: true, detectionScore: 1, text: "あっ", confidence: 1)]
            return block
        }
        let upright = rect(100, 100, 40, 80)
        let tilted = [CGPoint(x: 100, y: 100), CGPoint(x: 140, y: 104), CGPoint(x: 136, y: 184), CGPoint(x: 96, y: 180)]
        let text = PipelineLayoutRegion(kind: .text, bounds: CGRect(x: 90, y: 90, width: 60, height: 100), score: 0.6)
        let sfx = PipelineLayoutRegion(kind: .sfx, bounds: CGRect(x: 90, y: 90, width: 60, height: 100), score: 0.5)
        #expect(PipelineRoleFilter.tilt(upright) == 0)
        #expect(PipelineRoleFilter.tilt(tilted) > 5)
        #expect(PipelineRoleFilter.rescuingSpeech([block(.sfx, polygon: upright)], layout: [text])[0].role == .dialogue)
        #expect(PipelineRoleFilter.rescuingSpeech([block(.background, polygon: upright)], layout: [text])[0].role == .dialogue)
        // Tilted lines, an SFX region, no RF text or no S4 balloon: the LLM's role stands.
        #expect(PipelineRoleFilter.rescuingSpeech([block(.sfx, polygon: tilted)], layout: [text])[0].role == .sfx)
        #expect(PipelineRoleFilter.rescuingSpeech([block(.sfx, polygon: upright)], layout: [text, sfx])[0].role == .sfx)
        #expect(PipelineRoleFilter.rescuingSpeech([block(.background, polygon: upright)], layout: [])[0].role == .background)
        var free = block(.background, polygon: upright)
        free.balloon = nil
        #expect(PipelineRoleFilter.rescuingSpeech([free], layout: [text])[0].role == .background)
        var untranslated = block(.sfx, polygon: upright)
        untranslated.translation = nil
        #expect(PipelineRoleFilter.rescuingSpeech([untranslated], layout: [text])[0].role == .sfx)
    }

    @Test func shortLatinTextIsPaintedOnlyWhenTheLLMCallsItSpeech() {
        var block = placedBlock(0, CGRect(x: 0, y: 0, width: 80, height: 40), "안 돼!")
        block.sourceText = "NO!"
        block.role = .sfx
        #expect(PipelineRoleFilter.keepsSource(block))
        block.role = .dialogue
        #expect(!PipelineRoleFilter.keepsSource(block))
        block.role = .narration
        #expect(!PipelineRoleFilter.keepsSource(block))
    }

    @Test func providerErrorsAndSourceCopiesKeepTheSource() {
        let block = PipelineBlock(id: 3, lines: [], bounds: .zero, polygon: [], vertical: true, readingOrder: 0, sourceText: "SALE")
        let error = PipelineTranslation.apply([block]) { _ in RemoteTranslatedSegment(id: "x", text: "x", textRole: .error) }
        #expect(error[0].role == .background)
        let copy = PipelineTranslation.apply([block]) { _ in RemoteTranslatedSegment(id: "x", text: "SA LE") }
        #expect(copy[0].translation == nil)
        var marks = block
        marks.sourceText = "……!"
        #expect(PipelineTranslation.apply([marks]) { _ in RemoteTranslatedSegment(id: "x", text: "……!") }[0].translation == "……!")
        #expect(PipelineLayout.displayText("아ー 좋아") == "아~ 좋아")
    }

    @Test func legacyReplyRepairsApply() {
        var block = PipelineBlock(id: 4, lines: [], bounds: .zero, polygon: [], vertical: true, readingOrder: 0,
            sourceText: "このびちゃびちゃの下着は貰うぞ、絶対にね")
        func reply(_ text: String) -> String? {
            PipelineTranslation.apply([block]) { _ in RemoteTranslatedSegment(id: "x", text: text) }[0].translation
        }
        #expect(reply("このびちゃびちゃの下着は貰うぞ！絶対にね！") == nil)
        #expect(reply("좋아, このびちゃびちゃの下着は貰うぞ") == "좋아, このびちゃびちゃの下着は貰うぞ")
        #expect(reply("코드\\n입니다 \\uae68") == "코드\n입니다 깨")
        #expect(reply("서울 漢字 공부를 했어!") == "서울 漢字 공부를 했어!")
        block.sourceText = "原文"
        #expect(reply("오늘은 漢字") == "오늘은 漢字")
    }

    @Test func narrationRoleIsKeptAndPainted() {
        let block = PipelineBlock(id: 0, lines: [], bounds: .zero, polygon: [], vertical: false, readingOrder: 0, sourceText: "説明")
        let narration = PipelineTranslation.apply([block]) { _ in RemoteTranslatedSegment(id: "x", text: "설명", textRole: .narration) }
        #expect(narration[0].role == .narration && PipelineLayout.isPaintable(narration[0]))
    }

    @Test func sfxAndShortLatinKeepTheirSource() {
        func painted(_ source: String, _ role: RemoteTranslationTextRole) -> Bool {
            let block = PipelineBlock(id: 0, lines: [], bounds: .zero, polygon: [], vertical: true, readingOrder: 0, sourceText: source)
            return PipelineLayout.isPaintable(PipelineTranslation.apply([block]) { _ in RemoteTranslatedSegment(id: "x", text: "번역", textRole: role) }[0])
        }
        #expect(!painted("ドキッ", .sfx))
        #expect(painted("「……ゴクリッ」", .sfx))
        #expect(painted("どちゃっ頭っまた真っ白になるっやだこれ怖いっ", .sfx))
        #expect(!painted("1098", .dialogue))
        #expect(painted("あっ", .dialogue))
        #expect(painted("…!", .dialogue))
    }

    @Test func pageRequestsUseThePageLetteringContract() {
        let block = PipelineBlock(id: 0, lines: [], bounds: CGRect(x: 10, y: 10, width: 50, height: 50), polygon: [], vertical: true,
                            readingOrder: 0, sourceText: "こんにちは")
        let size = CGSize(width: 100, height: 100)
        let withImage = PipelineTranslation.requests(for: [block], pageSize: size, sourceLanguage: "ja", targetLanguage: "ko",
                                               imageJPEG: Data([0xFF, 0xD8, 0xFF]))
        #expect(withImage.first?.translatesPageLettering == true)
        let withoutImage = PipelineTranslation.requests(for: [block], pageSize: size, sourceLanguage: "ja", targetLanguage: "ko",
                                                  imageJPEG: nil)
        #expect(withoutImage.first?.translatesPageLettering == nil)
    }

    @Test func emergencySplitsAvoidLatinWordsAndNumbersAndCondenseFirst() {
        let characters = Array("Chulsoo").map(String.init)
        #expect(PipelineLayout.MeasuredText.adjustedSplit(characters, start: 0, end: 3) != 3)
        #expect(PipelineLayout.MeasuredText.joinsLatinOrNumber("1", ",") && !PipelineLayout.MeasuredText.joinsLatinOrNumber("가", "나"))
        // A word just too wide for the box is narrowed (0.9) rather than split.
        let text = PipelineLayout.MeasuredText("가나다라마", font: PipelineLayout.font(size: PipelineLayout.referenceSize))
        let narrow = text.condensed(by: 0.9)
        #expect(abs(narrow.widestWord - text.widestWord * 0.9) < 0.001 && narrow.scale == 0.9)
        #expect(ReaderTranslationPipelineService.renderOnlyFailure("s7: x; s9: 1 erased block(s) not placed"))
        #expect(!ReaderTranslationPipelineService.renderOnlyFailure("s5: timeout"))
    }

    @Test func paintKeepsPageSizeAndInkInsideFrames() throws {
        let size = 400
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let background = try #require(context.makeImage())
        let blocks = [placedBlock(0, CGRect(x: 40, y: 40, width: 200, height: 120), "번역 테스트")]
        let placed = PipelineLayout.place(blocks, pageSize: CGSize(width: size, height: size))
        let output = PipelinePainter.paint(background: background, blocks: blocks, placed: placed)
        #expect(output.width == size && output.height == size)
        var pixels = [UInt8](repeating: 0, count: size * size * 4)
        let reader = try #require(CGContext(data: &pixels, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
                                            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        reader.draw(output, in: CGRect(x: 0, y: 0, width: size, height: size))
        let frame = placed[0].frame.insetBy(dx: -2, dy: -2)
        var inside = 0, outside = 0
        for y in 0..<size {
            for x in 0..<size where pixels[(y * size + x) * 4 + 3] > 8 {
                if frame.contains(CGPoint(x: CGFloat(x) + 0.5, y: CGFloat(y) + 0.5)) { inside += 1 } else { outside += 1 }
            }
        }
        #expect(inside > 0)
        #expect(outside == 0)
    }

    @Test func replayMatchesTextFirstThenContainedRegions() {
        func block(_ id: Int, _ text: String, _ rect: CGRect) -> PipelineBlock {
            PipelineBlock(id: id, lines: [], bounds: rect, polygon: [], vertical: true, readingOrder: id, sourceText: text)
        }
        let entries = [
            PipelineTranslationReplay.Entry(id: "a", source: "お〜\n", rect: CGRect(x: 900, y: 0, width: 50, height: 50),
                                      translation: "오~", role: "dialogue"),
            PipelineTranslationReplay.Entry(id: "b", source: "前半", rect: CGRect(x: 10, y: 10, width: 40, height: 100),
                                      translation: "앞", role: "dialogue"),
            PipelineTranslationReplay.Entry(id: "c", source: "後半", rect: CGRect(x: 60, y: 10, width: 40, height: 100),
                                      translation: "뒤", role: "dialogue"),
        ]
        let blocks = [block(0, "お〜", CGRect(x: 0, y: 900, width: 10, height: 10)),
                      block(1, "前半後半", CGRect(x: 0, y: 0, width: 120, height: 130)),
                      block(2, "無関係", CGRect(x: 300, y: 300, width: 20, height: 20))]
        let result = PipelineTranslationReplay.apply(entries, to: blocks)
        #expect(result.map(\.translation) == ["오~", "앞 뒤", nil])
    }

    private final class PoolHandle {}
    private final class LoadCount: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func add() { lock.withLock { value += 1 } }
        var count: Int { lock.withLock { value } }
    }

    /// Polls (up to 2 s) until the pool's resident and loading counts satisfy `done`.
    private func settle(_ pool: PipelineHandlePool<PoolHandle>, until done: (Int, Int) -> Bool) async throws {
        for _ in 0..<200 {
            if done(await pool.resident, await pool.loading) { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    @Test func recognizerPoolShedsOnlyFreeHandlesAndHoldsAfterAWarning() async throws {
        let loads = LoadCount()
        let pool = PipelineHandlePool([PoolHandle(), PoolHandle(), PoolHandle()], idleSeconds: nil) {
            loads.add()
            return PoolHandle()
        }
        let held = await pool.acquire(rank: { 0 })
        await pool.shrink(cooldownSeconds: 60)
        // The checked-out handle stays until it comes back; the free ones go at once.
        #expect(await pool.resident == 1)
        await pool.release(held)
        await pool.release(await pool.acquire(rank: { 0 }))
        #expect(await pool.resident == 1)
        #expect(loads.count == 0)
    }

    @Test func recognizerPoolRegrowsOncePerMissingHandle() async throws {
        let loads = LoadCount()
        let pool = PipelineHandlePool([PoolHandle(), PoolHandle(), PoolHandle()], idleSeconds: nil) {
            loads.add()
            try? await Task.sleep(nanoseconds: 20_000_000)
            return PoolHandle()
        }
        let first = await pool.acquire(rank: { 0 })
        await pool.shrink()
        #expect(await pool.resident == 1)
        // Concurrent checkouts run on the remaining handle while one load per missing handle runs.
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<6 {
                group.addTask {
                    let handle = await pool.acquire(rank: { 0 })
                    try? await Task.sleep(nanoseconds: 5_000_000)
                    await pool.release(handle)
                }
            }
            await pool.release(first)
        }
        try await settle(pool) { resident, loading in resident == 3 && loading == 0 }
        #expect(await pool.resident == 3)
        #expect(loads.count == 2)
    }

    @Test func recognizerPoolShrinksAfterIdleTimeAndRegrowsOnDemand() async throws {
        let pool = PipelineHandlePool([PoolHandle(), PoolHandle()], idleSeconds: 0.2) { PoolHandle() }
        await pool.release(await pool.acquire(rank: { 0 }))
        #expect(await pool.resident == 2)
        try await settle(pool) { resident, _ in resident == 1 }
        #expect(await pool.resident == 1)
        // Held, so the idle timer cannot shrink it again while it regrows.
        let held = await pool.acquire(rank: { 0 })
        try await settle(pool) { resident, loading in resident == 2 && loading == 0 }
        #expect(await pool.resident == 2)
        await pool.release(held)
    }
}
