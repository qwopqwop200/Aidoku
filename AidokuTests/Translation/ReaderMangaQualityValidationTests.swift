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
        settings.maximumConcurrentRequests = config.maximumConcurrentRequests ?? 2
        if let value = config.preserveSourceTextColor { settings.overlay.preserveSourceTextColor = value }
        if let value = config.preserveSourceBackgroundColor { settings.overlay.preserveSourceBackgroundColor = value }
        settings.includePageImage = config.includePageImage ?? false
        settings.filterSFXWithLLM = config.filterSFXWithLLM ?? false
        settings.rightToLeftPanelOrder = config.rightToLeftPanelOrder ?? false
        if let effort = config.reasoningEffort { settings.reasoningEffort = effort }
        let output = folder.appendingPathComponent(config.label)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let responseAudit = QualityTranslationAuditTransport(
            base: BoundedURLSessionTransport(),
            outputDirectory: config.recordTranslationResponses == true ? output : nil
        )
        let translator = ReaderTranslationService(client: RemoteTranslationClient(
            credentialStore: QualityCredential(value: try config.runtimeCredential(folder: folder)),
            transport: config.recordTranslationResponses == true ? responseAudit : BoundedURLSessionTransport()
        ))
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
            await responseAudit.reset()
            await responseAudit.setPageID(name)
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
            if let expectedCount = config.expectedOCRRegionCounts?[name] {
                // Manually reviewed text-free illustrations are useful false-positive controls.
                #expect(regions.count == expectedCount)
            } else {
                #expect(!regions.isEmpty)
            }
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
            let firstDisplay = FirstDisplayProbe(controller: controller, source: source, settings: settings, started: started)
            let prepared = ReaderTranslationImagePreparation.apply(regions, image: source, settings: settings)
            let translated: [ReaderTranslationRegion]
            do {
                if let replay { translated = replay } else {
                    let progress: ReaderTranslationService.Progress?
                    if config.measureFirstDisplay == true {
                        progress = { snapshot in try await firstDisplay.show(snapshot) }
                    } else { progress = nil }
                    translated = try await translator.translate(regions: prepared, settings: settings, image: source, onProgress: progress)
                }
            } catch {
                // Diagnose every real image even if one provider request fails.
                Issue.record(error)
                firstDisplay.finish()
                if config.recordTranslationResponses == true {
                    try await responseAudit.flush(to: output.appendingPathComponent(name + "-responses.json"))
                }
                continue
            }
            #expect(translated.count == regions.count)
            #expect(translated.allSatisfy { $0.translation != nil })
            firstDisplay.finish()
            let records = translated.map(ReaderTranslationStoredRegion.init)
            try encoder.encode(records).write(to: output.appendingPathComponent(name + "-regions.json"))
            let size = CGSize(width: 430, height: 430 * source.size.height / source.size.width)
            let overlay = ReaderTranslationOverlayView(frame: CGRect(origin: .zero, size: size))
            controller.view.addSubview(overlay)
            overlay.update(regions: translated, imageSize: source.size, aspectFit: false, settings: settings,
                           image: source)
            let expectedEmpty = ReaderTranslationRegion.overlayItems(translated, imageSize: source.size).isEmpty
            var committed = false
            for _ in 0..<600 {
                overlay.layoutIfNeeded()
                if overlay.lastDiagnostic?.outcome == .committed ||
                    (expectedEmpty && overlay.lastDiagnostic?.outcome == .cleared) { committed = true; break }
                try await Task.sleep(for: .milliseconds(50))
            }
            #expect(committed)
            let audit = try await overlay.webView.evaluateJavaScript("""
            Array.from(document.querySelectorAll('[data-aidoku-image-ocr-overlay="item"]')).map(x => {
              const s=getComputedStyle(x);return {text:x.textContent,x:parseFloat(s.left),y:parseFloat(s.top),
                width:parseFloat(s.width),height:parseFloat(s.height),fontSize:parseFloat(s.fontSize),
                border:s.borderWidth,shadow:s.boxShadow,color:s.color,backgroundColor:s.backgroundColor,
                backgroundImage:s.backgroundImage,textShadow:s.textShadow,textStroke:s.webkitTextStroke,
                sourceTextColor:x.dataset.sourceTextColor,sourceTextColorAdjusted:x.dataset.sourceTextColorAdjusted,
                sourceBackgroundColor:x.dataset.sourceBackgroundColor,
                sourceSampledTextRGB:x.dataset.sourceSampledTextRGB,sourceAppliedTextRGB:x.dataset.sourceAppliedTextRGB,
                sourceSampledBackgroundRGB:x.dataset.sourceSampledBackgroundRGB,sourceAppliedBackgroundRGB:x.dataset.sourceAppliedBackgroundRGB,
                sourceTextOutline:x.dataset.sourceTextOutline,
                sourceSampledStrokeRGB:x.dataset.sourceSampledStrokeRGB,sourceAppliedStrokeRGB:x.dataset.sourceAppliedStrokeRGB,
                sourceStrokeColor:x.dataset.sourceStrokeColor,sourceStrokeConfidence:x.dataset.sourceStrokeConfidence,
                scrollWidth:x.scrollWidth,clientWidth:x.clientWidth,
                scrollHeight:x.scrollHeight,clientHeight:x.clientHeight};
            })
            """)
            let wrapMilliseconds = try await overlay.webView.evaluateJavaScript(
                "Number(document.querySelector('[data-aidoku-image-ocr-overlay=\"root\"]')?.dataset.koreanWrapMilliseconds || 0)"
            )
            let report: [String: Any] = ["koreanWrapMilliseconds": wrapMilliseconds,
                                       "ocrSeconds": ocrSeconds, "totalSeconds": Date().timeIntervalSince(started),
                                       "regions": regions.count, "replayed": replay != nil, "dom": audit, "displayExpected": !expectedEmpty,
                                       "firstDisplaySeconds": firstDisplay.firstSeconds ?? NSNull(),
                                       "includePageImage": settings.includePageImage, "filterSFXWithLLM": settings.filterSFXWithLLM]
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
            // WebKit's GPU snapshot can omit the source-image layer on dark
            // pages. Use the production compositor for a complete visual audit.
            let exported = try await ReaderTranslationImageExporter.render(image: source, regions: translated,
                settings: settings, viewport: size, aspectFit: false, host: controller.view)
            try exported.pngData()?.write(to: output.appendingPathComponent(name + "-exported.png"))
            if config.recordTranslationResponses == true {
                try await responseAudit.flush(to: output.appendingPathComponent(name + "-responses.json"))
            }
            if config.benchmarkKoreanWrap == true {
                let benchmark = try await benchmarkKoreanWrap(on: overlay.webView, regions: translated,
                    imageSize: source.size, size: size, settings: settings,
                    replacements: config.scriptReplacements.map { folder.appendingPathComponent($0) },
                    output: output.appendingPathComponent(name))
                try JSONSerialization.data(withJSONObject: benchmark, options: [.prettyPrinted, .sortedKeys])
                    .write(to: output.appendingPathComponent(name + "-wrap-benchmark.json"))
            }
            overlay.removeFromSuperview()
        }
        await ReaderOCRService.shared.purge()
    }

    // Same WKWebView, payload and process for both variants. Exclude navigation,
    // image decoding and the 50 ms diagnostic poll from this isolated JS cost.
    private func benchmarkKoreanWrap(on webView: WKWebView, regions: [ReaderTranslationRegion],
                                    imageSize: CGSize, size: CGSize,
                                    settings: ReaderTranslationSettings, replacements: URL?,
                                    output: URL) async throws -> [[String: Any]] {
        let script = BrowserPageImageOverlayRenderer.renderScript
        let begin = try #require(script.range(of: "// Repair existing Korean emergency breaks"))
        let end = try #require(script.range(of: "measurementNode.remove();", range: begin.upperBound..<script.endIndex))
        var baseline = script
        baseline.removeSubrange(begin.lowerBound..<end.lowerBound)
        baseline = baseline.replacingOccurrences(of: "const koreanWrapMeasure = document.createElement('canvas').getContext('2d');", with: "")
        var candidate = script
        if let replacements {
            baseline = script
            let changes = try JSONDecoder().decode([[String: String]].self, from: Data(contentsOf: replacements))
            for change in changes {
                let old = try #require(change["old"]), new = try #require(change["new"])
                #expect(candidate.contains(old))
                candidate = candidate.replacingOccurrences(of: old, with: new)
            }
        }
        let componentNativeStarted = Date()
        let encoded = try await BrowserPageImageOverlayRenderer.prepareLayoutData(
            items: ReaderTranslationRegion.overlayItems(regions, imageSize: imageSize), imageSize: imageSize,
            sourceRect: CGRect(origin: .zero, size: size), settings: settings.overlay,
            targetLanguage: settings.targetLanguage, viewport: size)
        let componentNativeMilliseconds = Date().timeIntervalSince(componentNativeStarted) * 1000
        var payload = try #require(JSONSerialization.jsonObject(with: encoded) as? [[String: Any]])
        // Offline cleanup candidates may inspect the already recognized source.
        // Stable IDs retain the input-region index even when unchanged text is omitted.
        for index in payload.indices {
            guard let id = payload[index]["id"] as? String,
                  let regionIndex = Int(id), regions.indices.contains(regionIndex)
            else { continue }
            payload[index]["sourceOriginalText"] = regions[regionIndex].source
        }
        if replacements != nil { try encoded.write(to: output.appendingPathExtension("layout.json")) }
        var measurements: [[String: Any]] = []
        var firstInvocation: [String: Any]?
        let benchmarkWorld = WKContentWorld.world(name: "aidoku-fixed-component-" + UUID().uuidString)
        for iteration in 0..<5 {
            let variants = iteration.isMultiple(of: 2) ? [false, true] : [true, false]
            for enabled in variants {
                let source = enabled ? candidate : baseline
                let timed = "const sourceCacheGlobalsBefore = Object.getOwnPropertyNames(globalThis).filter(key => key.startsWith('__aidokuSourceTextColors')).length; " +
                    "const began = performance.now(); const outcome = (() => {\n" + source +
                    "\n})(); const syncMilliseconds = performance.now() - began; " +
                    "const componentRoot = document.querySelector('[data-aidoku-image-ocr-overlay=\"root\"]'); " +
                    "const metric = key => componentRoot?.dataset[key] === undefined ? null : Number(componentRoot.dataset[key]); " +
                    "return {milliseconds: syncMilliseconds, status: outcome.status, sourceCacheGlobalsBefore, " +
                    "cleanupMilliseconds: metric('cleanupMilliseconds'), koreanWrapMilliseconds: metric('koreanWrapMilliseconds'), " +
                    "smallTextRefinementMilliseconds: metric('smallTextRefinementMilliseconds'), " +
                    "sourceColorCacheHits: metric('sourceColorCacheHits'), sourceColorSamples: metric('sourceColorSamples')};"
                let result = try await webView.callAsyncJavaScript(timed, arguments: [
                    "items": payload, "appearance": ["opacity": settings.overlay.opacity,
                        "preserveSourceTextColor": settings.overlay.preserveSourceTextColor,
                        "preserveSourceBackgroundColor": settings.overlay.preserveSourceBackgroundColor,
                        "minimumReadableFontSize": BrowserOverlayLayoutPlanner.minimumRenderedFontSize],
                    "revision": "1", "session": UUID().uuidString
                ], in: nil, contentWorld: benchmarkWorld)
                let row = try #require(result as? [String: Any])
                if firstInvocation == nil {
                    #expect((row["sourceCacheGlobalsBefore"] as? NSNumber)?.intValue == 0)
                    firstInvocation = row
                }
                #expect(row["status"] as? String == (ReaderTranslationRegion.overlayItems(regions, imageSize: imageSize).isEmpty ? "cleared" : "committed"))
                if iteration == 0, replacements != nil {
                    let label = enabled ? "candidate" : "baseline"
                    let audit = try await webView.evaluateJavaScript("""
                    Array.from(document.querySelectorAll('[data-aidoku-image-ocr-overlay="item"]')).map(node => {
                      const style=getComputedStyle(node), r=node.getBoundingClientRect(), lines=[];
                      const range=document.createRange();let offset=0;
                      for (const c of node.textContent) {
                        range.setStart(node.firstChild,offset);offset+=c.length;range.setEnd(node.firstChild,offset);
                        const boxes=Array.from(range.getClientRects()).filter(r=>r.width>0&&r.height>0);
                        const box=boxes[boxes.length-1];if(!box)continue;
                        let line=lines.find(l=>Math.abs(l.y-box.y)<1);
                        if(!line){line={y:box.y,text:'',offsets:[]};lines.push(line);}
                        line.text+=c;line.offsets.push(offset-c.length);
                      }
                      return {id:node.dataset.aidokuRegion,text:node.textContent,
                        font:parseFloat(style.fontSize),padding:style.padding,
                        color:style.color,backgroundColor:style.backgroundColor,textShadow:style.textShadow,
                        textStrokeWidth:style.webkitTextStrokeWidth,textStrokeColor:style.webkitTextStrokeColor,
                        paintOrder:style.paintOrder,
                        sourceSampledStrokeRGB:node.dataset.sourceSampledStrokeRGB,sourceAppliedStrokeRGB:node.dataset.sourceAppliedStrokeRGB,
                        sourceStrokeColor:node.dataset.sourceStrokeColor,sourceStrokeConfidence:node.dataset.sourceStrokeConfidence,
                        sourceCardProbe:node.dataset.sourceCardProbe,sourceCardProbeRects:node.dataset.sourceCardProbeRects,
                        sourceCardProbeBounds:node.dataset.sourceCardProbeBounds,
                        rect:[r.x,r.y,r.width,r.height],lines,
                        overflow:node.scrollWidth>node.clientWidth+1||node.scrollHeight>node.clientHeight+1};
                    })
                    """)
                    try JSONSerialization.data(withJSONObject: audit, options: [.prettyPrinted, .sortedKeys])
                        .write(to: output.appendingPathExtension(label + ".json"))
                    let snapshot: UIImage = try await withCheckedThrowingContinuation { continuation in
                        webView.takeSnapshot(with: nil) { image, error in
                            if let image { continuation.resume(returning: image) }
                            else { continuation.resume(throwing: error ?? CancellationError()) }
                        }
                    }
                    try snapshot.pngData()?.write(to: output.appendingPathExtension(label + ".png"))
                }
                if iteration > 0 { measurements.append(["enabled": enabled, "iteration": iteration,
                    "milliseconds": row["milliseconds"] ?? -1,
                    "cleanupMilliseconds": row["cleanupMilliseconds"] ?? NSNull(),
                    "koreanWrapMilliseconds": row["koreanWrapMilliseconds"] ?? NSNull(),
                    "smallTextRefinementMilliseconds": row["smallTextRefinementMilliseconds"] ?? NSNull(),
                    "nativeLayoutMillisecondsOncePerPage": componentNativeMilliseconds,
                    "firstInvocationMillisecondsOncePerPage": firstInvocation?["milliseconds"] ?? NSNull(),
                    "firstInvocationCleanupMillisecondsOncePerPage": firstInvocation?["cleanupMilliseconds"] ?? NSNull(),
                    "firstInvocationSourceColorCacheHitsOncePerPage": firstInvocation?["sourceColorCacheHits"] ?? NSNull(),
                    "firstInvocationSourceColorSamplesOncePerPage": firstInvocation?["sourceColorSamples"] ?? NSNull(),
                    "firstInvocationSourceCacheGlobalsBeforeOncePerPage": firstInvocation?["sourceCacheGlobalsBefore"] ?? NSNull(),
                    "benchmarkIsolatedSourceCacheWorld": true]) }
            }
        }
        return measurements
    }

    private struct Configuration: Decodable {
        let baseURL: String
        let model: String
        let apiKey: String?
        let credentialFile: String?
        let maximumConcurrentRequests: Int?
        let preserveSourceTextColor: Bool?
        let preserveSourceBackgroundColor: Bool?
        let includePageImage: Bool?
        let filterSFXWithLLM: Bool?
        let rightToLeftPanelOrder: Bool?
        let measureFirstDisplay: Bool?
        let recordTranslationResponses: Bool?
        func runtimeCredential(folder: URL) throws -> String {
            if let credentialFile {
                return try String(contentsOf: folder.appendingPathComponent(credentialFile), encoding: .utf8)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return apiKey ?? ""
        }
        let label: String
        let fixtures: [String]
        let expectedOCRRegionCounts: [String: Int]?
        let targetLanguage: String?
        let ocrOnly: Bool?
        let replayDirectory: String?
        let benchmarkKoreanWrap: Bool?
        let scriptReplacements: String?
        let reasoningEffort: OpenAIReasoningEffort?
    }

    @MainActor
    private final class FirstDisplayProbe {
        let overlay: ReaderTranslationOverlayView
        let source: UIImage
        let settings: ReaderTranslationSettings
        let started: Date
        var firstSeconds: Double?
        var rendering = false
        init(controller: UIViewController, source: UIImage, settings: ReaderTranslationSettings, started: Date) {
            self.source = source; self.settings = settings; self.started = started
            overlay = ReaderTranslationOverlayView(frame: CGRect(x: 0, y: 0, width: 430,
                height: 430 * source.size.height / source.size.width))
            controller.view.addSubview(overlay)
        }
        func show(_ regions: [ReaderTranslationRegion]) async throws {
            guard firstSeconds == nil, !rendering, regions.contains(where: {
                guard let translated = $0.translation, translated != $0.source, !translated.isEmpty else { return false }
                return settings.targetLanguage != "ko" || translated.unicodeScalars.contains { (0xAC00...0xD7A3).contains($0.value) }
            }) else { return }
            rendering = true
            overlay.update(regions: regions, imageSize: source.size, aspectFit: false, settings: settings, image: source)
            for _ in 0..<1500 {
                overlay.layoutIfNeeded()
                if overlay.lastDiagnostic?.outcome == .committed {
                    _ = try await overlay.webView.callAsyncJavaScript(
                        "await new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve)))",
                        arguments: [:], in: nil, contentWorld: ReaderTranslationDOM.contentWorld)
                    firstSeconds = Date().timeIntervalSince(started)
                    return
                }
                try await Task.sleep(for: .milliseconds(20))
            }
            throw URLError(.timedOut)
        }
        func finish() { overlay.cancelWork(); overlay.removeFromSuperview() }
    }

    private struct QualityCredential: TranslationCredentialProviding {
        let value: String
        func secret(for account: String) throws -> String { value }
    }
}
