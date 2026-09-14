import CryptoKit
import Foundation
import Testing
import UIKit
import WebKit
@testable import Aidoku

/// Opt-in real-device phase measurement. Uses saved credentials without exporting
/// them, and isolated original images rather than the user's library/cache.
@Suite(.serialized) @MainActor
struct ReaderDeviceSpeedTests {
    @Test(.enabled(if: FileManager.default.fileExists(atPath:
        URL.documentsDirectory.appendingPathComponent("DeviceSpeed/manifest.json").path)))
    func actualPhonePipelinePhases() async throws {
        let directory = URL.documentsDirectory.appendingPathComponent("DeviceSpeed")
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: directory.appendingPathComponent("manifest.json")))
        let output = directory.appendingPathComponent(manifest.runLabel)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        var settings = ReaderTranslationSettings()
        settings.targetLanguage = "ko"; settings.sourceLanguage = "auto"; settings.translationSourceLanguages = []
        settings.rightToLeftPanelOrder = true
        let hasKey = (try? KeychainTranslationCredentialStore().containsSecret(for: settings.selectedCredentialAccount)) == true
        var liveAPI = manifest.liveAPI && settings.provider == .custom && hasKey &&
            URLComponents(string: settings.custom.baseURL)?.host == manifest.expectedHost && settings.model == manifest.model
        let client = DeviceSpeedClient(), service = ReaderTranslationService(client: client)
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.keyWindow, window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        window.rootViewController = UIViewController(); window.makeKeyAndVisible()
        let viewport = window.bounds.size
        let monitor = DeviceSpeedHeartbeat()
        let ticker = Task { @MainActor in
            while !Task.isCancelled {
                monitor.tick()
                try? await Task.sleep(for: .milliseconds(16))
            }
        }
        defer { ticker.cancel(); window.isHidden = true; previous?.makeKey() }
        await ReaderOCRService.shared.purge()
        var rows: [[String: Any]] = []
        let metadata: [String: Any] = ["device": UIDevice.current.model, "system": UIDevice.current.systemVersion,
            "viewport": [viewport.width, viewport.height], "scale": scene.screen.scale,
            "lowPower": ProcessInfo.processInfo.isLowPowerModeEnabled, "savedCredentialAvailable": hasKey,
            "liveAPIInitiallyEnabled": liveAPI, "concurrency": settings.maximumConcurrentRequests,
            "model": settings.model, "configuredProtocol": settings.custom.apiProtocol.rawValue, "scope": "Physical device: local image decode, actual ReaderOCRService, saved live provider, actual WKWebView DOM commit and snapshot. Excludes image download/navigation."]
        func save() throws {
            try JSONSerialization.data(withJSONObject: ["metadata": metadata, "rows": rows], options: [.prettyPrinted, .sortedKeys])
                .write(to: output.appendingPathComponent("results.json"), options: .atomic)
        }
        try save()
        for fixture in manifest.fixtures {
            var row: [String: Any] = ["id": fixture.id, "work": fixture.work,
                "thermalStart": ProcessInfo.processInfo.thermalState.rawValue]
            let started = ContinuousClock.now
            let bytes = try Data(contentsOf: directory.appendingPathComponent(fixture.image))
            let hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
            #expect(hash == fixture.imageSHA256)
            let source = try #require(UIImage(data: bytes)), pixels = try #require(source.cgImage)
            row["decodeMS"] = elapsed(started)
            monitor.reset()
            let ocrStart = ContinuousClock.now
            let raw = try await ReaderOCRService.shared.recognize(image: pixels, configuration: settings.ocrConfiguration)
            row["ocrMS"] = elapsed(ocrStart); row["ocrMainActorMaxGapMS"] = monitor.maximumGap
            row["regions"] = raw.count
            row["ocrPhasesMS"] = await ReaderOCRService.shared.lastPhaseMilliseconds
            let repeatStart = ContinuousClock.now
            let repeated = try await ReaderOCRService.shared.recognize(image: pixels, configuration: settings.ocrConfiguration)
            row["repeatOCRMS"] = elapsed(repeatStart)
            #expect(repeated.map(\.source) == raw.map(\.source))
            #expect(await ReaderOCRService.shared.lastPhaseMilliseconds["ocrPasses"] == 1)
            let prepareStart = ContinuousClock.now
            let prepared = await Task.detached(priority: .utility) { [settings] in
                ReaderTranslationImagePreparation.apply(raw, image: source, settings: settings)
            }.value
            row["imageEvidenceMS"] = elapsed(prepareStart)
            var translated: [ReaderTranslationRegion] = fixture.regions.map {
                .init(id: $0.id, rect: CGRect(x: $0.x, y: $0.y, width: $0.width, height: $0.height),
                      source: $0.source, translation: $0.translation,
                      sourceOrientation: $0.vertical == true ? .vertical : .horizontal)
            }
            row["renderInput"] = "stored provider fixture"
            if liveAPI {
                monitor.reset()
                let apiStart = ContinuousClock.now, progress = DeviceSpeedProgress()
                do {
                    translated = try await service.translate(regions: prepared, settings: settings, onProgress: { values in
                        await progress.observe(values)
                    })
                    row["apiMS"] = elapsed(apiStart)
                    row["firstTranslatedBatchMS"] = await progress.firstMS
                    row["apiMainActorMaxGapMS"] = monitor.maximumGap
                    row["renderInput"] = "live provider output"
                    let sent = ReaderTranslationLanguageFilter.apply(prepared, settings: settings)
                    let retained = Set(translated.map(\.id))
                    row["sentRegions"] = sent.map { ["source": $0.source] }
                    row["semanticExcludedSources"] = sent.filter { !retained.contains($0.id) }.map(\.source)
                    row["localExcludedCount"] = prepared.count - sent.count
                } catch {
                    row["apiMS"] = elapsed(apiStart)
                    row["apiErrorType"] = String(reflecting: type(of: error))
                    row["apiErrorDomain"] = (error as NSError).domain; row["apiErrorCode"] = (error as NSError).code
                    liveAPI = false
                }
            }
            let overlay = ReaderTranslationOverlayView(frame: CGRect(origin: .zero, size: viewport))
            window.rootViewController?.view.addSubview(overlay)
            monitor.reset()
            let renderStart = ContinuousClock.now
            overlay.update(regions: translated, imageSize: source.size, aspectFit: true, settings: settings, image: source)
            let deadline = Date().addingTimeInterval(30)
            while overlay.lastDiagnostic == nil {
                guard Date() < deadline else { throw URLError(.timedOut) }
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(overlay.lastDiagnostic?.outcome == .committed)
            row["domCommitMS"] = elapsed(renderStart); row["renderMainActorMaxGapMS"] = monitor.maximumGap
            let snapshotStart = ContinuousClock.now
            let snapshot = try await overlay.webView.takeSnapshot(configuration: nil)
            row["snapshotMS"] = elapsed(snapshotStart)
            try snapshot.pngData()?.write(to: output.appendingPathComponent(fixture.id + ".png"))
            row["renderedCards"] = overlay.lastDiagnostic?.renderedItemCount
            row["thermalEnd"] = ProcessInfo.processInfo.thermalState.rawValue
            row["translatedRegions"] = translated.map { ["id": $0.id, "source": $0.source, "translation": $0.translation ?? ""] }
            rows.append(row); try save()
            overlay.cancelWork(); overlay.removeFromSuperview()
        }
        let batches = await client.measurements
        try JSONSerialization.data(withJSONObject: batches, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("provider-batches.json"), options: .atomic)
        await ReaderOCRService.shared.purge()
    }

    private func elapsed(_ start: ContinuousClock.Instant) -> Double {
        let c = start.duration(to: .now).components
        return Double(c.seconds) * 1000 + Double(c.attoseconds) / 1e15
    }
    private struct Manifest: Decodable {
        let runLabel: String; let liveAPI: Bool; let compareOCR: Bool?; let expectedHost: String; let model: String; let fixtures: [Fixture]
    }
    private struct Fixture: Decodable {
        let id: String; let image: String; let imageSHA256: String; let work: String; let regions: [Region]
    }
    private struct Region: Decodable {
        let id: String; let x: CGFloat; let y: CGFloat; let width: CGFloat; let height: CGFloat
        let source: String; let translation: String; let vertical: Bool?
    }
}

@MainActor private final class DeviceSpeedHeartbeat {
    private var last = ContinuousClock.now
    var maximumGap: Double = 0
    func reset() { last = .now; maximumGap = 0 }
    func tick() {
        let c = last.duration(to: .now).components
        maximumGap = max(maximumGap, Double(c.seconds) * 1000 + Double(c.attoseconds) / 1e15)
        last = .now
    }
}
private actor DeviceSpeedProgress {
    private let start = ContinuousClock.now
    private(set) var firstMS: Double?
    func observe(_ regions: [ReaderTranslationRegion]) {
        guard firstMS == nil, regions.contains(where: { !($0.translation ?? "").isEmpty }) else { return }
        let c = start.duration(to: .now).components
        firstMS = Double(c.seconds) * 1000 + Double(c.attoseconds) / 1e15
    }
}
private actor DeviceSpeedClient: RemoteTranslating {
    private let client = RemoteTranslationClient()
    private(set) var measurements: [[String: Double]] = []
    func translate(_ request: RemoteTranslationRequest, configuration: RemoteTranslationConfiguration) async throws -> RemoteTranslationBatchResult {
        let start = ContinuousClock.now
        let result = try await client.translate(request, configuration: configuration)
        let c = start.duration(to: .now).components
        measurements.append(["milliseconds": Double(c.seconds) * 1000 + Double(c.attoseconds) / 1e15,
                             "segments": Double(request.segments.count)])
        return result
    }
}
