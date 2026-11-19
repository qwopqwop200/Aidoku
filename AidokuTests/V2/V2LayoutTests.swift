import CoreGraphics
import Foundation
import Testing
@testable import Aidoku

struct V2LayoutTests {
    private func block(_ id: Int, _ bounds: CGRect, _ text: String, source: CGFloat = 40, vertical: Bool = false) -> V2Block {
        V2Block(
            id: id, lines: [], bounds: bounds, polygon: [], vertical: vertical, readingOrder: id, sourceText: "",
            balloon: nil, role: .dialogue, translation: text,
            style: V2Style(fontPixels: source, bold: false, textColor: V2RGB(r: 0, g: 0, b: 0),
                           strokeColor: V2RGB(r: 255, g: 255, b: 255), strokeWidth: 2)
        )
    }

    @Test func fitsTextInsideBoxAtCappedSourceSize() {
        let page = CGSize(width: 1000, height: 1400)
        let placed = V2Layout.place([block(0, CGRect(x: 100, y: 100, width: 400, height: 300), "안녕 하세요")], pageSize: page)
        #expect(placed.count == 1)
        let item = placed[0]
        #expect(item.fontPixels == 40 * V2Layout.Options().capRatio)
        #expect(CGRect(x: 80, y: 80, width: 440, height: 340).contains(item.frame))
        #expect(item.lines.joined(separator: " ") == "안녕 하세요")
    }

    @Test func wrapsKoreanAtSpacesNotMidWord() {
        let page = CGSize(width: 1000, height: 1400)
        let text = "리제 쨩의 보은은 역시나 어김없이 소변이 깨끗하게 잘 나오네"
        let placed = V2Layout.place([block(0, CGRect(x: 100, y: 100, width: 220, height: 600), text, source: 60)], pageSize: page)
        let words = Set(text.split(separator: " ").map(String.init))
        #expect(placed[0].lines.count > 1)
        for line in placed[0].lines {
            for word in line.split(separator: " ") { #expect(words.contains(String(word))) }
        }
    }

    @Test func neverRefusesAndStaysInsidePage() {
        let page = CGSize(width: 300, height: 300)
        let long = String(repeating: "아주 긴 번역 문장입니다 ", count: 30)
        let blocks = [block(0, CGRect(x: 280, y: 280, width: 15, height: 15), long),
                      block(1, CGRect(x: 0, y: 0, width: 10, height: 10), "가")]
        let placed = V2Layout.place(blocks, pageSize: page)
        #expect(placed.count == 2)
        for item in placed { #expect(CGRect(origin: .zero, size: page).contains(item.frame)) }
    }

    @Test func overlappingSourceBlocksDoNotOverlapWhenPlaced() {
        let page = CGSize(width: 1000, height: 1000)
        let blocks = [block(0, CGRect(x: 100, y: 100, width: 300, height: 300), "첫 번째 말풍선 대사"),
                      block(1, CGRect(x: 250, y: 250, width: 300, height: 300), "두 번째 말풍선 대사")]
        let placed = V2Layout.place(blocks, pageSize: page)
        #expect(placed.count == 2)
        let overlap = placed[0].frame.intersection(placed[1].frame)
        #expect(overlap.isNull || overlap.width <= 0.5 || overlap.height <= 0.5)
    }

    @Test func skipsBackgroundAndEmptyTranslations() {
        var background = block(0, CGRect(x: 0, y: 0, width: 100, height: 100), "배경")
        background.role = .background
        let empty = block(1, CGRect(x: 200, y: 0, width: 100, height: 100), "  ")
        #expect(V2Layout.place([background, empty], pageSize: CGSize(width: 400, height: 400)).isEmpty)
    }

    @Test func paintKeepsPageSizeAndInkInsideFrames() throws {
        let size = 400
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let background = try #require(context.makeImage())
        let blocks = [block(0, CGRect(x: 40, y: 40, width: 200, height: 120), "번역 테스트")]
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
}
