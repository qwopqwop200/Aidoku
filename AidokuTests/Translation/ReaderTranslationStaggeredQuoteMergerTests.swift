import CoreGraphics
import Testing
import UIKit
@testable import Aidoku

struct ReaderTranslationStaggeredQuoteMergerTests {
    private func page(closing: Bool = true, freshOpening: Bool = false, wrongCorner: Bool = false) throws -> CGImage {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        return try #require(UIGraphicsImageRenderer(size: CGSize(width: 420, height: 420), format: format).image { ctx in
            UIColor(white: 0.12, alpha: 1).setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 420, height: 420))
            let ink = UIColor(red: 0.65, green: 0.25, blue: 0.55, alpha: 1)
            func corner(_ x: CGFloat, _ y: CGFloat, opening: Bool) {
                let rail = CGRect(x: x, y: opening ? y : y + 8, width: 28, height: 4)
                let leg = CGRect(x: opening ? x + 24 : x, y: y, width: 4, height: 12)
                UIColor.white.setFill(); ctx.fill(rail.insetBy(dx: -2, dy: -2)); ctx.fill(leg.insetBy(dx: -2, dy: -2))
                ink.setFill(); ctx.fill(rail); ctx.fill(leg)
            }
            for x in [CGFloat(194), 260] {
                let start = x == 194 ? 154 : 74
                for y in stride(from: start, through: 264, by: 22) {
                    let glyph = CGRect(x: x, y: CGFloat(y), width: 28, height: 10)
                    UIColor.white.setFill(); ctx.fill(glyph.insetBy(dx: -2, dy: -2))
                    ink.setFill(); ctx.fill(glyph)
                }
            }
            corner(260, 48, opening: true)
            if closing { corner(194, 306, opening: wrongCorner) }
            if freshOpening { corner(194, 130, opening: true) }
        }.cgImage)
    }

    private func regions(first: String = "「今日は", last: String = "良い天気") -> [ReaderTranslationRegion] {
        [ReaderTranslationRegion(id: "right", rect: CGRect(x: 250.0 / 420, y: 40.0 / 420, width: 50.0 / 420, height: 250.0 / 420),
            source: first, sourceOrientation: .vertical, sourceSingleVerticalColumn: true),
         ReaderTranslationRegion(id: "left", rect: CGRect(x: 184.0 / 420, y: 125.0 / 420, width: 50.0 / 420, height: 185.0 / 420),
            source: last, sourceOrientation: .vertical, sourceSingleVerticalColumn: true)]
    }

    @Test func missingClosingRequiresMeasuredCornerAndPreservesReadingOrder() throws {
        let image = try page()
        for input in [regions(), Array(regions().reversed())] {
            let output = ReaderTranslationStaggeredQuoteMerger.apply(input, image: image,
                enclosure: ReaderTranslationEnclosedBackground.ComponentMap(image: image))
            #expect(output.count == 1)
            #expect(output.first?.source == "「今日は良い天気」")
            #expect(output.first?.id == input.first?.id)
            #expect(output.first?.unitMemberRects == regions().map(\.rect))
            #expect(output.first?.sourceSingleVerticalColumn == false)
        }
    }

    @Test func independentUtterancesAndUnmeasuredPunctuationStaySeparate() throws {
        for image in [try page(closing: false), try page(freshOpening: true), try page(wrongCorner: true)] {
            let input = regions()
            #expect(ReaderTranslationStaggeredQuoteMerger.apply(input, image: image,
                enclosure: ReaderTranslationEnclosedBackground.ComponentMap(image: image)) == input)
        }
        let image = try page()
        for input in [regions(first: "「今日は」"), regions(last: "「良い天気"), regions(first: "今日は") ] {
            #expect(ReaderTranslationStaggeredQuoteMerger.apply(input, image: image,
                enclosure: ReaderTranslationEnclosedBackground.ComponentMap(image: image)) == input)
        }
    }
}
