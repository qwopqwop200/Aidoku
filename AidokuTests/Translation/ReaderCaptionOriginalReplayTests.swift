import Testing
import UIKit
import WebKit
@testable import Aidoku

/// Explicit local original-image replay. No image or credential is bundled.
@Suite(.serialized)
@MainActor
struct ReaderCaptionOriginalReplayTests {
    private static var directory: URL { URL.documentsDirectory.appendingPathComponent("CaptionOriginalReplay") }

    @Test
    func originalThroughOCRTranslationAndRendering() async throws {
        try #require(FileManager.default.fileExists(atPath:
            URL.documentsDirectory.appendingPathComponent("CaptionOriginalReplay/credential.txt").path), "Required local replay fixture is missing")
        let directory = Self.directory
        let image = try #require(UIImage(contentsOfFile: directory.appendingPathComponent("original.png").path))
        let cgImage = try #require(image.cgImage)
        let domain = "CaptionOriginalReplay." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let preferences = try #require(PropertyListSerialization.propertyList(
            from: Data(contentsOf: directory.appendingPathComponent("preferences.plist")), options: 0, format: nil) as? [String: Any])
        defaults.setPersistentDomain(preferences, forName: domain)
        let settings = ReaderTranslationSettings(defaults: defaults)
        let recognized = try await ReaderOCRService.shared.recognize(image: cgImage, configuration: settings.ocrConfiguration)
        #expect(!recognized.isEmpty)
        let credentials = ReplayCredentials(url: directory.appendingPathComponent("credential.txt"))
        let client = RemoteTranslationClient(credentialStore: credentials)
        let service = ReaderTranslationService(client: client)
        let translated = try await service.translate(regions: recognized, settings: settings, image: image)
        #expect(translated.contains { $0.translation?.contains("고마") == true })
        let size = CGSize(width: cgImage.width, height: cgImage.height)
        let viewport = CGSize(width: 430, height: 932)
        let frame = CGRect(origin: .zero, size: viewport)
        let items = ReaderTranslationRegion.layoutItems(translated, imageSize: size)
        let payload = try await BrowserPageImageOverlayRenderer.prepareLayoutData(items: items, imageSize: size,
            sourceRect: frame, settings: settings.overlay, targetLanguage: settings.targetLanguage, viewport: viewport)
        let values = try JSONSerialization.jsonObject(with: payload)
        let appearance: [String: Any] = ["opacity": settings.overlay.renderedBackgroundOpacity,
            "preserveSourceTextColor": settings.overlay.preserveSourceTextColor,
            "preserveSourceBackgroundColor": settings.overlay.preserveSourceBackgroundColor,
            "inpaintingEnabled": settings.overlay.usesSourceInpainting,
            "minimumReadableFontSize": BrowserOverlayLayoutPlanner.minimumRenderedFontSize]
        let document: [String: Any] = ["items": values, "appearance": appearance, "viewport": [430, 932],
            "scale": 3, "imageSize": [cgImage.width, cgImage.height], "displayRect": [0, 0, 430, 932]]
        try JSONSerialization.data(withJSONObject: document, options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appendingPathComponent("original.payload.json"))
        let web = WKWebView(frame: frame)
        web.loadHTMLString("<meta name='viewport' content='width=device-width,initial-scale=1'><body style='margin:0'>", baseURL: nil)
        for _ in 0..<200 where web.isLoading { try await Task.sleep(for: .milliseconds(20)) }
        let source = "data:image/png;base64," + (try Data(contentsOf: directory.appendingPathComponent("original.png"))).base64EncodedString()
        _ = try await web.callAsyncJavaScript(LegacyReaderTranslationOverlayView.backgroundScript,
            arguments: ["source": source, "fit": "contain", "revision": 1], in: nil, contentWorld: .page)
        let result = try await web.callAsyncJavaScript(BrowserPageImageOverlayRenderer.renderScript,
            arguments: ["items": values, "appearance": appearance, "revision": "1", "session": "original-replay"],
            in: nil, contentWorld: .page)
        print("CAPTION_ORIGINAL_REPLAY regions=\(recognized.count) translated=\(translated.count) result=\(String(describing: result))")
        let audit = try await web.evaluateJavaScript("""
        JSON.stringify(Array.from(document.querySelectorAll('[data-aidoku-image-ocr-overlay]')).map(n=>({
          kind:n.dataset.aidokuImageOcrOverlay,id:n.dataset.aidokuRegion,text:n.innerText,
          data:{...n.dataset},style:n.getAttribute('style'),rect:(()=>{const r=n.getBoundingClientRect();return [r.x,r.y,r.width,r.height]})()})))
        """)
        let auditData = Data((try #require(audit as? String)).utf8)
        try auditData.write(to: directory.appendingPathComponent("original.audit.json"))
        let auditRows = try #require(JSONSerialization.jsonObject(with: auditData) as? [[String: Any]])
        let captions = auditRows.filter { ($0["kind"] as? String) == "source-readability-panel" &&
            ($0["text"] as? String)?.contains("고마") == true }
        // The polish pass may detach the text from its owner; find the panel by
        // region identity in that case, rather than relying on DOM nesting.
        let captionIDs = Set(auditRows.filter { ($0["kind"] as? String) == "item" &&
            ($0["text"] as? String)?.contains("고마") == true }.compactMap { $0["id"] as? String })
        let owners = captions.isEmpty ? auditRows.filter { ($0["kind"] as? String) == "source-readability-panel" &&
            captionIDs.contains($0["id"] as? String ?? "") } : captions
        #expect(owners.isEmpty, "Short restored captions must not retain a rectangular panel")
        let caption = try #require(auditRows.first { ($0["kind"] as? String) == "item" &&
            captionIDs.contains($0["id"] as? String ?? "") })
        let data = try #require(caption["data"] as? [String: String])
        #expect(data["smallCaptionInpainted"] == "true")
        #expect(data["sourceBackgroundColor"] == "inpainted")
        let snapshot = try await web.takeSnapshot(configuration: nil)
        try #require(snapshot.pngData()).write(to: directory.appendingPathComponent("original.render.png"))
    }
}

private struct ReplayCredentials: TranslationCredentialProviding {
    let url: URL
    func secret(for account: String) throws -> String {
        try String(contentsOf: url, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
