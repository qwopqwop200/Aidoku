import Testing
import UIKit
import WebKit
@testable import Aidoku

@Suite(.serialized)
@MainActor
struct ReaderSlantedTextTests {
    private static let webFixture = RegressionWebFixture()

    private nonisolated static var directory: URL { URL.documentsDirectory.appendingPathComponent("SlantedText") }

    private func quad(angle: CGFloat, size: CGSize = CGSize(width: 180, height: 48), center: CGPoint = CGPoint(x: 200, y: 180)) -> [CGPoint] {
        [CGPoint(x: -size.width / 2, y: -size.height / 2), CGPoint(x: size.width / 2, y: -size.height / 2),
         CGPoint(x: size.width / 2, y: size.height / 2), CGPoint(x: -size.width / 2, y: size.height / 2)].map {
            CGPoint(x: center.x + $0.x * cos(angle) - $0.y * sin(angle),
                    y: center.y + $0.x * sin(angle) + $0.y * cos(angle))
        }
    }

    @Test(arguments: [-80.0, -65, -45, -25, -8, 8, 25, 45, 65, 80], [false, true])
    func recoversPixelAngleAndSourceCenter(degrees: Double, vertical: Bool) throws {
        let angle = CGFloat(degrees * .pi / 180)
        let size = vertical ? CGSize(width: 48, height: 180) : CGSize(width: 180, height: 48)
        let geometry = try #require(BrowserOverlayRotation.geometry(polygon: quad(angle: angle, size: size)))
        #expect(abs(geometry.radians - angle) < 0.0001)
        #expect(abs(geometry.rect.midX - 200) < 0.0001 && abs(geometry.rect.midY - 180) < 0.0001)
        #expect(abs(geometry.rect.width - size.width) < 0.0001 && abs(geometry.rect.height - size.height) < 0.0001)
    }

    @Test func rejectsJitterInvalidQuadsAndStrongPerspective() {
        #expect(BrowserOverlayRotation.geometry(polygon: quad(angle: 0)) == nil)
        #expect(BrowserOverlayRotation.geometry(polygon: quad(angle: .pi / 180)) == nil)
        #expect(BrowserOverlayRotation.geometry(polygon: []) == nil)
        #expect(BrowserOverlayRotation.geometry(polygon: Array(repeating: CGPoint(x: CGFloat.nan, y: 0), count: 4)) == nil)
        var trapezoid = quad(angle: 0.3); trapezoid[1].x -= 110
        #expect(BrowserOverlayRotation.geometry(polygon: trapezoid) == nil)
        #expect(BrowserOverlayRotation.geometry(polygon: Array(quad(angle: 0.3).reversed())) == nil)
        #expect(BrowserOverlayRotation.geometry(polygon: quad(angle: 82 * .pi / 180)) == nil)
        #expect(BrowserOverlayRotation.geometry(polygon: quad(angle: -82 * .pi / 180)) == nil)
    }

    @Test(arguments: [-28.0, -10, 10, 28])
    func verticalDetectorEdgeOrderDoesNotTurnGlyphsSideways(degrees: Double) throws {
        let radians = CGFloat(degrees * .pi / 180)
        let canonical = quad(angle: radians, size: CGSize(width: 35, height: 210))
        let detector = [canonical[1], canonical[2], canonical[3], canonical[0]]
        let geometry = try #require(BrowserOverlayRotation.geometry(polygon: detector, singleVerticalColumn: true))
        #expect(abs(geometry.radians - radians) < 0.0001)
        #expect(abs(geometry.rect.width - 35) < 0.001)
        #expect(abs(geometry.rect.height - 210) < 0.001)
    }

    @Test func quantizedQuadKeepsTextCornersInsideAllFourEdges() throws {
        let points = [CGPoint(x: 100, y: 90), CGPoint(x: 302, y: 122),
                      CGPoint(x: 294, y: 164), CGPoint(x: 94, y: 132)]
        let geometry = try #require(BrowserOverlayRotation.geometry(polygon: points))
        let corners = quad(angle: geometry.radians, size: geometry.rect.size,
                           center: CGPoint(x: geometry.rect.midX, y: geometry.rect.midY))
        for corner in corners {
            for i in points.indices {
                let a = points[i], b = points[(i + 1) % 4]
                #expect((b.x - a.x) * (corner.y - a.y) - (b.y - a.y) * (corner.x - a.x) >= -0.0001)
            }
        }
    }

    @Test func thinSkewCannotGrowAnOversizedReplacementPanel() {
        let points = [CGPoint(x: 100, y: 100), CGPoint(x: 300, y: 120),
                      CGPoint(x: 299.5, y: 126.5), CGPoint(x: 99.5, y: 105)]
        #expect(BrowserOverlayRotation.geometry(polygon: points) == nil)
    }

    @Test(arguments: [23.2, 31.6, 40.8])
    func fractionalWidthDoesNotRejectAFittingWrappedCaption(width: Double) throws {
        let geometry = try #require(BrowserOverlayRotation.geometry(
            polygon: quad(angle: -0.15, size: CGSize(width: width, height: 230))))
        let layout = BrowserOverlayRotation.layout(geometry: geometry,
            variant: .plain("왜 이 녀석은 표적이 되지 않았지?", vertical: false),
            maximumFontSize: 14, measurementCache: nil)
        #expect(layout != nil)
    }

    @Test func mappingUsesPixelsAndKeepsCacheRoundTrip() throws {
        let pixels = quad(angle: -0.35)
        let size = CGSize(width: 800, height: 1200)
        var region = ReaderTranslationRegion(id: "slanted", rect: CGRect(x: 0.1, y: 0.1, width: 0.3, height: 0.1),
            source: "傾いた文字", translation: "기울어진 글자", polygon: pixels.map { CGPoint(x: $0.x / size.width, y: $0.y / size.height) })
        region.sourceOrientation = .horizontal
        region.auxiliaryInkPolygons = [pixels.map { CGPoint(x: $0.x / size.width, y: $0.y / size.height) }]
        let stored = try JSONDecoder().decode(ReaderTranslationStoredRegion.self,
            from: JSONEncoder().encode(ReaderTranslationStoredRegion(region)))
        let item = stored.region.overlayItem(index: 0, imageSize: size)
        #expect(stored.region.auxiliaryInkPolygons == region.auxiliaryInkPolygons)
        #expect(item.auxiliaryInkPolygons.first?.count == 4)
        let mapped = try #require(BrowserOverlayRotation.mapped(item: item, imageSize: size,
            sourceRect: CGRect(x: 10, y: 20, width: 400, height: 600), settings: ReaderTranslationSettings.defaultOverlay))
        #expect(abs(mapped.radians + 0.35) < 0.0001)
        #expect(abs(mapped.rect.midX - 110) < 0.0001 && abs(mapped.rect.midY - 110) < 0.0001)
    }

    @Test func nearUprightLabelsTakeTheUprightPath() {
        let size = CGSize(width: 800, height: 1200)
        func mapped(degrees: CGFloat, box: CGSize, text: String, vertical: Bool = false) -> BrowserOverlayRotation.Geometry? {
            let points = quad(angle: degrees * .pi / 180, size: box, center: CGPoint(x: 400, y: 600))
            var region = ReaderTranslationRegion(
                id: "near-upright", rect: CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2),
                source: text, translation: "번역", polygon: points.map { CGPoint(x: $0.x / size.width, y: $0.y / size.height) })
            region.sourceOrientation = vertical ? .vertical : .horizontal
            return BrowserOverlayRotation.mapped(item: region.overlayItem(index: 0, imageSize: size), imageSize: size,
                                                 sourceRect: CGRect(origin: .zero, size: size), settings: ReaderTranslationSettings.defaultOverlay)
        }
        // A short label's detector box tilts by a few degrees; its baseline
        // rises by a fifth of a glyph at most, so it is set upright.
        #expect(mapped(degrees: 3.5, box: CGSize(width: 60, height: 20), text: "Skip") == nil)
        // The same angle over a long line is visible lettering slant.
        #expect(mapped(degrees: 3.5, box: CGSize(width: 400, height: 20), text: "a long slanted handwritten line of text") != nil)
        // Vertical columns, display lettering and steeper labels keep their quad.
        #expect(mapped(degrees: 3.5, box: CGSize(width: 20, height: 60), text: "縦書き", vertical: true) != nil)
        #expect(mapped(degrees: 3.5, box: CGSize(width: 90, height: 60), text: "ドン") != nil)
        #expect(mapped(degrees: 5, box: CGSize(width: 60, height: 20), text: "Skip") != nil)
        // The upright label's payload records its quad tilt, which keeps it
        // out of the page's size cohorts (it used to be a rotated caption).
        let points = quad(angle: 3.5 * .pi / 180, size: CGSize(width: 60, height: 20), center: CGPoint(x: 400, y: 600))
        let item = BrowserOverlayItem(
            stableRegionID: 1, rect: NativeOCRScopeGeometry.bounds(for: points) ?? .zero,
            sourceText: "Skip", translatedText: "건너뛰기", confidence: 1, sourceOrientation: .horizontal, sourcePolygon: points)
        let payload = BrowserPageImageOverlayRenderer.layoutPayload(
            items: [item], imageSize: size,
            sourceRect: CGRect(origin: .zero, size: size), settings: ReaderTranslationSettings.defaultOverlay,
            targetLanguage: "ko", viewport: size).first
        #expect((payload?["rotation"] as? NSNumber)?.doubleValue == 0)
        #expect(abs(((payload?["nearUprightRotation"] as? NSNumber)?.doubleValue ?? 0) - 3.5 * .pi / 180) < 0.01)
    }

    @Test func smallUnfittableTranslationRetainsOrdinaryLayout() throws {
        let geometry = try #require(BrowserOverlayRotation.geometry(polygon: quad(angle: 0.3, size: CGSize(width: 8, height: 8))))
        #expect(BrowserOverlayRotation.layout(geometry: geometry, variant: .plain("아주 긴 번역문이라서 들어갈 수 없다", vertical: false),
            maximumFontSize: 14, measurementCache: nil) == nil)
    }

    @Test(arguments: [-78.0, -25, 25, 78])
    func nativeCardsRetainAngleAcrossReuseAndResetForAnUprightReplacement(degrees: Double) throws {
        let overlay = BrowserOverlayView(frame: CGRect(x: 0, y: 0, width: 430, height: 400))
        let angle = CGFloat(degrees * .pi / 180)
        let points = quad(angle: angle)
        let bounds = try #require(NativeOCRScopeGeometry.bounds(for: points))
        func item(_ polygon: [CGPoint]) -> BrowserOverlayItem {
            .init(stableRegionID: 7, rect: bounds, sourceText: "傾いた文字", translatedText: "기울어진 글자",
                  confidence: 1, sourceOrientation: .horizontal, sourcePolygon: polygon)
        }
        func cards(_ view: UIView) -> [UIView] {
            (view.accessibilityIdentifier == "aidoku.reader.overlay.item" ? [view] : []) + view.subviews.flatMap(cards)
        }
        func fonts(_ view: UIView) -> [CGFloat] {
            (view as? UILabel).map { [$0.font.pointSize] } ?? view.subviews.flatMap(fonts)
        }
        for polygon in [points, points, []] {
            overlay.render([item(polygon)], imageSize: overlay.bounds.size, sourceRect: overlay.bounds,
                settings: ReaderTranslationSettings.defaultOverlay, targetLanguage: "ko")
            overlay.layoutIfNeeded()
            let card = try #require(cards(overlay).first)
            #expect(abs(atan2(card.transform.b, card.transform.a) - (polygon.isEmpty ? 0 : angle)) < 0.001)
            if !polygon.isEmpty {
                #expect(abs(card.center.x - 200) < 0.01 && abs(card.center.y - 180) < 0.01)
                #expect(bounds.insetBy(dx: -0.1, dy: -0.1).contains(card.frame))
            } else {
                let reference = BrowserOverlayView(frame: overlay.bounds)
                reference.render([item([])], imageSize: reference.bounds.size, sourceRect: reference.bounds,
                    settings: ReaderTranslationSettings.defaultOverlay, targetLanguage: "ko")
                reference.layoutIfNeeded()
                #expect(fonts(card) == fonts(try #require(cards(reference).first)))
                #expect(card.layer.mask == nil)
            }
        }
    }

    @Test func narrowSlantedVerticalColumnOffersAnUprightKoreanCard() throws {
        // A slanted vertical column two syllables wide cannot hold a Korean
        // sentence without breaking every word. The payload keeps the rotated
        // layout (its erasure and fallback) and offers the planner's upright
        // card; one short word or a steep column keeps only its slanted quad.
        let size = CGSize(width: 430, height: 800)
        func payload(_ translation: String, degrees: CGFloat) throws -> [String: Any] {
            let points = quad(angle: degrees * .pi / 180, size: CGSize(width: 24, height: 220), center: CGPoint(x: 215, y: 400))
            let bounds = try #require(NativeOCRScopeGeometry.bounds(for: points))
            let item = BrowserOverlayItem(stableRegionID: 3, rect: bounds, sourceText: "何でコイツは標的にならなかったんだ",
                                          translatedText: translation, confidence: 1, sourceOrientation: .vertical,
                                          sourceSingleVerticalColumn: true, sourcePolygon: points)
            return try #require(BrowserPageImageOverlayRenderer.layoutPayload(
                items: [item], imageSize: size,
                sourceRect: CGRect(origin: .zero, size: size), settings: ReaderTranslationSettings.defaultOverlay,
                targetLanguage: "ko", viewport: size).first)
        }
        func number(_ value: Any?) -> Double { (value as? NSNumber)?.doubleValue ?? .nan }
        let sentence = try payload("왜 이 녀석은 표적이 되지 않았지?", degrees: 6)
        #expect(abs(number(sentence["rotation"]) - 6 * .pi / 180) < 0.01)
        let upright = try #require(sentence["uprightAlternative"] as? [String: Any])
        #expect(number(upright["width"]) - number(upright["paddingLeft"]) - number(upright["paddingRight"]) >=
            3 * number(upright["fontSize"]))
        #expect(try payload("톡톡", degrees: 6)["uprightAlternative"] is NSNull)
        #expect(try payload("왜 이 녀석은 표적이 되지 않았지?", degrees: 25)["uprightAlternative"] is NSNull)
    }

    @Test func nearUprightVerticalColumnsSetUprightTextInsideTheirQuad() throws {
        // A vertical column's quad tilts by detector noise below 4.2 degrees.
        // The payload keeps the quad's layout and erasure (box, rotation, size)
        // and marks the caption upright; steeper columns and rows do not.
        let size = CGSize(width: 430, height: 800), center = CGPoint(x: 215, y: 400)
        func payload(degrees: CGFloat, vertical: Bool = true) throws -> [String: Any] {
            let box = vertical ? CGSize(width: 40, height: 160) : CGSize(width: 300, height: 30)
            let points = quad(angle: degrees * .pi / 180, size: box, center: center)
            let bounds = try #require(NativeOCRScopeGeometry.bounds(for: points))
            let item = BrowserOverlayItem(stableRegionID: 4, rect: bounds, sourceText: "どうなってるんだよ",
                                          translatedText: "어떻게 된 거야", confidence: 1, sourceOrientation: vertical ? .vertical : .horizontal,
                                          sourceSingleVerticalColumn: vertical, sourcePolygon: points)
            return try #require(BrowserPageImageOverlayRenderer.layoutPayload(
                items: [item], imageSize: size,
                sourceRect: CGRect(origin: .zero, size: size), settings: ReaderTranslationSettings.defaultOverlay,
                targetLanguage: "ko", viewport: size).first)
        }
        func number(_ value: Any?) -> CGFloat { CGFloat((value as? NSNumber)?.doubleValue ?? .nan) }
        let column = try payload(degrees: 3.5)
        #expect(abs(number(column["rotation"]) - 3.5 * .pi / 180) < 0.01)
        #expect(column["uprightQuadText"] as? Bool == true)
        #expect(try payload(degrees: 5)["uprightQuadText"] as? Bool == false)
        #expect(try payload(degrees: 3.5, vertical: false)["uprightQuadText"] as? Bool == false)
        // The upright plate outline: the page frame clipped to the quad grown
        // by the margin never reaches further than the margin past the quad.
        let geometry = try #require(BrowserOverlayRotation.geometry(polygon: quad(
            angle: 3.5 * .pi / 180,
            size: CGSize(width: 40, height: 160), center: center), singleVerticalColumn: true))
        let frame = [CGPoint(x: 195, y: 300), CGPoint(x: 235, y: 300), CGPoint(x: 235, y: 500), CGPoint(x: 195, y: 500)]
        let outline = BrowserOverlayRotation.clipped(frame, toQuad: geometry)
        let margin = BrowserOverlayRotation.uprightQuadMargin + 0.001
        let c = cos(geometry.radians), s = sin(geometry.radians)
        #expect(outline.count >= 4)
        for point in outline {
            let dx = point.x - geometry.panelRect.midX, dy = point.y - geometry.panelRect.midY
            #expect(abs(dx * c + dy * s) <= geometry.panelRect.width / 2 + margin)
            #expect(abs(-dx * s + dy * c) <= geometry.panelRect.height / 2 + margin)
            #expect(point.x >= 195 - 0.001 && point.x <= 235 + 0.001)
        }
    }

    @Test func nonReplacementModesAndPendingOCRKeepTheirExistingLayout() {
        let points = quad(angle: 0.2)
        let source = CGRect(x: 100, y: 100, width: 200, height: 100)
        var settings = ReaderTranslationSettings.defaultOverlay
        let pending = BrowserOverlayItem(rect: source, sourceText: "原文", translatedText: nil, confidence: 1, sourcePolygon: points)
        #expect(BrowserOverlayRotation.mapped(item: pending, imageSize: CGSize(width: 430, height: 400),
            sourceRect: CGRect(x: 0, y: 0, width: 430, height: 400), settings: settings) == nil)
        settings.mode = .originalAndTranslation
        let translated = BrowserOverlayItem(rect: source, sourceText: "原文", translatedText: "번역", confidence: 1, sourcePolygon: points)
        #expect(BrowserOverlayRotation.mapped(item: translated, imageSize: CGSize(width: 430, height: 400),
            sourceRect: CGRect(x: 0, y: 0, width: 430, height: 400), settings: settings) == nil)
    }

    @Test func canvasGlyphBoundsContainTheActualWebKitInk() async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene); window.rootViewController = UIViewController(); window.makeKeyAndVisible()
        defer { window.isHidden = true }
        let web = Self.webFixture.acquire(frame: CGRect(x: 0, y: 0, width: 430, height: 260))
        defer { Self.webFixture.release(web) }
        web.scrollView.contentInsetAdjustmentBehavior = .never
        window.rootViewController?.view.addSubview(web)
        window.rootViewController?.view.layoutIfNeeded()
        web.layoutIfNeeded()
        try await RegressionWebFixture.load("""
        <meta name='viewport' content='width=device-width,initial-scale=1'><style>
        html,body{margin:0;height:260px;background:white}div{position:absolute;left:30px;top:20px;width:360px;height:210px;
        display:flex;align-items:center;justify-content:center;text-align:center;white-space:pre-wrap;
        font:700 31.5px 'Apple SD Gothic Neo',-apple-system,sans-serif;line-height:1.193;letter-spacing:-.012em;color:black}
        </style><div>역겨워! 목욕할 시간이야.\nQuick brown fox 123!</div>
        """, in: web)

        // Reattached WebKit views settle viewport/scroll geometry during presentation.
        // Measure glyphs after the same paint fence used for the snapshot.
        _ = try await web.callAsyncJavaScript("await new Promise(r=>requestAnimationFrame(()=>requestAnimationFrame(r)))", arguments: [:], in: nil, contentWorld: .page)
        let rects = try #require(try await web.evaluateJavaScript(#"""
        (()=>{const n=document.querySelector('div'),t=n.firstChild,s=getComputedStyle(n),c=document.createElement('canvas').getContext('2d');
        c.font=`${s.fontWeight} ${s.fontSize} ${s.fontFamily}`;const range=document.createRange(),out=[];let offset=0;
        for(const ch of t.textContent){const next=offset+ch.length;if(!/\s/u.test(ch)){
          range.setStart(t,offset);range.setEnd(t,next);const m=c.measureText(ch);
          for(const r of range.getClientRects()){const baseline=r.top+(r.height-m.fontBoundingBoxAscent-m.fontBoundingBoxDescent)/2+m.fontBoundingBoxAscent;
            out.push([r.left-m.actualBoundingBoxLeft-1,baseline-m.actualBoundingBoxAscent-1,
              r.left+m.actualBoundingBoxRight+1,baseline+m.actualBoundingBoxDescent+1]);}}offset=next;}return out;})()
        """#) as? [[Double]])
        let snapshot: UIImage = try await withCheckedThrowingContinuation { continuation in
            web.takeSnapshot(with: nil) { image, error in
                if let image { continuation.resume(returning: image) }
                else { continuation.resume(throwing: error ?? CancellationError()) }
            }
        }
        let cg = try #require(snapshot.cgImage)
        try FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        try snapshot.pngData()?.write(to: Self.directory.appendingPathComponent("font-footprint.png"))
        try JSONSerialization.data(withJSONObject: rects).write(to: Self.directory.appendingPathComponent("font-footprint-rects.json"))
        var pixels = [UInt8](repeating: 0, count: cg.width * cg.height * 4)
        try pixels.withUnsafeMutableBytes { buffer in
            let context = try #require(CGContext(data: buffer.baseAddress, width: cg.width, height: cg.height,
                bitsPerComponent: 8, bytesPerRow: cg.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        }
        let scale = Double(cg.width) / 430
        var ink = 0, outside = 0
        for y in 0..<cg.height { for x in 0..<cg.width where pixels[(y * cg.width + x) * 4] < 180 && pixels[(y * cg.width + x) * 4 + 3] >= 250 {
            ink += 1
            let px = (Double(x) + 0.5) / scale, py = (Double(y) + 0.5) / scale
            if !rects.contains(where: { px >= $0[0] && py >= $0[1] && px <= $0[2] && py <= $0[3] }) { outside += 1 }
        } }
        #expect(ink > 300)
        #expect(outside == 0, "measured footprint must contain the rendered glyphs: \(outside)/\(ink)")
    }

    // Fixed, reviewed dataset text/geometry. This isolates actual WebKit
    // layout/rasterization from changes in a remote translation provider.
}
