import Foundation
import ImageIO
import UIKit
import WebKit
import Testing
@testable import Aidoku

/// Bundled detector precision contracts through the production pipeline.
@Suite(.serialized)
struct OCRDetectorPrecisionDeviceTests {

    /// Every bundled fp16 detector tier must load with the production
    /// configuration and return float32 output through the production pipeline.
    @Test func bundledFloat16DetectorsRunThroughProductionPipeline() async throws {
        let width = 800, height = 1_100
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        // Dark horizontal strokes resembling a text line.
        for row in 500..<530 { for column in 200..<600 where column % 40 < 28 {
            let offset = row * width * 4 + column * 4
            bytes[offset] = 0; bytes[offset + 1] = 0; bytes[offset + 2] = 0
        } }
        let frame = try #require(NativeOCRRGBAFrame(width: width, height: height, bytesPerRow: width * 4, bytes: bytes))
        for tier in IPhoneOCRModelTier.allCases {
            let profile = NativeCoreMLOCRModelProfile.profile(for: tier)
            let detector = NativeCoreMLDetector(modelResourceName: profile.detectorResourceName,
                                                maximumSide: IPhoneOCRSettings.defaultDetectorMaximumSide)
            let result = try await detector.detect(frame: frame, requestID: "fp16-\(tier.rawValue)",
                                                   configuration: profile.postprocessConfiguration)
            #expect(result.width == width && result.height == height)
            print("OCR_PRECISION_TIER \(tier.rawValue) boxes=\(result.boxes.count) ms=\(result.diagnostics.totalMilliseconds)")
            await detector.purgeResources()
        }
    }

    @Test
    @MainActor func capturedPanelIncidents() async throws {
        try #require(FileManager.default.fileExists(atPath:
            URL.documentsDirectory.appendingPathComponent("PanelIncidents/incident-1.image").path), "Required local replay fixture is missing")
        let directory = URL.documentsDirectory.appendingPathComponent("PanelIncidents")
        let pipeline = NativeCoreMLOCRPipeline(modelTier: .medium, detectorMaximumSide: 2000, recognizerMaximumWidth: 1600)
        for index in 1...3 {
            let source = try #require(CGImageSourceCreateWithURL(directory.appendingPathComponent("incident-\(index).image") as CFURL, nil))
            let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
            let result = try await pipeline.recognize(image: image, requestID: "panel-\(index)", confidenceThreshold: 0.35,
                detectorConfiguration: .init(threshold: 0.3, boxThreshold: 0.3, unclipRatio: 1.5, maximumCandidates: 3000, recoveryBoxThreshold: 0.2))
            func rows(_ lines: [NativeCoreMLOCRLine]) -> [[String: Any]] {
                lines.map { ["text": $0.text, "score": $0.score, "polygon": $0.polygon.map { [$0.x, $0.y] },
                             "orientation": $0.orientation.rawValue] }
            }
            let dump: [String: Any] = ["width": image.width, "height": image.height,
                "lines": rows(result.lines), "recovered": rows(result.recoveryCandidates),
                "isolated": rows(result.isolatedLines), "gaps": rows(result.gapLines.map(\.line)), "milliseconds": result.totalMilliseconds]
            try JSONSerialization.data(withJSONObject: dump, options: [.prettyPrinted, .sortedKeys])
                .write(to: directory.appendingPathComponent("incident-\(index).ocr.json"))
            #expect(!result.lines.isEmpty)
            await pipeline.purgeResources()
            let regions = try await ReaderOCRService.shared.recognize(image: image, configuration: .init(
                detectorMaximumSide: 2000, confidenceThreshold: 0.35, detectorPixelThreshold: 0.3, detectorConfidenceThreshold: 0.3))
            await ReaderOCRService.shared.purge()
            let grouped: [[String: Any]] = regions.map { ["id": $0.id, "source": $0.source,
                "rect": [$0.rect.minX, $0.rect.minY, $0.rect.width, $0.rect.height]] }
            try JSONSerialization.data(withJSONObject: grouped, options: [.prettyPrinted, .sortedKeys])
                .write(to: directory.appendingPathComponent("incident-\(index).regions.json"))
            let word = index == 1 ? "尻尾" : index == 2 ? "呼び込み" : "おっぱい"
            let target = try #require(regions.first { $0.source.contains(word) })
            if index == 1 {
                #expect(!target.source.contains("Bun"))
                #expect(target.rect.maxY < 0.21)
            } else if index == 2 {
                #expect(target.source.contains("そんなん"))
                #expect(target.rect.maxY > 0.15, "The detected final glyph must join its recovered column")
            } else {
                #expect(target.source.contains("うう"), "A short voiced opening belongs to the utterance")
            }
            let live = FileManager.default.fileExists(atPath: directory.appendingPathComponent("live-provider").path)
            var settings = ReaderTranslationSettings()
            if !live {
                settings.overlay = ReaderTranslationSettings.defaultOverlay
                settings.overlay.inpaintingEnabled = true
                settings.overlay.preserveSourceBackgroundColor = true
                settings.overlay.preserveSourceTextColor = true
                settings.overlay.opacity = 1
            }
            let uiImage = UIImage(cgImage: image)
            let translated: [ReaderTranslationRegion]
            if live {
                translated = try await ReaderTranslationService.shared.translate(regions: regions, settings: settings, image: uiImage)
                let caption = try #require(translated.first { $0.id == target.id })
                #expect(caption.translation != caption.source)
            } else {
                let text = try #require(JSONSerialization.jsonObject(with: Data(contentsOf:
                    directory.appendingPathComponent("translations.json"))) as? [String: String])
                translated = regions.map { value in
                    var region = value
                    region.translation = value.id == target.id ? text[String(index)] : value.source
                    return region
                }
            }
            let translatedRows: [[String: Any]] = translated.map {
                ["id": $0.id, "source": $0.source, "translation": $0.translation ?? ""]
            }
            try JSONSerialization.data(withJSONObject: ["liveProvider": live, "regions": translatedRows], options: [.sortedKeys])
                .write(to: directory.appendingPathComponent("incident-\(index).translation.json"))
            let size = CGSize(width: image.width, height: image.height), viewport = CGSize(width: 430, height: 574)
            let frame = CGRect(x: 0, y: 0, width: 430, height: 430 * size.height / size.width)
            let items = BrowserPageImageOverlayRenderer.layoutPayload(items: ReaderTranslationRegion.layoutItems(translated, imageSize: size),
                imageSize: size, sourceRect: frame, settings: settings.overlay, targetLanguage: "ko", viewport: viewport)
            let payload: [String: Any] = ["items": items, "imageSize": [image.width, image.height],
                "viewport": [430, 574], "scale": 3, "displayRect": [0, 0, 430, frame.height],
                "appearance": ["inpaintingEnabled": true, "minimumReadableFontSize": 5, "opacity": 1,
                               "preserveSourceBackgroundColor": true, "preserveSourceTextColor": true]]
            try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
                .write(to: directory.appendingPathComponent("incident-\(index).payload.json"))
            let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
            let window = UIWindow(windowScene: scene)
            window.frame = CGRect(origin: .zero, size: viewport)
            window.rootViewController = UIViewController()
            let overlay = LegacyReaderTranslationOverlayView(frame: window.bounds)
            window.rootViewController?.view.addSubview(overlay)
            window.makeKeyAndVisible()
            defer { overlay.cancelWork(); window.isHidden = true }
            overlay.update(regions: translated, imageSize: size, aspectFit: true, settings: settings, image: uiImage)
            for _ in 0..<400 where overlay.lastDiagnostic == nil { try await Task.sleep(for: .milliseconds(50)) }
            #expect(overlay.lastDiagnostic?.outcome == .committed)
            let audit = try await overlay.webView.evaluateJavaScript("""
            JSON.stringify(Array.from(document.querySelectorAll('[data-aidoku-image-ocr-overlay]')).map(n=>({
              kind:n.dataset.aidokuImageOcrOverlay,id:n.dataset.aidokuRegion,data:{...n.dataset}})))
            """)
            let auditData = Data((try #require(audit as? String)).utf8)
            try auditData.write(to: directory.appendingPathComponent("incident-\(index).audit.json"))
            let auditRows = try #require(JSONSerialization.jsonObject(with: auditData) as? [[String: Any]])
            let renderedID = String(try #require(translated.firstIndex { $0.id == target.id }))
            #expect(auditRows.contains { $0["kind"] as? String == "item" && $0["id"] as? String == renderedID })
            #expect(!auditRows.contains { $0["kind"] as? String == "source-readability-panel" && $0["id"] as? String == renderedID })
            // Use the same complete-page PDF rasterization as the reader cache;
            // a DOM commit can precede the first GPU snapshot's painted tiles.
            let snapshot = try await ReaderTranslationImageExporter.renderCacheSnapshot(
                image: uiImage, imageSize: size, regions: translated, settings: settings,
                viewport: viewport, scale: 3, aspectFit: true, host: window, dark: false, preparedLayout: nil)
            try #require(snapshot.pngData()).write(to: directory.appendingPathComponent("incident-\(index).render.png"))
        }
        await pipeline.purgeResources()
    }

}
