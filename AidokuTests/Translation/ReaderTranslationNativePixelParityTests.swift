import Testing
import UIKit
import WebKit
import CryptoKit
@testable import Aidoku

/// Explicit, opt-in migration gate. Any differing decoded RGBA pixel fails;
/// typography antialiasing, cleanup and background differences are not waived.
@Suite(.serialized)
@MainActor
struct ReaderTranslationNativePixelParityTests {
    // Keep all native/WebKit capture gates in one serialized suite so only
    // one parity window is active at a time on the shared simulator.
    @Test func hanFontPaintMatchesActualIOSWebCaptureAtEveryTrackingSign() async throws {
        try await NativeHanPDFPaintParityCapture().run()
    }

    @Test func sourceCanvasPaintMatchesActualIOSWebCapture() async throws {
        try await NativeSourceCanvasPaintParityCapture().run()
    }

    @Test func sourceCanvasAlphaPaintMatchesActualIOSWebCapture() async throws {
        try await NativeSourceCanvasAlphaPaintParityCapture().run()
    }

    @Test func verticalCSSOMMatchesActualIOSForOriginalPlatformCases() async throws {
        try await NativeVerticalCSSOMParityCapture().run()
    }

    @Test func sourceCanvasBackingRoutesProduceDiagnosticCaptures() async throws {
        try await NativeSourceCanvasBackingDiagnosticCapture().run()
    }

    @Test func sourceCanvasTransformPaintMatchesActualIOSWebCapture() async throws {
        try await NativeSourceCanvasTransformPaintParityCapture().run()
    }

    @Test func sourceCanvasProducerRoutesProduceDiagnosticCaptures() async throws {
        try await NativeSourceCanvasProducerDiagnosticCapture().run()
    }

    @Test func foreignBackgroundPaintMatchesActualIOSWebCapture() async throws {
        try await NativeForeignBackgroundPaintParityCapture().run()
    }

    @Test func constantGradientBackendsProduceDiagnosticCaptures() async throws {
        try await NativeConstantGradientBackendDiagnosticCapture().run()
    }

    @Test func sourceCanvasRealizationRoutesProduceDiagnosticCaptures() async throws {
        try await NativeSourceCanvasRealizationDiagnosticCapture().run()
    }

    @Test func sourceCanvasLayersProduceDiagnosticCaptures() async throws {
        try await NativeSourceCanvasLayerDiagnosticCapture().run()
    }

    @Test func sourceCanvasRotationRepeatabilityProducesDiagnosticCaptures() async throws {
        try await NativeSourceCanvasRotationRepeatDiagnosticCapture().run()
    }

    @Test func detachedMetalGradientProducesDiagnosticCaptures() async throws {
        try await NativeDetachedGradientMetalDiagnosticCapture().run()
    }

    @Test func sourceCanvasDetachedMetalProducesDiagnosticCaptures() async throws {
        try await NativeSourceCanvasDetachedMetalDiagnosticCapture().run()
    }

    @Test func foreignBackgroundDetachedMetalMatchesImmutableCaptures() async throws {
        try await NativeForeignBackgroundDetachedMetalDiagnosticCapture().run()
    }

    @Test func detachedMetalWorkerMatchesImmutableGradientCaptures() async throws {
        try await NativeDetachedGradientWorkerDiagnosticCapture().run()
    }

    @Test func sourceCanvasAsyncDrawingProducesDiagnosticCaptures() async throws {
        try await NativeSourceCanvasAsyncPaintDiagnosticCapture().run()
    }

    @Test func sourceCanvasDetachedAsyncDrawingProducesDiagnosticCaptures() async throws {
        try await NativeSourceCanvasDetachedAsyncPaintDiagnosticCapture().run()
    }

    @Test func sourceCanvasDetachedUIViewDrawingProducesDiagnosticCaptures() async throws {
        try await NativeSourceCanvasDetachedUIViewPaintDiagnosticCapture().run()
    }

    @Test func sourceCanvasDetachedHierarchyDrawingProducesDiagnosticCaptures() async throws {
        try await NativeSourceCanvasDetachedHierarchyPaintDiagnosticCapture().run()
    }

    @Test func sourceCanvasOccludedHierarchyDrawingProducesDiagnosticCaptures() async throws {
        try await NativeSourceCanvasOccludedHierarchyPaintDiagnosticCapture().run()
    }

    @Test func sourceCanvasHierarchyCompositorMatchesActualIOSWebCapture() async throws {
        try await NativeSourceCanvasHierarchyParityCapture().run()
    }

    @Test func nativeFinalImagesExactlyMatchFrozenWebRenderer() async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIViewController()
        window.overrideUserInterfaceStyle = .light
        window.makeKeyAndVisible()
        defer { window.isHidden = true; ReaderTranslationImageExporter.clearIdleRenderer() }
        let directory = URL.documentsDirectory.appendingPathComponent("NativeRenderParity", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["gate": "exact-decoded-RGBA", "passed": false,
            "expectedFixtureCount": 0, "completedFixtureCount": 0, "fixtures": []] as [String: Any])
            .write(to: directory.appendingPathComponent("report.json"), options: .atomic)
        let fixtures = syntheticFixtures() + (try replayFixtures(in: directory))
        guard Set(fixtures.map(\.id)).count == fixtures.count else { throw ParityError.invalidFixture }
        var reports: [[String: Any]] = []
        var failures: [String] = []
        // Invalidate an earlier report before work starts; a crash cannot leave
        // a stale success associated with newly compiled renderer sources.
        try JSONSerialization.data(withJSONObject: ["gate": "exact-decoded-RGBA", "passed": false,
            "expectedFixtureCount": fixtures.count, "completedFixtureCount": 0, "fixtures": []] as [String: Any])
            .write(to: directory.appendingPathComponent("report.json"), options: .atomic)
        for fixture in fixtures {
            let output = directory.appendingPathComponent(fixture.id, isDirectory: true)
            if FileManager.default.fileExists(atPath: output.path) {
                try FileManager.default.removeItem(at: output)
            }
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            window.frame = CGRect(origin: .zero, size: fixture.viewport)
            let host = try #require(window.rootViewController?.view)
            host.frame = window.bounds
            let source = fixture.image
            let input = ["id": fixture.id, "viewport": [fixture.viewport.width, fixture.viewport.height],
                         "aspectFit": fixture.aspectFit, "targetLanguage": fixture.settings.targetLanguage,
                         "sourceDigest": ReaderTranslationRenderAsset.digestSource(source) ?? "unavailable",
                         "regionsDigest": ReaderTranslationRenderAsset.digest(fixture.regions),
                         "sourcePixelSize": [source.cgImage?.width ?? 0, source.cgImage?.height ?? 0]] as [String: Any]
            let settings = try JSONEncoder().encode(fixture.settings.overlay)
            let regions = try JSONEncoder().encode(fixture.regions.map(ReaderTranslationStoredRegion.init))
            try settings.write(to: output.appendingPathComponent("settings.json"))
            try regions.write(to: output.appendingPathComponent("regions.json"))
            try JSONSerialization.data(withJSONObject: input, options: [.prettyPrinted, .sortedKeys])
                .write(to: output.appendingPathComponent("input.json"))
            try #require(source.pngData()).write(to: output.appendingPathComponent("source.png"))
            do {
                let reference = try await frozenWebRender(fixture, host: host, output: output)
                let candidate = try await ReaderTranslationImageExporter.render(image: source, regions: fixture.regions,
                    settings: fixture.settings, viewport: fixture.viewport, aspectFit: fixture.aspectFit, host: host,
                    onNativeDiagnostic: { data in try data.write(to: output.appendingPathComponent("native-final-layout.json")) },
                    onNativePDFCapture: { data in try data.write(to: output.appendingPathComponent("native-typography.pdf")) },
                    onNativeLayersCapture: { data in try data.write(to: output.appendingPathComponent("native-layers.json")) })
                try #require(reference.pngData()).write(to: output.appendingPathComponent("web.png"))
                try #require(candidate.pngData()).write(to: output.appendingPathComponent("native.png"))
                let comparison = try compare(reference, candidate)
                try #require(comparison.diff.pngData()).write(to: output.appendingPathComponent("diff.png"))
                let report = comparison.report.merging(["id": fixture.id, "status": comparison.exact ? "exact" : "mismatch"]) { _, new in new }
                reports.append(report)
                if !comparison.exact { failures.append(fixture.id + ": decoded RGBA pixels differ") }
            } catch {
                reports.append(["id": fixture.id, "status": "error", "error": String(describing: error)])
                failures.append(fixture.id + ": " + String(describing: error))
            }
            // Preserve every completed comparison even if a later fixture crashes.
            let summary: [String: Any] = ["gate": "exact-decoded-RGBA", "passed": failures.isEmpty && reports.count == fixtures.count,
                "expectedFixtureCount": fixtures.count, "completedFixtureCount": reports.count,
                "os": UIDevice.current.systemVersion, "device": UIDevice.current.model,
                "nativeTypeface": UIFont.systemFont(ofSize: 12).fontName,
                "bundledLetterFonts": BrowserOverlayLetterFonts.shared.availabilityKey, "fixtures": reports]
            try JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys])
                .write(to: directory.appendingPathComponent("report.json"), options: .atomic)
        }
        #expect(failures.isEmpty, Comment(rawValue: failures.joined(separator: "\n")))
        #expect(reports.count == fixtures.count)
    }

    /// Replays saved input geometry/translations, never invokes OCR or a provider.
    private func frozenWebRender(_ fixture: Fixture, host: UIView, output: URL) async throws -> UIImage {
        let overlay = LegacyReaderTranslationOverlayView(frame: CGRect(origin: .zero, size: fixture.viewport))
        overlay.overrideUserInterfaceStyle = .light
        overlay.alpha = 0
        host.insertSubview(overlay, at: 0)
        defer { overlay.cancelWork(); overlay.removeFromSuperview() }
        let sourceRect = ReaderTranslationGeometry.displayRect(CGRect(x: 0, y: 0, width: 1, height: 1),
            imageSize: fixture.image.size, bounds: overlay.bounds, aspectFit: fixture.aspectFit)
        let payload = LegacyReaderTranslationLayout.layoutPayload(
            items: ReaderTranslationRegion.layoutItems(fixture.regions, imageSize: fixture.image.size),
            imageSize: fixture.image.size, sourceRect: sourceRect, settings: fixture.settings.overlay,
            targetLanguage: fixture.settings.targetLanguage, viewport: fixture.viewport)
        let layout = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        try layout.write(to: output.appendingPathComponent("web-layout.json"))
        let prepared = Task<Data, Error> { layout }
        overlay.update(regions: fixture.regions, imageSize: fixture.image.size, aspectFit: fixture.aspectFit,
                       settings: fixture.settings, image: fixture.image, preparedLayout: prepared)
        while overlay.lastDiagnostic?.outcome != .committed && overlay.lastDiagnostic?.outcome != .cleared {
            overlay.layoutIfNeeded()
            if case .failed = overlay.lastDiagnostic?.outcome { throw ParityError.referenceFailed }
            try await Task.sleep(for: .milliseconds(20))
        }
        guard overlay.lastDiagnostic?.isCacheable != false else { throw ParityError.referenceFailed }
        try await NativeSourceCanvasPixelDiagnostic.capture(image: fixture.image, webView: overlay.webView, output: output, fixtureID: fixture.id)
        let finalLayout = try await overlay.webView.callAsyncJavaScript(Self.finalWebLayoutScript,
            arguments: [:], in: nil, contentWorld: ReaderTranslationDOM.contentWorld)
        if let finalLayout = finalLayout as? String {
            try Data(finalLayout.utf8).write(to: output.appendingPathComponent("web-final-layout.json"))
        }
        let raw = try await overlay.webView.callAsyncJavaScript(ReaderTranslationImageExporter.prepareExportScript,
            arguments: [:], in: nil, contentWorld: ReaderTranslationDOM.contentWorld)
        let json = try #require(raw as? String)
        let data = Data(json.utf8)
        try data.write(to: output.appendingPathComponent("web-layers.json"))
        let layers = try JSONDecoder().decode(ReaderTranslationImageExporter.ExportLayers.self, from: data)
        let rect = ReaderTranslationGeometry.displayRect(CGRect(x: 0, y: 0, width: 1, height: 1),
            imageSize: fixture.image.size, bounds: overlay.bounds, aspectFit: fixture.aspectFit)
        let configuration = WKPDFConfiguration()
        configuration.rect = rect
        let pdf = try await withCheckedThrowingContinuation { continuation in
            overlay.webView.createPDF(configuration: configuration) { continuation.resume(with: $0) }
        }
        try pdf.write(to: output.appendingPathComponent("web-typography.pdf"))
        return try LegacyReaderTranslationCompositor.composite(image: fixture.image, typography: pdf, layers: layers,
            displayRect: rect, size: ReaderTranslationImageExporter.outputSize(for: fixture.image))
    }

    private struct Fixture {
        let id: String
        let image: UIImage
        let regions: [ReaderTranslationRegion]
        let settings: ReaderTranslationSettings
        var viewport = CGSize(width: 390, height: 700)
        var aspectFit = true
    }

    private func syntheticFixtures() -> [Fixture] {
        let name = "NativeParity-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        var settings = ReaderTranslationSettings(defaults: defaults)
        settings.automaticallyTranslate = true
        settings.includePageImage = false
        settings.sourceLanguage = "auto"
        settings.targetLanguage = "ko"
        settings.overlay = ReaderTranslationSettings.defaultOverlay
        settings.overlay.appearance = .white
        settings.overlay.opacity = 1
        let source = sourceImage(size: CGSize(width: 640, height: 880))
        let horizontal = ReaderTranslationRegion(id: "horizontal", rect: CGRect(x: 0.1, y: 0.1, width: 0.65, height: 0.16),
            source: "HELLO WORLD", translation: "안녕, 세상! 함께 출발하자.", sourceOrientation: .horizontal)
        let vertical = ReaderTranslationRegion(id: "vertical", rect: CGRect(x: 0.73, y: 0.32, width: 0.13, height: 0.34),
            source: "こんにちは世界", translation: "안녕하세요, 세계 여러분!", sourceOrientation: .vertical)
        let tilted = ReaderTranslationRegion(id: "tilted", rect: CGRect(x: 0.1, y: 0.57, width: 0.48, height: 0.17),
            source: "ガチャ", translation: "달칵!", polygon: [CGPoint(x: 0.1, y: 0.57), CGPoint(x: 0.58, y: 0.65),
                CGPoint(x: 0.57, y: 0.74), CGPoint(x: 0.09, y: 0.66)])
        var fixtures = [Fixture(id: "empty-source-identity", image: source, regions: [], settings: settings),
            Fixture(id: "horizontal-korean", image: source, regions: [horizontal], settings: settings),
            Fixture(id: "vertical-source", image: source, regions: [vertical], settings: settings),
            Fixture(id: "rotated-polygon", image: source, regions: [tilted], settings: settings),
            Fixture(id: "mixed-multiple-cards", image: source, regions: [horizontal, vertical, tilted], settings: settings)]
        var dark = settings
        dark.overlay.appearance = .dark
        dark.overlay.opacity = 0.55
        fixtures.append(Fixture(id: "dark-translucent", image: source, regions: [horizontal, vertical], settings: dark))
        var sourceSettings = settings
        sourceSettings.overlay.appearance = .source
        fixtures.append(Fixture(id: "source-color-inpainting", image: source, regions: [horizontal, tilted], settings: sourceSettings))
        var combined = settings
        combined.overlay.mode = .originalAndTranslation
        fixtures.append(Fixture(id: "original-plus-translation", image: source, regions: [horizontal, vertical], settings: combined))
        var cjk = settings
        cjk.targetLanguage = "ja"
        var cjkRegion = vertical
        cjkRegion.translation = "こんにちは、世界！…そう、あの時。"
        fixtures.append(Fixture(id: "vertical-japanese-punctuation", image: source, regions: [cjkRegion], settings: cjk))
        let small = ReaderTranslationRegion(id: "small", rect: CGRect(x: 0.2, y: 0.38, width: 0.1, height: 0.045),
            source: "먼저", translation: "너희 먼저 먹어.", sourceOrientation: .horizontal)
        fixtures.append(Fixture(id: "small-korean-word-fit", image: source, regions: [small], settings: settings))
        fixtures.append(Fixture(id: "landscape-fill", image: source, regions: [horizontal, vertical], settings: settings,
            viewport: CGSize(width: 700, height: 390), aspectFit: false))
        fixtures.append(Fixture(id: "webtoon-offscreen", image: sourceImage(size: CGSize(width: 480, height: 2400)),
            regions: [horizontal, vertical, tilted], settings: sourceSettings))
        return fixtures
    }

    private func sourceImage(size: CGSize) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.preferredRange = .standard
        return UIGraphicsImageRenderer(size: size, format: format).image { drawing in
            UIColor(white: 0.96, alpha: 1).setFill()
            drawing.fill(CGRect(origin: .zero, size: size))
            let context = drawing.cgContext
            context.setFillColor(UIColor(red: 0.7, green: 0.83, blue: 0.94, alpha: 1).cgColor)
            context.fill(CGRect(x: size.width * 0.04, y: size.height * 0.5, width: size.width * 0.57, height: size.height * 0.3))
            context.setFillColor(UIColor.white.cgColor)
            context.fillEllipse(in: CGRect(x: size.width * 0.06, y: size.height * 0.06, width: size.width * 0.74, height: size.height * 0.24))
            context.setFillColor(UIColor.black.cgColor)
            // Deterministic ink fixtures, independent of host font rasterization.
            for index in 0..<7 {
                let x = size.width * (0.14 + CGFloat(index) * 0.075)
                let y = size.height * 0.14
                context.fill(CGRect(x: x, y: y, width: 3, height: 24))
                context.fill(CGRect(x: x + 12, y: y, width: 3, height: 24))
                context.fill(CGRect(x: x, y: y + 10, width: 15, height: 3))
            }
            for index in 0..<6 {
                let y = size.height * (0.35 + CGFloat(index) * 0.043)
                context.fill(CGRect(x: size.width * 0.77, y: y, width: 20, height: 3))
                context.fill(CGRect(x: size.width * 0.78, y: y, width: 3, height: 24))
            }
        }
    }

    /// Optional real-image replay manifest. Geometry is normalized and source
    /// images/settings/translations are all frozen inputs supplied before launch.
    private func replayFixtures(in directory: URL) throws -> [Fixture] {
        let manifest = directory.appendingPathComponent("fixtures.json")
        guard FileManager.default.fileExists(atPath: manifest.path) else { return [] }
        let entries = try JSONDecoder().decode([ReplayFixture].self, from: Data(contentsOf: manifest))
        return try entries.map { entry in
            guard entry.id.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil else { throw ParityError.invalidFixture }
            guard entry.viewport.count == 2, entry.viewport.allSatisfy({ $0.isFinite && $0 > 0 }),
                  entry.viewport.allSatisfy({ $0 <= 16_384 }) else { throw ParityError.invalidFixture }
            let image = try #require(UIImage(contentsOfFile: directory.appendingPathComponent(entry.image).path))
            let data = try Data(contentsOf: directory.appendingPathComponent(entry.regions))
            let stored = try JSONDecoder().decode([ReaderTranslationStoredRegion].self, from: data)
            var settings = syntheticFixtures()[0].settings
            settings.overlay = try JSONDecoder().decode(IPhoneOverlaySettings.self,
                from: Data(contentsOf: directory.appendingPathComponent(entry.settings)))
            settings.targetLanguage = entry.targetLanguage
            return Fixture(id: entry.id, image: image, regions: stored.map(\.region), settings: settings,
                viewport: CGSize(width: entry.viewport[0], height: entry.viewport[1]), aspectFit: entry.aspectFit)
        }
    }

    private struct ReplayFixture: Decodable {
        let id: String
        let image: String
        let regions: String
        let settings: String
        let targetLanguage: String
        let viewport: [CGFloat]
        let aspectFit: Bool
    }
    /// Read committed DOM geometry before export preparation hides/extracts layers.
    private static let finalWebLayoutScript = """
    const box=r=>({x:r.left,y:r.top,width:r.width,height:r.height});
    const properties=['left','top','width','height','fontSize','lineHeight','fontFamily','fontWeight',
      'paddingTop','paddingRight','paddingBottom','paddingLeft','letterSpacing','textAlign',
      'color','backgroundColor','backgroundImage','webkitTextStrokeWidth','webkitTextStrokeColor',
      'paintOrder','transform','transformOrigin','scale','rotate','translate','clipPath',
      'overflow','overflowX','overflowY','boxSizing','alignItems','justifyContent',
      'opacity','visibility','display','borderRadius','zIndex'];
    const parentProperties=['fontStyle','writingMode','whiteSpace','wordBreak','textWrap','overflowWrap'];
    const layoutMetrics=element=>({offsetLeft:element.offsetLeft,offsetTop:element.offsetTop,
      offsetWidth:element.offsetWidth,offsetHeight:element.offsetHeight,
      scrollWidth:element.scrollWidth,scrollHeight:element.scrollHeight,
      clientWidth:element.clientWidth,clientHeight:element.clientHeight,
      clientLeft:element.clientLeft,clientTop:element.clientTop});
    const nodes=Array.from(document.querySelectorAll('[data-aidoku-image-ocr-overlay]'));
    return JSON.stringify({viewport:{width:innerWidth,height:innerHeight},
      layers:nodes.map(node=>{
        const computed=getComputedStyle(node),range=document.createRange();range.selectNodeContents(node);
        const style=Object.fromEntries([...properties,...parentProperties].map(key=>[key,computed[key]||'']));
        const inline=Object.fromEntries(properties.map(key=>[key,node.style[key]||'']));
        const context=document.createElement('canvas').getContext('2d');
        context.font=`${computed.fontStyle} ${computed.fontWeight} ${computed.fontSize} ${computed.fontFamily}`;
        context.letterSpacing=computed.letterSpacing;
        const metrics=text=>{
          const measured=context.measureText(text);
          return Object.fromEntries(['width','actualBoundingBoxLeft','actualBoundingBoxRight',
            'actualBoundingBoxAscent','actualBoundingBoxDescent','fontBoundingBoxAscent',
            'fontBoundingBoxDescent','emHeightAscent','emHeightDescent','alphabeticBaseline']
            .map(key=>[key,Number.isFinite(measured[key])?measured[key]:null]));
        };
        const scalarRects=[],walker=document.createTreeWalker(node,NodeFilter.SHOW_TEXT);
        let textNode,utf16Offset=0;
        while((textNode=walker.nextNode())){
          let offset=0;
          for(const scalar of Array.from(textNode.data)){
            if(!/^\\s$/.test(scalar)&&scalarRects.length<32768){
              const scalarRange=document.createRange();
              scalarRange.setStart(textNode,offset);scalarRange.setEnd(textNode,offset+scalar.length);
              const candidates=Array.from(scalarRange.getClientRects()).filter(r=>r.width>0&&r.height>0);
              if(candidates.length)scalarRects.push({scalar,utf16Offset:utf16Offset+offset,rect:box(candidates[candidates.length-1])});
            }
            offset+=scalar.length;
          }
          utf16Offset+=textNode.data.length;
        }
        return {kind:node.dataset.aidokuImageOcrOverlay,id:node.dataset.aidokuRegion||null,
          parentKind:node.parentElement?.dataset?.aidokuImageOcrOverlay||null,
          ...layoutMetrics(node),childElementCount:node.childElementCount,
          layoutChildren:Array.from(node.children).map(child=>{
            const childStyle=getComputedStyle(child);
            return {tag:child.tagName,kind:child.dataset?.aidokuImageOcrOverlay||null,
              text:child.textContent,rect:box(child.getBoundingClientRect()),...layoutMetrics(child),
              style:Object.fromEntries(properties.map(key=>[key,childStyle[key]||'']))};
          }),
          transformOrigin:computed.transformOrigin,
          text:node.textContent,rect:box(node.getBoundingClientRect()),ink:box(range.getBoundingClientRect()),
          lineRects:Array.from(range.getClientRects()).map(box),style,inline,dataset:{...node.dataset},
          canvasFont:context.font,textMetrics:metrics(node.textContent||''),koreanMetrics:metrics('안녕'),scalarRects};
      })});
    """

    private enum ParityError: Error { case referenceFailed, invalidFixture, invalidPixels }

    private func compare(_ reference: UIImage, _ candidate: UIImage) throws -> (exact: Bool, diff: UIImage, report: [String: Any]) {
        let lhs = try pixels(reference), rhs = try pixels(candidate)
        guard lhs.width == rhs.width, lhs.height == rhs.height else { throw ParityError.invalidPixels }
        var diff = [UInt8](repeating: 0, count: lhs.bytes.count)
        var changed = 0, maximum = 0, total: UInt64 = 0
        var minX = lhs.width, minY = lhs.height, maxX = -1, maxY = -1
        for offset in stride(from: 0, to: lhs.bytes.count, by: 4) {
            var pixelChanged = false
            for channel in 0..<4 {
                let delta = abs(Int(lhs.bytes[offset + channel]) - Int(rhs.bytes[offset + channel]))
                total += UInt64(delta)
                maximum = max(maximum, delta)
                pixelChanged = pixelChanged || delta != 0
                if channel < 3 { diff[offset + channel] = UInt8(delta) }
            }
            diff[offset + 3] = 255
            if pixelChanged {
                changed += 1
                let pixel = offset / 4, x = pixel % lhs.width, y = pixel / lhs.width
                minX = min(minX, x); minY = min(minY, y); maxX = max(maxX, x); maxY = max(maxY, y)
                if diff[offset] == 0 && diff[offset + 1] == 0 && diff[offset + 2] == 0 { diff[offset] = 255 }
            }
        }
        let provider = try #require(CGDataProvider(data: Data(diff) as CFData))
        let colorSpace = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let image = try #require(CGImage(width: lhs.width, height: lhs.height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: lhs.width * 4, space: colorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue), provider: provider,
            decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let report: [String: Any] = ["width": lhs.width, "height": lhs.height, "differentPixels": changed,
            "differentPixelFraction": Double(changed) / Double(lhs.width * lhs.height), "maximumChannelDelta": maximum,
            "meanAbsoluteChannelDelta": Double(total) / Double(lhs.bytes.count),
            "differenceBounds": changed == 0 ? [] : [minX, minY, maxX - minX + 1, maxY - minY + 1],
            "webRGBAHash": SHA256.hash(data: Data(lhs.bytes)).map { String(format: "%02x", $0) }.joined(),
            "nativeRGBAHash": SHA256.hash(data: Data(rhs.bytes)).map { String(format: "%02x", $0) }.joined()]
        return (changed == 0, UIImage(cgImage: image), report)
    }

    private func pixels(_ image: UIImage) throws -> (width: Int, height: Int, bytes: [UInt8]) {
        let source = try #require(image.cgImage)
        let width = source.width, height = source.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let colorSpace = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: colorSpace,
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            // Bitmap rows follow CGImage/PNG order. A UIKit coordinate flip
            // here inverted diagnostic bounds and the generated diff image.
            context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { throw ParityError.invalidPixels }
        return (width, height, bytes)
    }
}
