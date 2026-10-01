import CoreGraphics
import Foundation
import Testing
@testable import Aidoku

// swiftlint:disable large_tuple

// swiftlint:disable:next type_body_length
struct NativeOCRRegionSeparatorTests {
    private let left = CGRect(x: 10, y: 10, width: 12, height: 100)
    private let right = CGRect(x: 28, y: 10, width: 12, height: 100)

    private func map(background: UInt8 = 255, ink: (Int, Int) -> UInt8?) -> NativeOCRRegionSeparator {
        let width = 140, height = 140
        var bytes = [UInt8](repeating: background, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                if let value = ink(x, y) { bytes[y * width + x] = value }
            }
        }
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8,
            bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue), provider: provider,
            decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        return NativeOCRRegionSeparator(image: image)!
    }

    @Test func geometryRejectionsDoNotRasterizeAndLaterValidQueryStillFindsRule() {
        let separator = map { x, _ in x == 25 ? 0 : nil }
        #expect(!separator.hasRasterizedImage)
        #expect(!separator.separates(left, right, orientation: .unknown))
        #expect(!separator.separates(left, left.offsetBy(dx: 5, dy: 0), orientation: .vertical))
        #expect(!separator.separates(left, right.offsetBy(dx: 60, dy: 0), orientation: .vertical))
        #expect(!separator.hasRasterizedImage)
        #expect(separator.separates(left, right, orientation: .vertical))
        #expect(separator.hasRasterizedImage)
        #expect(separator.separates(right, left, orientation: .vertical))
    }

    @Test func longThinVerticalRuleSeparatesBothInputOrders() {
        let separator = map { x, _ in x == 25 ? 0 : nil }
        #expect(separator.separates(left, right, orientation: .vertical))
        #expect(separator.separates(right, left, orientation: .vertical))
    }

    @Test func horizontalRuleUsesOriginalImageAxes() {
        let separator = map { _, y in y == 25 ? 0 : nil }
        let upper = CGRect(x: 10, y: 10, width: 100, height: 12)
        let lower = CGRect(x: 10, y: 28, width: 100, height: 12)
        #expect(separator.separates(upper, lower, orientation: .horizontal))
        #expect(!separator.separates(left, right, orientation: .vertical))
    }

    @Test func darkCGBackgroundIsNotASeparator() {
        let separator = map(background: 0) { _, _ in nil }
        #expect(!separator.separates(left, right, orientation: .vertical))
    }

    @Test func broadInkAndOneSidedBoundaryRemainUncertain() {
        let broad = map { x, _ in (23...27).contains(x) ? 0 : nil }
        let oneSided = map { x, _ in x >= 25 ? 0 : nil }
        #expect(!broad.separates(left, right, orientation: .vertical))
        #expect(!oneSided.separates(left, right, orientation: .vertical))
    }

    @Test func shortGlyphStrokeIsNotASeparator() {
        let separator = map { x, y in x == 25 && (45...65).contains(y) ? 0 : nil }
        #expect(!separator.separates(left, right, orientation: .vertical))
    }

    @Test func ruleMustLieBetweenTheActualSourceBoxes() {
        let separator = map { x, _ in x == 80 ? 0 : nil }
        #expect(!separator.separates(left, right, orientation: .vertical))
    }

    @Test func unknownOrientationAndOverlappingColumnsStayUnchanged() {
        let separator = map { x, _ in x == 25 ? 0 : nil }
        #expect(!separator.separates(left, right, orientation: .unknown))
        #expect(!separator.separates(left, left.offsetBy(dx: 5, dy: 0), orientation: .vertical))
    }

    @Test func horizontalFrameSeparatesVerticalContinuationAcrossPanels() {
        let upper = CGRect(x: 40, y: 10, width: 20, height: 40)
        let lower = CGRect(x: 40, y: 66, width: 20, height: 50)
        let separator = map { _, y in (56...58).contains(y) ? 0 : nil }
        #expect(separator.separates(upper, lower, orientation: .vertical))
        #expect(separator.separates(lower, upper, orientation: .vertical))
        let lines = [upper, lower].enumerated().map { index, box in
            NativeCoreMLOCRLine(polygon: [CGPoint(x: box.minX, y: box.minY), CGPoint(x: box.maxX, y: box.minY),
                CGPoint(x: box.maxX, y: box.maxY), CGPoint(x: box.minX, y: box.maxY)],
                text: index == 0 ? "強盗みたい" : "あったかな", score: 0.99, orientation: .vertical)
        }
        #expect(NativeOCRTextLineMerger.merge(lines, imageWidth: 140, imageHeight: 140).count == 1)
        let guarded = NativeOCRTextLineMerger.merge(lines, imageWidth: 140, imageHeight: 140,
            separationCheck: { separator.separates($0, $1, orientation: $2) })
        #expect(guarded.map(\.text) == lines.map(\.text))
    }

    @Test func verticalContinuationWithoutFullBrightSidedRuleStaysConnected() {
        let upper = CGRect(x: 40, y: 10, width: 20, height: 40)
        let lower = CGRect(x: 40, y: 66, width: 20, height: 50)
        let blank = map { _, _ in nil }
        let stroke = map { x, y in y == 56 && x < 47 ? 0 : nil }
        let broad = map { _, y in (51...64).contains(y) ? 0 : nil }
        let dark = map(background: 0) { _, _ in nil }
        for separator in [blank, stroke, broad, dark] {
            #expect(!separator.separates(upper, lower, orientation: .vertical))
        }
    }

    @Test func cancelledQueryDoesNotAddSeparationEvidence() async {
        let separator = map { x, _ in x == 25 ? 0 : nil }
        let first = left, second = right
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return separator.separates(first, second, orientation: .vertical)
        }
        #expect(await task.value == false)
        #expect(!separator.hasRasterizedImage)
    }

    @Test func separatorVetoPreservesTextAndDefaultMergeContract() {
        let lines = [left, right].enumerated().map { index, box in
            NativeCoreMLOCRLine(polygon: [CGPoint(x: box.minX, y: box.minY), CGPoint(x: box.maxX, y: box.minY),
                CGPoint(x: box.maxX, y: box.maxY), CGPoint(x: box.minX, y: box.maxY)],
                text: index == 0 ? "左側の文章" : "右側の文章", score: 0.99,
                orientation: .vertical, orientationIsEstimated: false, sourceTileBounds: nil)
        }
        let separator = map { x, _ in x == 25 ? 0 : nil }
        let baseline = NativeOCRTextLineMerger.merge(lines, imageWidth: 140, imageHeight: 140)
        let guarded = NativeOCRTextLineMerger.merge(lines, imageWidth: 140, imageHeight: 140,
            separationCheck: { separator.separates($0, $1, orientation: $2) })
        #expect(baseline.count == 1)
        #expect(guarded.count == 2)
        #expect(Set(guarded.map(\.text)) == Set(lines.map(\.text)))
    }

    private func grayImage(width: Int, height: Int, background: UInt8, ink: (Int, Int) -> UInt8?) -> CGImage {
        var bytes = [UInt8](repeating: background, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                if let value = ink(x, y) { bytes[y * width + x] = value }
            }
        }
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8,
                       bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue), provider: provider,
                       decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }

    @Test func enclosedComponentMapSeparatesOnlyNeighbouringBalloons() {
        // Two touching outlined balloons; the shared border is not one straight page-long rule.
        func outline(_ x: Int, _ y: Int, _ box: (Int, Int, Int, Int)) -> Bool {
            let (x0, y0, x1, y1) = box
            guard (x0...x1).contains(x), (y0...y1).contains(y) else { return false }
            return x - x0 < 2 || x1 - x < 2 || y - y0 < 2 || y1 - y < 2
        }
        let image = grayImage(width: 300, height: 220, background: 200) { x, y in
            if outline(x, y, (20, 20, 141, 190)) || outline(x, y, (140, 50, 280, 200)) { return 0 }
            if (22...139).contains(x) && (22...188).contains(y) { return 255 }
            if (142...278).contains(x) && (52...198).contains(y) { return 255 }
            // Unenclosed white page margin along the right edge.
            if x >= 285 && y >= 80 { return 255 }
            return nil
        }
        let map = ReaderTranslationEnclosedBackground.ComponentMap(image: image)
        let first = CGRect(x: 110, y: 40, width: 20, height: 120)
        let second = CGRect(x: 80, y: 40, width: 20, height: 120)
        let neighbour = CGRect(x: 152, y: 70, width: 20, height: 110)
        #expect(map.separates(first, neighbour))
        #expect(map.separates(neighbour, second))
        #expect(!map.separates(first, second))
        // Page background and boxes crossing an outline abstain.
        #expect(!map.separates(first, CGRect(x: 285, y: 20, width: 10, height: 60)))
        #expect(!map.separates(CGRect(x: 130, y: 60, width: 20, height: 100), first))
        // Lettering on the page beside a balloon is not part of that balloon's text.
        let margin = CGRect(x: 287, y: 100, width: 10, height: 80)
        #expect(map.component(of: margin) == nil)
        #expect(map.separates(neighbour, margin))
    }

    @Test func nestedBalloonOpenAtTheImageEdgeSeparatesFromTheOuterBalloon() {
        // A small oval balloon drawn over a larger one (diverse2-3055): both papers run off the image
        // edge, so neither is an enclosing component, but the oval outline still separates the texts.
        let image = grayImage(width: 240, height: 260, background: 190) { x, y in
            let dx = Double(x - 30) / 75, dy = Double(y - 140) / 85
            let d = dx * dx + dy * dy
            if (0.93...1.07).contains(d) { return 0 }
            if d < 0.93 { return 255 }
            if (70...225).contains(x) && y <= 180 { return x <= 72 || x >= 223 || y >= 178 ? 0 : 255 }
            return nil
        }
        let map = ReaderTranslationEnclosedBackground.ComponentMap(image: image)
        let inner = CGRect(x: 20, y: 110, width: 22, height: 70)
        let outer = CGRect(x: 150, y: 40, width: 22, height: 110)
        let outerNext = CGRect(x: 185, y: 40, width: 22, height: 110)
        #expect(map.component(of: inner) == nil)
        #expect(map.component(of: outer) == nil)
        #expect(map.separates(inner, outer))
        #expect(map.separates(outerNext, inner))
        #expect(!map.separates(outer, outerNext))
    }

    @Test func speedLineWedgesAreNotBalloons() {
        // Radial speed lines split white paper into long wedges: not balloon-shaped, so no veto.
        let image = grayImage(width: 240, height: 260, background: 255) { x, y in
            for angle: Double in [20, 35, 50, 65] {
                let t = angle * .pi / 180
                if abs(-sin(t) * Double(x) + cos(t) * Double(y)) <= 1.2 { return 0 }
            }
            return nil
        }
        let map = ReaderTranslationEnclosedBackground.ComponentMap(image: image)
        #expect(!map.separates(CGRect(x: 155, y: 139, width: 16, height: 16), CGRect(x: 112, y: 176, width: 16, height: 16)))
    }

    @Test func lightLetteringHaloIsNotABalloon() {
        // Dark artwork with light outlines around two columns of glyph ink.
        let image = grayImage(width: 200, height: 200, background: 40) { x, y in
            for x0 in [40, 100] where (x0...(x0 + 30)).contains(x) && (30...170).contains(y) {
                return (x0 + 5...x0 + 25).contains(x) && (35...165).contains(y) ? 0 : 255
            }
            return nil
        }
        let map = ReaderTranslationEnclosedBackground.ComponentMap(image: image)
        #expect(!map.separates(CGRect(x: 45, y: 35, width: 20, height: 130), CGRect(x: 105, y: 35, width: 20, height: 130)))
    }

    @Test func balloonInteriorMeasuresThePaperAroundOneColumn() throws {
        // A tall elliptical balloon around one text column, a box holding two columns, and a light
        // halo around lettering on dark artwork.
        let image = grayImage(width: 400, height: 300, background: 60) { x, y in
            let dx = Double(x - 100) / 70, dy = Double(y - 150) / 120, r = dx * dx + dy * dy
            if r <= 1 { return r > 0.92 ? 0 : (abs(x - 100) < 8 && (80...220).contains(y) && y % 6 < 4 ? 0 : 255) }
            if (230...330).contains(x) && (40...260).contains(y) {
                if x < 233 || x > 327 || y < 43 || y > 257 { return 0 }
                return (x % 40 < 12 && (60...240).contains(y) && y % 6 < 4) ? 0 : 255
            }
            if (350...390).contains(x) && (40...200).contains(y) { return (355...385).contains(x) && (45...195).contains(y) ? 0 : 255 }
            return nil
        }
        let map = ReaderTranslationEnclosedBackground.ComponentMap(image: image)
        let column = CGRect(x: 92, y: 78, width: 16, height: 144)
        let pair = [CGRect(x: 238, y: 58, width: 14, height: 184), CGRect(x: 278, y: 58, width: 14, height: 184)]
        let halo = CGRect(x: 355, y: 45, width: 30, height: 150)
        let interiors = map.balloonInteriors(of: [column] + pair + [halo], candidates: [true, true, true, true])
        let interior = try #require(interiors[0])
        // The paper runs across the balloon, well beyond the OCR column, and stops at the outline.
        let spans = stride(from: 0, to: interior.spans.count, by: 2).map { (interior.spans[$0], interior.spans[$0 + 1]) }
        let middle = spans[spans.count / 2]
        #expect(middle.0 * 400 < 50 && middle.0 * 400 > 30 && middle.1 * 400 > 150 && middle.1 * 400 < 170)
        #expect(spans.first!.1 - spans.first!.0 < middle.1 - middle.0)
        #expect(abs(interior.center.x * 400 - 100) < 4 && abs(interior.center.y * 300 - 150) < 6)
        // Two captions share the box: one interior measured around both; a halo on artwork is not a balloon.
        #expect(interior.members == nil)
        let shared = try #require(interiors[1])
        #expect(shared.members == 2 && interiors[2] == shared && interiors[3] == nil)
        #expect(abs(shared.center.x * 400 - 280) < 6 && shared.rect.minX * 400 < 236 && shared.rect.maxX * 400 > 324)
        // Non-candidates get none, and a crop that holds the balloon keeps its shape.
        #expect(map.balloonInteriors(of: [column], candidates: [false]) == [nil])
        let crop = CGRect(x: 0, y: 0, width: 0.5, height: 1)
        let cropped = try #require(interior.cropped(to: crop))
        #expect(abs(cropped.rect.width - interior.rect.width * 2) < 0.000_1 && abs(cropped.center.x - interior.center.x * 2) < 0.000_1)
        #expect(interior.cropped(to: CGRect(x: 0.5, y: 0, width: 0.5, height: 1)) == nil)
    }

    @Test func sharedBalloonInteriorKeepsJoinedLobesApart() throws {
        // Two round lobes joined by a narrow neck, one column in each: two balloons, not one unit.
        // A third balloon holds two columns side by side in one lobe: one unit.
        let image = grayImage(width: 420, height: 260, background: 60) { x, y in
            func lobe(_ cx: Double, _ cy: Double, _ r: Double) -> Double { (Double(x) - cx) * (Double(x) - cx) / (r * r) +
                (Double(y) - cy) * (Double(y) - cy) / (r * r) }
            let a = lobe(70, 90, 55), b = lobe(170, 170, 55)
            let neck = abs(Double(x - 120) - Double(y - 130)) < 12 && (95...145).contains(x)
            if a <= 1 || b <= 1 || neck {
                if (a <= 1 && a > 0.9) || (b <= 1 && b > 0.9) { return neck ? 255 : 0 }
                if (62...76).contains(x) && (60...120).contains(y) && y % 6 < 4 { return 0 }
                if (162...176).contains(x) && (140...200).contains(y) && y % 6 < 4 { return 0 }
                return 255
            }
            let c = lobe(330, 130, 70)
            if c <= 1 {
                if c > 0.92 { return 0 }
                if ((304...318).contains(x) || (342...356).contains(x)) && (85...175).contains(y) && y % 6 < 4 { return 0 }
                return 255
            }
            return nil
        }
        let map = ReaderTranslationEnclosedBackground.ComponentMap(image: image)
        let boxes = [CGRect(x: 60, y: 58, width: 18, height: 64), CGRect(x: 160, y: 138, width: 18, height: 64),
                     CGRect(x: 302, y: 83, width: 18, height: 94), CGRect(x: 340, y: 83, width: 18, height: 94)]
        let interiors = map.balloonInteriors(of: boxes, candidates: [false, false, false, false])
        #expect(interiors[0] == nil && interiors[1] == nil)
        let unit = try #require(interiors[2])
        #expect(unit.members == 2 && interiors[3] == unit)
        // Stored regions keep the shared count; older stores without it decode as lone interiors.
        let data = try JSONEncoder().encode(unit)
        #expect(try JSONDecoder().decode(ReaderTranslationBalloonInterior.self, from: data) == unit)
        var legacy = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        legacy.removeValue(forKey: "members")
        let old = try JSONDecoder().decode(ReaderTranslationBalloonInterior.self, from: JSONSerialization.data(withJSONObject: legacy))
        #expect(old.members == nil && old.rect == unit.rect)
        #expect(unit.cropped(to: CGRect(x: 0, y: 0, width: 1, height: 1))?.members == 2)
    }

    @Test func balloonUnitIsProposedInSourceReadingOrder() throws {
        // Two vertical columns sharing one balloon: the right column reads first. The payload keeps
        // each caption's own card and erasure and proposes the unit with the shared paper.
        let size = CGSize(width: 400, height: 400)
        let spans = (0..<24).flatMap { band -> [Double] in
            let y = (Double(band) + 0.5) / 24 * 2 - 1, half = 0.2 * (1 - y * y).squareRoot()
            return [0.5 - half, 0.5 + half]
        }
        var shared = ReaderTranslationBalloonInterior(rect: CGRect(x: 0.3, y: 0.3, width: 0.4, height: 0.4),
                                                      center: CGPoint(x: 0.5, y: 0.5), spans: spans)
        shared.members = 2
        var left = ReaderTranslationRegion(id: "left", rect: CGRect(x: 0.42, y: 0.38, width: 0.05, height: 0.2),
                                           source: "いたみたい", translation: "있었던 것 같아", sourceOrientation: .vertical)
        var right = ReaderTranslationRegion(id: "right", rect: CGRect(x: 0.53, y: 0.36, width: 0.05, height: 0.14),
                                            source: "なんか", translation: "뭔가", sourceOrientation: .vertical)
        left.balloonInterior = shared
        right.balloonInterior = shared
        var overlay = ReaderTranslationSettings.defaultOverlay
        overlay.enforceSourceReplacement()
        overlay.visible = true
        let payload = NativeTranslationLayoutPlanner.payload(
            items: ReaderTranslationRegion.layoutItems([left, right], imageSize: size), imageSize: size,
            sourceRect: CGRect(origin: .zero, size: size), settings: overlay, targetLanguage: "ko", viewport: size)
        #expect(payload.count == 2)
        let units = payload.compactMap { $0["balloonUnit"] as? [String: Any] }
        #expect(units.count == 2)
        #expect(units.allSatisfy { ($0["members"] as? [String]) == ["1", "0"] })
        #expect(payload.allSatisfy { $0["balloonInterior"] is NSNull })
        let interior = try #require(units.first?["interior"] as? [String: Any])
        #expect((interior["spans"] as? [Double])?.count == spans.count)
        // Horizontal lines read top down; blocks side by side keep the OCR order.
        let rows = [CGRect(x: 0, y: 50, width: 40, height: 10), CGRect(x: 60, y: 10, width: 40, height: 10),
                    CGRect(x: 0, y: 12, width: 40, height: 10)]
        #expect(BrowserOverlayLayoutPlanner.readingOrder([0, 1, 2], sources: rows, sourceVerticals: [false, false, false],
                                                         orderKeys: [0, 1, 2]) == [1, 2, 0])
        // A tie follows the largest box: a column with a lone kana reads right to left, a line with a
        // short word read as a column reads top down, then in OCR order.
        let kana = [CGRect(x: 0, y: 0, width: 20, height: 120), CGRect(x: 30, y: 2, width: 12, height: 12)]
        #expect(BrowserOverlayLayoutPlanner.readingOrder([0, 1], sources: kana, sourceVerticals: [true, false]) == [1, 0])
        let line = [CGRect(x: 0, y: 0, width: 20, height: 18), CGRect(x: 24, y: 1, width: 90, height: 18)]
        #expect(BrowserOverlayLayoutPlanner.readingOrder([0, 1], sources: line, sourceVerticals: [true, false],
                                                         orderKeys: [0, 1]) == [0, 1])
    }

    @Test func balloonInteriorSurvivesStorageAndReachesTheOverlayItem() throws {
        let interior = ReaderTranslationBalloonInterior(rect: CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4),
                                                        center: CGPoint(x: 0.25, y: 0.4), spans: [0.12, 0.38, -1, -1])
        var region = ReaderTranslationRegion(id: "r", rect: CGRect(x: 0.2, y: 0.3, width: 0.05, height: 0.2), source: "テスト",
                                             translation: "테스트", sourceOrientation: .vertical)
        region.balloonInterior = interior
        let data = try JSONEncoder().encode(ReaderTranslationStoredRegion(region))
        #expect(try JSONDecoder().decode(ReaderTranslationStoredRegion.self, from: data).region == region)
        #expect(region.overlayItem(index: 0, imageSize: CGSize(width: 100, height: 100)).balloonInterior == interior)
        // Regions stored before interiors existed still decode.
        var legacy = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        legacy.removeValue(forKey: "balloonInterior")
        let old = try JSONDecoder().decode(ReaderTranslationStoredRegion.self, from: JSONSerialization.data(withJSONObject: legacy))
        #expect(old.region.balloonInterior == nil)
    }

    @Test func balloonUnitsJoinBlocksFragmentsAndRubyOfOneBalloonOnly() {
        // Page 400x300 on grey artwork: balloon A (two columns, a one-glyph tail below the right
        // column, ruby beside it), balloon B beside A with its own column, two lobes joined by a
        // narrow neck, and katakana sound effects on a white patch.
        func inside(_ x: Int, _ y: Int, _ box: (Int, Int, Int, Int)) -> Bool {
            (box.0...box.2).contains(x) && (box.1...box.3).contains(y)
        }
        let texts: [(Int, Int, Int, Int)] = [(150, 40, 170, 180), (120, 40, 140, 150), (150, 186, 170, 204), (174, 40, 180, 90),
                                             (250, 60, 270, 200), (40, 214, 60, 244), (40, 258, 60, 288), (310, 220, 330, 260),
                                             (340, 220, 360, 250)]
        let image = grayImage(width: 400, height: 300, background: 120) { x, y in
            // Glyph-like strokes inside every text box leave paper between them.
            if let box = texts.first(where: { inside(x, y, $0) }) {
                let thin = box.2 - box.0 < 10
                return (y - box.1) % (thin ? 4 : 6) < (thin ? 1 : 2) && (x - box.0) % (thin ? 3 : 5) != 0 ? 0 : 255
            }
            if inside(x, y, (100, 20, 200, 220)) { return x < 102 || x > 198 || y < 22 || y > 218 ? 0 : 255 }
            if inside(x, y, (230, 20, 290, 220)) { return x < 232 || x > 288 || y < 22 || y > 218 ? 0 : 255 }
            // Two lobes: 30..70 x 205..250 and 30..70 x 252..295 joined by a 6 px neck.
            if inside(x, y, (30, 205, 70, 250)) || inside(x, y, (30, 252, 70, 295)) || inside(x, y, (47, 249, 53, 253)) {
                return 255
            }
            if inside(x, y, (300, 210, 370, 270)) { return 255 }
            return nil
        }
        let size = CGSize(width: 400, height: 300)
        func region(_ id: Int, _ box: (Int, Int, Int, Int), _ text: String,
                    _ orientation: BrowserOCRSourceOrientation = .vertical) -> ReaderTranslationRegion {
            let rect = CGRect(x: CGFloat(box.0) / size.width, y: CGFloat(box.1) / size.height,
                              width: CGFloat(box.2 - box.0 + 1) / size.width, height: CGFloat(box.3 - box.1 + 1) / size.height)
            return ReaderTranslationRegion(id: "region-\(id)", rect: rect, source: text,
                                           polygon: [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
                          CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.maxY)],
                sourceOrientation: orientation, sourceSingleVerticalColumn: orientation == .vertical)
        }
        let input = [region(0, texts[0], "ひとつめのれつです"), region(1, texts[1], "ふたつめの"), region(2, texts[2], "ね"),
                     region(3, texts[3], "るびです"), region(4, texts[4], "となりのふきだし"), region(5, texts[5], "うえです"),
                     region(6, texts[6], "したです"), region(7, texts[7], "ガビーン"), region(8, texts[8], "バオ")]
        let map = ReaderTranslationEnclosedBackground.ComponentMap(image: image)
        let output = ReaderTranslationBalloonMerger.joinBalloonUnits(input, image: image, enclosure: map) { a, b, _ in
            map.separates(a, b)
        }
        // Balloon A: right column, its tail below, then the left column; ruby becomes erase-only ink.
        let joined = output.first { $0.source.contains("ひとつめ") }
        #expect(joined?.source == "ひとつめのれつですねふたつめの")
        #expect(joined?.auxiliaryInkRects.contains(input[3].rect) == true)
        #expect(!output.contains { $0.source == "るびです" })
        // The neighbouring balloon, the joined lobes and the sound effects stay separate.
        #expect(output.contains { $0.source == "となりのふきだし" })
        #expect(output.contains { $0.source == "うえです" } && output.contains { $0.source == "したです" })
        #expect(output.contains { $0.source == "ガビーン" } && output.contains { $0.source == "バオ" })
        #expect(output.count == 6)
    }

    @Test func balloonUnitsJoinOffsetBlocksTiltedRowsAndOverlappingLatinStacks() {
        // Page 600x500 on grey artwork. Balloon A: an aside "HM?" above right of its paragraph (comic-8035).
        // Balloon B: two tilted rows of one caption (comic-0409). On the artwork: a tilted handwritten stack
        // whose rows 1+3 and row 2 are two overlapping regions (comic-8527).
        func inside(_ x: Int, _ y: Int, _ box: (Int, Int, Int, Int)) -> Bool {
            (box.0...box.2).contains(x) && (box.1...box.3).contains(y)
        }
        let texts: [(Int, Int, Int, Int)] = [(345, 50, 395, 70), (180, 80, 330, 170), (60, 302, 200, 330), (60, 342, 230, 378)]
        let image = grayImage(width: 600, height: 500, background: 120) { x, y in
            if let box = texts.first(where: { inside(x, y, $0) }) {
                return (y - box.1) % 6 < 2 && (x - box.0) % 5 != 0 ? 0 : 255
            }
            if inside(x, y, (150, 20, 480, 200)) { return x < 152 || x > 478 || y < 22 || y > 198 ? 0 : 255 }
            if inside(x, y, (30, 260, 280, 420)) { return x < 32 || x > 278 || y < 262 || y > 418 ? 0 : 255 }
            return nil
        }
        let size = CGSize(width: 600, height: 500)
        func region(_ id: Int, _ points: [CGPoint], _ text: String) -> ReaderTranslationRegion {
            let xs = points.map(\.x), ys = points.map(\.y)
            let rect = CGRect(x: xs.min()! / size.width, y: ys.min()! / size.height,
                              width: (xs.max()! - xs.min()!) / size.width, height: (ys.max()! - ys.min()!) / size.height)
            return ReaderTranslationRegion(id: "region-\(id)", rect: rect, source: text,
                                           polygon: points.map { CGPoint(x: $0.x / size.width, y: $0.y / size.height) },
                                           sourceOrientation: .horizontal, sourceSingleVerticalColumn: false)
        }
        func box(_ b: (Int, Int, Int, Int)) -> [CGPoint] {
            [CGPoint(x: b.0, y: b.1), CGPoint(x: b.2, y: b.1), CGPoint(x: b.2, y: b.3), CGPoint(x: b.0, y: b.3)]
        }
        // Rows tilted by about -0.11 rad: rising to the right.
        func tilted(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat, slope: CGFloat = -0.11) -> [CGPoint] {
            [CGPoint(x: x, y: y), CGPoint(x: x + width, y: y + width * slope),
             CGPoint(x: x + width, y: y + width * slope + height), CGPoint(x: x, y: y + height)]
        }
        let stack = [tilted(420, 300, 70, 18, slope: 0.2), tilted(428, 318, 50, 18, slope: 0.2), tilted(422, 336, 72, 18, slope: 0.2)]
        let input = [region(0, box(texts[1]), "UH, WE DIDN'T HAVE ANY PROBLEMS THOUGH."), region(1, box(texts[0]), "HM?"),
                     region(2, tilted(60, 315, 140, 20), "その物語は、"), region(3, tilted(60, 357, 170, 22), "名もなき小さな球場から"),
                     region(4, [stack[0][0], stack[0][1], stack[2][2], stack[2][3]], "No, I'm worried."),
                     region(5, stack[1], "just")]
        let lines: [ReaderTranslationBalloonMerger.SourceLine] = zip(stack, ["No, I'm", "just", "worried."]).map {
            .init(polygon: $0.0, text: $0.1, orientation: .horizontal)
        }
        let map = ReaderTranslationEnclosedBackground.ComponentMap(image: image)
        let output = ReaderTranslationBalloonMerger.joinBalloonUnits(input, image: image, enclosure: map, sourceLines: lines) { a, b, _ in
            map.separates(a, b)
        }
        #expect(output.map(\.source).sorted() == ["HM? UH, WE DIDN'T HAVE ANY PROBLEMS THOUGH.", "No, I'm just worried.",
                                                   "その物語は、名もなき小さな球場から"], "\(output.map(\.source))")
        // The tilted caption keeps a rotated quad, so its translation keeps the baseline.
        let caption = try? #require(output.first { $0.source.hasPrefix("その") })
        let rotation = caption.flatMap { region in
            BrowserOverlayRotation.geometry(polygon: region.polygon.map { CGPoint(x: $0.x * size.width, y: $0.y * size.height) })
        }
        #expect(rotation.map { abs($0.radians + 0.11) < 0.03 } == true)
    }

    @Test func overlappingLatinStacksOnArtJoinOnlyAtTextSize() {
        // An interleaved Latin stack (rows 1+3 and row 2) drawn on artwork joins (comic-8527). Display rows
        // of a logo on art (comic-4064: glyph over 4 % of the page) keep their own regions, so no joined
        // plate covers the art between them.
        func inside(_ x: Int, _ y: Int, _ box: (Int, Int, Int, Int)) -> Bool {
            (box.0...box.2).contains(x) && (box.1...box.3).contains(y)
        }
        func run(scale: Int) -> [String] {
            let rows = [(100, 100, 100 + 70 * scale, 100 + 18 * scale), (108, 100 + 18 * scale, 108 + 50 * scale, 100 + 36 * scale),
                        (102, 100 + 36 * scale, 102 + 72 * scale, 100 + 54 * scale)]
            let image = grayImage(width: 600, height: 500, background: 120) { x, y in
                guard let box = rows.first(where: { inside(x, y, $0) }) else { return nil }
                return (y - box.1) % (6 * scale) < 2 * scale && (x - box.0) % 5 != 0 ? 0 : nil
            }
            func region(_ id: Int, _ b: (Int, Int, Int, Int), _ text: String) -> ReaderTranslationRegion {
                ReaderTranslationRegion(id: "region-\(id)", rect: CGRect(x: CGFloat(b.0) / 600, y: CGFloat(b.1) / 500,
                                                                         width: CGFloat(b.2 - b.0) / 600, height: CGFloat(b.3 - b.1) / 500),
                                        source: text, sourceOrientation: .horizontal, sourceSingleVerticalColumn: false)
            }
            let input = [region(0, (100, 100, 102 + 72 * scale, 100 + 54 * scale), "No, I'm worried."), region(1, rows[1], "just")]
            let map = ReaderTranslationEnclosedBackground.ComponentMap(image: image)
            return ReaderTranslationBalloonMerger.joinBalloonUnits(input, image: image, enclosure: map) { a, b, _ in
                map.separates(a, b)
            }.map(\.source).sorted()
        }
        #expect(run(scale: 1).count == 1, "\(run(scale: 1))")
        #expect(run(scale: 2).count == 2, "\(run(scale: 2))")
    }

    @Test func horizontalBalloonUnitsReadSideBySideBlocksRightToLeftAndLinePiecesLeftToRight() {
        // comic-2183: two staggered English blocks side by side in one balloon read right block first
        // (their heights overlap, but they are not one line); pieces of one line join left to right.
        // comic-2347: in a stair-shaped balloon the blocks' joined rectangle cuts the balloon's corner (its
        // outline and the art beyond). The balloon itself holds them as one caption: they join, and the unit
        // carries its members and the stair-shaped interior that bounds its erasure, plate and lettering.
        func inside(_ x: Int, _ y: Int, _ box: (Int, Int, Int, Int)) -> Bool {
            (box.0...box.2).contains(x) && (box.1...box.3).contains(y)
        }
        let texts: [(Int, Int, Int, Int)] = [(210, 40, 300, 110), (120, 70, 205, 150), (200, 280, 260, 300), (266, 280, 300, 300),
                                             (520, 235, 600, 310), (606, 265, 700, 345)]
        func stair(_ x: Int, _ y: Int) -> Bool { inside(x, y, (500, 220, 640, 335)) || inside(x, y, (600, 245, 780, 380)) }
        let image = grayImage(width: 800, height: 400, background: 120) { x, y in
            if let box = texts.first(where: { inside(x, y, $0) }) {
                return (y - box.1) % 6 < 2 && (x - box.0) % 5 != 0 ? 0 : 255
            }
            if stair(x, y) {
                let ring = [(-2, 0), (2, 0), (0, -2), (0, 2), (-2, -2), (2, 2), (-2, 2), (2, -2)]
                return ring.allSatisfy { stair(x + $0.0, y + $0.1) } ? 255 : 0
            }
            if inside(x, y, (100, 20, 480, 200)) { return x < 102 || x > 478 || y < 22 || y > 198 ? 0 : 255 }
            if inside(x, y, (170, 250, 330, 330)) { return x < 172 || x > 328 || y < 252 || y > 328 ? 0 : 255 }
            return nil
        }
        let size = CGSize(width: 800, height: 400)
        func region(_ id: Int, _ box: (Int, Int, Int, Int), _ text: String) -> ReaderTranslationRegion {
            let rect = CGRect(x: CGFloat(box.0) / size.width, y: CGFloat(box.1) / size.height,
                              width: CGFloat(box.2 - box.0 + 1) / size.width, height: CGFloat(box.3 - box.1 + 1) / size.height)
            return ReaderTranslationRegion(id: "region-\(id)", rect: rect, source: text,
                                           polygon: [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
                          CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.maxY)],
                sourceOrientation: .horizontal, sourceSingleVerticalColumn: false)
        }
        // Region order puts the left block first, as the native grouping may.
        let input = [region(0, texts[1], "SO IT MAKES SENSE THAT WE WOULD BOTH COME HERE."),
                     region(1, texts[0], "THIS IS THE ONLY MOVIE THEATER IN THE AREA,"),
                     region(2, texts[3], "AN"), region(3, texts[2], "KOB"),
                     region(4, texts[5], "WHAT KIND OF REQUEST WOULD YOU LIKE"), region(5, texts[4], "WELL THEN, MARIMARI")]
        let map = ReaderTranslationEnclosedBackground.ComponentMap(image: image)
        let output = ReaderTranslationBalloonMerger.joinBalloonUnits(input, image: image, enclosure: map) { a, b, _ in
            map.separates(a, b)
        }
        #expect(output.map(\.source).sorted() == [
            "KOB AN", "THIS IS THE ONLY MOVIE THEATER IN THE AREA, SO IT MAKES SENSE THAT WE WOULD BOTH COME HERE.",
            "WHAT KIND OF REQUEST WOULD YOU LIKE WELL THEN, MARIMARI"
        ], "\(output.map(\.source))")
        let unit = try? #require(output.first { $0.source.hasPrefix("WHAT KIND") })
        #expect((unit?.unitMemberRects ?? []).sorted { $0.minX < $1.minX } == [input[5].rect, input[4].rect])
        // Blocks joined on their rectangle's paper (2183) carry their members too.
        #expect(output.first { $0.source.hasPrefix("THIS IS") }?.unitMemberRects.count == 2)
        let interior = unit.flatMap {
            ReaderTranslationEnclosedBackground.attachingBalloonInteriors([$0], image: image, map: map).first?.balloonInterior
        }
        let spans = interior?.spans ?? []
        // Rows below the upper step (y 340...375) hold only the lower step's paper (x >= 600): the union's
        // corner at x 520...600 is outline and artwork, never unit interior.
        let bands = spans.count / 2
        let lower = (0..<bands).filter { band in
            guard let rect = interior?.rect else { return false }
            let y = (rect.minY + rect.height * (CGFloat(band) + 0.5) / CGFloat(bands)) * size.height
            return y > 340 && y < 375 && spans[2 * band] >= 0
        }
        #expect(!lower.isEmpty && lower.allSatisfy { spans[2 * $0] * size.width >= 598 })
        // Both members lie inside the interior's bounds.
        #expect(interior.map { $0.rect.insetBy(dx: -0.002, dy: -0.002).contains(input[4].rect.union(input[5].rect)) } == true)
    }

    @Test func unitMembersSurviveStorageCropAndReachTheOverlayItem() throws {
        var region = ReaderTranslationRegion(id: "u", rect: CGRect(x: 0.2, y: 0.3, width: 0.4, height: 0.2), source: "AB",
                                             translation: "에이비", sourceOrientation: .horizontal)
        region.unitMemberRects = [CGRect(x: 0.2, y: 0.3, width: 0.1, height: 0.1), CGRect(x: 0.4, y: 0.35, width: 0.2, height: 0.15)]
        let data = try JSONEncoder().encode(ReaderTranslationStoredRegion(region))
        #expect(try JSONDecoder().decode(ReaderTranslationStoredRegion.self, from: data).region == region)
        let item = region.overlayItem(index: 0, imageSize: CGSize(width: 200, height: 100))
        #expect(item.unitMemberRects == [CGRect(x: 40, y: 30, width: 20, height: 10), CGRect(x: 80, y: 35, width: 40, height: 15)])
        let cropped = try #require(region.cropped(to: CGRect(x: 0, y: 0, width: 1, height: 0.5)))
        #expect(cropped.unitMemberRects.count == 2)
        #expect(abs(cropped.unitMemberRects[1].minY - 0.7) < 1e-9)
        // Ordinary regions store no member key; regions stored before units existed still decode.
        let plain = try JSONSerialization.jsonObject(with: JSONEncoder().encode(ReaderTranslationStoredRegion(
            ReaderTranslationRegion(id: "p", rect: .init(x: 0, y: 0, width: 0.1, height: 0.1), source: "P")))) as? [String: Any]
        #expect(plain?["unitMemberRects"] == nil)
        var legacy = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        legacy.removeValue(forKey: "unitMemberRects")
        let old = try JSONDecoder().decode(ReaderTranslationStoredRegion.self, from: JSONSerialization.data(withJSONObject: legacy))
        #expect(old.region.unitMemberRects.isEmpty)
    }
}

// swiftlint:enable large_tuple
