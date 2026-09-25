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

    @Test func smallUnfittableTranslationRetainsOrdinaryLayout() throws {
        let geometry = try #require(BrowserOverlayRotation.geometry(polygon: quad(angle: 0.3, size: CGSize(width: 8, height: 8))))
        #expect(BrowserOverlayRotation.layout(geometry: geometry, variant: .plain("아주 긴 번역문이라서 들어갈 수 없다", vertical: false),
            maximumFontSize: 14, measurementCache: nil) == nil)
    }

    @Test(arguments: [-78.0, -25, 25, 78])
    func nativeCardsRetainAngleAcrossReuseAndResetForAnUprightReplacement(degrees: Double) throws {
        guard #available(iOS 18.0, *) else { return }
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

    @Test(.enabled(if: FileManager.default.fileExists(atPath: directory.appendingPathComponent("fixtures.json").path)))
    func freshOCRPreservesDatasetAnglesThroughTheReaderPipeline() async throws {
        guard #available(iOS 18.0, *) else { return }
        struct Fixture: Decodable {
            let id: String; let polygon: [[Double]]; let translation: String
            let orientation: String; let freshOCR: Bool
            let ocrAngleToleranceDegrees: Double?
        }
        let fixtures = try JSONDecoder().decode([Fixture].self, from: Data(contentsOf: Self.directory.appendingPathComponent("fixtures.json")))
        let output = Self.directory.appendingPathComponent("fresh-ocr")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let selected = fixtures.filter(\.freshOCR)
        #expect(selected.count == 12)
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene); window.rootViewController = UIViewController(); window.makeKeyAndVisible()
        defer { window.isHidden = true; ReaderTranslationImageExporter.clearIdleRenderer() }
        for fixture in selected {
            let source = try #require(UIImage(contentsOfFile: Self.directory.appendingPathComponent(fixture.id + "-full.png").path)?.cgImage)
            let settings = ReaderTranslationSettings()
            let regions = try await ReaderOCRService.shared.recognize(image: source, configuration: settings.ocrConfiguration)
            let expected = try #require(BrowserOverlayRotation.geometry(polygon: fixture.polygon.map { CGPoint(x: $0[0], y: $0[1]) },
                singleVerticalColumn: fixture.orientation == "vertical"))
            let bounds = expected.footprint
            func rect(_ region: ReaderTranslationRegion) -> CGRect {
                CGRect(x: region.rect.minX * CGFloat(source.width), y: region.rect.minY * CGFloat(source.height),
                       width: region.rect.width * CGFloat(source.width), height: region.rect.height * CGFloat(source.height))
            }
            func overlap(_ region: ReaderTranslationRegion) -> CGFloat {
                let r = rect(region), i = r.intersection(bounds)
                guard !i.isNull else { return 0 }
                return i.width * i.height / (r.width * r.height + bounds.width * bounds.height - i.width * i.height)
            }
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(regions.map(ReaderTranslationStoredRegion.init)).write(to: output.appendingPathComponent(fixture.id + ".json"))
            let matched = try #require(regions.max { overlap($0) < overlap($1) })
            #expect(overlap(matched) > 0.35, "\(fixture.id) source correspondence")
            let latinControls = ["diverse-0474-g6": "INTENSITY", "diverse-0460-g1": "BEVERLY", "comic-4876-g2": "SALE"]
            if let word = latinControls[fixture.id] { #expect(matched.source.uppercased().contains(word)) }

            let polygon = matched.polygon.map { CGPoint(x: $0.x * CGFloat(source.width), y: $0.y * CGFloat(source.height)) }
            let detected = try #require(BrowserOverlayRotation.geometry(polygon: polygon,
                singleVerticalColumn: matched.sourceOrientation == .vertical && matched.sourceSingleVerticalColumn == true), "\(fixture.id) retained angle")
            let tolerance = (fixture.ocrAngleToleranceDegrees ?? 5) * .pi / 180
            #expect(abs(detected.radians - expected.radians) < tolerance, "\(fixture.id) reviewed silver-reference tolerance")
            var translated = matched; translated.translation = fixture.translation
            var renderSettings = settings
            renderSettings.targetLanguage = "ko"; renderSettings.overlay = ReaderTranslationSettings.defaultOverlay
            // Exercise the glyph-restoration path after fresh recognition,
            // not just the legacy translucent white-card geometry.
            renderSettings.overlay.preserveSourceColors = true
            renderSettings.overlay.opacity = 1
            let image = UIImage(cgImage: source)
            let viewport = CGSize(width: 430, height: 430 * image.size.height / image.size.width)
            let payload = try #require(BrowserPageImageOverlayRenderer.layoutPayload(
                items: ReaderTranslationRegion.overlayItems([translated], imageSize: image.size),
                imageSize: image.size, sourceRect: CGRect(origin: .zero, size: viewport),
                settings: renderSettings.overlay, targetLanguage: "ko", viewport: viewport).first)
            let angleValue = try #require(payload["rotation"] as? NSNumber)
            let renderedAngle = angleValue.doubleValue
            #expect(abs(renderedAngle - detected.radians) < 0.001, "\(fixture.id) full-page rotation")
            let rendered = try await ReaderTranslationImageExporter.render(image: image, regions: [translated],
                settings: renderSettings, viewport: viewport, aspectFit: false, host: window.rootViewController!.view)
            try rendered.pngData()?.write(to: output.appendingPathComponent(fixture.id + "-translated.png"))
            let report: [String: Any] = ["overlap": overlap(matched), "expectedAngle": expected.radians,
                "detectedAngle": detected.radians, "renderedAngle": renderedAngle,
                "source": matched.source, "translation": fixture.translation]
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                .write(to: output.appendingPathComponent(fixture.id + "-audit.json"))
        }
    }

    @Test(.enabled(if: FileManager.default.fileExists(atPath: directory.appendingPathComponent("ruby-00-+25.png").path)))
    func freshRotatedRubyImagesKeepOCRAndRenderingEvidence() async throws {
        guard #available(iOS 18.0, *) else { return }
        let ids = ["ruby-00-+25", "ruby-01--25", "ruby-02-+25", "ruby-03-+25",
                   "ruby-04--25", "ruby-05-+25", "ruby-06--25", "ruby-07-+25"]
        let output = Self.directory.appendingPathComponent("fresh-ruby")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene); window.rootViewController = UIViewController(); window.makeKeyAndVisible()
        defer { window.isHidden = true; ReaderTranslationImageExporter.clearIdleRenderer() }
        var readings = 0
        for id in ids {
            let image = try #require(UIImage(contentsOfFile: Self.directory.appendingPathComponent(id + "-full.png").path))
            let source = try #require(image.cgImage)
            var settings = ReaderTranslationSettings()
            let regions = try await ReaderOCRService.shared.recognize(image: source, configuration: settings.ocrConfiguration)
            #expect(!regions.isEmpty, "\(id) actual rotated source recognition")
            let anchors = ["ruby-00-+25": "楽園", "ruby-01--25": "人気者", "ruby-02-+25": "保護者",
                "ruby-03-+25": "魔法少女", "ruby-04--25": "示威運動", "ruby-05-+25": "難易度",
                "ruby-06--25": "風呂", "ruby-07-+25": "幽霊部"]
            #expect(regions.map(\.source).joined().contains(anchors[id]!), "\(id) recovered body anchor")
            let body = try #require(regions.first { $0.source.contains(anchors[id]!) })
            let angle = try #require(BrowserOverlayRotation.geometry(polygon: body.polygon.map {
                CGPoint(x: $0.x * CGFloat(source.width), y: $0.y * CGFloat(source.height))
            }, singleVerticalColumn: body.sourceSingleVerticalColumn == true), "\(id) merged body retained rotation")
            let expected: CGFloat = id.contains("--25") ? -25 : 25
            #expect(abs(angle.radians * 180 / .pi - expected) < 6, "\(id) merged body angle")
            let retainedReadings = regions.flatMap(\.auxiliaryInkPolygons).count
            if id != "ruby-07-+25" { #expect(retainedReadings >= 2, "\(id) reading ownership") }
            readings += retainedReadings
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(regions.map(ReaderTranslationStoredRegion.init)).write(to: output.appendingPathComponent(id + ".json"))
            settings.targetLanguage = "ko"; settings.overlay = ReaderTranslationSettings.defaultOverlay
            settings.overlay.preserveSourceColors = true; settings.overlay.opacity = 1
            let translated = regions.map { region in
                var copy = region; copy.translation = "이곳의 이야기를 전하는 말이야"; return copy
            }
            let viewport = CGSize(width: 430, height: 430 * image.size.height / image.size.width)
            let rendered = try await ReaderTranslationImageExporter.render(image: image, regions: translated,
                settings: settings, viewport: viewport, aspectFit: false, host: window.rootViewController!.view)
            try rendered.pngData()?.write(to: output.appendingPathComponent(id + "-translated.png"))
        }
        #expect(readings >= 50, "fresh OCR must retain reading geometry, separately from pixel inference")
    }

    // Fixed, reviewed dataset text/geometry. This isolates actual WebKit
    // layout/rasterization from changes in a remote translation provider.
    @Test(.enabled(if: FileManager.default.fileExists(atPath: directory.appendingPathComponent("fixtures.json").path)))
    func datasetReplay() async throws {
        struct Fixture: Decodable {
            let id: String; let source: String; let translation: String; let orientation: String
            let cropPolygon: [[Double]]; let expectedRotation: Bool
            let expectedAngle: Double
            let targetLanguage: String?
            let auxiliaryInkRects: [[Double]]?
            let auxiliaryInkPolygons: [[[Double]]]?
        }
        let fixtures = try JSONDecoder().decode([Fixture].self, from: Data(contentsOf: Self.directory.appendingPathComponent("fixtures.json")))
        let output = Self.directory.appendingPathComponent("results")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene); window.rootViewController = UIViewController(); window.makeKeyAndVisible()
        defer { window.isHidden = true }
        for fixture in fixtures {
            let data = try Data(contentsOf: Self.directory.appendingPathComponent(fixture.id + ".png"))
            let image = try #require(UIImage(data: data))
            let points = fixture.cropPolygon.map { CGPoint(x: $0[0], y: $0[1]) }
            let minX = points.map(\.x).min()!, maxX = points.map(\.x).max()!
            let minY = points.map(\.y).min()!, maxY = points.map(\.y).max()!
            let sourceBox = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
            let size = CGSize(width: 430, height: 430 * image.size.height / image.size.width)
            let web = Self.webFixture.acquire(frame: CGRect(origin: .zero, size: size))
            defer { Self.webFixture.release(web) }
            web.scrollView.contentInsetAdjustmentBehavior = .never
            window.rootViewController?.view.addSubview(web)
            defer { web.removeFromSuperview() }
            try await RegressionWebFixture.load("<meta name='viewport' content='width=device-width,initial-scale=1'><style>body{margin:0}img{display:block;width:100%}</style><img id='reader-source-image' src='data:image/png;base64,\(data.base64EncodedString())'>", in: web)

            _ = try await web.callAsyncJavaScript("await document.getElementById('reader-source-image').decode()", arguments: [:], in: nil, contentWorld: .page)
            var revision = 0
            for colors in [true, false] {
              for inpainting in [true, false] {
                for rotated in [false, true] {
                    revision += 1
                    let item = BrowserOverlayItem(stableRegionID: 0, rect: sourceBox,
                        sourceText: fixture.source, translatedText: fixture.translation, confidence: 0.99,
                        sourceOrientation: .init(tolerantRawValue: fixture.orientation),
                        sourceSingleVerticalColumn: fixture.orientation == "vertical",
                        sourcePolygon: rotated ? points : [],
                        auxiliaryInkRects: (fixture.auxiliaryInkRects ?? []).map { CGRect(x: $0[0], y: $0[1], width: $0[2], height: $0[3]) },
                        auxiliaryInkPolygons: (fixture.auxiliaryInkPolygons ?? []).map { $0.map { CGPoint(x: $0[0], y: $0[1]) } })
                    var settings = ReaderTranslationSettings.defaultOverlay
                    settings.preserveSourceColors = colors; settings.inpaintingEnabled = inpainting
                    let payload = BrowserPageImageOverlayRenderer.layoutPayload(items: [item], imageSize: image.size,
                        sourceRect: CGRect(origin: .zero, size: size), settings: settings,
                        targetLanguage: fixture.targetLanguage ?? "ko", viewport: size)
                    let start = Date()
                    _ = try await web.callAsyncJavaScript(BrowserPageImageOverlayRenderer.renderScript,
                        arguments: ["revision": String(revision), "session": fixture.id, "items": payload,
                            "appearance": ["opacity": 1, "preserveSourceTextColor": colors,
                                "preserveSourceBackgroundColor": colors, "inpaintingEnabled": inpainting,
                                "minimumReadableFontSize": 5]], in: nil, contentWorld: .page)
                    let audit = try #require(try await web.evaluateJavaScript(#"""
                    (()=>{const n=document.querySelector('[data-aidoku-image-ocr-overlay="item"]');
                      const s=getComputedStyle(n),m=new DOMMatrix(s.transform),r=document.createRange();r.selectNodeContents(n);
                      const b=r.getBoundingClientRect(),f=n.getBoundingClientRect();
                      return {text:n.textContent,rotation:Math.atan2(m.b,m.a),...n.dataset,
                        frame:[f.x,f.y,f.width,f.height],ink:[b.x,b.y,b.width,b.height],
                        local:[parseFloat(s.left),parseFloat(s.top),parseFloat(s.width),parseFloat(s.height)],
                        font:parseFloat(s.fontSize),color:s.color,background:s.backgroundColor,
                        visibility:s.visibility,
                        slantedMasks:[...document.querySelectorAll('[data-slanted-glyph-mask="true"]')]
                          .filter(p=>p.dataset.aidokuRegion===n.dataset.aidokuRegion).length,
                        axisAlignedPanels:[...document.querySelectorAll('[data-aidoku-image-ocr-overlay="source-readability-panel"]')]
                          .filter(p=>p.dataset.aidokuRegion===n.dataset.aidokuRegion&&getComputedStyle(p).transform==='none').length,
                        overflow:n.scrollHeight>n.clientHeight+1||n.scrollWidth>n.clientWidth+1};})()
                    """#) as? [String: Any])
                    #expect(audit["text"] as? String == fixture.translation)
                    #expect(audit["overflow"] as? Bool == false, "\(fixture.id) overflow")
                    let angle = try #require(audit["rotation"] as? Double)
                    if rotated && fixture.expectedRotation {
                        #expect(audit["rotatingPanel"] as? String == "true")
                        #expect(audit["axisAlignedPanels"] as? Int == 0, "\(fixture.id) must rotate its background too")
                        if colors && inpainting {
                            #expect(audit["background"] as? String == "rgba(0, 0, 0, 0)")
                            let erased = audit["slantedSourceErased"] as? String == "true"
                            #expect(audit["slantedArtworkSafe"] as? String == String(erased))
                            #expect(audit["slantedMasks"] as? Int == (erased ? 1 : 0))
                            #expect(audit["visibility"] as? String == (erased ? "visible" : "hidden"))
                            if erased, let floor = (audit["slantedFontFloor"] as? String).flatMap(Double.init),
                               let font = audit["font"] as? Double {
                                #expect(font >= floor - 0.01, "\(fixture.id) must keep readable text size")
                            }
                        } else {
                            #expect(audit["background"] as? String != "rgba(0, 0, 0, 0)")
                        }
                        if colors, let contrastValue = audit["sourceContrastAfter"] as? String,
                           let contrast = Double(contrastValue) {
                            #expect(contrast >= 4.49, "\(fixture.id) readable text on its rotated panel")
                        }
                        // Manifest reference is independent of the implementation
                        // and includes reviewed vertical-axis corrections.
                        #expect(abs(angle - fixture.expectedAngle * .pi / 180) < 0.001, "\(fixture.id) angle")
                        let frame = try #require(audit["frame"] as? [Double])
                        let scale = size.width / image.size.width
                        #expect(abs(frame[0] + frame[2] / 2 - points.map(\.x).reduce(0, +) / 4 * scale) < 1)
                        #expect(abs(frame[1] + frame[3] / 2 - points.map(\.y).reduce(0, +) / 4 * scale) < 1)
                    } else { #expect(abs(angle) < 0.001) }
                    let name = fixture.id + (colors ? "-colors" : "-white") + (inpainting ? "-inpaint" : "-panel") + (rotated ? "-after" : "-before")
                    let report: [String: Any] = ["fixture": fixture.id, "audit": audit, "payload": payload,
                        "renderSeconds": Date().timeIntervalSince(start), "sourceSize": [image.size.width, image.size.height]]
                    try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                        .write(to: output.appendingPathComponent(name + ".json"))
                    _ = try await web.callAsyncJavaScript("await new Promise(r=>requestAnimationFrame(()=>requestAnimationFrame(r)))", arguments: [:], in: nil, contentWorld: .page)
                    let config = WKSnapshotConfiguration(); config.rect = CGRect(origin: .zero, size: size)
                    let snapshot: UIImage = try await withCheckedThrowingContinuation { continuation in
                        web.takeSnapshot(with: config) { image, error in
                            if let image { continuation.resume(returning: image) }
                            else { continuation.resume(throwing: error ?? CancellationError()) }
                        }
                    }
                    try snapshot.pngData()?.write(to: output.appendingPathComponent(name + ".png"))
                }
              }
            }
        }
    }
}
