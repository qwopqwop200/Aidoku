import Testing
import UIKit
@testable import Aidoku

/// Explicit replay of the user-supplied original, kept in Documents/ConnectedBalloonReplay.
@Suite(.serialized)
@MainActor
struct ReaderConnectedBalloonReplayTests {
    @Test
    func originalPage() async throws {
        let directory = URL.documentsDirectory.appendingPathComponent("ConnectedBalloonReplay")
        let image = try #require(UIImage(contentsOfFile: directory.appendingPathComponent("original.png").path)?.cgImage)
        let audit = ConnectedRecognitionAudit()
        let profile = NativeCoreMLOCRModelProfile.profile(for: .medium)
        let pipeline = NativeCoreMLOCRPipeline(
            detector: NativeCoreMLDetector(modelResourceName: profile.detectorResourceName, maximumSide: 2000),
            recognizer: NativeCoreMLRecognizer(modelResourceName: profile.recognizerResourceName,
                dictionaryResourceName: profile.dictionaryResourceName,
                expectedDictionaryCharacterCount: profile.expectedDictionaryCharacterCount, maximumRecognitionWidth: 1600, auditObserver: { audit.record($0) }),
            postprocessConfiguration: profile.postprocessConfiguration)
        let raw = try await pipeline.recognize(image: image, requestID: "connected-balloon", confidenceThreshold: 0.35,
            detectorConfiguration: .init(threshold: 0.3, boxThreshold: 0.3, unclipRatio: 1.5,
                                         maximumCandidates: 3000, recoveryBoxThreshold: 0.2))
        try JSONSerialization.data(withJSONObject: raw.lines.map {
            ["text": $0.text, "score": $0.score, "polygon": $0.polygon.map { [$0.x, $0.y] },
             "orientation": $0.orientation.rawValue] as [String: Any]
        }, options: .prettyPrinted).write(to: directory.appendingPathComponent("raw.json"))
        try audit.data().write(to: directory.appendingPathComponent("recognizer.json"))
        await pipeline.purgeResources()
        let regions = try await ReaderOCRService.shared.recognize(image: image, configuration: .init(
            detectorMaximumSide: 2000, recognizerMaximumWidth: 1280, confidenceThreshold: 0.35, detectorPixelThreshold: 0.3, detectorConfidenceThreshold: 0.3))
        try JSONEncoder().encode(regions.map(ReaderTranslationStoredRegion.init))
            .write(to: directory.appendingPathComponent("regions.json"))
        try await render(regions, image: image, directory: directory)
        #expect(regions.count == 4)
        let right = try #require(regions.first { $0.source.hasPrefix("チェリノ") })
        // Source erasure must not include the balloon outline in the detector's padding.
        #expect(right.rect.minY > 0.075)
        #expect(right.rect.maxY < 0.2)
        #expect(right.rect.minX > 0.225)
        #expect(regions.contains { $0.source == "チェリノに会ったらよろしくね" })
        #expect(regions.contains { $0.source == "あと蚊が出たら殺しといて!" })
        #expect(regions.contains { $0.source == "分かりました" })
        #expect(regions.contains { $0.source == "■学園転覆" })
        await ReaderOCRService.shared.purge()
    }
    private func render(_ regions: [ReaderTranslationRegion], image: CGImage, directory: URL) async throws {
        // Fixed Korean fixture translations isolate OCR/layout from provider variability.
        let translations = ["チェリノに会ったらよろしくね": "체리노를 만나면 안부 전해 줘",
                            "あと蚊が出たら殺しといて!": "그리고 모기가 나오면 잡아 줘!",
                            "分かりました": "알겠습니다", "■学園転覆": "■학원 전복"]
        let translated = regions.map { original in
            var region = original
            region.translation = translations[original.source] ?? original.source
            return region
        }
        var settings = ReaderTranslationSettings()
        settings.overlay = ReaderTranslationSettings.defaultOverlay
        settings.overlay.inpaintingEnabled = true
        settings.overlay.preserveSourceBackgroundColor = true
        settings.overlay.preserveSourceTextColor = true
        settings.overlay.opacity = 1
        let size = CGSize(width: image.width, height: image.height)
        let viewport = CGSize(width: 430, height: 430 * size.height / size.width)
        let output = directory.appendingPathComponent("native-replay")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let uiImage = UIImage(cgImage: image)
        let rendered = try await NativeTranslationRenderer.render(image: uiImage, imageSize: size,
            items: ReaderTranslationRegion.layoutItems(translated, imageSize: size), settings: settings.overlay,
            targetLanguage: settings.targetLanguage, viewport: viewport, scale: 3, aspectFit: true,
            dark: false, collectDiagnostics: true)
        #expect(rendered.renderedItemCount > 0)
        let auditData = try #require(rendered.diagnosticData)
        try auditData.write(to: output.appendingPathComponent("audit.json"))
        try rendered.layoutData.write(to: output.appendingPathComponent("native-layout.json"))
        let auditObject = try JSONSerialization.jsonObject(with: auditData)
        let audit = try #require(auditObject as? [String: Any])
        let cards = try #require(audit["cards"] as? [[String: Any]])
        try #require(!cards.isEmpty)
        for card in cards {
            let panels = try #require(card["panels"] as? [[String: Any]])
            #expect(panels.isEmpty, "Connected balloon prose must not retain a source readability panel")
        }
        // Persist the same complete-page native export used by the reader cache.
        let snapshot = try await ReaderTranslationImageExporter.renderCacheSnapshot(
            image: uiImage, imageSize: size, regions: translated, settings: settings,
            viewport: viewport, scale: 3, aspectFit: true, host: nil, dark: false, preparedLayout: nil)
        let png = try #require(snapshot.pngData())
        try png.write(to: output.appendingPathComponent("render.png"))
    }

}

private final class ConnectedRecognitionAudit: @unchecked Sendable {
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
