import Testing
import UIKit
@testable import Aidoku

struct ReaderTranslationBalloonMergerTests {
    @Test(.enabled(if: FileManager.default.fileExists(atPath: URL.documentsDirectory.appendingPathComponent("blue-merge-source.png").path)))
    func capturedBlueBalloonJoinsShortStaggeredColumns() async throws {
        let folder = URL.documentsDirectory
        let image = try #require(UIImage(contentsOfFile: folder.appendingPathComponent("blue-merge-source.png").path)?.cgImage)
        let configuration = ReaderOCRConfiguration()
        let pipeline = NativeCoreMLOCRPipeline(modelTier: configuration.modelTier,
            detectorMaximumSide: configuration.detectorMaximumSide, recognizerMaximumWidth: configuration.recognizerMaximumWidth)
        let native = try await pipeline.recognize(image: image, requestID: UUID().uuidString,
            confidenceThreshold: configuration.confidenceThreshold,
            detectorConfiguration: configuration.detectorPostprocessConfiguration)
        let raw: [[String: Any]] = native.lines.map { ["text": $0.text, "polygon": $0.polygon.map { [$0.x, $0.y] },
            "orientation": String(describing: $0.orientation), "score": $0.score] }
        try JSONSerialization.data(withJSONObject: raw, options: .prettyPrinted)
            .write(to: folder.appendingPathComponent("blue-merge-raw.json"))
        let geometric = NativeOCRTextLineMerger.merge(native.lines, imageWidth: image.width, imageHeight: image.height)
        let geometry: [[String: Any]] = geometric.map { ["text": $0.text, "rect": [$0.boundingRect.minX,
            $0.boundingRect.minY, $0.boundingRect.width, $0.boundingRect.height], "orientation": String(describing: $0.sourceOrientation)] }
        try JSONSerialization.data(withJSONObject: geometry, options: .prettyPrinted)
            .write(to: folder.appendingPathComponent("blue-merge-geometry.json"))
        await pipeline.purgeResources()
        let regions = try await ReaderOCRService.shared.recognize(image: image, configuration: configuration)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(regions.map(ReaderTranslationStoredRegion.init))
            .write(to: folder.appendingPathComponent("blue-merge-regions.json"))
        let upper = regions.filter { $0.rect.midY * CGFloat(image.height) < 310 }
        #expect(upper.count == 1)
        #expect(upper.first?.source.contains("は") == true)
        #expect(upper.first?.source.contains("ちょ") == true)
        #expect(upper.first?.sourceSingleVerticalColumn == false)
        #expect(regions.contains { $0.rect.minY * CGFloat(image.height) > 350 && $0.source.contains("ストロー") })
        // The supplied translated screenshot has omitted leading dots and a
        // short right-hand box. Reconstruct those visible glyph bounds on the
        // original pixels; full-screenshot medium OCR above is a separate control.
        func fragment(_ id: String, _ text: String, _ box: CGRect) -> ReaderTranslationRegion {
            ReaderTranslationRegion(id: id, rect: CGRect(x: box.minX / CGFloat(image.width), y: box.minY / CGFloat(image.height),
                width: box.width / CGFloat(image.width), height: box.height / CGFloat(image.height)), source: text,
                sourceOrientation: .vertical, sourceSingleVerticalColumn: true)
        }
        let split = [fragment("reaction-left", "ちょ…っ", CGRect(x: 89, y: 138, width: 40, height: 145)),
                     fragment("reaction-right", "は!?", CGRect(x: 137, y: 213, width: 40, height: 72))]
            + regions.filter { $0.rect.minY * CGFloat(image.height) > 310 }
        let repaired = ReaderTranslationBalloonMerger.apply(split, image: image)
        #expect(repaired.count == split.count - 1)
        #expect(repaired.first?.source == "は!?ちょ…っ")
        #expect(repaired.first?.sourceSingleVerticalColumn == false)
        #expect(Array(repaired.dropFirst()) == Array(split.dropFirst(2)))
        try encoder.encode(split.map(ReaderTranslationStoredRegion.init))
            .write(to: folder.appendingPathComponent("blue-merge-split.json"))
        try encoder.encode(repaired.map(ReaderTranslationStoredRegion.init))
            .write(to: folder.appendingPathComponent("blue-merge-repaired.json"))
    }

    @Test(.enabled(if: FileManager.default.fileExists(atPath: URL.documentsDirectory.appendingPathComponent("gray-merge-source.png").path)))
    func capturedGrayBalloonKeepsAllThreeColumnsTogether() async throws {
        let folder = URL.documentsDirectory
        let screenshot = try #require(UIImage(contentsOfFile: folder.appendingPathComponent("gray-merge-source.png").path)?.cgImage)
        let image = screenshot
        let configuration = ReaderOCRConfiguration(confidenceThreshold: 0.2)
        let pipeline = NativeCoreMLOCRPipeline(modelTier: configuration.modelTier,
            detectorMaximumSide: configuration.detectorMaximumSide, recognizerMaximumWidth: configuration.recognizerMaximumWidth)
        let native = try await pipeline.recognize(image: image, requestID: UUID().uuidString, confidenceThreshold: configuration.confidenceThreshold)
        let raw: [[String: Any]] = native.lines.map { ["text": $0.text, "polygon": $0.polygon.map { [$0.x, $0.y] }, "orientation": String(describing: $0.orientation), "score": $0.score] }
        try JSONSerialization.data(withJSONObject: raw, options: .prettyPrinted).write(to: folder.appendingPathComponent("gray-merge-raw.json"))
        await pipeline.purgeResources()
        let regions = try await ReaderOCRService.shared.recognize(image: image, configuration: configuration)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(regions.map(ReaderTranslationStoredRegion.init)).write(to: folder.appendingPathComponent("gray-merge-regions.json"))
        let leftBalloon = regions.filter { $0.rect.midX < 0.3 && $0.rect.midY < 0.4 }
        #expect(leftBalloon.count == 1)
        #expect(leftBalloon.first?.source == "もうここには来ないんだから気にしなくていい")
        #expect(regions.count == 3)
    }

    @Test(arguments: [0.5, 1.0, 2.0])
    func shortColouredReactionsNeedMatchingInkAlignmentAndClearGutter(scale: CGFloat) throws {
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
            ReaderTranslationRegion(id: id, rect: CGRect(x: box.minX / (240 * scale), y: box.minY / (300 * scale),
                width: box.width / (240 * scale), height: box.height / (300 * scale)), source: text,
                sourceOrientation: .vertical, sourceSingleVerticalColumn: true)
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
        #expect(ReaderTranslationBalloonMerger.apply([left, shifted], image: image).count == 2)
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

    @Test(.enabled(if: FileManager.default.fileExists(atPath: URL.documentsDirectory.appendingPathComponent("DeviceSpeed/horizontal-source.png").path)))
    func capturedHorizontalBalloon() async throws {
        let directory = URL.documentsDirectory.appendingPathComponent("DeviceSpeed")
        let image = try #require(UIImage(contentsOfFile: directory.appendingPathComponent("horizontal-source.png").path)?.cgImage)
        let configuration = ReaderTranslationSettings().ocrConfiguration
        let pipeline = NativeCoreMLOCRPipeline(modelTier: configuration.modelTier,
            detectorMaximumSide: configuration.detectorMaximumSide, recognizerMaximumWidth: configuration.recognizerMaximumWidth)
        let native = try await pipeline.recognize(image: image, requestID: UUID().uuidString, confidenceThreshold: configuration.confidenceThreshold)
        let separator = NativeOCRRegionSeparator(image: image)
        let merged = NativeOCRTextLineMerger.merge(native.lines, imageWidth: image.width, imageHeight: image.height,
            separationCheck: { separator?.separates($0, $1, orientation: $2) ?? false })
        let raw: [[String: Any]] = native.lines.map { ["text": $0.text, "polygon": $0.polygon.map { [$0.x, $0.y] }, "orientation": String(describing: $0.orientation)] }
        let rows: [[String: Any]] = merged.map { ["text": $0.text, "box": [$0.boundingRect.minX, $0.boundingRect.minY, $0.boundingRect.width, $0.boundingRect.height]] }
        try JSONSerialization.data(withJSONObject: ["raw": raw, "merged": rows], options: .prettyPrinted)
            .write(to: directory.appendingPathComponent("horizontal-diagnostics.json"))
        #expect(merged.filter { $0.boundingRect.minY > 140 && $0.boundingRect.maxY < 250 }.map(\.text) == ["どしたん話聞こか？"])
        await pipeline.purgeResources()
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

    @Test(.enabled(if: FileManager.default.fileExists(atPath: URL.documentsDirectory.appendingPathComponent("MangaQuality/user-merge.png").path)))
    func capturedTranslucentBalloonJoinsOffsetLexicalColumns() throws {
        let image = try #require(UIImage(contentsOfFile: URL.documentsDirectory.appendingPathComponent("MangaQuality/user-merge.png").path)?.cgImage)
        // Actual detector boxes: the leading ellipsis of the right column was
        // not recognized, shifting its lexical top 71 px below the left one.
        let regions = [
            ReaderTranslationRegion(id: "left", rect: CGRect(x: 266/1290.0, y: 780/1824.0, width: 50/1290.0, height: 292/1824.0),
                source: "困ちいないよ", sourceOrientation: .vertical, sourceSingleVerticalColumn: true),
            ReaderTranslationRegion(id: "right", rect: CGRect(x: 318/1290.0, y: 851/1824.0, width: 47/1290.0, height: 393/1824.0),
                source: "確かに足は不自由だけど", sourceOrientation: .vertical, sourceSingleVerticalColumn: true)
        ]
        let result = ReaderTranslationBalloonMerger.apply(regions, image: image)
        #expect(result.count == 1)
        #expect(result.first?.source == "確かに足は不自由だけど困ちいないよ")
        #expect(result.first?.id == "left")
        // The lower lobe shares a flood component with the left column but
        // fails the text-block checks. It must not reserve that column.
        let lowerLobe = ReaderTranslationRegion(id: "lower-lobe",
            rect: CGRect(x: 116/1290.0, y: 992/1824.0, width: 93/1290.0, height: 351/1824.0),
            source: "私はあまりヒトと関わりたくないんだっ", sourceOrientation: .vertical, sourceSingleVerticalColumn: false)
        let full = ReaderTranslationBalloonMerger.apply(regions + [lowerLobe], image: image)
        #expect(full.count == 2)
        #expect(full.first?.source == "確かに足は不自由だけど困ちいないよ")
        #expect(full.last?.source == lowerLobe.source)
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
