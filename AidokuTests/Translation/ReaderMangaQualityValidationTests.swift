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
            let wrapMilliseconds = try await overlay.webView.evaluateJavaScript(
                "Number(document.querySelector('[data-aidoku-image-ocr-overlay=\"root\"]')?.dataset.koreanWrapMilliseconds || 0)"
            )
            let report: [String: Any] = ["koreanWrapMilliseconds": wrapMilliseconds,
                                       "ocrSeconds": ocrSeconds, "totalSeconds": Date().timeIntervalSince(started),
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
        let encoded = try await BrowserPageImageOverlayRenderer.prepareLayoutData(
            items: ReaderTranslationRegion.overlayItems(regions, imageSize: imageSize), imageSize: imageSize,
            sourceRect: CGRect(origin: .zero, size: size), settings: settings.overlay,
            targetLanguage: settings.targetLanguage, viewport: size)
        let payload = try JSONSerialization.jsonObject(with: encoded)
        if replacements != nil { try encoded.write(to: output.appendingPathExtension("layout.json")) }
        var measurements: [[String: Any]] = []
        for iteration in 0..<5 {
            let variants = iteration.isMultiple(of: 2) ? [false, true] : [true, false]
            for enabled in variants {
                let source = enabled ? candidate : baseline
                let timed = "const began = performance.now(); const outcome = (() => {\n" + source +
                    "\n})(); return {milliseconds: performance.now() - began, status: outcome.status};"
                let result = try await webView.callAsyncJavaScript(timed, arguments: [
                    "items": payload, "appearance": ["opacity": settings.overlay.opacity,
                        "preserveSourceTextColor": settings.overlay.preserveSourceTextColor,
                        "preserveSourceBackgroundColor": settings.overlay.preserveSourceBackgroundColor,
                        "minimumReadableFontSize": BrowserOverlayLayoutPlanner.minimumRenderedFontSize],
                    "revision": "1", "session": UUID().uuidString
                ], in: nil, contentWorld: ReaderTranslationDOM.contentWorld)
                let row = try #require(result as? [String: Any])
                #expect(row["status"] as? String == "committed")
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
                    "milliseconds": row["milliseconds"] ?? -1]) }
            }
        }
        return measurements
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
        let benchmarkKoreanWrap: Bool?
        let scriptReplacements: String?
        let reasoningEffort: OpenAIReasoningEffort?
    }

    private struct QualityCredential: TranslationCredentialProviding {
        let value: String
        func secret(for account: String) throws -> String { value }
    }
}
