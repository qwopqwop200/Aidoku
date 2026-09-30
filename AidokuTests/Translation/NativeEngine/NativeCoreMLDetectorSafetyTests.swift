import CoreGraphics
import Foundation
import XCTest
@testable import Aidoku
final class NativeCoreMLDetectorSafetyTests: XCTestCase {
    func testProbabilitySupportRecoversWeakEdgesWithoutChangingRecognitionBoxes() throws {
        let w = 128, h = 96
        var values = [Float](repeating: 0, count: w * h)
        for y in 20..<50 { for x in 20..<40 { values[y * w + x] = 0.92 } }
        for y in 28..<38 { for x in 40..<47 { values[y * w + x] = 0.2 } }
        for y in 31..<35 { for x in 49..<53 { values[y * w + x] = 0.4 } }
        for y in 80..<85 { for x in 110..<115 { values[y * w + x] = 0.4 } }
        let map = NativeCoreMLDetectionMap(width: w, height: h, values: values)
        let original = try NativeCoreMLDBPostprocessor.decode(map: map, sourceWidth: w, sourceHeight: h).boxes
        XCTAssertEqual(original.count, 1)
        let supported = try NativeCoreMLDBPostprocessor.addingErasureSupport(map: map, boxes: original, sourceWidth: w, sourceHeight: h)
        XCTAssertEqual(supported.map(\.polygon), original.map(\.polygon))
        XCTAssertEqual(supported.map(\.score), original.map(\.score))
        XCTAssertFalse(supported[0].erasurePolygons.isEmpty)
        XCTAssertTrue(supported[0].erasurePolygons.flatMap { $0 }.contains { $0.x >= 53 })
        XCTAssertFalse(supported[0].erasurePolygons.flatMap { $0 }.contains { $0.x >= 100 })
        XCTAssertThrowsError(try NativeCoreMLDBPostprocessor.addingErasureSupport(
            map: map, boxes: original, sourceWidth: w, sourceHeight: h, cancellationCheck: { throw CancellationError() }))
    }

    func testProbabilitySupportRetainsPartialMapSourceTransform() throws {
        var full = [Float](repeating: 0, count: 128 * 96)
        for y in 25..<55 { for x in 40..<62 { full[y * 128 + x] = 0.9 } }
        for y in 31..<45 { for x in 62..<67 { full[y * 128 + x] = 0.2 } }
        let map = NativeCoreMLDetectionMap(width: 128, height: 96, values: full)
        let boxes = try NativeCoreMLDBPostprocessor.decode(map: map, sourceWidth: 256, sourceHeight: 192).boxes
        let expected = try NativeCoreMLDBPostprocessor.addingErasureSupport(map: map, boxes: boxes, sourceWidth: 256, sourceHeight: 192)
        var crop: [Float] = []
        for y in 8..<72 { crop.append(contentsOf: full[(y * 128 + 16)..<(y * 128 + 80)]) }
        let actual = try NativeCoreMLDBPostprocessor.addingErasureSupport(
            map: .init(width: 64, height: 64, values: crop), boxes: boxes, sourceWidth: 256, sourceHeight: 192,
            geometry: .init(originX: 16, originY: 8, fullWidth: 128, fullHeight: 96))
        XCTAssertEqual(actual, expected)
    }

    func testErasureEvidenceSurvivesGroupingAndEncodingWithoutGrowingLayout() throws {
        let body = [CGPoint(x: 20, y: 20), CGPoint(x: 80, y: 20), CGPoint(x: 80, y: 50), CGPoint(x: 20, y: 50)]
        let support = [CGPoint(x: 76, y: 21), CGPoint(x: 96, y: 21), CGPoint(x: 96, y: 49), CGPoint(x: 76, y: 49)]
        let native = NativeCoreMLOCRLine(polygon: body, text: "HELLO", score: 0.99, orientation: .horizontal, erasurePolygons: [support])
        let grouped = try XCTUnwrap(NativeOCRTextLineMerger.merge([native], imageWidth: 140, imageHeight: 100).first)
        XCTAssertEqual(grouped.boundingRect, CGRect(x: 20, y: 20, width: 60, height: 30))
        XCTAssertTrue(grouped.auxiliaryInkPolygons.contains(support))
        let decoded = try JSONDecoder().decode(PaddleOCRLine.self, from: JSONEncoder().encode(grouped))
        XCTAssertEqual(decoded, grouped)
    }

    func testPipelinePassesThresholdChangesWithoutRecreatingModels() async throws {
        let frame = try XCTUnwrap(NativeOCRRGBAFrame(width: 16, height: 16, bytes: [UInt8](repeating: 255, count: 16 * 16 * 4)))
        let context = try XCTUnwrap(CGContext(data: nil, width: 16, height: 16, bitsPerComponent: 8,
                                            bytesPerRow: 64, space: CGColorSpaceCreateDeviceRGB(),
                                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = try XCTUnwrap(context.makeImage())
        let pipeline = NativeCoreMLOCRPipeline(detector: ThresholdProbeDetector(),
                                              postprocessConfiguration: .tiny, frameConverter: { _ in frame })
        let custom = ReaderOCRConfiguration(detectorPixelThreshold: 0.45, detectorConfidenceThreshold: 0.8, detectorMinimumBoxSide: 7)
            .detectorPostprocessConfiguration
        let operations: [() async throws -> NativeCoreMLOCRResult] = [
            { try await pipeline.recognize(image: image, requestID: "image", confidenceThreshold: 0.75,
                                           detectorConfiguration: custom) },
            { try await pipeline.recognize(frame: frame, requestID: "frame", confidenceThreshold: 0.75,
                                           detectorConfiguration: custom) },
            { try await pipeline.recognize(image: image, requestID: "image-scopes", confidenceThreshold: 0.75,
                                           detectorConfiguration: custom, recognitionScopes: [.zero]) },
            { try await pipeline.recognize(frame: frame, requestID: "frame-scopes", confidenceThreshold: 0.75,
                                           detectorConfiguration: custom, recognitionScopes: [.zero]) },
            { try await pipeline.recognize(frame: frame, requestID: "default", confidenceThreshold: 0.75) }
        ]
        for (index, operation) in operations.enumerated() {
            do {
                _ = try await operation()
                XCTFail("Expected the detector probe to capture this request")
            } catch let probe as ThresholdProbeResult {
                XCTAssertEqual(probe.configuration, index == 4 ? .tiny : custom)
            }
        }
    }

    func testMinimumDetectionSizeUsesMapPixelsAndCanRecoverSmallText() throws {
        let map = rectangularMap(width: 32, height: 32,
                                 rectangle: CGRect(x: 4, y: 4, width: 12, height: 3), foreground: 0.9)
        var settings = ReaderOCRConfiguration()
        for scale in [1, 10] {
            settings.detectorMinimumBoxSide = 3
            let original = try NativeCoreMLDBPostprocessor.decode(map: map, sourceWidth: 32 * scale, sourceHeight: 32 * scale,
                                                                 configuration: settings.detectorPostprocessConfiguration)
            XCTAssertTrue(original.boxes.isEmpty)
            settings.detectorMinimumBoxSide = 2
            let relaxed = try NativeCoreMLDBPostprocessor.decode(map: map, sourceWidth: 32 * scale, sourceHeight: 32 * scale,
                                                                configuration: settings.detectorPostprocessConfiguration)
            XCTAssertEqual(relaxed.boxes.count, 1)
        }
    }

    func testMinimumDetectionSizeAlsoControlsExpandedBoxGate() throws {
        let map = rectangularMap(width: 32, height: 32,
                                 rectangle: CGRect(x: 4, y: 4, width: 3, height: 3), foreground: 0.9)
        for minimum in [1.0, 2.0] {
            let settings = ReaderOCRConfiguration(detectorMinimumBoxSide: minimum)
            let result = try NativeCoreMLDBPostprocessor.decode(map: map, sourceWidth: 32, sourceHeight: 32,
                                                               configuration: settings.detectorPostprocessConfiguration)
            // Both candidates have a short side of 2. Expansion reaches 3.5;
            // the expanded gate retains its original minimum + 2 relationship.
            XCTAssertEqual(result.boxes.count, minimum == 1 ? 1 : 0)
        }
    }

    func testMinimumDetectionSizeAppliesToWeakSplitParts() throws {
        var pixels = [Float](repeating: 0, count: 64 * 100)
        fill(&pixels, mapWidth: 64, rectangle: CGRect(x: 4, y: 4, width: 10, height: 50), value: 0.95)
        fill(&pixels, mapWidth: 64, rectangle: CGRect(x: 20, y: 35, width: 10, height: 50), value: 0.95)
        fill(&pixels, mapWidth: 64, rectangle: CGRect(x: 13, y: 40, width: 8, height: 1), value: 0.95)
        let map = NativeCoreMLDetectionMap(width: 64, height: 100, values: pixels)
        for minimum in [3.0, 20.0] {
            let settings = ReaderOCRConfiguration(detectorMinimumBoxSide: minimum)
            let result = try NativeCoreMLDBPostprocessor.decode(map: map, sourceWidth: 64, sourceHeight: 100,
                                                               configuration: settings.detectorPostprocessConfiguration,
                                                               allowsWeakBridgeSplit: true)
            XCTAssertEqual(result.boxes.count, minimum == 3 ? 2 : 0)
        }
    }

    func testUserPixelAndRegionThresholdsFilterDifferentStages() throws {
        let map = rectangularMap(width: 32, height: 32,
                                 rectangle: CGRect(x: 4, y: 4, width: 12, height: 8), foreground: 0.5)
        func decode(_ settings: ReaderOCRConfiguration) throws -> NativeCoreMLDBPostprocessResult {
            try NativeCoreMLDBPostprocessor.decode(map: map, sourceWidth: 32, sourceHeight: 32,
                                                  configuration: settings.detectorPostprocessConfiguration)
        }
        var settings = ReaderOCRConfiguration()
        let rejectedRegion = try decode(settings)
        XCTAssertEqual(rejectedRegion.candidateComponents, 1)
        // Below the box threshold a component survives only as a weak box for adjacent-line recovery;
        // the pipeline never reads it in the primary pass.
        XCTAssertTrue(rejectedRegion.boxes.allSatisfy { $0.score < settings.detectorPostprocessConfiguration.boxThreshold })
        XCTAssertTrue(try NativeCoreMLDBPostprocessor.decode(
            map: map, sourceWidth: 32, sourceHeight: 32,
            configuration: settings.detectorPostprocessConfiguration.withRecoveryBoxThreshold(nil)).boxes.isEmpty)
        settings.detectorConfidenceThreshold = 0.45
        XCTAssertEqual(try decode(settings).boxes.count, 1)
        settings.detectorPixelThreshold = 0.55
        let rejectedPixels = try decode(settings)
        XCTAssertEqual(rejectedPixels.candidateComponents, 0)
        XCTAssertTrue(rejectedPixels.boxes.isEmpty)
        XCTAssertEqual(settings.confidenceThreshold, 0.75)
    }

    func testAdjacentLineRecoveryAdmitsOnlySiblingLinesOfAcceptedCaptions() {
        func column(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat) -> [CGPoint] {
            [CGPoint(x: x, y: y), CGPoint(x: x + width, y: y), CGPoint(x: x + width, y: y + height), CGPoint(x: x, y: y + height)]
        }
        func line(_ polygon: [CGPoint], _ text: String, vertical: Bool = true) -> NativeCoreMLOCRLine {
            NativeCoreMLOCRLine(polygon: polygon, text: text, score: 0.6, orientation: vertical ? .vertical : .horizontal)
        }
        let anchor = line(column(200, 100, 40, 200), "かよわいねぇ")
        let candidates = [
            line(column(250, 90, 40, 160), "元チャン様"), // sibling column one pitch to the right
            line(column(145, 120, 42, 140), "上着も"), // sibling column to the left
            line(column(330, 100, 40, 200), "遠いね"), // two pitches away: a neighbouring caption
            line(column(250, 400, 40, 160), "下の方"), // not side by side with the anchor
            line(column(250, 100, 90, 200), "大きな字"), // display lettering, 2x thicker
            line(column(250, 100, 18, 120), "るび"), // ruby-sized
            line(column(250, 150, 160, 40), "横書き", vertical: false), // other orientation
            line(column(250, 100, 40, 200), "ーき"), // stroke noise
            line(column(250, 100, 40, 200), "SALE") // Latin
        ]
        let admitted = NativeOCRAdjacentLineRecovery.admitted(candidates, anchors: [anchor]) { _, _, _ in false }
        XCTAssertEqual(admitted.map(\.text), ["元チャン様", "上着も"])
        // A balloon outline or another enclosed surface between the lines vetoes the recovery.
        XCTAssertTrue(NativeOCRAdjacentLineRecovery.admitted(candidates, anchors: [anchor]) { _, _, _ in true }.isEmpty)
        // A Latin sign is not a caption the lettering continues.
        XCTAssertTrue(NativeOCRAdjacentLineRecovery.admitted([candidates[0]], anchors: [line(anchor.polygon, "SAFE")]) { _, _, _ in
            false
        }.isEmpty)
        // A short or repeated sound effect is not a caption either.
        for sound in ["もしゃ", "もしゃもい", "ドキドキドキ"] {
            XCTAssertTrue(NativeOCRAdjacentLineRecovery.admitted([candidates[0]], anchors: [line(anchor.polygon, sound)]) { _, _, _ in
                false
            }.isEmpty)
        }
        // Recovery only extends one caption: a recovered line left on its own, a regrouping that joins two
        // captions, or an extension that crowds a neighbour keeps the base grouping.
        func region(_ id: String, _ source: String, _ rect: CGRect) -> ReaderTranslationRegion {
            ReaderTranslationRegion(id: id, rect: rect, source: source)
        }
        let bounds = CGRect(x: 0, y: 0, width: 1_000, height: 1_000)
        let base = [region("region-0", "かよわいねぇ", CGRect(x: 0.2, y: 0.1, width: 0.04, height: 0.2)),
                    region("region-1", "遠いね", CGRect(x: 0.4, y: 0.1, width: 0.04, height: 0.2))]
        let baseLines = [line(column(200, 100, 40, 200), "かよわいねぇ"), line(column(400, 100, 40, 200), "遠いね")]
        let recovered = [candidates[0]]
        let extended = region("region-5", "元チャン様かよわいねぇ", CGRect(x: 0.2, y: 0.09, width: 0.09, height: 0.21))
        let kept = NativeOCRAdjacentLineRecovery.extending(base, with: [extended, base[1]], baseLines: baseLines,
                                                          recovered: recovered, imageBounds: bounds)
        XCTAssertEqual(kept.map(\.id), ["region-0", "region-1"])
        XCTAssertEqual(kept[0].source, "元チャン様かよわいねぇ")
        let alone = [base[0], region("region-2", "元チャン様", CGRect(x: 0.25, y: 0.09, width: 0.04, height: 0.16)), base[1]]
        XCTAssertEqual(NativeOCRAdjacentLineRecovery.extending(base, with: alone, baseLines: baseLines, recovered: recovered,
                                                              imageBounds: bounds), base)
        let bridged = [region("region-0", "かよわいねぇ元チャン様遠いね", CGRect(x: 0.2, y: 0.09, width: 0.24, height: 0.21))]
        XCTAssertEqual(NativeOCRAdjacentLineRecovery.extending(base, with: bridged, baseLines: baseLines, recovered: recovered,
                                                              imageBounds: bounds), base)
        let neighbour = [base[0], region("region-1", "遠いね", CGRect(x: 0.3, y: 0.1, width: 0.04, height: 0.2))]
        let crowding = NativeOCRAdjacentLineRecovery.extending(
            neighbour, with: [extended, neighbour[1]], baseLines: [baseLines[0], line(column(300, 100, 40, 200), "遠いね")],
            recovered: recovered, imageBounds: bounds)
        XCTAssertEqual(crowding, neighbour)
        // A caption already touching its neighbour is not extended either.
        let touching = [base[0], region("region-1", "遠いね", CGRect(x: 0.29, y: 0.1, width: 0.04, height: 0.2))]
        XCTAssertEqual(NativeOCRAdjacentLineRecovery.extending(
            touching, with: [extended, touching[1]], baseLines: [baseLines[0], line(column(290, 100, 40, 200), "遠いね")],
            recovered: recovered, imageBounds: bounds), touching)
        // Watermark notices and Latin-mixed garble are never recovered or used as anchors.
        XCTAssertFalse(NativeOCRAdjacentLineRecovery.admits("無断転載禁止"))
        XCTAssertFalse(NativeOCRAdjacentLineRecovery.admits("白体 徒P5"))
        XCTAssertFalse(NativeOCRAdjacentLineRecovery.anchors("AI学習自作発言"))
        // A one-glyph anchor has no reading direction.
        XCTAssertTrue(NativeOCRAdjacentLineRecovery.admitted([candidates[0]], anchors: [line(column(200, 100, 40, 40), "字")]) { _, _, _ in
            false
        }.isEmpty)
        XCTAssertTrue(NativeOCRAdjacentLineRecovery.admits("死んじゃうよ!!"))
        XCTAssertFalse(NativeOCRAdjacentLineRecovery.admits("岛"))
    }

    func testLatinStackRecoveryCompletesCapitalLetteringOnly() {
        func row(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat) -> [CGPoint] {
            [CGPoint(x: x, y: y), CGPoint(x: x + width, y: y), CGPoint(x: x + width, y: y + height), CGPoint(x: x, y: y + height)]
        }
        func line(_ polygon: [CGPoint], _ text: String) -> NativeCoreMLOCRLine {
            NativeCoreMLOCRLine(polygon: polygon, text: text, score: 0.57, orientation: .horizontal)
        }
        // comic-8895: "SO" above "YOU CAN / TRUST / HIM." read at 0.57 (gate 0.75).
        let anchor = line(row(97, 415, 65, 19), "YOUI CAN")
        let candidates = [
            line(row(116, 400, 26, 17), "So"), // the dropped first row of the stack
            line(row(116, 360, 26, 17), "SO"), // two pitches above: another balloon
            line(row(116, 400, 26, 17), "1..."), // digits are not a lettering row
            line(row(116, 400, 26, 17), "もう"), // kana next to a Latin row is not recovered here
            line(row(90, 400, 90, 40), "BIG") // display lettering, 2x thicker
        ]
        let admitted = NativeOCRAdjacentLineRecovery.admitted(candidates, anchors: [anchor]) { _, _, _ in false }
        XCTAssertEqual(admitted.map(\.text), ["So"])
        XCTAssertTrue(NativeOCRAdjacentLineRecovery.admitted(candidates, anchors: [anchor]) { _, _, _ in true }.isEmpty)
        // Mixed-case anchors (brand labels, dialogue boxes) never pull in the small print around them.
        XCTAssertTrue(NativeOCRAdjacentLineRecovery.admitted(candidates, anchors: [line(anchor.polygon, "Old Town")]) { _, _, _ in
            false
        }.isEmpty)
        XCTAssertFalse(NativeOCRAdjacentLineRecovery.latinAnchors("NO AI TRAINING 無断転載禁止"))
        XCTAssertFalse(NativeOCRAdjacentLineRecovery.admitsLatin("THIS IS A LONG ROW"))
        XCTAssertTrue(NativeOCRAdjacentLineRecovery.admitsLatin("I..."))
    }

    func testGapLineRecoveryProposesOnlyInkColumnsOfTheFlanksStyle() {
        func column(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat) -> [CGPoint] {
            [CGPoint(x: x, y: y), CGPoint(x: x + width, y: y), CGPoint(x: x + width, y: y + height), CGPoint(x: x, y: y + height)]
        }
        // Glyph-like ink (bars in 30 px cells, 6 px leading) on light paper; columns at x 300 (A), 255 (gap), 210 (B).
        func glyph(_ x: Int, _ y: Int, left: Int, top: Int, bottom: Int) -> Bool {
            guard x >= left, x < left + 30, y >= top, y < bottom else { return false }
            let cellY = (y - top) % 36, cellX = x - left
            guard cellY < 30 else { return false }
            return (5..<10).contains(cellY) || (20..<25).contains(cellY) || (13..<18).contains(cellX)
        }
        func page(middle: @escaping (Int, Int) -> Int?) -> (Int, Int) -> Int {
            { x, y in
                if glyph(x, y, left: 300, top: 100, bottom: 316) || glyph(x, y, left: 210, top: 100, bottom: 316) { return 20 }
                return middle(x, y) ?? 240
            }
        }
        let lines = [NativeOCRGapLineRecovery.Line(polygon: column(294, 94, 42, 222), text: "水中発破の許可"),
                     NativeOCRGapLineRecovery.Line(polygon: column(204, 94, 42, 222), text: "なのに何で")]
        let missed = page { x, y in glyph(x, y, left: 255, top: 130, bottom: 280) ? 20 : nil }
        let proposals = NativeOCRGapLineRecovery.proposals(width: 1_000, height: 1_000, luminance: missed, lines: lines, blockers: [])
        XCTAssertEqual(proposals.count, 1)
        let box = NativeOCRScopeGeometry.bounds(for: proposals.first?.polygon ?? []) ?? .null
        XCTAssertEqual(box.midX, 270, accuracy: 4)
        XCTAssertEqual(box.minY, 124, accuracy: 8)
        XCTAssertEqual(box.maxY, 280, accuracy: 10)
        XCTAssertEqual(proposals.first?.flankTexts, ["水中発破の許可", "なのに何で"])
        // An empty gutter, tone/art on another surface, or a detector box already in the gap: no proposal.
        XCTAssertTrue(NativeOCRGapLineRecovery.proposals(width: 1_000, height: 1_000, luminance: page { _, _ in nil },
                                                         lines: lines, blockers: []).isEmpty)
        let art = page { x, y in (250..<290).contains(x) && (100..<316).contains(y) ? ((x + y) % 5 < 2 ? 20 : 130) : nil }
        XCTAssertTrue(NativeOCRGapLineRecovery.proposals(width: 1_000, height: 1_000, luminance: art, lines: lines, blockers: []).isEmpty)
        XCTAssertTrue(NativeOCRGapLineRecovery.proposals(width: 1_000, height: 1_000, luminance: missed, lines: lines,
                                                         blockers: [column(250, 130, 40, 150)]).isEmpty)
        // Short flanks only (no four-character caption line) are not a caption the gap continues.
        let short = lines.map { NativeOCRGapLineRecovery.Line(polygon: $0.polygon, text: "あっ") }
        XCTAssertTrue(NativeOCRGapLineRecovery.proposals(width: 1_000, height: 1_000, luminance: missed, lines: short, blockers: []).isEmpty)

        // Reads: Japanese as long as the ink, never a re-read of a flank, Latin, or a notice.
        let proposal = NativeOCRGapLineRecovery.Proposal(polygon: column(249, 124, 42, 160), vertical: true,
                                                         flanks: lines.map(\.polygon), flankTexts: lines.map(\.text))
        XCTAssertTrue(NativeOCRGapLineRecovery.accepts("が下りない筈", proposal: proposal))
        XCTAssertFalse(NativeOCRGapLineRecovery.accepts("水中発破の", proposal: proposal))
        XCTAssertFalse(NativeOCRGapLineRecovery.accepts("が", proposal: proposal))
        XCTAssertFalse(NativeOCRGapLineRecovery.accepts("SALE", proposal: proposal))
        XCTAssertFalse(NativeOCRGapLineRecovery.accepts("無断転載禁止", proposal: proposal))

        // A gap line may join its two flank captions (and only those) into one region.
        func line(_ polygon: [CGPoint], _ text: String) -> NativeCoreMLOCRLine {
            NativeCoreMLOCRLine(polygon: polygon, text: text, score: 0.9, orientation: .vertical)
        }
        let bounds = CGRect(x: 0, y: 0, width: 500, height: 500)
        let baseLines = [line(lines[0].polygon, lines[0].text), line(lines[1].polygon, lines[1].text)]
        let base = [ReaderTranslationRegion(id: "region-0", rect: CGRect(x: 0.588, y: 0.188, width: 0.084, height: 0.444),
                                            source: lines[0].text),
                    ReaderTranslationRegion(id: "region-1", rect: CGRect(x: 0.408, y: 0.188, width: 0.084, height: 0.444),
                                            source: lines[1].text)]
        let gap = NativeCoreMLOCRGapLine(line: line(proposal.polygon, "が下りない筈"), flanks: lines.map(\.polygon))
        let joined = [ReaderTranslationRegion(id: "region-0", rect: CGRect(x: 0.408, y: 0.188, width: 0.264, height: 0.444),
                                              source: "水中発破の許可が下りない筈なのに何で")]
        let bridged = NativeOCRAdjacentLineRecovery.extending(base, with: joined, baseLines: baseLines, recovered: [gap.line],
                                                             bridges: [gap], imageBounds: bounds)
        XCTAssertEqual(bridged.map(\.id), ["region-0"])
        XCTAssertEqual(bridged.first?.source, "水中発破の許可が下りない筈なのに何で")
        let completedFlanks = baseLines.map { original in
            let rect = NativeOCRScopeGeometry.bounds(for: original.polygon)!.insetBy(dx: -1, dy: -1)
            return line(column(rect.minX, rect.minY, rect.width, rect.height), original.text)
        }
        XCTAssertEqual(NativeOCRAdjacentLineRecovery.extending(base, with: joined, baseLines: completedFlanks,
            recovered: [gap.line], bridges: [gap], imageBounds: bounds), bridged)
        // Without the bridge (an adjacent-line recovery), joining two captions keeps the base grouping.
        XCTAssertEqual(NativeOCRAdjacentLineRecovery.extending(base, with: joined, baseLines: baseLines, recovered: [gap.line],
                                                              imageBounds: bounds), base)
        // A separated flank (balloon outline between) vetoes the gap line.
        XCTAssertTrue(NativeOCRGapLineRecovery.admitted([gap]) { _, _, _ in true }.isEmpty)
        XCTAssertEqual(NativeOCRGapLineRecovery.admitted([gap]) { _, _, _ in false }, [gap])
    }

    func testEdgeRecoveryRequiresCaptionPitchInkAndUnoccupiedPaper() {
        func column(_ x: CGFloat) -> [CGPoint] {
            [CGPoint(x: x, y: 94), CGPoint(x: x + 42, y: 94),
             CGPoint(x: x + 42, y: 316), CGPoint(x: x, y: 316)]
        }
        let lines = [NativeOCRGapLineRecovery.Line(polygon: column(204), text: "なのに何で"),
                     NativeOCRGapLineRecovery.Line(polygon: column(249), text: "水中発破の許可")]
        func page(_ missing: Bool, paper: Int = 240) -> (Int, Int) -> Int {
            { x, y in
                for left in missing ? [210, 255, 300] : [210, 255] {
                    if x >= left, x < left + 30, y >= 100, y < 316 {
                        let cy = (y - 100) % 36, cx = x - left
                        if cy < 30 && ((5..<10).contains(cy) || (20..<25).contains(cy) || (13..<18).contains(cx)) { return 20 }
                    }
                }
                return x >= 294 ? paper : 240
            }
        }
        let found = NativeOCRGapLineRecovery.edgeProposals(width: 1000, height: 1000,
            luminance: page(true), lines: lines, blockers: [])
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found.first?.edge, true)
        XCTAssertEqual(NativeOCRScopeGeometry.bounds(for: found.first?.polygon ?? [])?.midX ?? 0, 315, accuracy: 1)
        XCTAssertTrue(NativeOCRGapLineRecovery.edgeProposals(width: 1000, height: 1000,
            luminance: page(false), lines: lines, blockers: []).isEmpty)
        XCTAssertTrue(NativeOCRGapLineRecovery.edgeProposals(width: 1000, height: 1000,
            luminance: page(true, paper: 130), lines: lines, blockers: []).isEmpty)
        XCTAssertTrue(NativeOCRGapLineRecovery.edgeProposals(width: 1000, height: 1000,
            luminance: page(true), lines: lines, blockers: [column(294)]).isEmpty)
        let short = lines.map { NativeOCRGapLineRecovery.Line(polygon: $0.polygon, text: "あっ") }
        XCTAssertTrue(NativeOCRGapLineRecovery.edgeProposals(width: 1000, height: 1000,
            luminance: page(true), lines: short, blockers: []).isEmpty)
    }

    func testDBPostprocessFindsScoresAndUnclipsRectangle() throws {
        let map = rectangularMap(
            width: 64,
            height: 64,
            rectangle: CGRect(x: 10, y: 20, width: 20, height: 10),
            foreground: 0.9
        )

        let result = try NativeCoreMLDBPostprocessor.decode(
            map: map,
            sourceWidth: 64,
            sourceHeight: 64
        )

        XCTAssertEqual(result.candidateComponents, 1)
        let box = try XCTUnwrap(result.boxes.first)
        XCTAssertEqual(result.boxes.count, 1)
        XCTAssertEqual(box.score, 0.9, accuracy: 0.000_01)
        XCTAssertEqual(box.polygon.count, 4)
        XCTAssertEqual(box.polygon.map(\.x).min(), 5)
        XCTAssertEqual(box.polygon.map(\.x).max(), 34)
        XCTAssertEqual(box.polygon.map(\.y).min(), 15)
        XCTAssertEqual(box.polygon.map(\.y).max(), 34)
    }

    func testDBPostprocessUsesStrictMaskAndBoxThresholds() throws {
        let exactlyMaskThreshold = rectangularMap(
            width: 32,
            height: 32,
            rectangle: CGRect(x: 4, y: 4, width: 12, height: 8),
            foreground: 0.25
        )
        let belowBoxThreshold = rectangularMap(
            width: 32,
            height: 32,
            rectangle: CGRect(x: 4, y: 4, width: 12, height: 8),
            foreground: 0.5
        )
        let configuration = NativeCoreMLDBPostprocessConfiguration(
            threshold: 0.25,
            boxThreshold: 0.6,
            unclipRatio: 1.5,
            maximumCandidates: 3_000
        )

        let maskResult = try NativeCoreMLDBPostprocessor.decode(
            map: exactlyMaskThreshold,
            sourceWidth: 32,
            sourceHeight: 32,
            configuration: configuration
        )
        let scoreResult = try NativeCoreMLDBPostprocessor.decode(
            map: belowBoxThreshold,
            sourceWidth: 32,
            sourceHeight: 32,
            configuration: configuration
        )

        XCTAssertEqual(maskResult.candidateComponents, 0)
        XCTAssertTrue(maskResult.boxes.isEmpty)
        XCTAssertEqual(scoreResult.candidateComponents, 1)
        XCTAssertTrue(scoreResult.boxes.isEmpty)
    }

    func testDBPostprocessHonorsCandidateBound() throws {
        var values = [Float](repeating: 0, count: 64 * 64)
        for origin in [CGPoint(x: 2, y: 2), CGPoint(x: 20, y: 2), CGPoint(x: 38, y: 2)] {
            fill(
                &values,
                mapWidth: 64,
                rectangle: CGRect(origin: origin, size: CGSize(width: 5, height: 5)),
                value: 0.95
            )
        }
        let map = NativeCoreMLDetectionMap(
            width: 64,
            height: 64,
            values: values
        )
        let configuration = NativeCoreMLDBPostprocessConfiguration(
            threshold: 0.3,
            boxThreshold: 0.6,
            unclipRatio: 1.5,
            maximumCandidates: 2
        )

        let result = try NativeCoreMLDBPostprocessor.decode(
            map: map,
            sourceWidth: 64,
            sourceHeight: 64,
            configuration: configuration
        )

        XCTAssertEqual(result.candidateComponents, 2)
        XCTAssertEqual(result.boxes.count, 2)
    }

    func testDBRunSpansPreserveEightConnectedComponents() throws {
        var values = [Float](repeating: 0, count: 48 * 32)
        // These two blocks touch only at one diagonal pixel and therefore
        // belong to the same 8-connected component.
        fill(
            &values,
            mapWidth: 48,
            rectangle: CGRect(x: 3, y: 3, width: 6, height: 6),
            value: 0.95
        )
        fill(
            &values,
            mapWidth: 48,
            rectangle: CGRect(x: 9, y: 9, width: 6, height: 6),
            value: 0.95
        )
        // A separate component verifies that run expansion does not bridge a
        // true horizontal gap.
        fill(
            &values,
            mapWidth: 48,
            rectangle: CGRect(x: 28, y: 5, width: 8, height: 7),
            value: 0.95
        )
        let map = NativeCoreMLDetectionMap(
            width: 48,
            height: 32,
            values: values
        )

        let result = try NativeCoreMLDBPostprocessor.decode(
            map: map,
            sourceWidth: 48,
            sourceHeight: 32,
            configuration: NativeCoreMLDBPostprocessConfiguration(
                threshold: 0.3,
                boxThreshold: 0.2,
                unclipRatio: 1.5,
                maximumCandidates: 3_000
            )
        )

        XCTAssertEqual(result.candidateComponents, 2)
        XCTAssertEqual(result.boxes.count, 2)
    }

    func testLetteringUnitRecoveryFindsOnlyTheUnreadSameStyleHalfOnPaper() {
        typealias Unit = NativeOCRLetteringUnitRecovery
        func quad(_ rect: CGRect) -> [CGPoint] {
            [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
             CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.maxY)]
        }
        // A 400 x 200 white page. Glyphs: 36 px hollow squares with 5 px black strokes.
        let width = 400, height = 200
        func page(glyphs: [CGRect], hatch: CGRect? = nil) -> Unit.Pixel {
            { x, y in
                let point = CGPoint(x: CGFloat(x) + 0.5, y: CGFloat(y) + 0.5)
                for glyph in glyphs where glyph.contains(point) && !glyph.insetBy(dx: 5, dy: 5).contains(point) {
                    return (10, 10, 10)
                }
                if let hatch, hatch.contains(point), (x + y) % 6 < 2 { return (10, 10, 10) }
                return (250, 250, 250)
            }
        }
        let first = CGRect(x: 60, y: 80, width: 36, height: 36)
        let second = CGRect(x: 104, y: 80, width: 36, height: 36)
        // The page pass read the first glyph only; its box has the detector's margin.
        let anchor = Unit.Line(polygon: quad(first.insetBy(dx: -4, dy: -4)), text: "だ")
        let found = Unit.neighbours(width: width, height: height, pixel: page(glyphs: [first, second]), lines: [anchor],
                                    occupied: [first.insetBy(dx: -4, dy: -4)])
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found.first?.side, .after)
        XCTAssertFalse(found.first?.vertical ?? true)
        XCTAssertTrue(found.first.map { $0.ink.insetBy(dx: -2, dy: -2).contains(second) } ?? false)
        // Nothing unread next to it, the neighbour already read, or the neighbour inside hatching: no unit.
        XCTAssertTrue(Unit.neighbours(width: width, height: height, pixel: page(glyphs: [first]), lines: [anchor],
                                      occupied: [first.insetBy(dx: -4, dy: -4)]).isEmpty)
        XCTAssertTrue(Unit.neighbours(width: width, height: height, pixel: page(glyphs: [first, second]), lines: [anchor],
                                      occupied: [first.insetBy(dx: -4, dy: -4), second.insetBy(dx: -4, dy: -4)]).isEmpty)
        XCTAssertTrue(Unit.neighbours(width: width, height: height,
                                      pixel: page(glyphs: [first, second], hatch: CGRect(x: 98, y: 60, width: 80, height: 80)),
                                      lines: [anchor], occupied: [first.insetBy(dx: -4, dy: -4)]).isEmpty)
        // Grey artwork inside the unit's box (the erase would not be clean): no unit.
        let drawn: Unit.Pixel = { x, y in
            if (100...103).contains(x) && (100...118).contains(y) { return (120, 120, 120) }
            return page(glyphs: [first, second])(x, y)
        }
        XCTAssertTrue(Unit.neighbours(width: width, height: height, pixel: drawn, lines: [anchor],
                                      occupied: [first.insetBy(dx: -4, dy: -4)]).isEmpty)
        // Body-size Han lines and long lines are no anchors; display-size Han lines are.
        XCTAssertFalse(Unit.isAnchor("数学", glyph: 30, medianGlyph: 30))
        XCTAssertTrue(Unit.isAnchor("にぎ", glyph: 30, medianGlyph: 30))
        XCTAssertFalse(Unit.isAnchor("推し", glyph: 30, medianGlyph: 30))
        XCTAssertTrue(Unit.isAnchor("恋愛", glyph: 60, medianGlyph: 30))
        XCTAssertFalse(Unit.isAnchor("いえそんなことないです", glyph: 30, medianGlyph: 30))
        XCTAssertFalse(Unit.isAnchor("禁止", glyph: 90, medianGlyph: 30))

        // Unit reads: the anchor extended on the neighbour's side, in kana and marks for a kana anchor.
        XCTAssertTrue(Unit.completes("だら…", anchor: "だ", side: .after))
        XCTAssertTrue(Unit.completes("これがー", anchor: "これが", side: .after))
        XCTAssertTrue(Unit.completes("ははは", anchor: "はは", side: .after))
        XCTAssertFalse(Unit.completes("だ", anchor: "だ", side: .after))
        XCTAssertFalse(Unit.completes("らだ", anchor: "だ", side: .after))
        XCTAssertFalse(Unit.completes("セ也", anchor: "セ", side: .after))
        XCTAssertFalse(Unit.completes("第一", anchor: "第", side: .after))
        XCTAssertFalse(Unit.completes("次の日ー", anchor: "次の日", side: .after))
        XCTAssertTrue(Unit.completes("恋愛頭脳戦", anchor: "頭脳戦", side: .before))
        XCTAssertFalse(Unit.completes("フあのー", anchor: "あの", side: .after))
    }

    func testDBPostprocessChecksCancellationDuringWork() {
        let map = rectangularMap(
            width: 128,
            height: 128,
            rectangle: CGRect(x: 4, y: 4, width: 100, height: 100),
            foreground: 0.95
        )
        var checks = 0

        XCTAssertThrowsError(
            try NativeCoreMLDBPostprocessor.decode(
                map: map,
                sourceWidth: 128,
                sourceHeight: 128,
                cancellationCheck: {
                    checks += 1
                    if checks == 2 { throw CancellationError() }
                }
            )
        ) { error in
            XCTAssertTrue(error is CancellationError)
        }
    }

    func testIsolatedLineRecoveryAdmitsOnlyNearThresholdKanaReadsWithoutNeighbours() {
        func box(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat) -> [CGPoint] {
            [CGPoint(x: x, y: y), CGPoint(x: x + width, y: y), CGPoint(x: x + width, y: y + height), CGPoint(x: x, y: y + height)]
        }
        func read(_ index: Int, _ polygon: [CGPoint], _ text: String, _ confidence: Double) -> NativeCoreMLRecognizedRegion {
            NativeCoreMLRecognizedRegion(sourceIndex: index, polygon: polygon, text: text, confidence: confidence)
        }
        let accepted = [read(0, box(100, 100, 40, 200), "かよわいねぇ", 0.95)]
        let reads = [
            read(1, box(400, 100, 40, 120), "こら～!", 0.7), // a balloon of its own
            read(2, box(500, 100, 40, 80), "うう…", 0.62),
            read(3, box(600, 100, 40, 80), "まで!?", 0.5), // below the margin
            read(4, box(700, 100, 40, 80), "天皇", 0.7), // Han only on a kana page
            read(5, box(800, 100, 40, 80), "ABC", 0.7), // Latin
            read(6, box(900, 100, 40, 80), "第3話", 0.7), // digits
            read(7, box(100, 150, 40, 80), "ねぇ", 0.7), // overlaps an accepted line
            read(8, box(405, 110, 40, 100), "こら", 0.65), // overlaps a stronger candidate
            read(9, box(300, 500, 40, 80), "無断転載", 0.7) // notice
        ]
        let found = NativeOCRIsolatedLineRecovery.candidates(reads, threshold: 0.75, accepted: accepted, occupied: [])
        XCTAssertEqual(found.map(\.sourceIndex), [1, 2])
        XCTAssertTrue(NativeOCRIsolatedLineRecovery.candidates(reads, threshold: 0.75, accepted: accepted,
                                                               occupied: [box(400, 100, 40, 120), box(500, 100, 40, 80)]).isEmpty)
        // A Chinese page (no kana among accepted lines) admits Han reads, but not one Han character repeated.
        let chinese = [read(0, box(100, 100, 40, 200), "要丟不丟隨便你", 0.95)]
        let han = [read(1, box(400, 100, 40, 120), "唰啦", 0.7), read(2, box(500, 100, 40, 120), "国国", 0.7)]
        XCTAssertEqual(NativeOCRIsolatedLineRecovery.candidates(han, threshold: 0.75, accepted: chinese, occupied: []).map(\.sourceIndex), [1])
        // Dense low-quality handwriting (too many candidates on one page) recovers nothing.
        let many = (0..<7).map { read(10 + $0, box(CGFloat(1_000 + 60 * $0), 100, 40, 80), "あいう", 0.7) }
        XCTAssertEqual(NativeOCRIsolatedLineRecovery.candidates(Array(many.prefix(6)), threshold: 0.75,
                                                               accepted: accepted, occupied: []).map(\.sourceIndex), Array(10..<16))
        // The cap counts admitted non-overlapping reads, not raw candidates or duplicate detections.
        let duplicate = read(99, many[0].polygon, "あいう", 0.65)
        XCTAssertEqual(NativeOCRIsolatedLineRecovery.candidates(Array(many.prefix(6)) + [duplicate], threshold: 0.75,
                                                               accepted: accepted, occupied: []).count, 6)
        XCTAssertTrue(NativeOCRIsolatedLineRecovery.candidates(many, threshold: 0.75, accepted: accepted, occupied: []).isEmpty)

        // New captions never overlap an existing caption and take fresh ids.
        let existing = [
            ReaderTranslationRegion(id: "region-0", rect: CGRect(x: 0.1, y: 0.1, width: 0.04, height: 0.2), source: "かよわいねぇ"),
            ReaderTranslationRegion(id: "region-1", rect: CGRect(x: 0.2, y: 0.1, width: 0.04, height: 0.2), source: "上着も")
        ]
        let grouped = [ReaderTranslationRegion(id: "region-0", rect: CGRect(x: 0.4, y: 0.1, width: 0.04, height: 0.12), source: "こら～!"),
                       ReaderTranslationRegion(id: "region-1", rect: CGRect(x: 0.105, y: 0.15, width: 0.04, height: 0.1), source: "ねぇ")]
        let captions = NativeOCRIsolatedLineRecovery.captions(grouped, beside: existing)
        XCTAssertEqual(captions.map(\.source), ["こら～!"])
        XCTAssertEqual(captions.map(\.id), ["region-2"])
        // Recovered captions carry their flag through storage and into the overlay payload item.
        XCTAssertEqual(captions.map(\.isRecoveredLine), [true])
        XCTAssertTrue(ReaderTranslationStoredRegion(captions[0]).region.isRecoveredLine)
        XCTAssertFalse(ReaderTranslationStoredRegion(existing[0]).region.isRecoveredLine)
        XCTAssertTrue(captions[0].overlayItem(index: 0, imageSize: CGSize(width: 100, height: 100)).recoveredLine)
    }

    func testOpenPaperAdmitsTextOnPaperButNotOnArtwork() throws {
        // 400x400 white page: a dark glyph block on the paper at (60, 60), and one on a striped tone area at (260, 260).
        let context = try XCTUnwrap(CGContext(data: nil, width: 400, height: 400, bitsPerComponent: 8, bytesPerRow: 400,
                                              space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0))
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 400, height: 400))
        context.setFillColor(gray: 0.35, alpha: 1)
        for x in stride(from: 200, to: 400, by: 6) { context.fill(CGRect(x: x, y: 0, width: 3, height: 200)) }
        context.setFillColor(gray: 0, alpha: 1)
        // CoreGraphics has a bottom-left origin: y 330 here is image row 60.
        for y in stride(from: 300, to: 340, by: 10) { context.fill(CGRect(x: 62, y: y, width: 16, height: 3)) }
        for y in stride(from: 100, to: 140, by: 10) { context.fill(CGRect(x: 262, y: y, width: 16, height: 3)) }
        let image = try XCTUnwrap(context.makeImage())
        let map = ReaderTranslationEnclosedBackground.ComponentMap(image: image)
        XCTAssertTrue(map.onOpenPaper(CGRect(x: 60, y: 58, width: 20, height: 44)))
        XCTAssertFalse(map.onOpenPaper(CGRect(x: 260, y: 258, width: 20, height: 44)))
    }

    func testStackedRowSplitFindsOnlyShortLatinRowStacks() {
        func box(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat) -> [CGPoint] {
            [CGPoint(x: x, y: y), CGPoint(x: x + width, y: y), CGPoint(x: x + width, y: y + height), CGPoint(x: x, y: y + height)]
        }
        // Three centred lettered rows (letter-like bars, 20 px tall, 8 px leading) inside one box at (100, 100).
        func letters(_ x: Int, _ y: Int, rows: [(Int, Int)], top: Int) -> Bool {
            for (index, row) in rows.enumerated() {
                let rowTop = top + index * 28
                guard y >= rowTop, y < rowTop + 20, x >= row.0, x < row.1 else { continue }
                let cell = (x - row.0) % 14
                return cell < 3 || (cell < 11 && (y - rowTop < 3 || y - rowTop > 16))
            }
            return false
        }
        let stack: (Int, Int) -> Int = { x, y in letters(x, y, rows: [(110, 166), (104, 174), (116, 158)], top: 108) ? 20 : 240 }
        let proposals = NativeOCRStackedRowSplit.proposals(width: 1_000, height: 1_000, luminance: stack,
                                                             boxes: [(sourceIndex: 3, polygon: box(100, 100, 80, 96))])
        XCTAssertEqual(proposals.count, 1)
        XCTAssertEqual(proposals.first?.sourceIndex, 3)
        XCTAssertEqual(proposals.first?.rows.count, 3)
        let middle = NativeOCRScopeGeometry.bounds(for: proposals.first?.rows[1] ?? []) ?? .null
        XCTAssertEqual(middle.midY, 146, accuracy: 3)
        XCTAssertEqual(middle.minX, 101, accuracy: 4)
        // One vertical column of square glyphs (rows as tall as wide), a flat box or uniform tone: no proposal.
        let column: (Int, Int) -> Int = { x, y in
            guard x >= 110, x < 140, y >= 108 else { return 240 }
            let cell = (y - 108) % 36
            return cell < 30 && y < 108 + 36 * 4 && ((x - 110) % 10 < 3 || cell % 10 < 3) ? 20 : 240
        }
        XCTAssertTrue(NativeOCRStackedRowSplit.proposals(width: 1_000, height: 1_000, luminance: column,
                                                         boxes: [(sourceIndex: 1, polygon: box(104, 100, 42, 160))]).isEmpty)
        XCTAssertTrue(NativeOCRStackedRowSplit.proposals(width: 1_000, height: 1_000, luminance: { _, _ in 240 },
                                                         boxes: [(sourceIndex: 1, polygon: box(100, 100, 80, 96))]).isEmpty)
        XCTAssertTrue(NativeOCRStackedRowSplit.proposals(width: 1_000, height: 1_000, luminance: { x, y in (x + y) % 4 < 2 ? 20 : 240 },
                                                         boxes: [(sourceIndex: 1, polygon: box(100, 100, 80, 96))]).isEmpty)

        func read(_ text: String, _ confidence: Double) -> NativeCoreMLRecognizedRegion {
            NativeCoreMLRecognizedRegion(sourceIndex: 0, polygon: box(0, 0, 10, 10), text: text, confidence: confidence)
        }
        XCTAssertTrue(NativeOCRStackedRowSplit.accepts([read("I'LL", 0.95), read("SEE", 0.99), read("YOU!", 0.6)], threshold: 0.75))
        XCTAssertFalse(NativeOCRStackedRowSplit.accepts([read("I'LL", 0.95), nil], threshold: 0.75))
        XCTAssertFalse(NativeOCRStackedRowSplit.accepts([read("I'LL", 0.6), read("SEE", 0.6)], threshold: 0.75))
        XCTAssertFalse(NativeOCRStackedRowSplit.accepts([read("食べに", 0.95), read("SEE", 0.99)], threshold: 0.75))
        XCTAssertFalse(NativeOCRStackedRowSplit.accepts([read("400K", 0.95), read("SEE", 0.99)], threshold: 0.75))
        XCTAssertFalse(NativeOCRStackedRowSplit.accepts([read("I", 0.95), read("-", 0.99)], threshold: 0.75))
    }

    func fill(_ values: inout [Float], mapWidth: Int, rectangle: CGRect, value: Float) {
        for y in Int(rectangle.minY)..<Int(rectangle.maxY) {
            for x in Int(rectangle.minX)..<Int(rectangle.maxX) { values[y * mapWidth + x] = value }
        }
    }
    func rectangularMap(width: Int, height: Int, rectangle: CGRect, foreground: Float) -> NativeCoreMLDetectionMap {
        var values = [Float](repeating: 0, count: width * height)
        fill(&values, mapWidth: width, rectangle: rectangle, value: foreground)
        return NativeCoreMLDetectionMap(width: width, height: height, values: values)
    }
}

private struct ThresholdProbeResult: Error {
    let configuration: NativeCoreMLDBPostprocessConfiguration
}

private final class ThresholdProbeDetector: NativeCoreMLDetecting {
    func detect(frame: NativeOCRRGBAFrame, requestID: String, configuration: NativeCoreMLDBPostprocessConfiguration,
                cancellationCheck: @escaping @Sendable () throws -> Void) async throws -> NativeCoreMLDetectionResult {
        try cancellationCheck()
        throw ThresholdProbeResult(configuration: configuration)
    }
    func cancelCurrent() {}
    func purgeResources() async {}
}

extension NativeCoreMLDetectorSafetyTests {
    func bridgeMap(extra: Bool = false) -> NativeCoreMLDetectionMap {
        var v = [Float](repeating: 0, count: 140 * 210)
        fill(&v, mapWidth: 140, rectangle: CGRect(x: 10, y: 10, width: 20, height: 101), value: 0.95)
        fill(&v, mapWidth: 140, rectangle: CGRect(x: 44, y: 70, width: 20, height: 101), value: 0.95)
        fill(&v, mapWidth: 140, rectangle: CGRect(x: 29, y: 80, width: 16, height: 1), value: 0.95)
        if extra { fill(&v, mapWidth: 140, rectangle: CGRect(x: 100, y: 185, width: 11, height: 16), value: 0.95) }
        return NativeCoreMLDetectionMap(width: 140, height: 210, values: v)
    }
    func testWeakSplitDefaultDisabledAndExplicitBudget() throws {
        let map = bridgeMap(extra: true)
        let config = NativeCoreMLDBPostprocessConfiguration(threshold: 0.3, boxThreshold: 0.6, unclipRatio: 1.5, maximumCandidates: 2)
        let disabled = try NativeCoreMLDBPostprocessor.decode(map: map, sourceWidth: 140, sourceHeight: 210, configuration: config)
        let enabled = try NativeCoreMLDBPostprocessor.decode(map: map, sourceWidth: 140, sourceHeight: 210, configuration: config, allowsWeakBridgeSplit: true)
        XCTAssertEqual(disabled.boxes.count, 1)
        XCTAssertEqual(enabled.boxes.count, 2)
        XCTAssertEqual(enabled.candidateComponents, 2)
    }
    func testWeakSplitDirtyWindowParity() throws {
        let map = bridgeMap()
        let full = try NativeCoreMLDBPostprocessor.decode(map: map, sourceWidth: 140, sourceHeight: 210, allowsWeakBridgeSplit: true)
        var values: [Float] = []
        for y in 5..<180 { values += Array(map.values[(y * 140 + 5)..<(y * 140 + 70)]) }
        let local = try NativeCoreMLDBPostprocessor.decode(map: .init(width: 65, height: 175, values: values), sourceWidth: 140, sourceHeight: 210, geometry: .init(originX: 5, originY: 5, fullWidth: 140, fullHeight: 210), allowsWeakBridgeSplit: true)
        XCTAssertEqual(full, local)
    }
    func testWeakSplitAdditionalScansPropagateCancellation() throws {
        let w = 1100, h = 1600
        var values = [Float](repeating: 0, count: w * h)
        for y in 0..<h { for x in 0..<1040 where (x < 400 || x >= 640) && (x + y) % 2 == 0 { values[y * w + x] = 0.95 } }
        for x in 399...641 { values[800 * w + x] = 0.95 }
        var checks = 0
        XCTAssertThrowsError(try NativeCoreMLDBPostprocessor.decode(map: .init(width: w, height: h, values: values), sourceWidth: w, sourceHeight: h, allowsWeakBridgeSplit: true, cancellationCheck: {
            checks += 1
            if checks == 1000 { throw CancellationError() }
        })) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertEqual(checks, 1000)
    }
    func inside(_ p: CGPoint, polygon: [CGPoint], tolerance: Double = 1.5) -> Bool {
        var signs: [Double] = []
        for i in 0..<4 {
            let a = polygon[i], b = polygon[(i + 1) % 4]
            let cross = Double((b.x-a.x)*(p.y-a.y)-(b.y-a.y)*(p.x-a.x))
            let length = hypot(Double(b.x-a.x), Double(b.y-a.y))
            signs.append(cross / max(1, length))
        }
        return signs.allSatisfy { $0 >= -tolerance } || signs.allSatisfy { $0 <= tolerance }
    }
    func testRotatedWeakSplitsAreConvexNonzeroAndContainLobes() throws {
        let original = bridgeMap(); var exercised = 0
        for degrees in [-10.0, -5, 0, 5, 10] {
            let angle = degrees * .pi / 180, c = cos(angle), s = sin(angle)
            let n = 320
            var values = [Float](repeating: 0, count: n * n)
            var lobePoints: [CGPoint] = []
            for y in 0..<n { for x in 0..<n {
                let dx = Double(x)-160, dy = Double(y)-160
                let ox = Int((dx*c+dy*s+37).rounded()), oy = Int((-dx*s+dy*c+90).rounded())
                if ox >= 0 && ox < original.width && oy >= 0 && oy < original.height {
                    values[y*n+x] = original.values[oy*original.width+ox]
                    if (10...29).contains(ox) && (10...110).contains(oy) || (44...63).contains(ox) && (70...170).contains(oy) { lobePoints.append(CGPoint(x:x,y:y)) }
                }
            } }
            let result = try NativeCoreMLDBPostprocessor.decode(map: .init(width:n,height:n,values:values), sourceWidth:n,sourceHeight:n,allowsWeakBridgeSplit:true)
            if result.boxes.count != 2 { continue }
            exercised += 1
            for box in result.boxes {
                XCTAssertEqual(box.polygon.count,4)
                var area: CGFloat = 0, crosses: [CGFloat] = []
                for i in 0..<4 {
                    let a=box.polygon[i], b=box.polygon[(i+1)%4], c=box.polygon[(i+2)%4]
                    area += a.x*b.y-b.x*a.y
                    crosses.append((b.x-a.x)*(c.y-b.y)-(b.y-a.y)*(c.x-b.x))
                    XCTAssertTrue(a.x.isFinite && a.y.isFinite && a.x>=0 && a.y>=0 && a.x<=CGFloat(n) && a.y<=CGFloat(n))
                }
                XCTAssertGreaterThan(abs(area),1)
                XCTAssertTrue(crosses.allSatisfy{$0>=0} || crosses.allSatisfy{$0<=0})
            }
            XCTAssertTrue(lobePoints.allSatisfy { point in result.boxes.contains { inside(point,polygon:$0.polygon) } }, "Lobe clipped at angle \(degrees)")
        }
        XCTAssertGreaterThanOrEqual(exercised,3)
    }
}
