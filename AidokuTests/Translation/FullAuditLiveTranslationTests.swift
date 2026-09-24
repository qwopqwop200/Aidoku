import Foundation
import Testing
import UIKit
import WebKit
@testable import Aidoku

/// Opt-in actual provider test. Runtime credentials stay in simulator Documents.
/// Live model runs are service validation, not deterministic output equivalence.
@Suite(.serialized)
@MainActor
struct FullAuditLiveTranslationTests {
    private nonisolated static var directory: URL {
        URL.documentsDirectory.appendingPathComponent("FullAuditLive")
    }

    @Test(.enabled(if: FileManager.default.fileExists(
        atPath: directory.appendingPathComponent("run.json").path
    )))
    func smallLiveTranslationReachesFinalRenderedOutput() async throws {
        let folder = Self.directory
        let config = try JSONDecoder().decode(Configuration.self, from: Data(
            contentsOf: folder.appendingPathComponent("run.json")
        ))
        let credentialURL = folder.appendingPathComponent(config.credentialFile).standardizedFileURL
        guard credentialURL.deletingLastPathComponent() == folder.standardizedFileURL else {
            throw AuditError.invalidCredentialPath
        }
        let credential = try String(contentsOf: credentialURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !credential.isEmpty else { throw AuditError.emptyCredential }
        let suite = "AidokuTests.FullAuditLive." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var settings = ReaderTranslationSettings(defaults: defaults)
        settings.provider = .custom
        settings.custom.baseURL = config.baseURL
        settings.custom.apiProtocol = .chatCompletions
        settings.model = config.model
        settings.targetLanguage = "ko"
        settings.maximumConcurrentRequests = 1
        settings.includePageImage = false
        if let effort = config.reasoningEffort { settings.reasoningEffort = effort }
        // Runtime override only; preserve product defaults, prompts, parser and timeout.
        let translator = ReaderTranslationService(client: RemoteTranslationClient(
            credentialStore: RuntimeCredential(value: credential),
            transport: BoundedURLSessionTransport()
        ))
        let output = folder.appendingPathComponent("output")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        // Preflight uses the same bounded URLSession implementation and proxy policy.
        let modelsURL = try #require(URL(string: config.baseURL)?.appendingPathComponent("models"))
        var modelsRequest = URLRequest(url: modelsURL)
        modelsRequest.timeoutInterval = 300
        modelsRequest.setValue("Bearer " + credential, forHTTPHeaderField: "Authorization")
        let modelsStarted = Date()
        do {
            let response = try await BoundedURLSessionTransport().data(
                for: modelsRequest, maximumResponseBytes: 1_048_576,
                bypassesProxy: modelsURL.scheme == "http"
            )
            let body = try JSONSerialization.jsonObject(with: response.data) as? [String: Any]
            let ids = (body?["data"] as? [[String: Any]])?.compactMap { $0["id"] as? String } ?? []
            let report: [String: Any] = [
                "stage": "models", "status": response.response.statusCode,
                "modelIDs": ids, "requestedModelPresent": ids.contains(config.model),
                "elapsedSeconds": Date().timeIntervalSince(modelsStarted),
                "headersMilliseconds": response.metrics.responseHeadersMilliseconds as Any? ?? NSNull(),
                "firstByteMilliseconds": response.metrics.firstBodyByteMilliseconds as Any? ?? NSNull(),
                "bodyMilliseconds": response.metrics.bodyMilliseconds as Any? ?? NSNull(),
                "totalMilliseconds": response.metrics.totalMilliseconds as Any? ?? NSNull()
            ]
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                .write(to: output.appendingPathComponent("models.json"))
            try #require(response.response.statusCode == 200)
            try #require(ids.contains(config.model))
        } catch {
            // Never serialize error descriptions/userInfo: those can contain requests.
            let safeError = error as NSError
            let report: [String: Any] = [
                "stage": "models", "errorDomain": safeError.domain, "errorCode": safeError.code,
                "elapsedSeconds": Date().timeIntervalSince(modelsStarted)
            ]
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                .write(to: output.appendingPathComponent("models-error.json"))
            throw error
        }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let size = CGSize(width: 400, height: 300)
        let source = UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            ("Good morning." as NSString).draw(
                in: CGRect(x: 40, y: 60, width: 320, height: 100),
                withAttributes: [.font: UIFont.systemFont(ofSize: 28), .foregroundColor: UIColor.black]
            )
        }
        let region = ReaderTranslationRegion(
            id: "greeting", rect: CGRect(x: 0.1, y: 0.2, width: 0.8, height: 1.0 / 3.0),
            source: "Good morning.", translation: nil
        )
        try #require(source.pngData()).write(to: output.appendingPathComponent("source.png"))
        let clock = ContinuousClock()
        let start = clock.now
        // No progress callback: no intermediate OCR/translation presentation.
        // Actual HTTP/parse failures propagate; there is no fixture fallback.
        let translated: [ReaderTranslationRegion]
        do {
            translated = try await translator.translate(regions: [region], settings: settings, image: source)
        } catch {
            let safeError = error as NSError
            let duration = start.duration(to: clock.now)
            let report: [String: Any] = [
                "stage": "translation", "errorDomain": safeError.domain, "errorCode": safeError.code,
                "elapsedSeconds": Double(duration.components.seconds) +
                    Double(duration.components.attoseconds) / 1e18
            ]
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                .write(to: output.appendingPathComponent("translation-error.json"))
            throw error
        }
        let translationFinished = clock.now
        try #require(translated.count == 1)
        let result = try #require(translated.first)
        #expect(result.id == region.id)
        #expect(result.rect == region.rect)
        #expect(result.source == region.source)
        let text = try #require(result.translation?.trimmingCharacters(in: .whitespacesAndNewlines))
        try #require(!text.isEmpty && text != region.source)
        try #require(text.unicodeScalars.contains { (0xAC00...0xD7A3).contains(Int($0.value)) })
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(translated.map(ReaderTranslationStoredRegion.init))
            .write(to: output.appendingPathComponent("regions.json"))

        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        let controller = UIViewController()
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        let overlay = ReaderTranslationOverlayView(frame: CGRect(origin: .zero, size: size))
        controller.view.addSubview(overlay)
        overlay.update(regions: translated, imageSize: source.size, aspectFit: false,
                       settings: settings, image: source)
        var committed = false
        for _ in 0..<600 {
            overlay.layoutIfNeeded()
            if overlay.lastDiagnostic?.outcome == .committed { committed = true; break }
            try await Task.sleep(for: .milliseconds(50))
        }
        try #require(committed)
        _ = try await overlay.webView.callAsyncJavaScript(
            "await new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve)))",
            arguments: [:], in: nil, contentWorld: ReaderTranslationDOM.contentWorld
        )
        let displayedTexts = try await overlay.webView.evaluateJavaScript(
            "Array.from(document.querySelectorAll('[data-aidoku-image-ocr-overlay=\"item\"]')).map(x=>x.textContent)"
        )
        let texts = try #require(displayedTexts as? [String])
        #expect(texts == [text])
        let displayed = clock.now
        let snapshot: UIImage = try await withCheckedThrowingContinuation { continuation in
            overlay.webView.takeSnapshot(with: nil) { image, error in
                if let image { continuation.resume(returning: image) }
                else { continuation.resume(throwing: error ?? AuditError.snapshotFailed) }
            }
        }
        try #require(snapshot.pngData()).write(to: output.appendingPathComponent("display.png"))
        let exported = try await ReaderTranslationImageExporter.render(
            image: source, regions: translated, settings: settings,
            viewport: size, aspectFit: false, host: controller.view
        )
        try #require(exported.pngData()).write(to: output.appendingPathComponent("export.png"))
        let finished = clock.now
        func seconds(_ duration: Duration) -> Double {
            Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
        }
        let timing: [String: Any] = [
            "translationServiceSeconds": seconds(start.duration(to: translationFinished)),
            "responseToDisplayedSeconds": seconds(translationFinished.duration(to: displayed)),
            "startToDisplayedSeconds": seconds(start.duration(to: displayed)),
            "snapshotAndExportSeconds": seconds(displayed.duration(to: finished)),
            "regionCount": translated.count, "displayTexts": texts,
            "liveProvider": true, "ocrExecuted": false, "fixedResponseReplay": false,
            "maximumConcurrentRequests": 1, "includePageImage": false,
            "reasoningPolicy": settings.reasoningEffort.rawValue,
            "outputEquivalenceProven": false
        ]
        try JSONSerialization.data(withJSONObject: timing, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("timing.json"))
    }

    @Test(.enabled(if: FileManager.default.fileExists(
        atPath: directory.appendingPathComponent("run.json").path
    )))
    func liveCancellationDoesNotPublishResult() async throws {
        let folder = Self.directory
        let config = try JSONDecoder().decode(Configuration.self, from: Data(
            contentsOf: folder.appendingPathComponent("run.json")
        ))
        let credentialURL = folder.appendingPathComponent(config.credentialFile).standardizedFileURL
        guard credentialURL.deletingLastPathComponent() == folder.standardizedFileURL else {
            throw AuditError.invalidCredentialPath
        }
        let credential = try String(contentsOf: credentialURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !credential.isEmpty else { throw AuditError.emptyCredential }
        let suite = "AidokuTests.FullAuditLive.Cancel." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var settings = ReaderTranslationSettings(defaults: defaults)
        settings.provider = .custom
        settings.custom.baseURL = config.baseURL
        settings.custom.apiProtocol = .chatCompletions
        settings.model = config.model
        settings.targetLanguage = "ko"
        settings.maximumConcurrentRequests = 1
        settings.includePageImage = false
        if let effort = config.reasoningEffort { settings.reasoningEffort = effort }
        let transport = CancellationAuditTransport()
        let service = ReaderTranslationService(client: RemoteTranslationClient(
            credentialStore: RuntimeCredential(value: credential), transport: transport
        ))
        let region = ReaderTranslationRegion(
            id: "cancel-greeting", rect: CGRect(x: 0.125, y: 0.125, width: 0.5, height: 0.25),
            source: "Good morning.", translation: nil
        )
        var completed = false
        var returnedResult = false
        var cancellationError = false
        var failureDomain: String?
        var failureCode: Int?
        let task = Task {
            defer { completed = true }
            do {
                _ = try await service.translate(regions: [region], settings: settings)
                returnedResult = true
            } catch {
                cancellationError = error is CancellationError
                let safe = error as NSError
                failureDomain = safe.domain
                failureCode = safe.code
            }
        }
        defer { task.cancel() }
        let clock = ContinuousClock()
        let started = clock.now
        while await transport.requestCount == 0 && !completed &&
                started.duration(to: clock.now) < .seconds(10) {
            try await Task.sleep(for: .milliseconds(10))
        }
        try await Task.sleep(for: .milliseconds(150))
        let finishedBeforeCancellation = completed
        let cancelledAt = clock.now
        task.cancel()
        while !completed && cancelledAt.duration(to: clock.now) < .seconds(10) {
            try await Task.sleep(for: .milliseconds(10))
        }
        let elapsed = cancelledAt.duration(to: clock.now)
        let output = folder.appendingPathComponent("output")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let report: [String: Any] = [
            "scope": "actual service and bounded transport cancellation; no UI/session exercised",
            "requestCount": await transport.requestCount,
            "activeTransportRequests": await transport.activeCount,
            "taskCompleted": completed,
            "resultReturned": returnedResult,
            "cancellationError": cancellationError,
            "completedBeforeCancel": finishedBeforeCancellation,
            "cancelToFinishSeconds": Double(elapsed.components.seconds) +
                Double(elapsed.components.attoseconds) / 1e18,
            "errorDomain": failureDomain as Any? ?? NSNull(),
            "errorCode": failureCode as Any? ?? NSNull(),
            "reasoningPolicy": settings.reasoningEffort.rawValue,
            "uiDisplayVerified": false
        ]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("cancellation.json"))
        try #require(!finishedBeforeCancellation, "Provider finished before cancellation; cancellation was not exercised")
        try #require(completed, "Cancellation did not finish within ten seconds")
        #expect(!returnedResult)
        #expect(cancellationError)
        #expect(await transport.requestCount == 1)
        #expect(await transport.activeCount == 0)
    }

    private actor CancellationAuditTransport: TranslationHTTPTransport {
        private(set) var requestCount = 0
        private(set) var activeCount = 0
        func data(for request: URLRequest, maximumResponseBytes: Int,
                  bypassesProxy: Bool) async throws -> TranslationHTTPResponse {
            try await data(for: request, maximumResponseBytes: maximumResponseBytes,
                           bypassesProxy: bypassesProxy, onBodyData: nil)
        }
        func data(for request: URLRequest, maximumResponseBytes: Int,
                  bypassesProxy: Bool, onBodyData: TranslationHTTPBodyObserver?) async throws -> TranslationHTTPResponse {
            // Count only; never retain or serialize URL, headers, payload or credentials.
            requestCount += 1
            guard requestCount == 1 else { throw CancellationError() }
            activeCount += 1
            defer { activeCount -= 1 }
            return try await BoundedURLSessionTransport().data(
                for: request, maximumResponseBytes: maximumResponseBytes,
                bypassesProxy: bypassesProxy, onBodyData: onBodyData
            )
        }
    }

    private struct Configuration: Decodable {
        let baseURL: String
        let model: String
        let credentialFile: String
        let reasoningEffort: OpenAIReasoningEffort?
    }
    private struct RuntimeCredential: TranslationCredentialProviding {
        let value: String
        func secret(for account: String) throws -> String { value }
    }
    private enum AuditError: Error {
        case invalidCredentialPath, emptyCredential, snapshotFailed
    }
}
