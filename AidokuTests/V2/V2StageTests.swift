import CoreGraphics
import CoreML
import Foundation
import Testing
@testable import Aidoku

/// Model-free contracts of the V2 stages: detection line assembly, grouping,
/// recognition plan, layout detection decode, removal mask, inpaint scatter,
/// style, layout/paint and translation replay.
struct V2StageTests {
    private func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> [CGPoint] {
        [CGPoint(x: x, y: y), CGPoint(x: x + w, y: y), CGPoint(x: x + w, y: y + h), CGPoint(x: x, y: y + h)]
    }

    private func line(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat) -> V2Line {
        V2Detection.line(polygon: [
            CGPoint(x: x + width, y: y), CGPoint(x: x + width, y: y + height),
            CGPoint(x: x, y: y + height), CGPoint(x: x, y: y)
        ], score: 0.9)!
    }

    private func column(_ x: CGFloat, _ y: CGFloat, _ height: CGFloat, _ text: String) -> V2Line {
        let bounds = CGRect(x: x, y: y, width: 40, height: height)
        return V2Line(polygon: rect(x, y, 40, height), bounds: bounds, vertical: true, detectionScore: 0.9,
                      text: text, confidence: 0.95)
    }

    private func placedBlock(_ id: Int, _ bounds: CGRect, _ text: String) -> V2Block {
        V2Block(
            id: id, lines: [], bounds: bounds, polygon: [], vertical: false, readingOrder: id, sourceText: "",
            balloon: nil, role: .dialogue, translation: text,
            style: V2Style(fontPixels: 40, bold: false, textColor: V2RGB(r: 0, g: 0, b: 0),
                           strokeColor: V2RGB(r: 255, g: 255, b: 255), strokeWidth: 2)
        )
    }

    private func maskBlock(_ polygon: [CGPoint], bounds: CGRect, role: V2Role = .dialogue) -> V2Block {
        let line = V2Line(polygon: polygon, bounds: bounds, vertical: false, detectionScore: 1)
        return V2Block(id: 0, lines: [line], bounds: bounds, polygon: polygon, vertical: false, readingOrder: 0,
                       sourceText: "", balloon: nil, role: role)
    }

    // MARK: S1-S3 detection and grouping

    @Test func detectionJoinsSplitColumnsButNotAcrossBalloons() {
        let fragments = [line(100, 100, 40, 120), line(102, 250, 38, 90), line(101, 360, 40, 40)]
        let joined = V2LineAssembly.assemble(fragments, layout: [])
        #expect(joined.count == 1)
        #expect(joined[0].bounds == CGRect(x: 100, y: 100, width: 41, height: 300))
        #expect(joined[0].vertical)
        let split = [line(100, 100, 40, 120), line(100, 240, 40, 120)]
        let balloons = [
            V2LayoutRegion(kind: .balloon, bounds: CGRect(x: 80, y: 80, width: 80, height: 150), score: 0.9),
            V2LayoutRegion(kind: .balloon, bounds: CGRect(x: 80, y: 232, width: 80, height: 150), score: 0.9)
        ]
        #expect(V2LineAssembly.assemble(split, layout: balloons).count == 2)
        // A tilted column whose two leftmost corners are its top edge keeps that edge on top.
        let tilted = V2Detection.line(polygon: [
            CGPoint(x: 74, y: 313), CGPoint(x: 143, y: 850), CGPoint(x: 90, y: 857), CGPoint(x: 20, y: 320)
        ], score: 0.9)!
        #expect(tilted.polygon == [
            CGPoint(x: 20, y: 320), CGPoint(x: 74, y: 313), CGPoint(x: 143, y: 850), CGPoint(x: 90, y: 857)
        ])
    }

    @Test func groupingReadsBalloonColumnsRightToLeft() {
        let balloon = V2LayoutRegion(kind: .balloon, bounds: CGRect(x: 380, y: 80, width: 200, height: 400), score: 0.95)
        let lines = [column(420, 100, 300, "左"), column(470, 100, 300, "右"), column(100, 900, 200, "下")]
        let blocks = V2Grouping.group(lines, layout: [balloon], pageSize: CGSize(width: 1000, height: 1400))
        #expect(blocks.count == 2)
        #expect(blocks[0].sourceText == "右左")
        #expect(blocks[0].balloon == balloon.bounds)
        #expect(blocks.map(\.readingOrder) == [0, 1])
    }

    /// Legacy paragraph rules: complete quoted units stay apart; a one-glyph line may join a column.
    @Test func groupingKeepsQuotesApartAndJoinsOneGlyphLines() {
        let size = CGSize(width: 1000, height: 1400)
        let quoted = [column(470, 100, 200, "「はい」"), column(420, 100, 200, "「いいえ」")]
        #expect(V2Grouping.group(quoted, layout: [], pageSize: size).count == 2)
        let glyph = V2Line(polygon: rect(470, 310, 40, 40), bounds: CGRect(x: 470, y: 310, width: 40, height: 40),
                           vertical: false, detectionScore: 0.9, text: "！", confidence: 0.95)
        #expect(V2Grouping.group([column(470, 100, 200, "あいうえ"), glyph], layout: [], pageSize: size).count == 1)
        // A narrow fragment cut off a column head continues it and reads first.
        let head = V2Line(polygon: rect(480, 110, 18, 36), bounds: CGRect(x: 480, y: 110, width: 18, height: 36),
                          vertical: true, detectionScore: 0.9, text: "ち", confidence: 0.95)
        let joined = V2Grouping.group([column(470, 140, 200, "ゃんと"), head], layout: [], pageSize: size)
        #expect(joined.map(\.sourceText) == ["ちゃんと"])
    }

    /// SFX guard: an unquoted line outside every RF text region does not join quoted speech below its quote.
    @Test func groupingKeepsSFXOutOfQuotedSpeech() {
        let size = CGSize(width: 1000, height: 1400)
        let lines = [column(470, 100, 200, "「やだぁ」"), column(470, 320, 80, "どちんっ")]
        #expect(V2Grouping.group(lines, layout: [], pageSize: size).count == 1)
        let text = V2LayoutRegion(kind: .text, bounds: CGRect(x: 460, y: 90, width: 60, height: 220), score: 0.9)
        #expect(V2Grouping.group(lines, layout: [text], pageSize: size).count == 2)
    }

    /// Legacy intercolumn ruby: a narrow kana rail just right of one kanji column is erased with it, never translated.
    @Test func groupingErasesRubyWithItsHostColumn() {
        let ruby = V2Line(polygon: rect(442, 120, 20, 120), bounds: CGRect(x: 442, y: 120, width: 20, height: 120),
                          vertical: true, detectionScore: 0.9, text: "かんじ", confidence: 0.95)
        let blocks = V2Grouping.group([column(400, 100, 200, "漢字です"), ruby], layout: [], pageSize: CGSize(width: 1000, height: 1400))
        #expect(blocks.count == 1)
        #expect(blocks.first?.sourceText == "漢字です" && blocks.first?.lines.count == 2)
    }

    /// Finite but overflowing coordinates give a NaN axis; grouping must fall back, not trap.
    @Test func overflowingPolygonDoesNotTrapGrouping() {
        let huge = CGFloat.greatestFiniteMagnitude
        let line = V2Line(polygon: [CGPoint(x: 0, y: 0), CGPoint(x: huge, y: 0), CGPoint(x: huge, y: 10), CGPoint(x: 0, y: 10)],
                          bounds: CGRect(x: 0, y: 0, width: huge, height: 10), vertical: false, detectionScore: 0.9,
                          text: "x", confidence: 0.9)
        #expect(V2Grouping.group([line], layout: [], pageSize: CGSize(width: 1000, height: 1400)).count == 1)
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
        let regions = try V2LayoutDetection.decode(V2RFDETRModel.RawOutput(boxes: boxes, logits: logits),
                                                   width: 1000, height: 2000)
        #expect(regions.map(\.kind) == [.balloon, .frame])
        let bounds = regions[0].bounds
        #expect(abs(bounds.minX - 400) <= 1 && abs(bounds.minY - 600) <= 1)
        #expect(abs(bounds.width - 200) <= 2 && abs(bounds.height - 800) <= 2)
    }

    @Test func recognitionPlanRotatesColumnsAndRejectsDegenerateQuads() throws {
        let tall = try #require(V2Recognition.plan(rect(10, 10, 50, 400)))
        #expect(tall.rotatedCounterClockwise)
        // Text lines are padded by 5% of the short side: 55 x 405, so 48 * 405 / 55 rounds to 353.
        #expect(tall.bucket.width == 353)
        let long = try #require(V2Recognition.plan(rect(0, 0, 1200, 40)))
        #expect(!long.rotatedCounterClockwise)
        #expect(long.bucket.width == 640)
        #expect(V2Recognition.plan(rect(0, 0, 0, 0)) == nil)
    }

    // MARK: S6 removal mask, S7 inpaint

    /// A white 400 x 200 RGBA page with black `strokes`.
    private func inkPage(_ strokes: [CGRect]) -> [UInt8] {
        var rgba = [UInt8](repeating: 255, count: 400 * 200 * 4)
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
        let mask = V2RemovalMask.build(rgba: rgba, width: width, height: height,
                                       blocks: [maskBlock(rect(100, 75, 170, 50), bounds: region)], layout: [])
        #expect(mask.count == width * height)
        for stroke in strokes {
            for y in Int(stroke.minY)..<Int(stroke.maxY) {
                for x in Int(stroke.minX)..<Int(stroke.maxX) { #expect(mask[y * width + x] == 255) }
            }
        }
        #expect(mask[30 * width + 30] == 0 && mask[160 * width + 350] == 0)
        let background = V2RemovalMask.build(rgba: rgba, width: width, height: height,
            blocks: [maskBlock(rect(100, 75, 170, 50), bounds: region, role: .background)], layout: [])
        #expect(background.allSatisfy { $0 == 0 })
    }

    /// A glyph 18-24 px past the end of a 50 px thick line is outside the 15 px ROI square but inside
    /// the 0.5-thickness line-end extension, so it is erased.
    @Test func removalMaskSearchesPastTheLineEnd() {
        let width = 400, height = 200
        let stroke = CGRect(x: 288, y: 85, width: 6, height: 30)
        let mask = V2RemovalMask.build(rgba: inkPage([stroke]), width: width, height: height,
                                       blocks: [maskBlock(rect(100, 75, 170, 50), bounds: CGRect(x: 100, y: 75, width: 170, height: 50))],
                                       layout: [])
        var erased = 0
        for y in Int(stroke.minY)..<Int(stroke.maxY) {
            for x in Int(stroke.minX)..<Int(stroke.maxX) where mask[y * width + x] == 255 { erased += 1 }
        }
        #expect(erased * 4 >= 3 * 180)
        #expect(mask[100 * width + 340] == 0)
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
        let mask = V2RemovalMask.build(rgba: rgba, width: width, height: height, blocks: blocks, layout: [])
        #expect(mask.count == width * height && mask.allSatisfy { $0 == 0 })
        #expect(V2RemovalMask.build(rgba: [], width: -3, height: 5, blocks: blocks, layout: []).isEmpty)
    }

    @Test func aotFitsTheWholePageIntoTheModelSide() throws {
        let width = 3000, height = 2000
        var mask = [UInt8](repeating: 0, count: width * height)
        mask[1000 * width + 1500] = 255
        let patch = try #require(V2AOTModel.wholePage(mask, width: width, height: height))
        #expect(patch.rect == (0, 0, width, height) && patch.origin == (0, 0) && patch.size == (1024, 683))
        let small = try #require(V2AOTModel.wholePage([UInt8](repeating: 1, count: 100), width: 10, height: 10))
        #expect(small.size == (10, 10))
        #expect(V2AOTModel.wholePage([UInt8](repeating: 0, count: 100), width: 10, height: 10) == nil)
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
        let content = V2AOTModel.fill(rgba: rgba, mask: mask, width: width, height: height, image: image, maskTensor: maskTensor)
        #expect(content.0 == width && content.1 == height)
        // A constant mid-gray prediction stands in for the model output.
        let raw = try MLMultiArray(shape: [1, 3, 1024, 1024], dataType: .float16)
        let values = raw.dataPointer.assumingMemoryBound(to: Float16.self)
        for i in 0..<(3 * 1024 * 1024) { values[i] = 0 }
        var restored = rgba
        try restored.withUnsafeMutableBufferPointer {
            try V2AOTModel.scatter(into: $0, mask: mask, width: width, height: height, raw: raw, content: content)
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
        let page = V2Page(id: "synthetic", image: try #require(context.makeImage()))
        let polygon = rect(90, 60, 60, 200)
        let block = V2Block(id: 0, lines: [V2Line(polygon: polygon, bounds: CGRect(x: 90, y: 60, width: 60, height: 200),
                                                  vertical: true, detectionScore: 1)],
                            bounds: CGRect(x: 90, y: 60, width: 60, height: 200), polygon: [], vertical: true,
                            readingOrder: 0, sourceText: "あいうえお", balloon: nil)
        let style = try #require(V2Style.estimate(page, blocks: [block]).first?.style)
        #expect(style.fontPixels > 0)
        #expect(max(style.textColor.r, style.textColor.g, style.textColor.b) < 40)
        let stroke = try #require(style.strokeColor)
        #expect(min(stroke.r, stroke.g, stroke.b) > 215)
        #expect(style.strokeWidth > 1)
        #expect(V2Style.estimate(page, blocks: []).isEmpty)
    }

    @Test func sourceSizeGroupFollowsTheLongerText() {
        func block(_ id: Int, _ line: V2Line, _ text: String) -> V2Block {
            V2Block(id: id, lines: [line], bounds: line.bounds, polygon: line.polygon, vertical: true,
                    readingOrder: id, sourceText: text, balloon: nil)
        }
        func mark(_ x: CGFloat) -> V2Line {
            V2Line(polygon: rect(x, 100, 30, 34), bounds: CGRect(x: x, y: 100, width: 30, height: 34),
                   vertical: true, detectionScore: 0.9)
        }
        let dialogue = block(1, column(200, 100, 400, ""), "あいうえおかきくけこさしすせそた")
        let alone = V2SimpleFont.estimate([dialogue])[0]
        // Two short marks and one dialogue share a group; the group takes the dialogue's size.
        let sizes = V2SimpleFont.estimate([block(0, mark(100), "ッ!"), dialogue, block(2, mark(300), "ッ!")])
        #expect(sizes.allSatisfy { abs($0 - alone) < 0.001 })
    }

    // MARK: S9 layout and paint, S10 replay

    @Test func layoutFitsTextInsideBoxAndStaysInsidePage() {
        let block = placedBlock(0, CGRect(x: 100, y: 100, width: 400, height: 300), "안녕 하세요")
        let placed = V2Layout.place([block], pageSize: CGSize(width: 1000, height: 1400))
        #expect(placed.count == 1)
        #expect(placed[0].fontPixels == 40)  // outside a balloon the cap is the source size
        #expect(CGRect(x: 80, y: 80, width: 440, height: 340).contains(placed[0].frame))
        #expect(placed[0].lines.joined(separator: " ") == "안녕 하세요")
        // The frame holds the painted ink: line advances between lines, one 0.94 em ink height for the last.
        let ink = (CGFloat(placed[0].lines.count - 1) * 1.18 + 0.94) * 40
        #expect(abs(placed[0].frame.height - 2 * V2Layout.strokeWidth(for: block, fontPixels: 40) - ink) < 0.01)
        let page = CGSize(width: 300, height: 300)
        let long = String(repeating: "아주 긴 번역 문장입니다 ", count: 30)
        let edge = V2Layout.place([placedBlock(0, CGRect(x: 280, y: 280, width: 15, height: 15), long)], pageSize: page)
        #expect(edge.count == 1 && CGRect(origin: .zero, size: page).contains(edge[0].frame))
    }

    private func verticalBlock(_ bounds: CGRect, _ text: String, balloon: CGRect? = nil) -> V2Block {
        var block = placedBlock(0, bounds, text)
        block.vertical = true
        block.balloon = balloon
        return block
    }

    @Test func layoutKeepsPunctuationWithItsWord() {
        let closing = V2Layout.MeasuredText.closing, opening = V2Layout.MeasuredText.opening
        for width: CGFloat in [70, 120, 200, 320] {
            let block = placedBlock(0, CGRect(x: 100, y: 100, width: width, height: 900), "「앗! 싫어, 하지 마세요…… 아윽!」")
            let placed = V2Layout.place([block], pageSize: CGSize(width: 1000, height: 1400))
            let lines = placed[0].lines
            #expect(lines.dropFirst().allSatisfy { !($0.first.map(closing.contains) ?? false) }, "\(width): \(lines)")
            #expect(lines.dropLast().allSatisfy { !($0.last.map(opening.contains) ?? false) }, "\(width): \(lines)")
        }
        // A space-separated run of marks joins its neighbour instead of standing alone.
        #expect(V2Layout.MeasuredText.glued(["그래", "……", "「", "가자"]) == ["그래 ……", "「 가자"])
    }

    @Test func layoutPrefersWholeWordsWhenTheSizeCostIsSmall() {
        // At the 48 px cap "말하지" would be split; a slightly smaller size keeps every word whole.
        let placed = V2Layout.place([placedBlock(0, CGRect(x: 100, y: 100, width: 130, height: 400), "말하지 마 바보")],
                                    pageSize: CGSize(width: 1000, height: 1400))
        #expect(placed[0].lines.allSatisfy { ["말하지", "마", "바보", "마 바보"].contains($0) }, "\(placed[0].lines)")
    }

    @Test func stackedVerticalSourceSwitchesToColumns() {
        let page = CGSize(width: 1000, height: 1400)
        let narrow = V2Layout.place([verticalBlock(CGRect(x: 100, y: 100, width: 60, height: 600), "「날뛰지 마! 뭐야」")],
                                    pageSize: page)
        #expect(narrow[0].vertical)
        #expect(narrow[0].frame.width <= 64 && narrow[0].frame.height <= 604)
        // A wide box keeps horizontal Korean.
        let wide = V2Layout.place([verticalBlock(CGRect(x: 100, y: 100, width: 300, height: 600), "「날뛰지 마! 뭐야」")],
                                  pageSize: page)
        #expect(!wide[0].vertical)
        #expect(V2Painter.verticalForms("「아...…」") == "﹁아︙︙﹂")
    }

    @Test func displayTextDropsProviderLineMarkup() {
        #expect(V2Layout.displayText("안 돼...っ<br>더 이상은") == "안 돼... 더 이상은")
        #expect(V2Layout.displayText("저 유두…!|탱글탱글해서") == "저 유두…! 탱글탱글해서")
        #expect(V2Layout.displayText("알고 있다니까!\u{200B}\u{200B} 그보다") == "알고 있다니까! 그보다")
        #expect(V2Layout.displayText("두근  두근\n  둘째 줄") == "두근 두근\n둘째 줄")
        #expect(V2Layout.displayText("검사 중에/숨기고\u{2800}있잖아") == "검사 중에 숨기고 있잖아")
        #expect(V2Layout.displayText("1/2 남았어") == "1/2 남았어")
        // Real kana and non-Hangul text are left alone.
        #expect(V2Layout.displayText("メイド喫茶っ") == "メイド喫茶っ")
        #expect(V2Layout.displayText("a|b") == "a|b")
        #expect(V2Layout.displayText("plain text") == "plain text")
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
        let raster = V2GrayRaster(pixels: pixels, width: size, height: size)
        let bounds = CGRect(x: 560, y: 400, width: 80, height: 400)
        let line = V2Line(polygon: rect(560, 400, 80, 400), bounds: bounds, vertical: true, detectionScore: 1)
        let block = V2Block(id: 0, lines: [line], bounds: bounds, polygon: [], vertical: true, readingOrder: 0,
                            sourceText: "あいうえお")
        let interior = V2Interior.apply([block], raster: raster, pageSize: CGSize(width: 1200, height: 1200))[0].balloon
        #expect(interior.map { $0.width > bounds.width * 1.5 } == true)
        #expect(interior.map { CGRect(x: 0, y: 236, width: 1200, height: 728).contains($0) } == true)
        // Tone (mid-gray paper) still grows but gets no row spans; background blocks are skipped.
        let gray = V2GrayRaster(pixels: [UInt8](repeating: 128, count: size * size), width: size, height: size)
        let toned = V2Interior.apply([block], raster: gray, pageSize: CGSize(width: 1200, height: 1200))[0]
        #expect(toned.balloon != nil && toned.rows == nil)
        var background = block
        background.role = .background
        #expect(V2Interior.apply([background], raster: raster, pageSize: CGSize(width: 1200, height: 1200))[0].balloon == nil)
    }

    @Test func balloonLobeLeavesTheTailOut() {
        // Paper: a disc of radius 30 about (50, 50) with a 4-cell tail to x 110; the rest is ink.
        func dirty(_ x: Int, _ y: Int) -> Bool {
            !((x - 50) * (x - 50) + (y - 50) * (y - 50) <= 900 || (x >= 50 && x < 110 && y >= 48 && y < 52))
        }
        let lobe = V2Interior.lobeRect((0, 0, 130, 100), source: (40, 40, 60, 60), dirty: dirty)
        #expect(lobe.map { $0.x0 >= 19 && $0.x1 <= 81 && $0.y0 >= 19 && $0.y1 <= 81 && $0.x1 - $0.x0 >= 30 } == true)
        // Paper reaching the growth limit is open lettering space, not a balloon.
        #expect(V2Interior.lobeRect((30, 30, 70, 70), source: (40, 40, 60, 60), dirty: dirty) == nil)
    }

    private func styled(_ px: CGFloat, fill: V2RGB = V2RGB(r: 0, g: 0, b: 0), stroke: V2RGB? = V2RGB(r: 255, g: 255, b: 255),
                        width: CGFloat = 3) -> V2Style {
        V2Style(fontPixels: px, bold: false, textColor: fill, strokeColor: stroke, strokeWidth: width)
    }

    @Test func cohortsSnapSourcesAndShareOneSize() {
        func block(_ id: Int, _ px: CGFloat) -> V2Block {
            var block = placedBlock(id, CGRect(x: CGFloat(id) * 200, y: 0, width: 100, height: 100), "가")
            // Colour is not part of the key (legacy families mix colours).
            block.style = styled(px, fill: id == 1 ? V2RGB(r: 220, g: 30, b: 30) : V2RGB(r: 0, g: 0, b: 0))
            return block
        }
        var plain = block(4, 43)
        plain.style?.strokeColor = nil                       // outline is not part of the key
        let blocks = [block(0, 40), block(1, 41), block(2, 47), block(3, 80), plain]
        let plan = V2Cohort.plan(blocks, sources: [40, 41, 47, 80, 43], capRatio: { _ in 1.2 }, floor: 10)
        #expect(plan.sources[0] == plan.sources[1])          // snapped within 1.08x
        #expect(plan.cohorts.map { $0.sorted() } == [[0, 1, 2, 4]])  // 80 px is its own size
        #expect(plan.caps[0] == plan.caps[1] && plan.caps[0] == plan.caps[2])  // one family cap
        // The family takes the largest cap step every member reached (members below 0.65 keep theirs).
        #expect(V2Cohort.familySize(cap: 50, fits: [50, 46, 20]) == 45)
        #expect(V2Cohort.familySize(cap: 50, fits: [20, 21]) == nil)
    }

    @Test func alignedStartsShareTheMedianCentredTop() {
        let sources = [CGRect(x: 0, y: 100, width: 100, height: 200), CGRect(x: 150, y: 110, width: 100, height: 100),
                       CGRect(x: 300, y: 105, width: 100, height: 300), CGRect(x: 900, y: 100, width: 100, height: 100)]
        var placed = sources.enumerated().map { index, rect in
            V2PlacedText(blockID: index, frame: CGRect(x: rect.minX, y: rect.minY + CGFloat(index) * 7, width: 100, height: 60),
                         fontPixels: 40, vertical: false, lines: ["가"])
        }
        V2Layout.alignStarts(&placed, sources.enumerated().map { placedBlock($0.offset, $0.element, "가") },
                             sources: [40, 40, 40, 40], page: CGRect(x: 0, y: 0, width: 1000, height: 1000))
        // Median of the centred tops 170, 130 and 225; the block 12.5 em away keeps its frame.
        #expect(placed.map(\.frame.minY) == [170, 170, 170, 121])
        // A tilted member keeps its frame; the upright rest still share one top.
        var tilted = sources.enumerated().map { index, rect in
            V2PlacedText(blockID: index, frame: CGRect(x: rect.minX, y: rect.minY + CGFloat(index) * 7, width: 100, height: 60),
                         fontPixels: 40, vertical: false, lines: ["가"], angle: index == 1 ? 0.1 : nil)
        }
        V2Layout.alignStarts(&tilted, sources.enumerated().map { placedBlock($0.offset, $0.element, "가") },
                             sources: [40, 40, 40, 40], page: CGRect(x: 0, y: 0, width: 1000, height: 1000))
        #expect(tilted.map(\.frame.minY) == [197.5, 117, 197.5, 121])
    }

    @Test func rotationFollowsTiltedLineQuads() {
        func quad(_ angle: CGFloat) -> V2Line {
            let c = cos(angle), s = sin(angle), w: CGFloat = 200, h: CGFloat = 40
            let points = [(-w / 2, -h / 2), (w / 2, -h / 2), (w / 2, h / 2), (-w / 2, h / 2)].map {
                CGPoint(x: 300 + $0.0 * c - $0.1 * s, y: 300 + $0.0 * s + $0.1 * c)
            }
            return V2Line(polygon: points, bounds: CGRect(x: 180, y: 240, width: 240, height: 120), vertical: false, detectionScore: 1)
        }
        func block(_ lines: [V2Line]) -> V2Block {
            V2Block(id: 0, lines: lines, bounds: CGRect(x: 180, y: 240, width: 240, height: 120), polygon: [], vertical: false,
                    readingOrder: 0, sourceText: "")
        }
        #expect(abs(V2Rotation.angle(block([quad(0.2), quad(0.21)])) - 0.205) < 0.01)
        #expect(V2Rotation.angle(block([quad(0.03)])) == 0)   // under 2.5 degrees: upright
        #expect(V2Rotation.angle(block([quad(0.2), quad(-0.2)])) == 0)   // no consensus
        let tilted = V2Rotation.bounds(CGRect(x: 0, y: 0, width: 100, height: 20), angle: .pi / 6)
        #expect(abs(tilted.width - (100 * cos(.pi / 6) + 20 * sin(.pi / 6))) < 0.01)
        #expect(abs(tilted.height - (100 * sin(.pi / 6) + 20 * cos(.pi / 6))) < 0.01)
        #expect(V2Rotation.inscribed(CGSize(width: 20, height: 400), angle: .pi / 6) == nil)
    }

    @Test func painterAddsAHaloOnlyWhenTextWouldVanish() {
        var block = placedBlock(0, CGRect(x: 0, y: 0, width: 100, height: 100), "가")
        block.style = styled(40, fill: V2RGB(r: 20, g: 20, b: 20), stroke: nil, width: 0)
        let dark = V2Painter.legible(block: block, fontPixels: 40, background: V2RGB(r: 30, g: 30, b: 30))
        #expect(dark.stroke != nil && dark.strokeWidth > 0)
        #expect(dark.stroke?.components?.first == 1)       // white halo on dark text and background
        let light = V2Painter.legible(block: block, fontPixels: 40, background: V2RGB(r: 250, g: 250, b: 250))
        #expect(light.stroke == nil)
    }

    @Test func layoutKeepsKoreanPhrasesAndSitsOverTheSource() {
        // "할 수" must not break between 할 and the dependent noun 수 when the pair fits a line.
        let text = V2Layout.MeasuredText("그건 할 수 있어", font: V2Layout.font(size: V2Layout.referenceSize))
        let probe = text.wrap(limits: { _ in text.paragraphs[0][0].width + text.spaceWidth + text.paragraphs[0][1].width + 1 })
        #expect(!probe.lines.contains { $0.hasPrefix("수") }, "\(probe.lines)")
        #expect(V2Layout.MeasuredText.couples("할", "수") && V2Layout.MeasuredText.couples("몇", "번"))
        // Compaction counts lone graphemes and split phrases when it picks among wraps.
        #expect(V2Layout.badBreaks(["있을", "수", "있어"]) == 2 && V2Layout.badBreaks(["있을 수", "있어"]) == 0)
        // A grown box keeps the text centred on its source, not on the box.
        var block = placedBlock(0, CGRect(x: 500, y: 200, width: 80, height: 60), "안녕")
        block.balloon = CGRect(x: 100, y: 100, width: 800, height: 300)
        let placed = V2Layout.place([block], pageSize: CGSize(width: 1000, height: 1000))
        #expect(abs(placed[0].frame.midX - 540) < 1 && abs(placed[0].frame.midY - 230) < 1, "\(placed[0].frame)")
    }

    @Test func rowSpansWidenTheMiddleLinesOfARoundBalloon() {
        // A diamond-like balloon: rows are widest at the centre (half-width 150 px there).
        let halves = (0..<60).map { CGFloat(150 - abs($0 - 30) * 4) }
        let rows = V2RowSpans(top: 100, step: 5, centre: 500, halfWidths: halves)
        #expect(rows.halfWidth(240, 260) == 142 && rows.halfWidth(90, 110) == 0)   // rows 28...31
        let text = V2Layout.MeasuredText("가나다라 마바사 아자차카 타파하 가나다 라마바사", font: V2Layout.font(size: V2Layout.referenceSize))
        let found = V2Layout.spanFit(text, size: 30, rows: rows, centreY: 250, stroke: 0, whole: true)
        #expect(found != nil)
        if let found {
            #expect(found.fit.lines.count >= 2)
            #expect(found.top >= rows.top && found.top + found.fit.extent.height <= rows.bottom)
            // The widest line lies within the widest span.
            #expect(found.fit.extent.width <= 2 * 150 + 0.5)
        }
        // Too big for the spans: no fit.
        #expect(V2Layout.spanFit(text, size: 200, rows: rows, centreY: 250, stroke: 0, whole: true) == nil)
    }

    @Test func lowConfidenceFragmentsOutsideBalloonsKeepTheirSource() {
        func block(_ text: String, confidence: Float, balloon: CGRect? = nil) -> V2Block {
            let line = V2Line(polygon: rect(0, 0, 40, 40), bounds: CGRect(x: 0, y: 0, width: 40, height: 40), vertical: true,
                              detectionScore: 1, text: text, confidence: confidence)
            return V2Block(id: 0, lines: [line], bounds: line.bounds, polygon: [], vertical: true, readingOrder: 0,
                           sourceText: text, balloon: balloon)
        }
        #expect(V2RoleFilter.isFragment(block("6", confidence: 0.4)))
        #expect(!V2RoleFilter.isFragment(block("6", confidence: 0.8)))
        #expect(!V2RoleFilter.isFragment(block("ン", confidence: 0.4, balloon: CGRect(x: 0, y: 0, width: 80, height: 80))))
        #expect(!V2RoleFilter.isFragment(block("なにこれ本当", confidence: 0.4)))
        #expect(V2RoleFilter.classify([block("6", confidence: 0.4)], layout: [])[0].role == .background)
    }

    @Test func providerErrorsAndSourceCopiesKeepTheSource() {
        let block = V2Block(id: 3, lines: [], bounds: .zero, polygon: [], vertical: true, readingOrder: 0, sourceText: "SALE")
        let error = V2Translation.apply([block]) { _ in RemoteTranslatedSegment(id: "x", text: "x", textRole: .error) }
        #expect(error[0].role == .background)
        let copy = V2Translation.apply([block]) { _ in RemoteTranslatedSegment(id: "x", text: "SA LE") }
        #expect(copy[0].translation == nil)
        var marks = block
        marks.sourceText = "……!"
        #expect(V2Translation.apply([marks]) { _ in RemoteTranslatedSegment(id: "x", text: "……!") }[0].translation == "……!")
        #expect(V2Layout.displayText("아ー 좋아") == "아~ 좋아")
    }

    @Test func legacyReplyRepairsApply() {
        var block = V2Block(id: 4, lines: [], bounds: .zero, polygon: [], vertical: true, readingOrder: 0,
            sourceText: "このびちゃびちゃの下着は貰うぞ、絶対にね")
        func reply(_ text: String) -> String? {
            V2Translation.apply([block]) { _ in RemoteTranslatedSegment(id: "x", text: text) }[0].translation
        }
        #expect(reply("このびちゃびちゃの下着は貰うぞ！絶対にね！") == nil)
        #expect(reply("좋아, このびちゃびちゃの下着は貰うぞ") == "좋아, このびちゃびちゃの下着は貰うぞ")
        #expect(reply("코드\\n입니다 \\uae68") == "코드\n입니다 깨")
        #expect(reply("서울 漢字 공부를 했어!") == "서울 漢字 공부를 했어!")
        block.sourceText = "原文"
        #expect(reply("오늘은 漢字") == "오늘은 漢字")
    }

    @Test func narrationRoleIsKeptAndPainted() {
        let block = V2Block(id: 0, lines: [], bounds: .zero, polygon: [], vertical: false, readingOrder: 0, sourceText: "説明")
        let narration = V2Translation.apply([block]) { _ in RemoteTranslatedSegment(id: "x", text: "설명", textRole: .narration) }
        #expect(narration[0].role == .narration && V2Layout.isPaintable(narration[0]))
    }

    @Test func sfxAndShortLatinKeepTheirSource() {
        func painted(_ source: String, _ role: RemoteTranslationTextRole) -> Bool {
            let block = V2Block(id: 0, lines: [], bounds: .zero, polygon: [], vertical: true, readingOrder: 0, sourceText: source)
            return V2Layout.isPaintable(V2Translation.apply([block]) { _ in RemoteTranslatedSegment(id: "x", text: "번역", textRole: role) }[0])
        }
        #expect(!painted("ドキッ", .sfx))
        #expect(painted("「……ゴクリッ」", .sfx))
        #expect(painted("どちゃっ頭っまた真っ白になるっやだこれ怖いっ", .sfx))
        #expect(!painted("1098", .dialogue))
        #expect(painted("あっ", .dialogue))
        #expect(painted("…!", .dialogue))
    }

    @Test func pageRequestsUseThePageLetteringContract() {
        let block = V2Block(id: 0, lines: [], bounds: CGRect(x: 10, y: 10, width: 50, height: 50), polygon: [], vertical: true,
                            readingOrder: 0, sourceText: "こんにちは")
        let size = CGSize(width: 100, height: 100)
        let withImage = V2Translation.requests(for: [block], pageSize: size, sourceLanguage: "ja", targetLanguage: "ko",
                                               imageJPEG: Data([0xFF, 0xD8, 0xFF]))
        #expect(withImage.first?.translatesPageLettering == true)
        let withoutImage = V2Translation.requests(for: [block], pageSize: size, sourceLanguage: "ja", targetLanguage: "ko",
                                                  imageJPEG: nil)
        #expect(withoutImage.first?.translatesPageLettering == nil)
    }

    @Test func emergencySplitsAvoidLatinWordsAndNumbersAndCondenseFirst() {
        let characters = Array("Chulsoo").map(String.init)
        #expect(V2Layout.MeasuredText.adjustedSplit(characters, start: 0, end: 3) != 3)
        #expect(V2Layout.MeasuredText.joinsLatinOrNumber("1", ",") && !V2Layout.MeasuredText.joinsLatinOrNumber("가", "나"))
        // A word just too wide for the box is narrowed (0.9) rather than split.
        let text = V2Layout.MeasuredText("가나다라마", font: V2Layout.font(size: V2Layout.referenceSize))
        let narrow = text.condensed(by: 0.9)
        #expect(abs(narrow.widestWord - text.widestWord * 0.9) < 0.001 && narrow.scale == 0.9)
        #expect(ReaderTranslationV2Service.renderOnlyFailure("s7: x; s9: 1 erased block(s) not placed"))
        #expect(!ReaderTranslationV2Service.renderOnlyFailure("s5: timeout"))
    }

    @Test func paintKeepsPageSizeAndInkInsideFrames() throws {
        let size = 400
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let background = try #require(context.makeImage())
        let blocks = [placedBlock(0, CGRect(x: 40, y: 40, width: 200, height: 120), "번역 테스트")]
        let placed = V2Layout.place(blocks, pageSize: CGSize(width: size, height: size))
        let output = V2Painter.paint(background: background, blocks: blocks, placed: placed)
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
        func block(_ id: Int, _ text: String, _ rect: CGRect) -> V2Block {
            V2Block(id: id, lines: [], bounds: rect, polygon: [], vertical: true, readingOrder: id, sourceText: text)
        }
        let entries = [
            V2TranslationReplay.Entry(id: "a", source: "お〜\n", rect: CGRect(x: 900, y: 0, width: 50, height: 50),
                                      translation: "오~", role: "dialogue"),
            V2TranslationReplay.Entry(id: "b", source: "前半", rect: CGRect(x: 10, y: 10, width: 40, height: 100),
                                      translation: "앞", role: "dialogue"),
            V2TranslationReplay.Entry(id: "c", source: "後半", rect: CGRect(x: 60, y: 10, width: 40, height: 100),
                                      translation: "뒤", role: "dialogue"),
        ]
        let blocks = [block(0, "お〜", CGRect(x: 0, y: 900, width: 10, height: 10)),
                      block(1, "前半後半", CGRect(x: 0, y: 0, width: 120, height: 130)),
                      block(2, "無関係", CGRect(x: 300, y: 300, width: 20, height: 20))]
        let result = V2TranslationReplay.apply(entries, to: blocks)
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
    private func settle(_ pool: V2HandlePool<PoolHandle>, until done: (Int, Int) -> Bool) async throws {
        for _ in 0..<200 {
            if done(await pool.resident, await pool.loading) { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    @Test func recognizerPoolShedsOnlyFreeHandlesAndHoldsAfterAWarning() async throws {
        let loads = LoadCount()
        let pool = V2HandlePool([PoolHandle(), PoolHandle(), PoolHandle()], idleSeconds: nil) {
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
        let pool = V2HandlePool([PoolHandle(), PoolHandle(), PoolHandle()], idleSeconds: nil) {
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
        let pool = V2HandlePool([PoolHandle(), PoolHandle()], idleSeconds: 0.2) { PoolHandle() }
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
