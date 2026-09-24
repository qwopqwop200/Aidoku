import CryptoKit
import Darwin
import Foundation
import Testing
import UIKit
@testable import Aidoku

/// Opt-in only. A fake HTTP transport replaces the server, not the production
/// request codec, response parser, batch matching, or final image renderer.
@Suite(.serialized) @MainActor
struct FullAuditTranslationReplayTests {
    nonisolated private static var root: URL { URL.documentsDirectory.appendingPathComponent("FullAuditReplay") }
    nonisolated private static var enabled: Bool { FileManager.default.fileExists(atPath: root.appendingPathComponent("enabled").path) }
    private static let texts = ["Open the door.", "Wait for me.", "We are home."]
    private static let translated = ["문을 열어 줘.", "기다려 줘.", "집에 도착했어."]

    private func settings() throws -> ReaderTranslationSettings {
        let name = "FullAuditReplay.isolated"
        let defaults = try #require(UserDefaults(suiteName: name))
        defaults.removePersistentDomain(forName: name)
        var value = ReaderTranslationSettings(defaults: defaults)
        value.provider = .custom
        value.custom.baseURL = "https://full-audit-replay.invalid/v1"
        value.custom.apiProtocol = .chatCompletions
        value.model = "full-audit-fixed-replay"
        value.reasoningEffort = .none
        value.sourceLanguage = "en"; value.targetLanguage = "ko"
        value.includePageImage = false; value.maximumConcurrentRequests = 1
        value.filterSFXWithLLM = false; value.filterBackgroundWithLLM = false
        value.translationSourceLanguages = []; value.rightToLeftPanelOrder = false
        value.overlay.visible = true
        return value
    }

    private var regions: [ReaderTranslationRegion] {
        Self.texts.enumerated().map { index, text in
            ReaderTranslationRegion(id: "region-\(index)",
                rect: CGRect(x: 0.15, y: 0.12 + Double(index) * 0.28, width: 0.7, height: 0.14),
                source: text, confidence: 0.99, sourceOrientation: .horizontal)
        }
    }

    private func source() -> UIImage {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.preferredRange = .standard
        return UIGraphicsImageRenderer(size: CGSize(width: 320, height: 480), format: format).image { context in
            UIColor(white: 0.82, alpha: 1).setFill(); context.fill(CGRect(x: 0, y: 0, width: 320, height: 480))
            for (index, region) in regions.enumerated() {
                let rect = CGRect(x: 35, y: region.rect.minY * 480 - 15, width: 250, height: 97)
                UIColor.white.setFill(); UIBezierPath(roundedRect: rect, cornerRadius: 24).fill()
                (Self.texts[index] as NSString).draw(in: CGRect(x: 55, y: region.rect.minY * 480, width: 210, height: 60),
                    withAttributes: [.font: UIFont.systemFont(ofSize: 20), .foregroundColor: UIColor.black])
            }
        }
    }

    @Test(.enabled(if: Self.enabled))
    func fixedHTTPParserRegionMappingAndFinalImages() async throws {
        guard #available(iOS 18.0, *) else { return }
        let settings = try settings(), input = regions, image = source()
        let output = Self.root.appendingPathComponent("artifacts")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.keyWindow, window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 320, height: 480)
        window.overrideUserInterfaceStyle = .light
        window.rootViewController = UIViewController(); window.makeKeyAndVisible()
        defer { window.isHidden = true; previous?.makeKey(); ReaderTranslationImageExporter.clearIdleRenderer() }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        try write(try #require(image.pngData()), name: "source.png", output: output)
        try write(try encoder.encode(input.map(ReaderTranslationStoredRegion.init)), name: "input-regions.json", output: output)
        var measurements: [[String: Any]] = []
        var firstBody: Data?, firstRegions: Data?, firstExport: Data?, firstOverlay: Data?
        for repetition in 0..<3 {
            // Fresh service means all three samples perform transport+parse+map;
            // no cached response is silently mistaken for a complete request.
            let transport = FullAuditReplayTransport(mode: .valid)
            let service = ReaderTranslationService(client: RemoteTranslationClient(
                credentialStore: FullAuditReplayCredentials(), transport: transport))
            let before = Self.footprintMiB(), start = ProcessInfo.processInfo.systemUptime
            let monitor = Task.detached { () -> [Double] in
                var samples: [Double] = []
                while !Task.isCancelled, samples.count < 3000 {
                    samples.append(Self.footprintMiB())
                    do { try await Task.sleep(for: .milliseconds(20)) } catch { break }
                }
                return samples
            }
            defer { monitor.cancel() }
            let translated = try await service.translate(regions: input, settings: settings)
            let translationMS = (ProcessInfo.processInfo.systemUptime - start) * 1000
            #expect(translated.map(\.id) == input.map(\.id))
            #expect(translated.map(\.source) == input.map(\.source))
            #expect(translated.map(\.rect) == input.map(\.rect))
            #expect(translated.map(\.translation) == Self.translated.map(Optional.some))
            let records = try encoder.encode(translated.map(ReaderTranslationStoredRegion.init))
            let bodies = await transport.bodies, responses = await transport.responses
            #expect(bodies.count == 1 && responses.count == 1)
            let body = try #require(bodies.first), response = try #require(responses.first)
            let renderStart = ProcessInfo.processInfo.systemUptime
            let exported = try await ReaderTranslationImageExporter.render(image: image, regions: translated,
                settings: settings, viewport: image.size, aspectFit: true, host: window)
            let renderMS = (ProcessInfo.processInfo.systemUptime - renderStart) * 1000
            let exportPNG = try #require(exported.pngData())
            let view = UIImageView(image: image); view.frame = CGRect(origin: .zero, size: image.size)
            view.contentMode = .scaleAspectFit; window.rootViewController?.view.addSubview(view)
            let page = ReaderTranslationPage(imageView: view)
            page.sourcePage = Page(sourceId: "full-audit-replay", chapterId: "fixed", index: 0)
            let displayStart = ProcessInfo.processInfo.systemUptime
            page.displayLoadedImage(.init(image: exported, regions: translated, settings: settings))
            view.layoutIfNeeded()
            #expect(page.isUsingCachedRendering)
            #expect(page.hasCompletedTranslation(settings: settings))
            #expect(!view.subviews.isEmpty)
            let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.preferredRange = .standard
            let visible = UIGraphicsImageRenderer(bounds: view.bounds, format: format).image { _ in
                view.drawHierarchy(in: view.bounds, afterScreenUpdates: true)
            }
            let overlayPNG = try #require(visible.pngData())
            let displayMS = (ProcessInfo.processInfo.systemUptime - displayStart) * 1000
            page.reset(); view.removeFromSuperview()
            try write(body, name: "request-\(repetition).json", output: output)
            try write(response, name: "response-\(repetition).json", output: output)
            try write(records, name: "regions-\(repetition).json", output: output)
            try write(exportPNG, name: "export-\(repetition).png", output: output)
            try write(overlayPNG, name: "overlay-\(repetition).png", output: output)
            if let firstBody { #expect(body == firstBody) }; firstBody = body
            if let firstRegions { #expect(records == firstRegions) }; firstRegions = records
            if let firstExport { #expect(exportPNG == firstExport) }; firstExport = exportPNG
            if let firstOverlay { #expect(overlayPNG == firstOverlay) }; firstOverlay = overlayPNG
            monitor.cancel()
            let memorySamples = await monitor.value
            let httpMS = await transport.elapsedMS.reduce(0, +)
            measurements.append(["iteration": repetition, "warmRenderer": repetition > 0,
                "fakeHTTPMilliseconds": httpMS, "parseMatchScheduleMilliseconds": translationMS - httpMS,
                "translationTotalMilliseconds": translationMS, "renderMilliseconds": renderMS,
                "commitAndSnapshotMilliseconds": displayMS, "footprintBeforeMiB": before,
                "footprintAfterMiB": Self.footprintMiB(), "sampledPeakMiB": memorySamples.max() ?? before,
                "memorySamples20ms": memorySamples, "requestCount": bodies.count,
                "exportSHA256": SHA256.hash(data: exportPNG).map { String(format: "%02x", $0) }.joined()])
        }
        let metadata: [String: Any] = ["samples": measurements, "scope": "Fixed HTTP transport, production parser and region matching, production export then cached overlay display. Footprints are app-process phase samples plus bounded20ms sampled peak, not continuous true peak; excludes WebKit. No real network. First renderer cold then warm; fresh translation service each iteration.",
            "os": ProcessInfo.processInfo.operatingSystemVersionString]
        try JSONSerialization.data(withJSONObject: metadata, options: [.sortedKeys, .prettyPrinted])
            .write(to: output.appendingPathComponent("measurements.json"), options: .atomic)
    }

    @Test(.enabled(if: Self.enabled), arguments: [FullAuditReplayTransport.Mode.missing, .duplicate])
    func malformedRegionIDsFailProductionParser(mode: FullAuditReplayTransport.Mode) async throws {
        let settings = try settings()
        let request = try #require(ReaderTranslationService.requests(regions: regions, settings: settings).first)
        let transport = FullAuditReplayTransport(mode: mode)
        let client = RemoteTranslationClient(credentialStore: FullAuditReplayCredentials(), transport: transport)
        do {
            _ = try await client.translate(request, configuration: settings.configuration)
            Issue.record("Missing/duplicate region IDs must fail production response validation")
        } catch let error as RemoteTranslationError {
            guard case .invalidResponse = error else { throw error }
        }
        #expect(await transport.bodies.count == 1)
    }

    @Test(.enabled(if: Self.enabled))
    func pendingAndCancelledHTTPKeepOriginalWithoutIntermediateOverlay() async throws {
        let settings = try settings(), image = source(), input = regions
        let transport = FullAuditReplayTransport(mode: .delayed)
        let service = ReaderTranslationService(client: RemoteTranslationClient(
            credentialStore: FullAuditReplayCredentials(), transport: transport))
        let view = UIImageView(image: image); view.frame = CGRect(origin: .zero, size: image.size)
        let page = ReaderTranslationPage(imageView: view)
        page.displayPrepared(input, settings: settings, completed: false)
        let work = Task { try await service.translate(regions: input, settings: settings) }
        defer { work.cancel(); page.reset() }
        for _ in 0..<100 where await transport.bodies.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        #expect(await transport.bodies.count == 1)
        #expect(view.image === image && view.subviews.isEmpty)
        #expect(!page.hasCompletedTranslation(settings: settings))
        work.cancel()
        do { _ = try await work.value; Issue.record("Cancelled HTTP must not return translated regions") }
        catch { #expect(error is CancellationError) }
        #expect(view.image === image && view.subviews.isEmpty)
        #expect(!page.canExportTranslation)
    }

    private func write(_ data: Data, name: String, output: URL) throws {
        try data.write(to: output.appendingPathComponent(name), options: .atomic)
        // Root can install untouched baseline artifacts here before the final
        // run. No tolerance or automatic reference replacement is permitted.
        let reference = Self.root.appendingPathComponent("reference").appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: reference.path) {
            #expect(try Data(contentsOf: reference) == data, "Exact baseline equality: \(name)")
        }
    }

    nonisolated private static func footprintMiB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1
    }
}

private struct FullAuditReplayCredentials: TranslationCredentialProviding {
    func secret(for account: String) throws -> String { "local-replay-placeholder" }
}

actor FullAuditReplayTransport: TranslationHTTPTransport {
    enum Mode: Sendable, Equatable { case valid, missing, duplicate, delayed }
    let mode: Mode
    var bodies: [Data] = [], responses: [Data] = [], elapsedMS: [Double] = []
    init(mode: Mode) { self.mode = mode }

    func data(for request: URLRequest, maximumResponseBytes: Int, bypassesProxy: Bool) async throws -> TranslationHTTPResponse {
        let start = ProcessInfo.processInfo.systemUptime
        defer { elapsedMS.append((ProcessInfo.processInfo.systemUptime - start) * 1000) }
        let body = try #require(request.httpBody)
        bodies.append(body) // HTTP body only: no Authorization/header/credential logging.
        if mode == .delayed { try await Task.sleep(for: .seconds(10)) }
        try Task.checkCancellation()
        let root = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let messages = try #require(root["messages"] as? [[String: Any]])
        let content = try #require(messages.first { $0["role"] as? String == "user" }?["content"])
        let text = try #require((content as? String) ?? (content as? [[String: Any]])?.compactMap { $0["text"] as? String }.first)
        let payload = try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        let segments = try #require(payload["segments"] as? [[String: Any]])
        let translations = ["Open the door.": "문을 열어 줘.", "Wait for me.": "기다려 줘.", "We are home.": "집에 도착했어."]
        var rows = try segments.reversed().map { segment -> [String: String] in
            let id = try #require(segment["id"] as? String)
            let sourceText = try #require(segment["text"] as? String)
            let translatedText = try #require(translations[sourceText])
            return ["id": id, "text": translatedText]
        }
        #expect(rows.count == 3)
        if mode == .missing { rows.removeLast() }
        if mode == .duplicate { rows[1]["id"] = rows[0]["id"] }
        let translated = String(decoding: try JSONSerialization.data(withJSONObject: ["translations": rows], options: [.sortedKeys]), as: UTF8.self)
        let envelope: [String: Any] = ["choices": [["index": 0, "finish_reason": "stop", "message": ["role": "assistant", "content": translated]]]]
        let data = try JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys])
        #expect(data.count <= maximumResponseBytes)
        responses.append(data)
        let url = try #require(request.url)
        let response = try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
        return .init(data: data, response: response)
    }
}
