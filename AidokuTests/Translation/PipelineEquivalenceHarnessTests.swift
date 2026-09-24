import CryptoKit
import Darwin
import Foundation
import Testing
import UIKit
import WebKit
@testable import Aidoku

/// Opt-in, on-device equivalence + speed harness for the OCR -> translate -> render pipeline.
///
/// Enabled only when `AIDOKU_EQUIV_LABEL` is set (pass `TEST_RUNNER_AIDOKU_EQUIV_LABEL=<label>` to xcodebuild).
/// Fixtures: every png/jpg in `Documents/OptimizationFixtures` (or `AIDOKU_EQUIV_FIXTURES`, relative to Documents).
/// Output: `Documents/EquivalenceRuns/<label>/`.
///
/// Translation modes:
/// - `AIDOKU_EQUIV_TRANSLATIONS_IN=<path relative to Documents or absolute>` replays saved provider batches
///   through the real `ReaderTranslationService` (deterministic render input).
/// - otherwise the live provider is called via the production service; the batches are saved to
///   `<run>/translations.json` for later replay.
/// Optional: `AIDOKU_EQUIV_API_KEY` (else Keychain), `AIDOKU_EQUIV_REPEATS` (warm OCR/render repeats, default 3),
/// `AIDOKU_EQUIV_THERMAL_WAIT` (max seconds to wait before each fixture for thermal state <= fair, default 90; 0 disables).
/// Never changes the user's settings, keychain, library or caches.
@Suite(.serialized) @MainActor
struct PipelineEquivalenceHarnessTests {
    static let baseURL = "https://edgexpert-6027.tail39860f.ts.net/v1"
    static let model = "gemma-4-26b-a4b-it"
    private static var environment: [String: String] { ProcessInfo.processInfo.environment }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["AIDOKU_EQUIV_LABEL"] != nil), .timeLimit(.minutes(60)))
    func pipelineEquivalenceHarness() async throws {
        guard #available(iOS 18.0, *) else { return }
        let env = Self.environment
        let label = try #require(env["AIDOKU_EQUIV_LABEL"]).trimmingCharacters(in: .whitespacesAndNewlines)
        try #require(!label.isEmpty && !label.contains("/"))
        let repeats = max(1, Int(env["AIDOKU_EQUIV_REPEATS"] ?? "") ?? 3)
        let documents = URL.documentsDirectory
        let fixtureFolder = documents.appendingPathComponent(env["AIDOKU_EQUIV_FIXTURES"] ?? "OptimizationFixtures")
        let output = documents.appendingPathComponent("EquivalenceRuns").appendingPathComponent(label)
        try? FileManager.default.removeItem(at: output)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        let fixtures = try FileManager.default.contentsOfDirectory(at: fixtureFolder, includingPropertiesForKeys: nil)
            .filter { ["png", "jpg", "jpeg"].contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        try #require(!fixtures.isEmpty, "No fixtures in \(fixtureFolder.path)")

        // Translation mode.
        var replay: [String: [String: RemoteTranslatedSegment]]?
        var replaySource: String?
        if let raw = env["AIDOKU_EQUIV_TRANSLATIONS_IN"], !raw.isEmpty {
            let url = raw.hasPrefix("/") ? URL(fileURLWithPath: raw) : documents.appendingPathComponent(raw)
            if FileManager.default.fileExists(atPath: url.path) {
                replay = try Self.loadReplay(url)
                replaySource = url.path
            } else {
                Issue.record("AIDOKU_EQUIV_TRANSLATIONS_IN=\(raw) does not exist; falling back to live provider")
            }
        }

        // Deterministic, isolated settings (not read from or written to the user's defaults).
        let suiteName = "equivalence-harness-\(UUID().uuidString)"
        let isolatedDefaults = try #require(UserDefaults(suiteName: suiteName))
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
        var settings = ReaderTranslationSettings(defaults: isolatedDefaults)
        settings.provider = .custom
        settings.custom.baseURL = Self.baseURL
        let userSettings = ReaderTranslationSettings()
        settings.custom.apiProtocol = userSettings.provider == .custom &&
            userSettings.custom.baseURL.trimmingCharacters(in: .whitespacesAndNewlines) == Self.baseURL
            ? userSettings.custom.apiProtocol : .chatCompletions
        settings.model = Self.model
        settings.reasoningEffort = .none
        settings.includePageImage = true
        settings.sourceLanguage = "auto"
        settings.targetLanguage = "ko"
        settings.translationSourceLanguages = []
        settings.rightToLeftPanelOrder = true
        settings.maximumConcurrentRequests = 16
        settings.overlay = ReaderTranslationSettings.defaultOverlay
        settings.overlay.appearance = .source
        settings.overlay.enforceSourceReplacement()
        settings.ocr = ReaderOCRConfiguration()

        let apiKey = env["AIDOKU_EQUIV_API_KEY"]
        let credentials: TranslationCredentialProviding = apiKey.map { HarnessStaticCredential(key: $0) }
            ?? KeychainTranslationCredentialStore()
        let recorder = HarnessTranslationClient(
            live: replay == nil ? RemoteTranslationClient(credentialStore: credentials) : nil, replay: replay)
        let translationService = ReaderTranslationService(client: recorder)

        // Host window for WebKit rendering.
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.keyWindow
        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        window.rootViewController = UIViewController()
        window.makeKeyAndVisible()
        let host = try #require(window.rootViewController?.view)
        let viewport = window.bounds.size
        let scale = scene.screen.scale
        defer { window.isHidden = true; previous?.makeKey(); ReaderTranslationImageExporter.clearIdleRenderer() }

        let sampler = HarnessFootprintSampler()
        let sampling = Task.detached(priority: .high) { [sampler] in
            while !Task.isCancelled {
                sampler.sample()
                try? await Task.sleep(for: .milliseconds(5))
            }
        }
        defer { sampling.cancel() }

        await ReaderOCRService.shared.purge()
        ReaderTranslationImageExporter.clearIdleRenderer()

        var rows: [[String: Any]] = []
        let metadata: [String: Any] = [
            "label": label, "date": ISO8601DateFormatter().string(from: Date()),
            "device": UIDevice.current.model, "system": UIDevice.current.systemVersion,
            "viewport": [viewport.width, viewport.height], "scale": scale,
            "lowPower": ProcessInfo.processInfo.isLowPowerModeEnabled,
            "thermalStart": ProcessInfo.processInfo.thermalState.rawValue,
            "translationMode": replay == nil ? "live" : "replay", "replaySource": replaySource ?? NSNull(),
            "apiKeySource": apiKey == nil ? "keychain" : "environment",
            "model": settings.model, "baseURL": Self.baseURL, "apiProtocol": settings.custom.apiProtocol.rawValue,
            "reasoningEffort": settings.reasoningEffort.rawValue, "includePageImage": settings.includePageImage,
            "shouldAttachPageImage": settings.shouldAttachPageImage,
            "sourceLanguage": settings.sourceLanguage, "targetLanguage": settings.targetLanguage,
            "rightToLeftPanelOrder": settings.rightToLeftPanelOrder,
            "overlayUsesSourceInpainting": settings.overlay.usesSourceInpainting,
            "ocrModelTier": settings.ocr.modelTier.rawValue, "repeats": repeats,
            "fixtures": fixtures.map(\.lastPathComponent)
        ]
        func save() throws {
            var meta = metadata
            meta["peakFootprintMiBSampled"] = sampler.overallPeakMiB
            meta["lifetimePeakFootprintMiB"] = HarnessFootprintSampler.lifetimePeakMiB()
            meta["thermalEnd"] = ProcessInfo.processInfo.thermalState.rawValue
            try Self.writeJSON(["metadata": meta, "rows": rows], to: output.appendingPathComponent("results.json"))
        }
        try save()

        let thermalWait = Double(env["AIDOKU_EQUIV_THERMAL_WAIT"] ?? "") ?? 90
        for file in fixtures {
            let coolStart = ContinuousClock.now
            while thermalWait > 0, ProcessInfo.processInfo.thermalState.rawValue > ProcessInfo.ThermalState.fair.rawValue,
                  Self.ms(coolStart) < thermalWait * 1000 {
                try await Task.sleep(for: .seconds(2))
            }
            let thermalWaitMS = Self.ms(coolStart)
            let name = file.deletingPathExtension().lastPathComponent
            var row: [String: Any] = ["fixture": name, "file": file.lastPathComponent,
                                      "thermalStart": ProcessInfo.processInfo.thermalState.rawValue]
            sampler.beginWindow()
            row["thermalWaitMS"] = thermalWaitMS
            let bytes = try Data(contentsOf: file)
            row["sha256"] = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
            let decodeStart = ContinuousClock.now
            let decoded = try #require(UIImage(data: bytes))
            let source = Self.upright(decoded)
            let pixels = try #require(source.cgImage)
            row["decodeMS"] = Self.ms(decodeStart)
            row["size"] = [pixels.width, pixels.height]

            // 1a. Stage breakdown: standalone production pipeline (same configuration as ReaderOCRService).
            let configuration = settings.ocrConfiguration
            var stage: [[String: Any]] = []
            var rawLines: [NativeCoreMLOCRLine] = []
            do {
                let pipeline = NativeCoreMLOCRPipeline(modelTier: configuration.modelTier,
                    detectorMaximumSide: configuration.detectorMaximumSide,
                    recognizerMaximumWidth: configuration.recognizerMaximumWidth)
                for pass in 0...repeats {
                    let start = ContinuousClock.now
                    let result = try await pipeline.recognize(image: pixels, requestID: "equiv-\(name)-\(pass)",
                        confidenceThreshold: configuration.confidenceThreshold,
                        detectorConfiguration: configuration.detectorPostprocessConfiguration)
                    let wall = Self.ms(start)
                    if pass == 0 { rawLines = result.lines }
                    else if result.lines != rawLines { row["rawLinesUnstableAcrossPasses"] = true }
                    stage.append(["pass": pass, "wallMS": wall,
                        "frameConversionMS": result.frameConversionMilliseconds,
                        "detectionMS": result.detectionMilliseconds, "recognitionMS": result.recognitionMilliseconds,
                        "totalMS": result.totalMilliseconds, "detectedBoxes": result.detectedBoxes,
                        "selectedBoxes": result.selectedBoxes,
                        "detector": Self.mirror(result.diagnostics.detection),
                        "recognizer": result.diagnostics.recognition.map { Self.mirror($0) } ?? NSNull()])
                }
                await pipeline.purgeResources()
            }
            row["ocrStages"] = stage
            try Self.writeJSON(rawLines.enumerated().map { index, line in
                ["index": index, "text": line.text, "score": line.score, "orientation": line.orientation.rawValue,
                 "polygon": line.polygon.map { [Double($0.x), Double($0.y)] }]
            }, to: output.appendingPathComponent("\(name).lines.json"))

            // 1b. End-to-end production OCR service: fresh instance (cold) then warm repeats.
            let service = ReaderOCRService()
            var ocrRuns: [[String: Any]] = []
            var recognized: [ReaderTranslationRegion] = []
            for pass in 0...repeats {
                let start = ContinuousClock.now
                let regions = try await service.recognize(image: pixels, configuration: configuration)
                let wall = Self.ms(start)
                if pass == 0 { recognized = regions }
                else if regions != recognized { row["ocrUnstableAcrossPasses"] = true }
                ocrRuns.append(["pass": pass, "wallMS": wall, "phases": await service.lastPhaseMilliseconds])
            }
            await service.purge()
            row["ocrService"] = ocrRuns
            row["regions"] = recognized.count

            // Production post-OCR preparation (panel order, language filter).
            let prepStart = ContinuousClock.now
            let prepared = ReaderTranslationImagePreparation.apply(recognized, image: source, settings: settings)
            let eligible = ReaderTranslationLanguageFilter.apply(prepared, settings: settings)
            row["preparationMS"] = Self.ms(prepStart)
            row["eligibleRegions"] = eligible.count
            try Self.writeJSON(["imageSize": [pixels.width, pixels.height],
                                "regions": Self.describe(recognized, width: pixels.width, height: pixels.height),
                                "prepared": Self.describe(prepared, width: pixels.width, height: pixels.height),
                                "eligibleIDs": eligible.map(\.id)],
                               to: output.appendingPathComponent("\(name).ocr.json"))

            // 3. Translation through the production service (live or replay).
            await recorder.begin(fixture: name)
            var translated: [ReaderTranslationRegion] = []
            if !eligible.isEmpty {
                let progress = HarnessProgress()
                let start = ContinuousClock.now
                do {
                    translated = try await translationService.translate(regions: eligible, settings: settings,
                        image: source, onProgress: { values in await progress.observe(values) })
                    row["translationMS"] = Self.ms(start)
                    row["firstTranslatedBatchMS"] = await progress.firstMS ?? NSNull()
                } catch {
                    row["translationMS"] = Self.ms(start)
                    row["translationError"] = String(describing: error)
                    Issue.record("Translation failed for \(name): \(error)")
                }
            }
            let batches = await recorder.batches(for: name)
            row["providerBatches"] = batches.map { ["ms": $0.milliseconds, "segments": $0.segments.count,
                                                    "replayMisses": $0.replayMisses] }
            row["providerWallMS"] = batches.reduce(0.0) { $0 + $1.milliseconds }
            row["replayMisses"] = batches.reduce(0) { $0 + $1.replayMisses }
            try Self.writeJSON(translated.map { ["id": $0.id, "source": $0.source, "translation": ($0.translation as Any?) ?? NSNull()] as [String: Any] },
                               to: output.appendingPathComponent("\(name).translated.json"))

            // 4. Render the final composited page (production renderLoadedImage, no cache).
            let renderable = !ReaderTranslationRegion.overlayItems(translated, imageSize: source.size).isEmpty
            row["renderedItems"] = ReaderTranslationRegion.overlayItems(translated, imageSize: source.size).count
            if renderable {
                let rect = ReaderTranslationGeometry.displayRect(CGRect(x: 0, y: 0, width: 1, height: 1),
                    imageSize: source.size, bounds: CGRect(origin: .zero, size: viewport), aspectFit: true)
                // Layout payload (native, fresh measurement cache) - also dumped for equivalence.
                let layoutStart = ContinuousClock.now
                let payload = BrowserPageImageOverlayRenderer.layoutPayload(
                    items: ReaderTranslationRegion.overlayItems(translated, imageSize: source.size),
                    imageSize: source.size, sourceRect: rect, settings: settings.overlay,
                    targetLanguage: settings.targetLanguage, viewport: viewport,
                    measurementCache: BrowserOverlayTextMeasurementCache())
                row["layoutPayloadMS"] = Self.ms(layoutStart)
                try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
                    .write(to: output.appendingPathComponent("\(name).layout.json"), options: .atomic)

                ReaderTranslationImageExporter.clearIdleRenderer()
                var renderRuns: [Double] = []
                var first: Data?
                for pass in 0..<max(2, repeats) {
                    let start = ContinuousClock.now
                    let image = try await ReaderTranslationImageExporter.renderLoadedImage(
                        image: source, regions: translated, settings: settings, viewport: viewport, scale: scale,
                        aspectFit: true, dark: false, host: host, cache: nil, key: "equiv-\(label)-\(name)-\(pass)")
                    renderRuns.append(Self.ms(start))
                    let png = try #require(image.pngData())
                    if pass == 0 {
                        first = png
                        try png.write(to: output.appendingPathComponent("\(name).render.png"), options: .atomic)
                        row["renderPixelSize"] = [image.size.width * image.scale, image.size.height * image.scale]
                    } else if png != first {
                        row["renderUnstableAcrossPasses"] = true
                        try png.write(to: output.appendingPathComponent("\(name).render.pass\(pass).png"), options: .atomic)
                    }
                }
                row["renderTotalMS"] = renderRuns
                ReaderTranslationImageExporter.clearIdleRenderer()

                // Instrumented DOM pass (same overlay view the exporter uses) for in-page JS timings.
                let overlay = ReaderTranslationOverlayView(frame: CGRect(origin: .zero, size: viewport))
                host.addSubview(overlay)
                var exportSettings = settings
                exportSettings.overlay.visible = true
                let domStart = ContinuousClock.now
                overlay.update(regions: translated, imageSize: source.size, aspectFit: true,
                               settings: exportSettings, image: source)
                overlay.layoutIfNeeded()
                let deadline = Date().addingTimeInterval(30)
                while overlay.lastDiagnostic == nil || overlay.lastDiagnostic?.outcome == .stale {
                    if Date() >= deadline { break }
                    try await Task.sleep(for: .milliseconds(5))
                }
                row["domCommitMS"] = Self.ms(domStart)
                row["domOutcome"] = overlay.lastDiagnostic.map { String(describing: $0.outcome) } ?? "timeout"
                if let raw = try? await overlay.webView.evaluateJavaScript(Self.metricsScript) as? String,
                   let data = raw.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data) {
                    row["jsMetrics"] = object
                }
                overlay.cancelWork(); overlay.removeFromSuperview()
            }
            row["peakFootprintMiB"] = sampler.windowPeakMiB
            row["footprintMiBAfter"] = HarnessFootprintSampler.currentMiB()
            row["thermalEnd"] = ProcessInfo.processInfo.thermalState.rawValue
            rows.append(row)
            try save()
            print("EQUIV \(label) \(name) regions=\(recognized.count) translated=\(translated.count)")
        }

        if replay == nil {
            try Self.writeJSON(await recorder.export(), to: output.appendingPathComponent("translations.json"))
        }
        try save()
    }

    // MARK: - Helpers

    static let metricsScript = """
    (() => {
      const r = document.querySelector('[data-aidoku-image-ocr-overlay="root"]');
      if (!r) return JSON.stringify(null);
      const o = {};
      for (const k of Object.keys(r.dataset)) {
        if (/(Milliseconds|Count|Pixels|Hits|Samples|BudgetUsed)$/.test(k)) { const n = Number(r.dataset[k]); if (Number.isFinite(n)) o[k] = n; }
      }
      o.itemCount = document.querySelectorAll('[data-aidoku-image-ocr-overlay="item"]').length;
      return JSON.stringify(o);
    })()
    """

    private static func upright(_ image: UIImage) -> UIImage {
        guard image.imageOrientation != .up else { return image }
        let format = UIGraphicsImageRendererFormat()
        format.scale = image.scale
        format.preferredRange = .standard
        return UIGraphicsImageRenderer(size: image.size, format: format).image { _ in image.draw(at: .zero) }
    }

    static func describe(_ regions: [ReaderTranslationRegion], width: Int, height: Int) -> [[String: Any]] {
        let w = Double(width), h = Double(height)
        return regions.enumerated().map { index, region in
            [
                "index": index, "id": region.id, "source": region.source, "confidence": region.confidence,
                "rectNormalized": [region.rect.minX, region.rect.minY, region.rect.width, region.rect.height].map { Double($0) },
                "rectPx": [Double(region.rect.minX) * w, Double(region.rect.minY) * h,
                           Double(region.rect.width) * w, Double(region.rect.height) * h],
                "polygonPx": region.polygon.map { [Double($0.x) * w, Double($0.y) * h] },
                "orientation": region.sourceOrientation.rawValue,
                "singleVerticalColumn": region.sourceSingleVerticalColumn.map { $0 as Any } ?? NSNull(),
                "translationOrder": region.translationOrder.map { $0 as Any } ?? NSNull(),
                "auxiliaryInkRectsPx": region.auxiliaryInkRects.map {
                    [Double($0.minX) * w, Double($0.minY) * h, Double($0.width) * w, Double($0.height) * h]
                },
                "auxiliaryInkPolygonsPx": region.auxiliaryInkPolygons.map { $0.map { [Double($0.x) * w, Double($0.y) * h] } }
            ]
        }
    }

    /// Flattens a diagnostics struct into JSON-compatible values (numbers, strings, bools, arrays of those).
    static func mirror(_ value: Any) -> [String: Any] {
        var result: [String: Any] = [:]
        for child in Mirror(reflecting: value).children {
            guard let key = child.label else { continue }
            switch child.value {
            case let v as Double: result[key] = v.isFinite ? v : NSNull()
            case let v as Int: result[key] = v
            case let v as UInt64: result[key] = v
            case let v as Bool: result[key] = v
            case let v as String: result[key] = v
            case let v as [Int]: result[key] = v
            case let v as [String]: result[key] = v
            default: continue
            }
        }
        return result
    }

    private static func loadReplay(_ url: URL) throws -> [String: [String: RemoteTranslatedSegment]] {
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        let fixtures = object?["fixtures"] as? [String: Any] ?? [:]
        var result: [String: [String: RemoteTranslatedSegment]] = [:]
        for (fixture, value) in fixtures {
            var map: [String: RemoteTranslatedSegment] = [:]
            for batch in (value as? [[String: Any]]) ?? [] {
                let segments = batch["segments"] as? [[String: Any]] ?? []
                let translations = batch["translations"] as? [[String: Any]] ?? []
                let texts = Dictionary(segments.compactMap { s -> (String, String)? in
                    guard let id = s["id"] as? String, let text = s["text"] as? String else { return nil }
                    return (id, text)
                }, uniquingKeysWith: { a, _ in a })
                for t in translations {
                    guard let id = t["id"] as? String, let text = t["text"] as? String, let sourceText = texts[id] else { continue }
                    map[HarnessTranslationClient.key(id: id, text: sourceText)] =
                        RemoteTranslatedSegment(id: id, text: text, isSFX: t["isSFX"] as? Bool)
                }
            }
            result[fixture] = map
        }
        return result
    }

    static func writeJSON(_ object: Any, to url: URL) throws {
        try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]).write(to: url, options: .atomic)
    }

    nonisolated static func ms(_ start: ContinuousClock.Instant) -> Double {
        let c = start.duration(to: .now).components
        return Double(c.seconds) * 1000 + Double(c.attoseconds) / 1e15
    }
}

private struct HarnessStaticCredential: TranslationCredentialProviding {
    let key: String
    func secret(for account: String) throws -> String { key }
}

private actor HarnessProgress {
    private let start = ContinuousClock.now
    private(set) var firstMS: Double?
    func observe(_ regions: [ReaderTranslationRegion]) {
        guard firstMS == nil, regions.contains(where: { !($0.translation ?? "").isEmpty }) else { return }
        firstMS = PipelineEquivalenceHarnessTests.ms(start)
    }
}

/// Records every provider batch (live) or serves saved batches (replay) behind the production service.
private actor HarnessTranslationClient: RemoteTranslating {
    struct Batch: Sendable {
        let segments: [RemoteTranslationSegment]
        let translations: [RemoteTranslatedSegment]
        let milliseconds: Double
        let replayMisses: Int
    }
    private let live: RemoteTranslationClient?
    private let replay: [String: [String: RemoteTranslatedSegment]]?
    private var fixture = ""
    private var recorded: [String: [Batch]] = [:]

    init(live: RemoteTranslationClient?, replay: [String: [String: RemoteTranslatedSegment]]?) {
        self.live = live
        self.replay = replay
    }

    static func key(id: String, text: String) -> String { id + "\u{1F}" + text }

    func begin(fixture: String) { self.fixture = fixture }

    func batches(for fixture: String) -> [Batch] { recorded[fixture] ?? [] }

    func translate(_ request: RemoteTranslationRequest, configuration: RemoteTranslationConfiguration) async throws -> RemoteTranslationBatchResult {
        let owner = fixture
        let start = ContinuousClock.now
        if let replay {
            let map = replay[owner] ?? [:]
            var misses = 0
            let translations = request.segments.map { segment -> RemoteTranslatedSegment in
                if let hit = map[Self.key(id: segment.id, text: segment.text)] {
                    return RemoteTranslatedSegment(id: segment.id, text: hit.text, isSFX: hit.isSFX)
                }
                // Same text under another id (e.g. candidate regrouped regions).
                if let hit = map.first(where: { $0.key.hasSuffix("\u{1F}" + segment.text) })?.value {
                    return RemoteTranslatedSegment(id: segment.id, text: hit.text, isSFX: hit.isSFX)
                }
                misses += 1
                return RemoteTranslatedSegment(id: segment.id, text: segment.text)
            }
            recorded[owner, default: []].append(.init(segments: request.segments, translations: translations,
                milliseconds: PipelineEquivalenceHarnessTests.ms(start), replayMisses: misses))
            return RemoteTranslationBatchResult(translations: translations, source: .network, providerRequestID: nil)
        }
        guard let live else { throw CancellationError() }
        let result = try await live.translate(request, configuration: configuration)
        recorded[owner, default: []].append(.init(segments: request.segments, translations: result.translations,
            milliseconds: PipelineEquivalenceHarnessTests.ms(start), replayMisses: 0))
        return result
    }

    func export() -> [String: Any] {
        var fixtures: [String: Any] = [:]
        for (name, batches) in recorded {
            fixtures[name] = batches.map { batch -> [String: Any] in
                ["milliseconds": batch.milliseconds,
                 "segments": batch.segments.map { ["id": $0.id, "text": $0.text] },
                 "translations": batch.translations.map { t -> [String: Any] in
                     var v: [String: Any] = ["id": t.id, "text": t.text]
                     if let sfx = t.isSFX { v["isSFX"] = sfx }
                     return v
                 }]
            }
        }
        return ["format": 1, "fixtures": fixtures]
    }
}

private final class HarnessFootprintSampler: @unchecked Sendable {
    private let lock = NSLock()
    private var overall: Double = 0
    private var window: Double = 0

    func sample() {
        let value = Self.currentMiB()
        lock.lock(); overall = max(overall, value); window = max(window, value); lock.unlock()
    }
    func beginWindow() { lock.lock(); window = Self.currentMiB(); lock.unlock() }
    var windowPeakMiB: Double { lock.lock(); defer { lock.unlock() }; return window }
    var overallPeakMiB: Double { lock.lock(); defer { lock.unlock() }; return overall }

    private static func info() -> task_vm_info_data_t? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return status == KERN_SUCCESS ? info : nil
    }
    static func currentMiB() -> Double { info().map { Double($0.phys_footprint) / 1_048_576 } ?? -1 }
    static func lifetimePeakMiB() -> Double { info().map { Double($0.ledger_phys_footprint_peak) / 1_048_576 } ?? -1 }
}
