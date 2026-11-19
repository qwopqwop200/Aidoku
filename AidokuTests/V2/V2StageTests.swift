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
        #expect(tall.bucket.width == 384)
        let long = try #require(V2Recognition.plan(rect(0, 0, 1200, 40)))
        #expect(!long.rotatedCounterClockwise)
        #expect(long.bucket.width == 640)
        #expect(V2Recognition.plan(rect(0, 0, 0, 0)) == nil)
    }

    // MARK: S6 removal mask, S7 inpaint

    @Test func removalMaskErasesInkButNotTheBalloonOrBackgroundRole() {
        let width = 400, height = 200
        let strokes = [CGRect(x: 110, y: 82, width: 6, height: 36), CGRect(x: 130, y: 97, width: 40, height: 6)]
        var rgba = [UInt8](repeating: 255, count: width * height * 4)
        for stroke in strokes {
            for y in Int(stroke.minY)..<Int(stroke.maxY) {
                for x in Int(stroke.minX)..<Int(stroke.maxX) {
                    let i = (y * width + x) * 4
                    rgba[i] = 0; rgba[i + 1] = 0; rgba[i + 2] = 0
                }
            }
        }
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

    // MARK: S9 layout and paint, S10 replay

    @Test func layoutFitsTextInsideBoxAndStaysInsidePage() {
        let placed = V2Layout.place([placedBlock(0, CGRect(x: 100, y: 100, width: 400, height: 300), "안녕 하세요")],
                                    pageSize: CGSize(width: 1000, height: 1400))
        #expect(placed.count == 1)
        #expect(placed[0].fontPixels == 40 * V2Layout.capRatio)
        #expect(CGRect(x: 80, y: 80, width: 440, height: 340).contains(placed[0].frame))
        #expect(placed[0].lines.joined(separator: " ") == "안녕 하세요")
        let page = CGSize(width: 300, height: 300)
        let long = String(repeating: "아주 긴 번역 문장입니다 ", count: 30)
        let edge = V2Layout.place([placedBlock(0, CGRect(x: 280, y: 280, width: 15, height: 15), long)], pageSize: page)
        #expect(edge.count == 1 && CGRect(origin: .zero, size: page).contains(edge[0].frame))
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
}
