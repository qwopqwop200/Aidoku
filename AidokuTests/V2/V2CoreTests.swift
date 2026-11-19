import CoreGraphics
import CoreML
import Foundation
import Testing
@testable import Aidoku

/// V2 integration primitives that need no model: replay matching, AOT
/// composition invariance (pixels outside the mask unchanged) and the
/// RF-DETR decode.
struct V2CoreTests {
    private func block(_ id: Int, _ text: String, _ rect: CGRect) -> V2Block {
        V2Block(id: id, lines: [], bounds: rect, polygon: [], vertical: true, readingOrder: id, sourceText: text)
    }

    @Test func replayMatchesTextFirstThenContainedRegions() {
        let entries = [
            V2TranslationReplay.Entry(id: "a", source: "お〜\n", rect: CGRect(x: 900, y: 0, width: 50, height: 50),
                                      translation: "오~", role: "dialogue"),
            V2TranslationReplay.Entry(id: "b", source: "前半", rect: CGRect(x: 10, y: 10, width: 40, height: 100),
                                      translation: "앞", role: "dialogue"),
            V2TranslationReplay.Entry(id: "c", source: "後半", rect: CGRect(x: 60, y: 10, width: 40, height: 100),
                                      translation: "뒤", role: "dialogue"),
            V2TranslationReplay.Entry(id: "d", source: "ドン", rect: CGRect(x: 500, y: 500, width: 80, height: 80),
                                      translation: "쾅", role: "sfx"),
        ]
        let blocks = [block(0, "お〜", CGRect(x: 0, y: 900, width: 10, height: 10)),
                      block(1, "前半後半", CGRect(x: 0, y: 0, width: 120, height: 130)),
                      block(2, "ドン!", CGRect(x: 490, y: 490, width: 100, height: 100)),
                      block(3, "無関係", CGRect(x: 300, y: 300, width: 20, height: 20))]
        let result = V2TranslationReplay.apply(entries, to: blocks)
        #expect(result[0].translation == "오~")
        #expect(result[1].translation == "앞 뒤")
        #expect(result[2].translation == "쾅")
        #expect(result[2].role == .sfx)
        #expect(result[3].translation == nil)
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

    @Test func rfDecodeKeepsConfidentQueriesWithMasks() throws {
        let boxes = try MLMultiArray(shape: [1, 300, 4], dataType: .float32)
        let logits = try MLMultiArray(shape: [1, 300, 5], dataType: .float32)
        let masks = try MLMultiArray(shape: [1, 300, 162, 162], dataType: .float32)
        let box = boxes.dataPointer.assumingMemoryBound(to: Float.self)
        let logit = logits.dataPointer.assumingMemoryBound(to: Float.self)
        let mask = masks.dataPointer.assumingMemoryBound(to: Float.self)
        for i in 0..<(300 * 4) { box[i] = 0.1 }
        for i in 0..<(300 * 5) { logit[i] = -10 }
        for i in 0..<(300 * 162 * 162) { mask[i] = -1 }
        // Query 3: a balloon centered at (0.5, 0.5), 0.2 x 0.4 of the page, mask positive everywhere.
        box[12] = 0.5; box[13] = 0.5; box[14] = 0.2; box[15] = 0.4
        logit[3 * 5 + 2] = 4
        for i in 0..<(162 * 162) { mask[3 * 162 * 162 + i] = 1 }
        let raw = V2RFDETRModel.RawOutput(boxes: boxes, logits: logits, masks: masks)
        let regions = try V2LayoutDetection.decode(raw, width: 1000, height: 2000)
        #expect(regions.count == 1)
        #expect(regions[0].kind == .balloon)
        let bounds = regions[0].bounds
        #expect(bounds == bounds.integral)
        #expect(abs(bounds.minX - 400) <= 1 && abs(bounds.minY - 600) <= 1)
        #expect(abs(bounds.width - 200) <= 2 && abs(bounds.height - 800) <= 2)
        #expect(regions[0].mask?.count == Int(bounds.width) * Int(bounds.height))
        #expect(regions[0].mask?.allSatisfy { $0 == 255 } == true)
    }
}
