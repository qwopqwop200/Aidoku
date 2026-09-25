import Foundation
import Testing
import UIKit
import WebKit
@testable import Aidoku

/// Explicit opt-in device experiment. Reads saved provider credentials without exporting them.
@Suite(.serialized) @MainActor
struct ReaderPipelineOptimizationDeviceTests {
    private nonisolated static var folder: URL { URL.documentsDirectory.appendingPathComponent("PipelineOptimization") }

    @Test(.enabled(if: FileManager.default.fileExists(atPath: folder.appendingPathComponent("run.json").path)))
    func actualImagePipelineAndCompactResponsesComparison() async throws {
        let config = try JSONDecoder().decode(Config.self, from: Data(contentsOf: Self.folder.appendingPathComponent("run.json")))
        defer { try? FileManager.default.removeItem(at: Self.folder.appendingPathComponent("run.json")) }
        let settings = ReaderTranslationSettings()
        try #require(settings.provider == .custom && settings.custom.apiProtocol == .responses)
        try #require(settings.reasoningEffort == .none && settings.model == config.model)
        try #require(URL(string: settings.custom.baseURL)?.host == config.expectedHost)
        let endpoint = try settings.configuration.validatedEndpoint().absoluteString
        let output = Self.folder.appendingPathComponent("output")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let standard = RemoteTranslationClient(transport: PipelineRequestRecorder(folder: output, label: "standard"))
        standard.compactOutput.markUnsupported(endpoint)
        let candidate = RemoteTranslationClient(transport: PipelineRequestRecorder(folder: output, label: "candidate"))
        // Match reader-open behavior: metadata runs while OCR prepares the page.
        let metadata = Task { await candidate.prepare(configuration: settings.configuration) }
        defer { metadata.cancel() }
        var rows: [[String: Any]] = []
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.keyWindow
        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        window.rootViewController = UIViewController()
        window.makeKeyAndVisible()
        defer { window.isHidden = true; previous?.makeKey() }
        for (index, filename) in config.images.enumerated() {
            try #require(URL(fileURLWithPath: filename).lastPathComponent == filename)
            let imageData = try Data(contentsOf: Self.folder.appendingPathComponent(filename))
            let image = try #require(UIImage(data: imageData))
            let pixels = try #require(image.cgImage)
            let ocrStart = ProcessInfo.processInfo.systemUptime
            let recognized = try await ReaderOCRService.shared.recognize(image: pixels, configuration: settings.ocrConfiguration)
            let prepared = await Task.detached(priority: .utility) {
                ReaderTranslationImagePreparation.apply(recognized, image: image, settings: settings)
            }.value
            let ocrMilliseconds = elapsed(ocrStart)
            try #require(!prepared.isEmpty)
            for mode in (index.isMultiple(of: 2) ? ["standard", "candidate"] : ["candidate", "standard"]) {
                let client = mode == "standard" ? standard : candidate
                let wasCompact = client.compactOutput.state(for: endpoint) == .verified || client.compactOutput.state(for: endpoint) == .eligible
                // A fresh service prevents the A/B request from being satisfied by its memory cache.
                let service = ReaderTranslationService(client: client)
                let attachesImage = settings.shouldAttachPageImage
                let start = ProcessInfo.processInfo.systemUptime
                let translated = try await service.translate(regions: prepared, settings: settings, image: image)
                let apiMilliseconds = elapsed(start)
                try #require(!translated.isEmpty)
                #expect(Set(translated.map(\.id)).isSubset(of: Set(prepared.map(\.id))))
                #expect(translated.allSatisfy { !($0.translation ?? "").isEmpty })
                let overlay = ReaderTranslationOverlayView(frame: window.bounds)
                window.rootViewController?.view.addSubview(overlay)
                defer { overlay.cancelWork(); overlay.removeFromSuperview() }
                let renderStart = ProcessInfo.processInfo.systemUptime
                overlay.update(regions: translated, imageSize: image.size, aspectFit: true, settings: settings, image: image)
                let deadline = Date().addingTimeInterval(45)
                while overlay.lastDiagnostic == nil {
                    guard Date() < deadline else { throw URLError(.timedOut) }
                    try await Task.sleep(for: .milliseconds(20))
                }
                try #require(overlay.lastDiagnostic?.outcome == .committed)
                let renderMilliseconds = elapsed(renderStart)
                let snapshot = try await overlay.webView.takeSnapshot(configuration: nil)
                try snapshot.pngData()?.write(to: output.appendingPathComponent("\(index)-\(mode).png"))
                rows.append([
                    "imageIndex": index, "mode": mode, "compactEligibleBeforeRequest": wasCompact,
                    "compactVerifiedAfterRequest": client.compactOutput.state(for: endpoint) == .verified,
                    "attachesPageImage": attachesImage, "ocrAndPreparationMS": ocrMilliseconds, "apiMS": apiMilliseconds, "renderMS": renderMilliseconds,
                    "inputRegions": prepared.count, "outputRegions": translated.count,
                    "thermalState": ProcessInfo.processInfo.thermalState.rawValue,
                    "regions": translated.map { ["id": $0.id, "source": $0.source, "translation": $0.translation ?? ""] }
                ])
                let scope = "Physical device; saved settings; real local images, OCR, provider and DOM commit. No navigation or image download."
                try JSONSerialization.data(withJSONObject: ["rows": rows, "scope": scope], options: [.prettyPrinted, .sortedKeys])
                    .write(to: output.appendingPathComponent("results.json"), options: .atomic)
            }
        }
        #expect(candidate.compactOutput.state(for: endpoint) == .verified)
    }

    private func elapsed(_ start: TimeInterval) -> Double { (ProcessInfo.processInfo.systemUptime - start) * 1000 }
    private struct Config: Decodable { let model: String; let expectedHost: String; let images: [String] }
}

/// Opt-in experiment artifacts contain provider payloads, never HTTP headers or credentials.
private actor PipelineRequestRecorder: TranslationHTTPTransport {
    let folder: URL
    let label: String
    let transport = BoundedURLSessionTransport()
    private var index = 0

    init(folder: URL, label: String) { self.folder = folder; self.label = label }

    func data(for request: URLRequest, maximumResponseBytes: Int, bypassesProxy: Bool) async throws -> TranslationHTTPResponse {
        if let body = request.httpBody {
            let name = "\(label)-request-\(index).json"
            index += 1
            try body.write(to: folder.appendingPathComponent(name), options: .atomic)
        }
        return try await transport.data(for: request, maximumResponseBytes: maximumResponseBytes, bypassesProxy: bypassesProxy)
    }
}
