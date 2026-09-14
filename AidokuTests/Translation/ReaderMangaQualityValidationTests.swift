import Foundation
import Testing
import UIKit
import WebKit
@testable import Aidoku

/// Opt-in real-page/live-provider validation. Inputs and credentials live only
/// in the simulator's Documents/MangaQuality directory, never in the repository.
@Suite(.serialized)
@MainActor
struct ReaderMangaQualityValidationTests {
    private nonisolated static var directory: URL { URL.documentsDirectory.appendingPathComponent("MangaQuality") }

    @Test(.enabled(if: FileManager.default.fileExists(atPath: directory.appendingPathComponent("run.json").path)))
    func compareRealOCRTranslationAndTypesetting() async throws {
        let folder = Self.directory
        let config = try JSONDecoder().decode(Configuration.self, from: Data(contentsOf: folder.appendingPathComponent("run.json")))
        let suite = "AidokuTests.MangaQuality.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var settings = ReaderTranslationSettings(defaults: defaults)
        settings.provider = .custom
        settings.custom.baseURL = config.baseURL
        settings.custom.apiProtocol = .chatCompletions
        settings.model = config.model
        if let targetLanguage = config.targetLanguage { settings.targetLanguage = targetLanguage }
        settings.maximumConcurrentRequests = 2
        if let effort = config.reasoningEffort { settings.reasoningEffort = effort }
        if let instructions = config.instructions { settings.instructions = instructions }
        let translator = ReaderTranslationService(client: RemoteTranslationClient(
            credentialStore: QualityCredential(value: config.apiKey)
        ))
        let output = folder.appendingPathComponent(config.label)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        let controller = UIViewController()
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true }

        for fixture in config.fixtures {
            let input = try #require(UIImage(contentsOfFile: folder.appendingPathComponent(fixture).path)?.cgImage)
            let pixels = fixture == "reference.png"
                ? try #require(input.cropping(to: CGRect(x: 0, y: 465, width: 1290, height: 1866))) : input
            let source = UIImage(cgImage: pixels)
            let name = URL(fileURLWithPath: fixture).deletingPathExtension().lastPathComponent
            try source.pngData()?.write(to: output.appendingPathComponent(name + "-source.png"))
            let started = Date()
            let replay: [ReaderTranslationRegion]?
            if let replayDirectory = config.replayDirectory {
                replay = try JSONDecoder().decode([ReaderTranslationStoredRegion].self, from: Data(
                    contentsOf: folder.appendingPathComponent(replayDirectory).appendingPathComponent(name + "-regions.json")
                )).map(\.region)
            } else { replay = nil }
            let regions: [ReaderTranslationRegion]
            if let replay { regions = replay } else {
                regions = try await ReaderOCRService.shared.recognize(
                    image: #require(source.cgImage), configuration: settings.ocrConfiguration
                )
            }
            let ocrSeconds = Date().timeIntervalSince(started)
            #expect(!regions.isEmpty)
            // Keep the evidence even when a live provider fails or times out.
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(regions.map(ReaderTranslationStoredRegion.init))
                .write(to: output.appendingPathComponent(name + "-ocr.json"))
            if config.ocrOnly == true {
                let timing: [String: Any] = ["ocrSeconds": ocrSeconds, "regionCount": regions.count,
                                              "imageWidth": pixels.width, "imageHeight": pixels.height]
                try JSONSerialization.data(withJSONObject: timing, options: [.prettyPrinted, .sortedKeys])
                    .write(to: output.appendingPathComponent(name + "-timing.json"))
                continue
            }
            let translated: [ReaderTranslationRegion]
            do {
                if let replay { translated = replay } else { translated = try await translator.translate(regions: regions, settings: settings) }
            } catch {
                // Diagnose every real image even if one provider request fails.
                Issue.record(error)
                continue
            }
            #expect(translated.count == regions.count)
            #expect(translated.allSatisfy { $0.translation != nil })
            let records = translated.map(ReaderTranslationStoredRegion.init)
            try encoder.encode(records).write(to: output.appendingPathComponent(name + "-regions.json"))
            let size = CGSize(width: 430, height: 430 * source.size.height / source.size.width)
            let overlay = ReaderTranslationOverlayView(frame: CGRect(origin: .zero, size: size))
            controller.view.addSubview(overlay)
            overlay.update(regions: translated, imageSize: source.size, aspectFit: false, settings: settings,
                           image: source)
            var committed = false
            for _ in 0..<600 {
                overlay.layoutIfNeeded()
                if overlay.lastDiagnostic?.outcome == .committed { committed = true; break }
                try await Task.sleep(for: .milliseconds(50))
            }
            #expect(committed)
            let audit = try await overlay.webView.evaluateJavaScript("""
            Array.from(document.querySelectorAll('[data-aidoku-image-ocr-overlay="item"]')).map(x => {
              const s=getComputedStyle(x);return {text:x.textContent,x:parseFloat(s.left),y:parseFloat(s.top),
                width:parseFloat(s.width),height:parseFloat(s.height),fontSize:parseFloat(s.fontSize),
                border:s.borderWidth,shadow:s.boxShadow,scrollWidth:x.scrollWidth,clientWidth:x.clientWidth,
                scrollHeight:x.scrollHeight,clientHeight:x.clientHeight};
            })
            """)
            let report: [String: Any] = ["ocrSeconds": ocrSeconds, "totalSeconds": Date().timeIntervalSince(started),
                                       "regions": regions.count, "replayed": replay != nil, "dom": audit]
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                .write(to: output.appendingPathComponent(name + "-audit.json"))
            _ = try await overlay.webView.callAsyncJavaScript(
                "await new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve)))",
                arguments: [:], in: nil, contentWorld: ReaderTranslationDOM.contentWorld
            )
            let snapshot: UIImage = try await withCheckedThrowingContinuation { continuation in
                overlay.webView.takeSnapshot(with: nil) { image, error in
                    if let image { continuation.resume(returning: image) } else { continuation.resume(throwing: error ?? CancellationError()) }
                }
            }
            try snapshot.pngData()?.write(to: output.appendingPathComponent(name + "-translated.png"))
            overlay.removeFromSuperview()
        }
        await ReaderOCRService.shared.purge()
    }

    private struct Configuration: Decodable {
        let baseURL: String
        let model: String
        let apiKey: String
        let label: String
        let fixtures: [String]
        let instructions: String?
        let targetLanguage: String?
        let ocrOnly: Bool?
        let replayDirectory: String?
        let reasoningEffort: OpenAIReasoningEffort?
    }

    private struct QualityCredential: TranslationCredentialProviding {
        let value: String
        func secret(for account: String) throws -> String { value }
    }
}
