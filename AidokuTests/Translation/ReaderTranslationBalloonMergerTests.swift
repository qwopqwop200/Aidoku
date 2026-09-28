import Testing
import UIKit
@testable import Aidoku

struct ReaderTranslationBalloonMergerTests {
    private struct DatasetFixture: Decodable {
        let id: String
        let expectedSources: [String]
        let freshOCRSource: String?
    }

    @Test(arguments: [0.5, 1.0, 2.0], [false, true])
    func repeatedKanaNeedsFullSizeAlignmentAndImageEvidence(scale: CGFloat, verticalLead: Bool) throws {
        func region(_ id: String, _ text: String, _ rect: CGRect, lead: Bool = false) -> ReaderTranslationRegion {
            ReaderTranslationRegion(id: id, rect: CGRect(x: rect.minX / 400, y: rect.minY / 400,
                width: rect.width / 400, height: rect.height / 400), source: text,
                confidence: lead ? 0.8 : 0.95, sourceOrientation: lead && !verticalLead ? .horizontal : .vertical,
                sourceSingleVerticalColumn: !lead || verticalLead)
        }
        func page(rule: Bool = false) throws -> CGImage {
            let format = UIGraphicsImageRendererFormat(); format.scale = 1
            return try #require(UIGraphicsImageRenderer(size: CGSize(width: 400 * scale, height: 400 * scale), format: format).image { ctx in
                ctx.cgContext.scaleBy(x: scale, y: scale)
                UIColor.white.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 400, height: 400))
                UIColor.black.setStroke(); ctx.cgContext.setLineWidth(3)
                ctx.cgContext.strokeEllipse(in: CGRect(x: 130, y: 120, width: 140, height: 180))
                if rule { UIColor.black.setFill(); ctx.fill(CGRect(x: 201, y: 130, width: 3, height: 150)) }
            }.cgImage)
        }
        let column = region("body", "しかたない", CGRect(x: 174, y: 155, width: 24, height: 120))
        let lead = region("lead", "し", CGRect(x: 206, y: 156, width: 24, height: 25), lead: true)
        let image = try page()
        for input in [[column, lead], [lead, column]] {
            let output = ReaderTranslationBalloonMerger.apply(input, image: image)
            #expect(output.map(\.source) == ["ししかたない"])
            #expect(output.first?.id == input.first?.id)
            #expect(output.first?.confidence == 0.8)
            #expect(output.first?.rect == column.rect.union(lead.rect))
            #expect(output.first?.sourceOrientation == .vertical)
            #expect(output.first?.sourceSingleVerticalColumn == false)
        }
        #expect(ReaderTranslationBalloonMerger.apply([column, lead], image: try page(rule: true)) == [column, lead])
        let rubyBody = region("body", "実は私", CGRect(x: 174, y: 155, width: 24, height: 120))
        let ruby = region("ruby", "じ", CGRect(x: 206, y: 156, width: 24, height: 25), lead: true)
        #expect(ReaderTranslationBalloonMerger.apply([rubyBody, ruby], image: image) == [rubyBody, ruby])
        for invalid in [
            region("lead", "し", CGRect(x: 206, y: 156, width: 10, height: 12), lead: true),
            region("lead", "し", CGRect(x: 206, y: 195, width: 24, height: 25), lead: true),
            region("lead", "し", CGRect(x: 240, y: 156, width: 24, height: 25), lead: true),
            region("lead", "し", CGRect(x: 142, y: 156, width: 24, height: 25), lead: true)
        ] {
            #expect(ReaderTranslationBalloonMerger.apply([column, invalid], image: image) == [column, invalid])
        }
        let middle = region("middle", "別", CGRect(x: 198, y: 160, width: 8, height: 20))
        #expect(ReaderTranslationBalloonMerger.apply([column, lead, middle], image: image) == [column, lead, middle])
    }

    @Test(arguments: [0.5, 1.0, 2.0], [false, true])
    func shortColouredReactionsNeedMatchingInkAlignmentAndClearGutter(scale: CGFloat, horizontalReaction: Bool) throws {
        func rect(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat) -> CGRect {
            CGRect(x: x * scale, y: y * scale, width: width * scale, height: height * scale)
        }
        func page(rightColour: UIColor = .systemBlue, rule: Bool = false) throws -> CGImage {
            let format = UIGraphicsImageRendererFormat(); format.scale = 1
            return try #require(UIGraphicsImageRenderer(size: CGSize(width: 240 * scale, height: 300 * scale), format: format).image { ctx in
                UIColor.white.setFill(); ctx.fill(rect(0, 0, 240, 300))
                for y in stride(from: 60, through: 180, by: 12) {
                    UIColor.systemBlue.setFill(); ctx.fill(rect(60, CGFloat(y), 18, 6))
                }
                for y in stride(from: 144, through: 192, by: 6) {
                    rightColour.setFill(); ctx.fill(rect(108, CGFloat(y), 18, 3))
                }
                if rule { UIColor.black.setFill(); ctx.fill(rect(92, 135, 3, 70)) }
            }.cgImage)
        }
        func region(_ id: String, _ text: String, _ box: CGRect) -> ReaderTranslationRegion {
            let horizontal = id == "right" && horizontalReaction
            return ReaderTranslationRegion(id: id, rect: CGRect(x: box.minX / (240 * scale), y: box.minY / (300 * scale),
                width: box.width / (240 * scale), height: box.height / (300 * scale)), source: text,
                sourceOrientation: horizontal ? .horizontal : .vertical, sourceSingleVerticalColumn: !horizontal)
        }
        let left = region("left", "ちょ…っ", rect(55, 55, 30, 145))
        let right = region("right", "は?", rect(102, 140, 30, 60))
        let image = try page()
        for input in [[left, right], [right, left]] {
            let output = ReaderTranslationBalloonMerger.apply(input, image: image)
            #expect(output.map(\.source) == ["は?ちょ…っ"])
            #expect(output.first?.id == input.first?.id)
            #expect(output.first?.sourceSingleVerticalColumn == false)
        }
        #expect(ReaderTranslationBalloonMerger.apply([left, right], image: try page(rule: true)).count == 2)
        #expect(ReaderTranslationBalloonMerger.apply([left, right], image: try page(rightColour: .systemRed)).count == 2)
        let plain = region("right", "はい", rect(102, 140, 30, 60))
        #expect(ReaderTranslationBalloonMerger.apply([left, plain], image: image).count == 2)
        let quoted = region("right", "「は?」", rect(102, 140, 30, 60))
        #expect(ReaderTranslationBalloonMerger.apply([left, quoted], image: image).count == 2)
        let shifted = region("right", "は?", rect(102, 165, 30, 60))
        #expect(ReaderTranslationBalloonMerger.apply([left, shifted], image: image) == [left, shifted])
        let wide = region("right", "は?", rect(102, 180, 30, 20))
        #expect(ReaderTranslationBalloonMerger.apply([left, wide], image: image) == [left, wide])
        let middle = ReaderTranslationRegion(id: "middle", rect: CGRect(x: 90 / 240.0, y: 145 / 300.0, width: 5 / 240.0, height: 50 / 300.0), source: "別")
        #expect(ReaderTranslationBalloonMerger.apply([left, right, middle], image: image).count == 3)
    }

    @Test func overlappingTailRequiresOriginalLastColumnEvidence() throws {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let image = try #require(UIGraphicsImageRenderer(size: CGSize(width: 300, height: 400), format: format).image { ctx in
            UIColor.darkGray.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 300, height: 400))
            for x in [105, 135, 165] {
                for y in stride(from: 25, to: 340, by: 12) {
                    UIColor.white.setFill(); ctx.fill(CGRect(x: x, y: y, width: 10, height: 10))
                    UIColor.magenta.setFill(); ctx.fill(CGRect(x: x + 1, y: y + 1, width: 8, height: 8))
                }
            }
        }.cgImage)
        func region(_ id: String, _ text: String, _ y: CGFloat, _ h: CGFloat, single: Bool) -> ReaderTranslationRegion {
            ReaderTranslationRegion(id: id, rect: CGRect(x: 100.0 / 300, y: y / 400, width: (single ? 30.0 : 90.0) / 300, height: h / 400),
                source: text, confidence: 1, sourceImageAspectRatio: 0.75, sourceOrientation: .vertical, sourceSingleVerticalColumn: single)
        }
        let head = region("head", "本文最後の列", 20, 270, single: false)
        let tail = region("tail", "続き", 210, 130, single: true)
        let line = ReaderTranslationBalloonMerger.SourceLine(polygon: [CGPoint(x: 100, y: 20), CGPoint(x: 130, y: 20),
            CGPoint(x: 130, y: 185), CGPoint(x: 100, y: 185)], text: "最後の列", orientation: .vertical)
        // Previous rectangle-only rule leaves the cached shape split.
        #expect(ReaderTranslationBalloonMerger.apply([head, tail], image: image).count == 2)
        #expect(ReaderTranslationBalloonMerger.apply([head, tail], image: image, sourceLines: [line]).map(\.source) == ["本文最後の列続き"])
        // The first screenshot's internal short fragment never extends past the head.
        let internalFragment = region("inside", "別の断片", 150, 100, single: true)
        #expect(ReaderTranslationBalloonMerger.apply([head, internalFragment], image: image, sourceLines: [line]).count == 2)
        let unrelated = ReaderTranslationBalloonMerger.SourceLine(polygon: line.polygon, text: "別の文", orientation: .vertical)
        #expect(ReaderTranslationBalloonMerger.apply([head, tail], image: image, sourceLines: [unrelated]).count == 2)
    }

    @Test func outlinedCaptionInkMatchesAcrossColumnWidthsButRejectsOtherSpeakers() throws {
        func sample(_ second: UIColor, firstColour: UIColor = .magenta) -> CGImage {
            let format = UIGraphicsImageRendererFormat(); format.scale = 1
            return UIGraphicsImageRenderer(size: CGSize(width: 130, height: 200), format: format).image { context in
                UIColor.darkGray.setFill(); context.fill(CGRect(x: 0, y: 0, width: 130, height: 200))
                for (x, colour) in [(20, firstColour), (70, second), (90, second)] {
                    for y in stride(from: 15, to: 175, by: 12) {
                        UIColor.white.setFill(); context.fill(CGRect(x: CGFloat(x), y: CGFloat(y), width: 8, height: 8))
                        colour.setFill(); context.fill(CGRect(x: CGFloat(x + 1), y: CGFloat(y + 1), width: 6, height: 6))
                    }
                }
            }.cgImage!
        }
        let first = CGRect(x: 10, y: 10, width: 30, height: 175)
        let second = CGRect(x: 60, y: 10, width: 50, height: 175)
        #expect(ReaderTranslationBalloonMerger.matchingOutlinedInk(in: sample(.magenta), first: first, second: second))
        #expect(!ReaderTranslationBalloonMerger.matchingOutlinedInk(in: sample(.orange), first: first, second: second))
        #expect(!ReaderTranslationBalloonMerger.matchingOutlinedInk(in: sample(.gray), first: first, second: second))
        #expect(ReaderTranslationBalloonMerger.differentOutlinedInk(in: sample(.orange), first: first, second: second))
        #expect(!ReaderTranslationBalloonMerger.differentOutlinedInk(in: sample(.magenta), first: first, second: second))
        #expect(!ReaderTranslationBalloonMerger.differentOutlinedInk(in: sample(.gray), first: first, second: second))
        let softenedOrange = sample(UIColor(red: 1, green: 0.65, blue: 0.3, alpha: 1), firstColour: .orange)
        #expect(!ReaderTranslationBalloonMerger.differentOutlinedInk(in: softenedOrange, first: first, second: second))
        #expect(ReaderTranslationBalloonMerger.matchingOutlinedInk(in: softenedOrange, first: first, second: second))
    }

    private func image(_ boxes: [CGRect]) throws -> CGImage {
        let context = try #require(CGContext(data: nil, width: 400, height: 400,
            bitsPerComponent: 8, bytesPerRow: 400, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0))
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 400, height: 400))
        context.setStrokeColor(gray: 0, alpha: 1)
        context.setLineWidth(4)
        for box in boxes { context.stroke(box) }
        return try #require(context.makeImage())
    }
    private var columns: [ReaderTranslationRegion] {
        [ReaderTranslationRegion(id: "right", rect: CGRect(x: 0.51, y: 0.4, width: 0.05, height: 0.2),
            source: "明日の", sourceImageAspectRatio: 1, sourceOrientation: .vertical),
         ReaderTranslationRegion(id: "left", rect: CGRect(x: 0.42, y: 0.4, width: 0.05, height: 0.2),
            source: "予定は？", sourceImageAspectRatio: 1, sourceOrientation: .vertical)]
    }
    @Test func joinsEnclosedColumnsInJapaneseOrder() throws {
        let result = ReaderTranslationBalloonMerger.apply(columns,
            image: try image([CGRect(x: 145, y: 135, width: 100, height: 130)]))
        #expect(result.count == 1)
        #expect(result.first?.source == "明日の予定は？")
        #expect(result.first?.id == "right")
    }
    @Test func alignedColumnsOnTranslucentBalloonUseTheClearBridge() throws {
        let context = try #require(CGContext(data: nil, width: 400, height: 400,
            bitsPerComponent: 8, bytesPerRow: 400, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0))
        context.setFillColor(gray: 0.4, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 400, height: 400))
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 145, y: 135, width: 100, height: 130))
        // Artwork visible through one column breaks the white flood component,
        // while the actual inter-column gutter remains inside the balloon.
        context.setFillColor(gray: 0.8, alpha: 1)
        context.fill(CGRect(x: 203, y: 145, width: 35, height: 45))
        let result = ReaderTranslationBalloonMerger.apply(columns, image: try #require(context.makeImage()))
        #expect(result.count == 1)
        #expect(result.first?.source == "明日の予定は？")
        #expect(result.first?.id == "right")
    }
    @Test func narrowWhiteNeckDoesNotTurnTwoLobesIntoOneTextBlock() throws {
        let result = ReaderTranslationBalloonMerger.apply(columns, image: try image([
            CGRect(x: 145, y: 135, width: 100, height: 130),
            CGRect(x: 196, y: 135, width: 2, height: 50),
            CGRect(x: 196, y: 210, width: 2, height: 55)
        ]))
        #expect(result.map(\.id) == columns.map(\.id))
        #expect(result.map(\.source) == columns.map(\.source))
    }

    @Test func separateBalloonsAndOpenBackgroundDoNotJoin() throws {
        #expect(ReaderTranslationBalloonMerger.apply(columns, image: try image([])).count == 2)
        #expect(ReaderTranslationBalloonMerger.apply(columns, image: try image([
            CGRect(x: 158, y: 140, width: 38, height: 120),
            CGRect(x: 198, y: 140, width: 38, height: 120)])).count == 2)
    }
    @Test func interveningUnclassifiedColumnPreventsJoining() throws {
        var input = columns
        input.append(.init(id: "middle", rect: CGRect(x: 0.48, y: 0.42, width: 0.02, height: 0.1),
            source: "別の文", sourceImageAspectRatio: 1, sourceOrientation: .unknown))
        #expect(ReaderTranslationBalloonMerger.apply(input,
            image: try image([CGRect(x: 145, y: 135, width: 100, height: 130)])).count == 3)
    }
    @Test func tinyRubyColumnDoesNotJoin() throws {
        var input = columns
        input[1] = ReaderTranslationRegion(id: "ruby", rect: CGRect(x: 0.42, y: 0.4, width: 0.015, height: 0.2),
            source: "よてい", sourceImageAspectRatio: 1, sourceOrientation: .vertical)
        #expect(ReaderTranslationBalloonMerger.apply(input,
            image: try image([CGRect(x: 145, y: 135, width: 100, height: 130)])).count == 2)
    }
    @Test func brightBridgeJoinsMixedColumnBlocksButDarkRuleDoesNot() throws {
        let right = ReaderTranslationRegion(id: "right", rect: CGRect(x: 0.45, y: 0.3, width: 0.1, height: 0.2), source: "明日の予定を", sourceImageAspectRatio: 1, sourceOrientation: .vertical, sourceSingleVerticalColumn: false)
        let left = ReaderTranslationRegion(id: "left", rect: CGRect(x: 0.4, y: 0.32, width: 0.051, height: 0.25), source: "教えてください", sourceImageAspectRatio: 1, sourceOrientation: .vertical, sourceSingleVerticalColumn: true)
        #expect(ReaderTranslationBalloonMerger.apply([right, left], image: try image([])).count == 1)
        #expect(ReaderTranslationBalloonMerger.apply([right, left], image: try image([CGRect(x: 178, y: 80, width: 3, height: 200)])).count == 2)
    }

}
