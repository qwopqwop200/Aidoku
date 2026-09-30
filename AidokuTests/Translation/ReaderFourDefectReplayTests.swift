import Testing
import UIKit
import WebKit
@testable import Aidoku

/// Explicit local replay: originals remain outside the repository and provider calls are not required.
@Suite(.serialized)
@MainActor
struct ReaderFourDefectReplayTests {
    @Test
    func capturedOriginals() async throws {
        try #require(FileManager.default.fileExists(atPath:
            URL.documentsDirectory.appendingPathComponent("FourDefectReplay/translations.json").path), "Required local replay fixture is missing")
        let directory = URL.documentsDirectory.appendingPathComponent("FourDefectReplay")
        for name in ["overflow", "missing"] {
            let image = try #require(UIImage(contentsOfFile: directory.appendingPathComponent(name + ".png").path)?.cgImage)
            let audit = FourDefectRecognitionAudit()
            let profile = NativeCoreMLOCRModelProfile.profile(for: .medium)
            let pipeline = NativeCoreMLOCRPipeline(
                detector: NativeCoreMLDetector(modelResourceName: profile.detectorResourceName, maximumSide: 2000),
                recognizer: NativeCoreMLRecognizer(modelResourceName: profile.recognizerResourceName,
                    dictionaryResourceName: profile.dictionaryResourceName,
                    expectedDictionaryCharacterCount: profile.expectedDictionaryCharacterCount,
                    maximumRecognitionWidth: 1600, auditObserver: { audit.record($0) }),
                postprocessConfiguration: profile.postprocessConfiguration)
            let raw = try await pipeline.recognize(image: image, requestID: name, confidenceThreshold: 0.35,
                detectorConfiguration: .init(threshold: 0.3, boxThreshold: 0.3, unclipRatio: 1.5,
                                             maximumCandidates: 3000, recoveryBoxThreshold: 0.2))
            func rows(_ lines: [NativeCoreMLOCRLine]) -> [[String: Any]] {
                lines.map { ["text": $0.text, "score": $0.score, "polygon": $0.polygon.map { [$0.x, $0.y] },
                             "orientation": $0.orientation.rawValue] }
            }
            try JSONSerialization.data(withJSONObject: ["lines": rows(raw.lines), "gaps": rows(raw.gapLines.map(\.line)),
                                                        "recovered": rows(raw.recoveryCandidates)], options: [.prettyPrinted])
                .write(to: directory.appendingPathComponent(name + ".raw.json"))
            try audit.data().write(to: directory.appendingPathComponent(name + ".recognizer.json"))
            if let frame = await NativeOCRCGImageAdapter.makeRGBAFrameOffMain(from: image) {
                let proposals = frame.bytes.withUnsafeBufferPointer { bytes in
                    let luminance: (Int, Int) -> Int = { x, y in
                        let i = y * frame.bytesPerRow + x * 4
                        return (Int(bytes[i]) * 299 + Int(bytes[i+1]) * 587 + Int(bytes[i+2]) * 114) / 1000
                    }
                    let lines = raw.lines.map { NativeOCRGapLineRecovery.Line(polygon: $0.polygon, text: $0.text) }
                    return NativeOCRGapLineRecovery.proposals(width: frame.width, height: frame.height,
                        luminance: luminance, lines: lines, blockers: []) + NativeOCRGapLineRecovery.edgeProposals(
                            width: frame.width, height: frame.height, luminance: luminance, lines: lines, blockers: [])
                }
                try JSONSerialization.data(withJSONObject: proposals.map { ["polygon": $0.polygon.map { [$0.x, $0.y] },
                    "edge": $0.edge] as [String: Any] }, options: [.prettyPrinted])
                    .write(to: directory.appendingPathComponent(name + ".proposals.json"))
            }
            await pipeline.purgeResources()
            let regions = try await ReaderOCRService.shared.recognize(image: image, configuration: .init(
                detectorMaximumSide: 2000, confidenceThreshold: 0.35, detectorPixelThreshold: 0.3, detectorConfidenceThreshold: 0.3))
            try JSONEncoder().encode(regions.map(ReaderTranslationStoredRegion.init))
                .write(to: directory.appendingPathComponent(name + ".regions.json"))
            #expect(!regions.isEmpty)
            if name == "overflow" {
                let caption = try #require(regions.first { $0.source.contains("パンツ") })
                #expect(!caption.source.contains("啡"))
                #expect(caption.rect.minX > 0.81)
            } else {
                let caption = try #require(regions.first { $0.source.contains("興味あるん") })
                #expect(caption.source.contains("レンタルペット"))
                #expect(caption.source.contains("だよなぁ"))
                #expect(!regions.contains { $0.source == "お払" })
                #expect(regions.contains { $0.source.contains("払ってないのにおっぱい") })
            }
            try await render(regions, image: image, name: name, directory: directory)
            await ReaderOCRService.shared.purge()
        }
    }
    private func render(_ regions: [ReaderTranslationRegion], image: CGImage, name: String, directory: URL) async throws {
        let translations = try #require(JSONSerialization.jsonObject(with: Data(contentsOf:
            directory.appendingPathComponent("translations.json"))) as? [String: String])
        var settings = ReaderTranslationSettings()
        settings.overlay = ReaderTranslationSettings.defaultOverlay
        settings.overlay.inpaintingEnabled = true
        settings.overlay.preserveSourceBackgroundColor = true
        settings.overlay.preserveSourceTextColor = true
        settings.overlay.opacity = 1
        let translated = regions.map { value in
            var region = value
            let key = name == "overflow" && value.source.contains("パンツ") ? "overflow"
                : value.source.contains("興味あるん") ? "missing"
                : value.source.contains("払ってないのに") ? "red" : ""
            region.translation = translations[key] ?? value.source
            return region
        }
        let uiImage = UIImage(cgImage: image)
        let prepared = try ReaderTranslationBackgroundImage.prepare(uiImage)
        try #require(prepared.pngData()).write(to: directory.appendingPathComponent(name + ".prepared.png"))
        let size = CGSize(width: image.width, height: image.height), viewport = CGSize(width: 430, height: 574)
        let frame = CGRect(x: 0, y: 0, width: 430, height: 430 * size.height / size.width)
        let items = BrowserPageImageOverlayRenderer.layoutPayload(items: ReaderTranslationRegion.layoutItems(translated, imageSize: size),
            imageSize: size, sourceRect: frame, settings: settings.overlay, targetLanguage: "ko", viewport: viewport)
        let payload: [String: Any] = ["items": items, "imageSize": [image.width, image.height],
            "viewport": [430, 574], "scale": 3, "displayRect": [0, 0, 430, frame.height],
            "appearance": ["inpaintingEnabled": true, "minimumReadableFontSize": 5, "opacity": 1,
                           "preserveSourceBackgroundColor": true, "preserveSourceTextColor": true]]
        try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
            .write(to: directory.appendingPathComponent("\(name).payload.json"))
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(origin: .zero, size: viewport)
        window.rootViewController = UIViewController()
        let overlay = ReaderTranslationOverlayView(frame: window.bounds)
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
        try auditData.write(to: directory.appendingPathComponent("\(name).audit.json"))
        let auditRows = try #require(JSONSerialization.jsonObject(with: auditData) as? [[String: Any]])
        let root = try #require(auditRows.first { $0["kind"] as? String == "root" }?["data"] as? [String: Any])
        let encoded = try #require(root["panelRestorationAudit"] as? String)
        let repairs = try #require(JSONSerialization.jsonObject(with: Data(encoded.utf8)) as? [[String: Any]])
        for (index, region) in translated.enumerated() where region.translation != region.source {
            let id = String(index)
            #expect(!auditRows.contains { $0["kind"] as? String == "source-readability-panel" && $0["id"] as? String == id })
            let repair = try #require(repairs.first { $0["id"] as? String == id })
            #expect(repair["sourceErasureVerified"] as? Bool == true)
            let minimum = name == "overflow" ? 35000 : region.source.contains("興味") ? 40000 : 75000
            #expect((repair["erased"] as? Int ?? 0) >= minimum, "Include the original white outlines, not just coloured cores")
        }
        // Use the same complete-page PDF rasterization as the reader cache;
        // a DOM commit can precede the first GPU snapshot's painted tiles.
        let snapshot = try await ReaderTranslationImageExporter.renderCacheSnapshot(
            image: uiImage, imageSize: size, regions: translated, settings: settings,
            viewport: viewport, scale: 3, aspectFit: true, host: window, dark: false, preparedLayout: nil)
        try #require(snapshot.pngData()).write(to: directory.appendingPathComponent("\(name).render.png"))
    }

}

private final class FourDefectRecognitionAudit: @unchecked Sendable {
    private let lock = NSLock()
    private var rows: [[String: Any]] = []
    func record(_ event: NativeCoreMLRecognitionAuditEvent) {
        guard case let .decoded(_, region, text, confidence, threshold, cacheHit) = event else { return }
        lock.lock(); defer { lock.unlock() }
        rows.append(["index": region.sourceIndex, "text": text, "confidence": confidence, "threshold": threshold,
                     "cached": cacheHit, "polygon": region.polygon.map { [$0.x, $0.y] }])
    }
    func data() throws -> Data {
        lock.lock(); defer { lock.unlock() }
        return try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted])
    }
}
