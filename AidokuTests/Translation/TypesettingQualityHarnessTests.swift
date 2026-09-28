import Darwin
import Foundation
import Synchronization
import Testing
import UIKit
import WebKit
@testable import Aidoku

/// Opt-in typesetting-quality harness over real dataset pages.
///
/// Enabled only when `AIDOKU_TSQ_CONFIG` names a JSON file (pass `TEST_RUNNER_AIDOKU_TSQ_CONFIG=<abs path>`).
/// Config: `{"stage": "ocr" | "render", "fixedDir": <abs>, "outDir": <abs>, "pages": [{"id", "image"}]}`.
/// - `ocr` runs production OCR + preparation once per page and stores the regions in `fixedDir`, so
///   baseline and candidate renders share identical OCR input. Existing files are kept.
/// - `render` replays `<id>.translations.json` (fixed text) through the production translation service
///   and exporter, writes `<outDir>/<id>.jpg`, and dumps per-item DOM geometry to `<outDir>/<id>.items.json`.
@Suite(.serialized) @MainActor
struct TypesettingQualityHarnessTests {
    fileprivate struct Page: Decodable { let id: String; let image: String }
    fileprivate struct Config: Decodable {
        let stage: String
        let fixedDir: String
        let outDir: String?
        let opacity: Double?
        let repeatRender: Int?
        let skipDOM: Bool?
        let ocrRender: Bool?
        /// Memory attribution: per-phase footprint, malloc and VM-tag snapshots.
        let memProbe: Bool?
        /// Footprint timeline (~20 ms) per page, with phase marks.
        let timeline: Bool?
        /// Capture a VM-tag snapshot the first time a page window rises this far above its start.
        let spikeMiB: Double?
        /// Page id -> idle milliseconds after that page (timeline keeps recording; a marker file
        /// `<outDir>/pause-<id>` exists during the pause so host tools can snapshot the heap).
        let pauseAfter: [String: Double]?
        /// Page ids whose start creates `<outDir>/mark-<id>` (host tools start a CPU sample).
        let markPages: [String]?
        /// Byte-sampled allocation backtraces (malloc_logger) over each page's render, summarized per page.
        let allocSample: Bool?
        /// `ocrraw` stage (diagnostic): detector thresholds for the raw box dump.
        let raw: RawOptions?
        /// `ocrab` stage: rounds of the same-binary A/B (candidate recovery off / on).
        let rounds: Int?
        /// `ocr` stage: run with the recovered-line OCR off (same-binary base).
        let recoveryOff: Bool?
        let pages: [Page]
    }
    fileprivate struct RawOptions: Decodable {
        let threshold: Double?
        let boxThreshold: Double?
        let suffix: String?
        let maximumSide: Int?
        /// Use the production detector thresholds (incl. recovery band) instead of the raw ones.
        let production: Bool?
    }
    private struct FixedRegions: Codable {
        let imageSize: [Double]
        let regions: [ReaderTranslationStoredRegion]
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["AIDOKU_TSQ_CONFIG"] != nil), .timeLimit(.minutes(240)))
    func typesettingQualityHarness() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["AIDOKU_TSQ_CONFIG"])
        let config = try JSONDecoder().decode(Config.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        let fixed = URL(fileURLWithPath: config.fixedDir)
        try FileManager.default.createDirectory(at: fixed, withIntermediateDirectories: true)

        let suiteName = "typesetting-quality-\(UUID().uuidString)"
        let isolatedDefaults = try #require(UserDefaults(suiteName: suiteName))
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
        var settings = ReaderTranslationSettings(defaults: isolatedDefaults)
        settings.provider = .custom
        settings.custom.baseURL = "https://typesetting-quality.invalid/v1"
        settings.model = "fixed-dataset-translation"
        settings.includePageImage = false
        settings.sourceLanguage = "auto"
        settings.targetLanguage = "ko"
        settings.translationSourceLanguages = []
        settings.rightToLeftPanelOrder = true
        settings.overlay = ReaderTranslationSettings.defaultOverlay
        settings.overlay.appearance = .source
        settings.overlay.enforceSourceReplacement()
        if let opacity = config.opacity { settings.overlay.opacity = opacity }
        settings.ocr = ReaderOCRConfiguration()

        if config.stage == "ocr" {
            NativeOCRIsolatedLineRecovery.isEnabled = config.recoveryOff != true
            defer { NativeOCRIsolatedLineRecovery.isEnabled = true }
            try await runOCR(config: config, fixed: fixed, settings: settings)
        } else if config.stage == "ocrraw" {
            try await runRawOCR(config: config, fixed: fixed)
        } else if config.stage == "ocrlines" {
            try await runOCRLines(config: config, fixed: fixed, settings: settings)
        } else if config.stage == "ocrab" {
            try await runOCRAB(config: config, fixed: fixed, settings: settings)
        } else {
            try await runRender(config: config, fixed: fixed, settings: settings)
        }
    }

    /// Diagnostic only: raw detector boxes with DB scores and their recognition at confidence 0.
    private func runRawOCR(config: Config, fixed: URL) async throws {
        let profile = NativeCoreMLOCRModelProfile.profile(for: .medium)
        let detector = NativeCoreMLDetector(modelResourceName: profile.detectorResourceName,
                                            maximumSide: config.raw?.maximumSide ?? NativeCoreMLDetectionPreprocessor.canvasSide)
        let recognizer = NativeCoreMLRecognizer(modelResourceName: profile.recognizerResourceName,
                                                dictionaryResourceName: profile.dictionaryResourceName,
                                                expectedDictionaryCharacterCount: profile.expectedDictionaryCharacterCount,
                                                maximumRecognitionWidth: 1_600)
        let base = profile.postprocessConfiguration
        let detection = config.raw?.production == true ? ReaderOCRConfiguration().detectorPostprocessConfiguration
            : NativeCoreMLDBPostprocessConfiguration(
                threshold: config.raw?.threshold ?? base.threshold, boxThreshold: config.raw?.boxThreshold ?? 0.3,
                unclipRatio: base.unclipRatio, maximumCandidates: base.maximumCandidates, minimumBoxSide: base.minimumBoxSide)
        let suffix = config.raw?.suffix ?? "raw"
        for page in config.pages {
            let target = fixed.appendingPathComponent("\(page.id).\(suffix).json")
            if FileManager.default.fileExists(atPath: target.path) { continue }
            guard let source = Self.load(page.image), let pixels = source.cgImage,
                  let frame = NativeOCRCGImageAdapter.makeRGBAFrame(from: pixels) else { continue }
            let detected = try await detector.detect(frame: frame, configuration: detection)
            let regions = detected.boxes.enumerated().compactMap { index, box in
                box.polygon.count == 4 ? NativeCoreMLRecognitionRegion(sourceIndex: index, polygon: box.polygon) : nil
            }
            let recognized = regions.isEmpty ? [] : try await recognizer.recognize(frame: frame, regions: regions,
                                                                                   confidenceThreshold: 0).regions
            let texts = Dictionary(recognized.map { ($0.sourceIndex, $0) }, uniquingKeysWith: { first, _ in first })
            let w = Double(pixels.width), h = Double(pixels.height)
            let boxes: [[String: Any]] = detected.boxes.enumerated().map { index, box in
                var row: [String: Any] = ["poly": box.polygon.map { [Double($0.x) / w, Double($0.y) / h] }, "score": box.score]
                if let r = texts[index] { row["text"] = r.text; row["conf"] = r.confidence }
                return row
            }
            let doc: [String: Any] = ["imageSize": [w, h], "boxes": boxes]
            try JSONSerialization.data(withJSONObject: doc).write(to: target, options: .atomic)
            print("TSQ ocrraw \(page.id) boxes=\(boxes.count)")
        }
        await detector.purgeResources()
        await recognizer.purgeResources()
    }

    /// Diagnostic only: pipeline lines (accepted, recovered, gap) and the service's regions before and after
    /// preparation, to locate where a confident line is lost.
    private func runOCRLines(config: Config, fixed: URL, settings: ReaderTranslationSettings) async throws {
        let pipeline = NativeCoreMLOCRPipeline(modelTier: .medium)
        let service = ReaderOCRService()
        defer { Task { await service.purge(); await pipeline.purgeResources() } }
        func quad(_ points: [CGPoint], _ w: Double, _ h: Double) -> [[Double]] { points.map { [Double($0.x) / w, Double($0.y) / h] } }
        for page in config.pages {
            let target = fixed.appendingPathComponent("\(page.id).lines.json")
            if FileManager.default.fileExists(atPath: target.path) { continue }
            guard let source = Self.load(page.image), let pixels = source.cgImage else { continue }
            let w = Double(pixels.width), h = Double(pixels.height)
            let configuration = settings.ocrConfiguration
            let result = try await pipeline.recognize(image: pixels, requestID: UUID().uuidString,
                                                      confidenceThreshold: configuration.confidenceThreshold,
                                                      detectorConfiguration: configuration.detectorPostprocessConfiguration)
            func rows(_ lines: [NativeCoreMLOCRLine]) -> [[String: Any]] {
                lines.map { ["poly": quad($0.polygon, w, h), "text": $0.text, "score": $0.score] }
            }
            let recognized = try await service.recognize(image: pixels, configuration: configuration)
            let prepared = ReaderTranslationImagePreparation.apply(recognized, image: source, settings: settings)
            let eligible = ReaderTranslationLanguageFilter.apply(prepared, settings: settings)
            let syncFrame = try #require(NativeOCRCGImageAdapter.makeRGBAFrame(from: pixels))
            let viaFrame = try await pipeline.recognize(frame: syncFrame, requestID: UUID().uuidString,
                                                        confidenceThreshold: configuration.confidenceThreshold,
                                                        detectorConfiguration: configuration.detectorPostprocessConfiguration)
            let offMain = await NativeOCRCGImageAdapter.makeRGBAFrameOffMain(from: pixels)
            print("TSQ ocrlines frames \(page.id) sync=\(syncFrame.width)x\(syncFrame.height) \(syncFrame.bytesPerRow) " +
                  "off=\(offMain?.width ?? 0)x\(offMain?.height ?? 0) \(offMain?.bytesPerRow ?? 0) " +
                  "same=\(offMain?.bytes == syncFrame.bytes) det=\(result.detectedBoxes)/\(viaFrame.detectedBoxes) " +
                  "sel=\(result.selectedBoxes)/\(viaFrame.selectedBoxes) lines=\(result.lines.count)/\(viaFrame.lines.count)")
            func regionRows(_ regions: [ReaderTranslationRegion]) -> [[String: Any]] {
                regions.map { ["rect": [$0.rect.minX, $0.rect.minY, $0.rect.width, $0.rect.height], "text": $0.source] }
            }
            let doc: [String: Any] = [
                "imageSize": [w, h], "lines": rows(result.lines), "recovered": rows(result.recoveryCandidates),
                "gaps": rows(result.gapLines.map(\.line)), "service": regionRows(recognized),
                "prepared": regionRows(prepared), "eligible": regionRows(eligible)
            ]
            try JSONSerialization.data(withJSONObject: doc).write(to: target, options: .atomic)
            print("TSQ ocrlines \(page.id) lines=\(result.lines.count)")
        }
    }

    /// Same-binary A/B of the candidate recovery: A = off, B = on, alternating order per page and round.
    private func runOCRAB(config: Config, fixed: URL, settings: ReaderTranslationSettings) async throws {
        let service = ReaderOCRService()
        defer { NativeOCRIsolatedLineRecovery.isEnabled = true; Task { await service.purge() } }
        let sampler = TSQFootprintSampler()
        let sampling = Task.detached(priority: .high) { [sampler] in
            while !Task.isCancelled {
                sampler.sample()
                try? await Task.sleep(for: .milliseconds(5))
            }
        }
        defer { sampling.cancel() }
        var rows: [[String: Any]] = []
        for round in 0..<(config.rounds ?? 1) {
            for (index, page) in config.pages.enumerated() {
                guard let source = Self.load(page.image), let pixels = source.cgImage else { continue }
                var row: [String: Any] = ["id": page.id, "round": round]
                let order = (index + round).isMultiple(of: 2) ? [false, true] : [true, false]
                for enabled in order {
                    NativeOCRIsolatedLineRecovery.isEnabled = enabled
                    sampler.beginWindow()
                    let start = ContinuousClock.now
                    let regions = try await service.recognize(image: pixels, configuration: settings.ocrConfiguration)
                    let key = enabled ? "B" : "A"
                    row[key + "ms"] = Self.ms(start)
                    row[key + "peak"] = sampler.windowPeakMiB
                    row[key + "regions"] = regions.count
                    row[key + "phases"] = await service.lastPhaseMilliseconds
                }
                rows.append(row)
                print("TSQ ocrab \(page.id) A=\(row["Ams"] ?? 0) B=\(row["Bms"] ?? 0)")
            }
        }
        try JSONSerialization.data(withJSONObject: rows, options: [.sortedKeys])
            .write(to: fixed.appendingPathComponent("ocrab-\(Int(Date().timeIntervalSince1970)).json"))
    }

    private func runOCR(config: Config, fixed: URL, settings: ReaderTranslationSettings) async throws {
        let service = ReaderOCRService()
        defer { Task { await service.purge() } }
        var timings: [String: Double] = [:]
        var phases: [String: [String: Double]] = [:]
        // Per-page peak physical footprint while OCR runs (same sampler as the render stage).
        let sampler = TSQFootprintSampler()
        let sampling = Task.detached(priority: .high) { [sampler] in
            while !Task.isCancelled {
                sampler.sample()
                try? await Task.sleep(for: .milliseconds(5))
            }
        }
        defer { sampling.cancel() }
        for page in config.pages {
            let target = fixed.appendingPathComponent("\(page.id).regions.json")
            if FileManager.default.fileExists(atPath: target.path) { continue }
            guard let source = Self.load(page.image), let pixels = source.cgImage else {
                Issue.record("Unreadable image \(page.image)")
                continue
            }
            sampler.beginWindow()
            let start = ContinuousClock.now
            let recognized = try await service.recognize(image: pixels, configuration: settings.ocrConfiguration)
            let prepared = ReaderTranslationImagePreparation.apply(recognized, image: source, settings: settings)
            let eligible = ReaderTranslationLanguageFilter.apply(prepared, settings: settings)
            timings[page.id] = Self.ms(start)
            phases[page.id] = await service.lastPhaseMilliseconds
            phases[page.id]?["peakFootprintMiB"] = sampler.windowPeakMiB
            let value = FixedRegions(imageSize: [Double(pixels.width), Double(pixels.height)],
                                     regions: eligible.map(ReaderTranslationStoredRegion.init))
            try JSONEncoder().encode(value).write(to: target, options: .atomic)
            print("TSQ ocr \(page.id) regions=\(eligible.count)")
        }
        let timingURL = fixed.appendingPathComponent("ocr-timings-\(Int(Date().timeIntervalSince1970)).json")
        try JSONSerialization.data(withJSONObject: timings, options: [.sortedKeys]).write(to: timingURL)
        try JSONSerialization.data(withJSONObject: phases, options: [.sortedKeys])
            .write(to: fixed.appendingPathComponent("ocr-phases-\(Int(Date().timeIntervalSince1970)).json"))
    }

    private func runRender(config: Config, fixed: URL, settings: ReaderTranslationSettings) async throws {
        let out = URL(fileURLWithPath: try #require(config.outDir))
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let client = FixedTranslationClient()

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

        let sampler = TSQFootprintSampler()
        let sampling = Task.detached(priority: .high) { [sampler] in
            while !Task.isCancelled {
                sampler.sample()
                try? await Task.sleep(for: .milliseconds(5))
            }
        }
        defer { sampling.cancel() }
        let startFootprint = TSQFootprintSampler.currentMiB()
        TSQPageProbe.prepare(config: config, out: out, sampler: sampler)
        let renderOCR = ReaderOCRService()
        defer { Task { await renderOCR.purge() } }
        var rows: [[String: Any]] = []

        for page in config.pages {
            let regionsURL = fixed.appendingPathComponent("\(page.id).regions.json")
            let translationsURL = fixed.appendingPathComponent("\(page.id).translations.json")
            guard let regionData = try? Data(contentsOf: regionsURL),
                  let stored = try? JSONDecoder().decode(FixedRegions.self, from: regionData),
                  let translationData = try? Data(contentsOf: translationsURL),
                  let texts = try? JSONSerialization.jsonObject(with: translationData) as? [String: String],
                  let source = Self.load(page.image) else {
                rows.append(["id": page.id, "error": "missing fixed input"])
                continue
            }
            var row: [String: Any] = ["id": page.id, "size": [source.size.width, source.size.height]]
            var probe = TSQPageProbe(config: config, page: page.id, out: out, sampler: sampler)
            var regions = stored.regions.map(\.region)
            // Balloon interiors missing from older fixed inputs, before the render's memory window.
            if regions.allSatisfy({ $0.balloonInterior == nil }), let pixels = source.cgImage {
                let filled = await Self.backfillingInteriors(regions, image: pixels)
                regions = filled.regions
                row["balloonInteriorRasterMS"] = filled.rasterMS
                row["balloonInteriorMS"] = filled.totalMS
                probe.snapshot("afterBackfill")
            }
            probe.mark("window")
            sampler.beginWindow(spikeMiB: config.spikeMiB)
            // Only regions with a fixed dataset translation are sent; others keep their source text.
            let sent = regions.filter { texts[$0.id] != nil }
            let sources = Dictionary(regions.compactMap { region in texts[region.id].map { (region.source, $0) } },
                                     uniquingKeysWith: { first, _ in first })
            await client.load(Self.plannedTexts(sent, texts: texts, settings: settings), sources: sources)
            // A fresh service per page: its in-memory request cache must not answer an identical
            // request on a later page with an earlier page's fixed text.
            let translationService = ReaderTranslationService(client: client)
            let translateStart = ContinuousClock.now
            var translated = sent.isEmpty ? [] : try await translationService.translate(regions: sent, settings: settings, image: source)
            row["translateMS"] = Self.ms(translateStart)
            row["translationMisses"] = await client.misses
            row["translationFallbacks"] = await client.fallbacks
            let translatedIDs = Set(translated.map(\.id))
            for region in regions where !translatedIDs.contains(region.id) {
                var unchanged = region
                unchanged.translation = region.source
                translated.append(unchanged)
            }
            let order = Dictionary(uniqueKeysWithValues: regions.enumerated().map { ($1.id, $0) })
            translated.sort { (order[$0.id] ?? 0) < (order[$1.id] ?? 0) }
            let items = ReaderTranslationRegion.overlayItems(translated, imageSize: source.size)
            row["items"] = items.count
            guard !items.isEmpty else {
                rows.append(row)
                continue
            }
            // Payload stage: native layout only, for the host WebKit renderer (no WebKit here).
            if config.stage == "payload" {
                let rect = ReaderTranslationGeometry.displayRect(
                    CGRect(x: 0, y: 0, width: 1, height: 1),
                    imageSize: source.size, bounds: CGRect(origin: .zero, size: viewport), aspectFit: true)
                var overlaySettings = settings.overlay
                overlaySettings.visible = true
                let layoutStart = ContinuousClock.now
                let payload = BrowserPageImageOverlayRenderer.layoutPayload(
                    items: ReaderTranslationRegion.layoutItems(translated, imageSize: source.size),
                    imageSize: source.size, sourceRect: rect, settings: overlaySettings,
                    targetLanguage: settings.targetLanguage, viewport: viewport,
                    measurementCache: BrowserOverlayTextMeasurementCache())
                row["layoutMS"] = Self.ms(layoutStart)
                let document: [String: Any] = [
                    "items": payload, "viewport": [viewport.width, viewport.height], "scale": scale,
                    "imageSize": [source.size.width, source.size.height],
                    "displayRect": [rect.minX, rect.minY, rect.width, rect.height],
                    "appearance": ["opacity": overlaySettings.renderedBackgroundOpacity,
                                   "preserveSourceTextColor": overlaySettings.preserveSourceTextColor,
                                   "preserveSourceBackgroundColor": overlaySettings.preserveSourceBackgroundColor,
                                   "inpaintingEnabled": overlaySettings.usesSourceInpainting,
                                   "minimumReadableFontSize": BrowserOverlayLayoutPlanner.minimumRenderedFontSize]
                ]
                try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys])
                    .write(to: out.appendingPathComponent("\(page.id).payload.json"), options: .atomic)
                rows.append(row)
                continue
            }
            // Leak probe: render the same page repeatedly and record the footprint after each pass.
            if let repeats = config.repeatRender, repeats > 0 {
                var footprints: [Double] = []
                for pass in 0..<repeats {
                    _ = try await ReaderTranslationImageExporter.renderLoadedImage(
                        image: source, regions: translated, settings: settings, viewport: viewport, scale: scale,
                        aspectFit: true, dark: false, host: host, cache: nil, key: "tsq-leak-\(page.id)-\(pass)")
                    if config.skipDOM != true {
                        let overlay = ReaderTranslationOverlayView(frame: CGRect(origin: .zero, size: viewport))
                        host.addSubview(overlay)
                        var probeSettings = settings
                        probeSettings.overlay.visible = true
                        overlay.update(regions: translated, imageSize: source.size, aspectFit: true, settings: probeSettings, image: source)
                        let deadline = Date().addingTimeInterval(60)
                        while overlay.lastDiagnostic == nil || overlay.lastDiagnostic?.outcome == .stale {
                            if Date() >= deadline { break }
                            try await Task.sleep(for: .milliseconds(5))
                        }
                        overlay.cancelWork()
                        overlay.removeFromSuperview()
                    }
                    ReaderTranslationImageExporter.clearIdleRenderer()
                    try await Task.sleep(for: .milliseconds(50))
                    footprints.append(TSQFootprintSampler.currentMiB())
                }
                row["repeatFootprintsMiB"] = footprints
            }
            ReaderTranslationImageExporter.clearIdleRenderer()
            let renderStart = ContinuousClock.now
            let image = try await ReaderTranslationImageExporter.renderLoadedImage(
                image: source, regions: translated, settings: settings, viewport: viewport, scale: scale,
                aspectFit: true, dark: false, host: host, cache: nil, key: "tsq-\(page.id)")
            row["renderMS"] = Self.ms(renderStart)
            row["renderPixelSize"] = [image.size.width * image.scale, image.size.height * image.scale]
            if let jpeg = image.jpegData(compressionQuality: 0.92) {
                try jpeg.write(to: out.appendingPathComponent("\(page.id).jpg"), options: .atomic)
            }
            row["peakFootprintMiB"] = sampler.windowPeakMiB
            probe.mark("exported")
            probe.snapshot("afterExport")
            probe.spike("exportSpike")
            sampler.beginWindow(spikeMiB: config.spikeMiB)
            // Residual probe: read the rendered page back with the production OCR.
            if config.ocrRender == true, let pixels = image.cgImage {
                let lines = try await renderOCR.recognize(image: pixels, configuration: settings.ocrConfiguration)
                let width = Double(pixels.width), height = Double(pixels.height)
                let dump = lines.map { region -> [String: Any] in
                    ["text": region.source, "confidence": region.confidence,
                     "rect": [Double(region.rect.minX), Double(region.rect.minY), Double(region.rect.width), Double(region.rect.height)],
                     "size": [width, height]]
                }
                try JSONSerialization.data(withJSONObject: dump).write(to: out.appendingPathComponent("\(page.id).ocr.json"), options: .atomic)
            }

            // Instrumented DOM pass on the same overlay view type the exporter uses.
            let overlay = ReaderTranslationOverlayView(frame: CGRect(origin: .zero, size: viewport))
            host.addSubview(overlay)
            var exportSettings = settings
            exportSettings.overlay.visible = true
            overlay.update(regions: translated, imageSize: source.size, aspectFit: true, settings: exportSettings, image: source)
            overlay.layoutIfNeeded()
            let deadline = Date().addingTimeInterval(60)
            while overlay.lastDiagnostic == nil || overlay.lastDiagnostic?.outcome == .stale {
                if Date() >= deadline { break }
                try await Task.sleep(for: .milliseconds(5))
            }
            row["domOutcome"] = overlay.lastDiagnostic.map { String(describing: $0.outcome) } ?? "timeout"
            if let raw = try? await overlay.webView.evaluateJavaScript(Self.dumpScript) as? String {
                try Data(raw.utf8).write(to: out.appendingPathComponent("\(page.id).items.json"), options: .atomic)
            }
            overlay.cancelWork()
            overlay.removeFromSuperview()
            ReaderTranslationImageExporter.clearIdleRenderer()
            row["footprintAfterMiB"] = TSQFootprintSampler.currentMiB()
            // The simulator's footprint includes pages the host compressor squeezed under host memory
            // pressure; live malloc bytes separate retained data from that noise.
            let settled = TSQMemProbe.snapshot(tags: false)
            row["compressedAfterMiB"] = settled["compressed"]
            row["mallocInUseAfterMiB"] = settled["mallocInUse"]
            row["domPeakFootprintMiB"] = sampler.windowPeakMiB
            try await probe.finish(into: &row)
            rows.append(row)
            print("TSQ render \(page.id) items=\(items.count)")
            try Self.writeRows(rows, sampler: sampler, startFootprint: startFootprint, viewport: viewport, scale: scale,
                               to: out.appendingPathComponent("results.json"))
        }
        try Self.writeRows(rows, sampler: sampler, startFootprint: startFootprint, viewport: viewport, scale: scale,
                           to: out.appendingPathComponent("results.json"))
    }

    /// Fixed inputs recorded before OCR attached balloon interiors get them from the production step
    /// (a fresh component map, as a page with one OCR line gets). In the app this is OCR work, off the
    /// main actor. On the main thread, drawing the lazily decoded source can wait on a utility-QoS
    /// thread; the Thread Performance Checker then reports a priority inversion (once per run) and
    /// XCTest symbolicates it in process: CoreSymbolication parses the app's DWARF, a +150-250 MiB
    /// transient that lands in the next page's memory window (A5).
    private struct Backfill: Sendable {
        let regions: [ReaderTranslationRegion]
        let rasterMS: Double
        let totalMS: Double
    }

    nonisolated private static func backfillingInteriors(_ regions: [ReaderTranslationRegion], image: CGImage) async -> Backfill {
        await Task.detached(priority: .utility) {
            let start = ContinuousClock.now
            let map = ReaderTranslationEnclosedBackground.ComponentMap(image: image)
            // Rasterizes without labelling (a corner box resolves to nothing): the part OCR already paid.
            _ = map.component(of: CGRect(x: 0, y: 0, width: 4, height: 4))
            let rasterMS = ms(start)
            let result = ReaderTranslationEnclosedBackground.attachingBalloonInteriors(regions, image: image, map: map)
            return Backfill(regions: result, rasterMS: rasterMS, totalMS: ms(start))
        }.value
    }

    // swiftlint:disable:next function_parameter_count
    private static func writeRows(_ rows: [[String: Any]], sampler: TSQFootprintSampler, startFootprint: Double,
                                  viewport: CGSize, scale: CGFloat, to url: URL) throws {
        let object: [String: Any] = ["rows": rows, "viewport": [viewport.width, viewport.height], "scale": scale,
                                     "startFootprintMiB": startFootprint, "peakFootprintMiB": sampler.overallPeakMiB,
                                     "endFootprintMiB": TSQFootprintSampler.currentMiB()]
        try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]).write(to: url, options: .atomic)
    }

    static let dumpScript = """
    (() => {
      const root = document.querySelector('[data-aidoku-image-ocr-overlay="root"]');
      if (!root) return JSON.stringify(null);
      const box = e => { const r = e.getBoundingClientRect(); return [r.left, r.top, r.width, r.height]; };
      const data = {};
      for (const k of Object.keys(root.dataset)) data[k] = root.dataset[k];
      const kind = e => e.getAttribute('data-aidoku-image-ocr-overlay');
      const layers = [...root.querySelectorAll('[data-aidoku-image-ocr-overlay]')]
        .filter(e => kind(e) !== 'item' && kind(e) !== 'measurement')
        .map(e => {
          const s = getComputedStyle(e);
          const d = {};
          for (const k of Object.keys(e.dataset)) d[k] = e.dataset[k];
          return { kind: kind(e), region: e.getAttribute('data-aidoku-region'), box: box(e), dataset: d,
                   hidden: s.display === 'none' || s.visibility === 'hidden', background: s.backgroundColor,
                   transform: s.transform };
        });
      const items = [...document.querySelectorAll('[data-aidoku-image-ocr-overlay="item"]')].map(e => {
        const s = getComputedStyle(e);
        const d = {};
        for (const k of Object.keys(e.dataset)) d[k] = e.dataset[k];
        const range = document.createRange();
        range.selectNodeContents(e);
        const lines = [...range.getClientRects()].filter(r => r.width > 0 && r.height > 0)
          .map(r => [r.left, r.top, r.width, r.height]);
        const ink = range.getBoundingClientRect();
        const parent = e.parentElement;
        return { region: e.getAttribute('data-aidoku-region'), box: box(e), ink: [ink.left, ink.top, ink.width, ink.height],
                 rects: lines.length, dataset: d, transform: s.transform, color: s.color, background: s.backgroundColor,
                 stroke: s.webkitTextStrokeColor, strokeWidth: s.webkitTextStrokeWidth, textShadow: s.textShadow,
                 fontSize: parseFloat(s.fontSize), lineHeight: s.lineHeight, writingMode: s.writingMode,
                 hidden: s.display === 'none' || s.visibility === 'hidden' || Number(s.opacity) === 0,
                 parentKind: parent ? kind(parent) : null, text: e.innerText,
                 overflowX: e.scrollWidth - e.clientWidth, overflowY: e.scrollHeight - e.clientHeight };
      });
      return JSON.stringify({ root: data, rootBox: box(root), items, layers });
    })()
    """

    /// The service sends batch-local segment IDs, so each region's fixed text is keyed by its planned
    /// request (segment texts in order). Keying by source text alone gave every region with the same
    /// source (e.g. two "は" effects) the first region's translation.
    private static func plannedTexts(_ regions: [ReaderTranslationRegion], texts: [String: String],
                                     settings: ReaderTranslationSettings) -> [[String]: [String]] {
        let eligible = ReaderTranslationLanguageFilter.apply(regions, settings: settings)
        var planned: [[String]: [String]] = [:]
        for plan in ReaderTranslationService.plans(regions: eligible, settings: settings) {
            let key = plan.request.segments.map(\.text)
            guard planned[key] == nil else { continue }
            planned[key] = plan.request.segments.map { texts[$0.id] ?? $0.text }
        }
        return planned
    }

    private static func load(_ path: String) -> UIImage? {
        guard let data = FileManager.default.contents(atPath: path), let image = UIImage(data: data) else { return nil }
        guard image.imageOrientation != .up else { return image }
        let format = UIGraphicsImageRendererFormat()
        format.scale = image.scale
        format.preferredRange = .standard
        return UIGraphicsImageRenderer(size: image.size, format: format).image { _ in image.draw(at: .zero) }
    }

    nonisolated static func ms(_ start: ContinuousClock.Instant) -> Double {
        let c = start.duration(to: .now).components
        return Double(c.seconds) * 1000 + Double(c.attoseconds) / 1e15
    }
}

/// Serves fixed dataset translations per region behind the production translation service.
private actor FixedTranslationClient: RemoteTranslating {
    private var planned: [[String]: [String]] = [:]
    private var sources: [String: String] = [:]
    private(set) var misses = 0
    private(set) var fallbacks = 0

    func load(_ planned: [[String]: [String]], sources: [String: String]) {
        self.planned = planned
        self.sources = sources
    }

    func translate(_ request: RemoteTranslationRequest, configuration: RemoteTranslationConfiguration) async throws -> RemoteTranslationBatchResult {
        // Segment IDs are batch-local; match the planned request by its segment texts, in order.
        if let texts = planned[request.segments.map(\.text)], texts.count == request.segments.count {
            let translations = zip(request.segments, texts).map { RemoteTranslatedSegment(id: $0.id, text: $1) }
            return RemoteTranslationBatchResult(translations: translations, source: .network, providerRequestID: nil)
        }
        // Unplanned request shape (e.g. a split retry): fall back to the region's source text.
        fallbacks += 1
        let translations = request.segments.map { segment in
            if let text = sources[segment.text] { return RemoteTranslatedSegment(id: segment.id, text: text) }
            misses += 1
            return RemoteTranslatedSegment(id: segment.id, text: segment.text)
        }
        return RemoteTranslationBatchResult(translations: translations, source: .network, providerRequestID: nil)
    }
}

private final class TSQFootprintSampler: @unchecked Sendable {
    private let lock = NSLock()
    private var overall: Double = 0
    private var window: Double = 0
    private var windowStart: Double = 0
    private var spikeThreshold: Double?
    private var spike: [String: Any]?
    private var recording = false
    private var samples: [(ContinuousClock.Instant, Double)] = []
    /// When set, a spike also creates this file (host tools snapshot the heap while it is live).
    nonisolated(unsafe) var spikeMarker: String?

    func sample() {
        let value = Self.currentMiB()
        let now = ContinuousClock.now
        lock.lock()
        overall = max(overall, value); window = max(window, value)
        if recording, samples.last.map({ $0.0.duration(to: now) >= .milliseconds(20) }) ?? true { samples.append((now, value)) }
        let capture = spike == nil && spikeThreshold.map { value - windowStart >= $0 } == true
        if capture { spike = [:] }
        lock.unlock()
        // Outside the lock: a VM walk takes a few milliseconds.
        if capture {
            if let spikeMarker { FileManager.default.createFile(atPath: spikeMarker, contents: nil) }
            var snapshot = TSQMemProbe.snapshot(tags: true)
            snapshot["windowStartMiB"] = windowStart
            lock.lock(); spike = snapshot; lock.unlock()
        }
    }
    func beginWindow(spikeMiB: Double? = nil) {
        let value = Self.currentMiB()
        lock.lock(); window = value; windowStart = value; spikeThreshold = spikeMiB; spike = nil; lock.unlock()
    }
    func takeSpike() -> [String: Any]? {
        lock.lock(); defer { spike = nil; spikeThreshold = nil; lock.unlock() }
        return spike
    }
    func beginTimeline(_ on: Bool) { lock.lock(); recording = on; samples = []; lock.unlock() }
    func takeTimeline(since start: ContinuousClock.Instant) -> [[Double]] {
        lock.lock(); defer { samples = []; recording = false; lock.unlock() }
        return samples.map { [(TypesettingQualityHarnessTests.ms(start) - TypesettingQualityHarnessTests.ms($0.0)).rounded(), $0.1.rounded()] }
    }
    var windowPeakMiB: Double { lock.lock(); defer { lock.unlock() }; return window }
    var overallPeakMiB: Double { lock.lock(); defer { lock.unlock() }; return overall }

    static func currentMiB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return status == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1
    }
}

/// Opt-in per-page memory attribution: phase snapshots, spikes, timeline, pauses, allocation samples.
@MainActor
private struct TSQPageProbe {
    private let config: TypesettingQualityHarnessTests.Config
    private let page: String
    private let out: URL
    private let sampler: TSQFootprintSampler
    private let start = ContinuousClock.now
    private var marks: [String: Double] = [:]
    private var mem: [String: Any] = [:]
    private let epoch = Date().timeIntervalSince1970

    static func prepare(config: TypesettingQualityHarnessTests.Config, out: URL, sampler: TSQFootprintSampler) {
        if config.memProbe == true { sampler.spikeMarker = out.appendingPathComponent("spike-marker").path }
        guard config.allocSample == true else { return }
        let installed = TSQAllocSampler.install()
        TSQAllocSampler.begin()
        let arrays = (0..<64).map { _ in [UInt8](repeating: 1, count: 65_536) }
        let recorded = TSQAllocSampler.end()
        print("TSQ allocSample installed=\(installed) selftest samples=\(recorded.count) arrays=\(arrays.count)")
    }

    init(config: TypesettingQualityHarnessTests.Config, page: String, out: URL, sampler: TSQFootprintSampler) {
        self.config = config
        self.page = page
        self.out = out
        self.sampler = sampler
        if config.markPages?.contains(page) == true {
            FileManager.default.createFile(atPath: out.appendingPathComponent("mark-\(page)").path, contents: nil)
        }
        snapshot("pre")
        if config.allocSample == true { TSQAllocSampler.begin() }
        sampler.beginTimeline(config.timeline == true)
    }

    mutating func mark(_ name: String) { marks[name] = TypesettingQualityHarnessTests.ms(start) }
    mutating func snapshot(_ name: String) { if config.memProbe == true { mem[name] = TSQMemProbe.snapshot(tags: true) } }
    mutating func spike(_ name: String) { if let value = sampler.takeSpike() { mem[name] = value } }

    mutating func finish(into row: inout [String: Any]) async throws {
        mark("after")
        spike("domSpike")
        snapshot("after")
        if let pause = config.pauseAfter?[page] {
            let marker = out.appendingPathComponent("pause-\(page)")
            FileManager.default.createFile(atPath: marker.path, contents: nil)
            try await Task.sleep(for: .milliseconds(Int(pause)))
            try? FileManager.default.removeItem(at: marker)
            snapshot("afterPause")
        }
        if config.memProbe == true { row["mem"] = mem }
        if config.allocSample == true { row["alloc"] = TSQAllocSampler.summary(TSQAllocSampler.end()) }
        if config.timeline == true {
            row["t0"] = epoch
            row["marks"] = marks
            row["timeline"] = sampler.takeTimeline(since: start)
        }
    }
}

/// Harness-only memory attribution: footprint ledgers, malloc zone totals and dirty bytes per VM tag.
private enum TSQMemProbe {
    static func snapshot(tags: Bool) -> [String: Any] {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        _ = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        var stats = malloc_statistics_t()
        malloc_zone_statistics(nil, &stats)
        let mib = { (value: Double) in (value / 1_048_576 * 10).rounded() / 10 }
        var result: [String: Any] = [
            "fp": mib(Double(info.phys_footprint)), "internal": mib(Double(info.internal)),
            "compressed": mib(Double(info.compressed)), "graphics": mib(Double(info.ledger_tag_graphics_footprint)),
            "media": mib(Double(info.ledger_tag_media_footprint)), "neural": mib(Double(info.ledger_tag_neural_footprint)),
            "mallocInUse": mib(Double(stats.size_in_use)), "mallocAllocated": mib(Double(stats.size_allocated))
        ]
        if tags { result["tags"] = tagDirty().mapValues(mib) }
        return result
    }

    /// Dirty + swapped bytes per VM user tag (suffix "s" for shared mappings), like vmmap's summary.
    static func tagDirty() -> [String: Double] {
        var totals: [String: Double] = [:]
        var address: vm_address_t = 0
        var depth: natural_t = 0
        let page = Double(getpagesize())
        while true {
            var size: vm_size_t = 0
            var info = vm_region_submap_info_data_64_t()
            var count = mach_msg_type_number_t(MemoryLayout<vm_region_submap_info_data_64_t>.size / MemoryLayout<natural_t>.size)
            let status = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: Int32.self, capacity: Int(count)) {
                    vm_region_recurse_64(mach_task_self_, &address, &size, &depth, $0, &count)
                }
            }
            guard status == KERN_SUCCESS else { break }
            if info.is_submap != 0 { depth += 1; continue }
            let bytes = (Double(info.pages_dirtied) + Double(info.pages_swapped_out)) * page
            if bytes > 0 {
                let shared = info.share_mode == SM_SHARED || info.share_mode == SM_TRUESHARED
                totals["\(info.user_tag)" + (shared ? "s" : ""), default: 0] += bytes
            }
            address += size
        }
        return totals.filter { $0.value >= 1_048_576 / 2 }
    }
}

/// Harness-only allocation sampler: one backtrace per 256 KiB allocated (weighted by bytes), installed
/// as libmalloc's `malloc_logger`. Summaries list the heaviest app frames and full stacks.
private enum TSQAllocSampler {
    typealias Logger = @convention(c) (UInt32, UInt, UInt, UInt, UInt, UInt32) -> Void
    static let slots = 16_384
    static let depth = 40
    nonisolated(unsafe) static let frames = UnsafeMutablePointer<UnsafeMutableRawPointer?>.allocate(capacity: slots * depth)
    nonisolated(unsafe) static let weights = UnsafeMutablePointer<Int>.allocate(capacity: slots)
    nonisolated(unsafe) static let counts = UnsafeMutablePointer<Int32>.allocate(capacity: slots)
    static let next = Atomic<Int>(0)
    static let bytes = Atomic<Int>(0)
    static let armed = Atomic<Bool>(false)
    static let period = 262_144

    static let logger: Logger = { type, _, arg2, arg3, _, _ in
        guard type & 2 != 0, TSQAllocSampler.armed.load(ordering: .relaxed) else { return }
        let size = Int(type & 4 != 0 ? arg3 : arg2)
        guard size > 0 else { return }
        let total = TSQAllocSampler.bytes.add(size, ordering: .relaxed).newValue
        let crossed = total / TSQAllocSampler.period - (total - size) / TSQAllocSampler.period
        guard crossed > 0 else { return }
        let slot = TSQAllocSampler.next.add(1, ordering: .relaxed).oldValue
        guard slot < TSQAllocSampler.slots else { return }
        TSQAllocSampler.weights[slot] = crossed
        TSQAllocSampler.counts[slot] = backtrace(TSQAllocSampler.frames + slot * TSQAllocSampler.depth, Int32(TSQAllocSampler.depth))
    }

    static func install() -> Bool {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "malloc_logger") else { return false }
        // Lazy statics allocate: initialize them all before the logger can run.
        frames[0] = nil; weights[0] = 0; counts[0] = 0
        _ = next.load(ordering: .relaxed); _ = bytes.load(ordering: .relaxed); _ = armed.load(ordering: .relaxed)
        _ = period; _ = slots; _ = depth
        var warm = [UnsafeMutableRawPointer?](repeating: nil, count: 4)
        _ = backtrace(&warm, 4)
        symbol.assumingMemoryBound(to: Logger?.self).pointee = logger
        return true
    }

    static func begin() {
        armed.store(false, ordering: .sequentiallyConsistent)
        next.store(0, ordering: .sequentiallyConsistent)
        bytes.store(0, ordering: .sequentiallyConsistent)
        armed.store(true, ordering: .sequentiallyConsistent)
    }

    /// (weight in periods, frames) per sample.
    static func end() -> [(Int, [UInt])] {
        armed.store(false, ordering: .sequentiallyConsistent)
        let count = min(slots, next.load(ordering: .sequentiallyConsistent))
        return (0..<count).map { slot in
            let n = Int(max(0, counts[slot]))
            return (weights[slot], (0..<n).map { UInt(bitPattern: frames[slot * depth + $0]) })
        }
    }

    static func symbol(_ address: UInt) -> String {
        var info = Dl_info()
        guard dladdr(UnsafeRawPointer(bitPattern: address), &info) != 0 else { return "?" }
        let image = info.dli_fname.map { String(cString: $0).split(separator: "/").last.map(String.init) ?? "?" } ?? "?"
        let name = info.dli_sname.map { String(cString: $0) } ?? "?"
        return image + "`" + name
    }

    static func summary(_ samples: [(Int, [UInt])]) -> [String: Any] {
        let mib = Double(period) / 1_048_576
        var names: [UInt: String] = [:]
        func name(_ address: UInt) -> String {
            if let cached = names[address] { return cached }
            let value = symbol(address); names[address] = value; return value
        }
        var byFrame: [String: Double] = [:], byStack: [String: Double] = [:]
        var total: Double = 0
        for (weight, stack) in samples {
            let value = Double(weight) * mib
            total += value
            // Skip the logger and libmalloc frames.
            let resolved = stack.dropFirst(2).map(name).filter { !$0.hasPrefix("libsystem_malloc") }
            for frame in Set(resolved) { byFrame[frame, default: 0] += value }
            byStack[resolved.prefix(14).joined(separator: " <- "), default: 0] += value
        }
        let top = { (table: [String: Double], n: Int) in
            table.sorted { $0.value > $1.value }.prefix(n).map { [$0.key, ($0.value * 10).rounded() / 10] as [Any] }
        }
        return ["totalMiB": (total * 10).rounded() / 10, "samples": samples.count,
                "frames": top(byFrame, 40), "stacks": top(byStack, 12)]
    }
}
