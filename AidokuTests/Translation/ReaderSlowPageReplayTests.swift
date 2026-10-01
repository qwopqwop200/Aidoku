import Testing
import UIKit
@testable import Aidoku

/// Opt-in reproduction with locally captured page data; no provider requests.
@Suite(.serialized) @MainActor
struct ReaderSlowPageReplayTests {
    @Test
    func recordedPageRenders() async throws {
        try #require(FileManager.default.fileExists(atPath:
            URL.documentsDirectory.appendingPathComponent("ZerodoReplay/source.avif").path), "Required local replay fixture is missing")
        let root = URL.documentsDirectory.appendingPathComponent("ZerodoReplay")
        let image = try #require(UIImage(contentsOfFile: root.appendingPathComponent("source.avif").path))
        let source = try ReaderTranslationBackgroundImage.prepare(image)
        try #require(source.pngData()).write(to: root.appendingPathComponent("source.prepared.png"))
        let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("translation-") && $0.pathExtension == "json" }
        #expect(!files.isEmpty)
        let viewport = CGSize(width: 430, height: 430 * image.size.height / image.size.width)
        var settings = ReaderTranslationSettings()
        settings.targetLanguage = "ko"
        settings.overlay = try JSONDecoder().decode(IPhoneOverlaySettings.self,
            from: Data(contentsOf: root.appendingPathComponent("overlay.json")))
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(origin: .zero, size: viewport)
        window.rootViewController = UIViewController()
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        var renderedPages = 0
        for file in files {
            let regions = try JSONDecoder().decode([ReaderTranslationStoredRegion].self, from: Data(contentsOf: file)).map(\.region)
            guard regions.count == 22 else { continue }
            let items = ReaderTranslationRegion.layoutItems(regions, imageSize: image.size)
            let payload = NativeTranslationLayoutPlanner.payload(items: items, imageSize: image.size,
                sourceRect: CGRect(origin: .zero, size: viewport), settings: settings.overlay,
                targetLanguage: "ko", viewport: viewport)
            let data = try JSONSerialization.data(withJSONObject: payload)
            try data.write(to: root.appendingPathComponent("page.payload.json"))
            let started = CACurrentMediaTime()
            let output = try await ReaderTranslationImageExporter.renderCacheSnapshot(
                image: image, imageSize: image.size, regions: regions, settings: settings,
                viewport: viewport, scale: 3, aspectFit: true, host: window, dark: false,
                preparedLayout: Task { data })
            print("SLOW_PAGE_RENDER elapsed_ms=\((CACurrentMediaTime() - started) * 1000) regions=\(regions.count)")
            try #require(output.pngData()).write(to: root.appendingPathComponent("rendered.png"))
            renderedPages += 1
        }
        #expect(renderedPages > 0, "The recorded 22-region page must actually be rendered")
    }
}
