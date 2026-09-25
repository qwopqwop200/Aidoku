import Testing
import UIKit
import WebKit
@testable import Aidoku

/// Supplied real-image boxes isolate background estimation from OCR/provider quality.
@Suite(.serialized)
@MainActor
struct ReaderSourceBackgroundColorTests {
    private nonisolated static var directory: URL { URL.documentsDirectory.appendingPathComponent("MangaQuality") }

    @Test(.enabled(if: FileManager.default.fileExists(atPath: directory.appendingPathComponent("background-replay.json").path)))
    func datasetBackgroundsInPreviewAndKoreanCaptions() async throws {
        struct Fixture: Decodable {
            let id: String
            let image: String
            let bounds: [Double]
            let source: String
            let expectedBackground: [Int]
            let split: String
            let snapshot: Bool
        }
        let fixtures = try JSONDecoder().decode([Fixture].self,
            from: Data(contentsOf: Self.directory.appendingPathComponent("background-replay.json")))
        let baseline = try String(contentsOf: Self.directory.appendingPathComponent("background-baseline.js"), encoding: .utf8)
        // Optional exact production JS snapshot permits Canvas-specific replay
        // without rebuilding unrelated native modules for each JS correction.
        let candidateURL = Self.directory.appendingPathComponent("background-candidate.js")
        let candidate = FileManager.default.fileExists(atPath: candidateURL.path)
            ? try String(contentsOf: candidateURL, encoding: .utf8) : BrowserSourceTextColor.script
        let output = Self.directory.appendingPathComponent("background-results")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let host = UIWindow(windowScene: scene)
        host.rootViewController = UIViewController(); host.makeKeyAndVisible()
        defer { host.isHidden = true }
        var counts: [String: Int] = [:]
        var reports: [[String: Any]] = []
        let webFixture = RegressionWebFixture()
        for fixture in fixtures {
            let data = try Data(contentsOf: Self.directory.appendingPathComponent(fixture.image))
            let image = try #require(UIImage(data: data))
            let width = min(430, 700 * image.size.width / image.size.height)
            let size = CGSize(width: width, height: width * image.size.height / image.size.width)
            var prior: [String: [String: Any]] = [:]
            for before in [true, false] {
                for translated in [false, true] {
                    let phase = translated ? "ko" : "ocr"
                    let name = fixture.id + (before ? "-before-" : "-after-") + phase
                    let web = webFixture.acquire(frame: CGRect(origin: .zero, size: size))
                    defer { webFixture.release(web) }
                    web.scrollView.contentInsetAdjustmentBehavior = .never
                    host.rootViewController?.view.addSubview(web)
                    defer { web.removeFromSuperview() }
                    try await RegressionWebFixture.load("<meta name='viewport' content='width=device-width,initial-scale=1'><body style='margin:0'></body>", in: web)

                    _ = try await web.callAsyncJavaScript("""
                    const image=new Image();image.id='reader-source-image';image.src='data:image/png;base64,'+encoded;
                    await image.decode();image.style.width='\(width)px';image.style.height='auto';document.body.appendChild(image);
                    """, arguments: ["encoded": data.base64EncodedString()], in: nil, contentWorld: .page)
                    var settings = ReaderTranslationSettings.defaultOverlay
                    settings.preserveSourceTextColor = true; settings.preserveSourceBackgroundColor = true
                    settings.inpaintingEnabled = false; settings.opacity = 1
                    let b = fixture.bounds
                    let item = BrowserOverlayItem(stableRegionID: 0,
                        rect: CGRect(x: b[0] * image.size.width, y: b[1] * image.size.height,
                            width: b[2] * image.size.width, height: b[3] * image.size.height),
                        sourceText: fixture.source, translatedText: translated ? "배경 색상 확인" : nil,
                        confidence: 1, sourceOrientation: b[2] * image.size.width > b[3] * image.size.height ? .horizontal : .vertical)
                    let payload = BrowserPageImageOverlayRenderer.layoutPayload(items: [item], imageSize: image.size,
                        sourceRect: CGRect(origin: .zero, size: size), settings: settings,
                        targetLanguage: translated ? "ko" : "ja", viewport: size)
                    let script = BrowserPageImageOverlayRenderer.renderScript.replacingOccurrences(
                        of: BrowserSourceTextColor.script, with: before ? baseline : candidate)
                    if before { #expect(script != BrowserPageImageOverlayRenderer.renderScript) }
                    _ = try await web.callAsyncJavaScript(script,
                        arguments: ["revision": "1", "session": "background-replay", "items": payload,
                            "appearance": ["minimumReadableFontSize": 1, "opacity": 1, "inpaintingEnabled": false,
                                "preserveSourceTextColor": true, "preserveSourceBackgroundColor": true]],
                        in: nil, contentWorld: .page)
                    let audit = try #require(try await web.evaluateJavaScript("""
                    (()=>{const root=document.querySelector('[data-aidoku-image-ocr-overlay="root"]');
                    const n=root.querySelector('[data-aidoku-image-ocr-overlay="item"]');
                    const source=document.getElementById('reader-source-image');
                    const cache=Object.keys(globalThis).filter(k=>k.startsWith('__aidoku')&&k.includes('SourceTextColorsV'))
                      .map(k=>globalThis[k]?.get(source)).find(c=>c?.size);
                    return {stats:{...root.dataset},background:n.dataset.sourceAppliedBackgroundRGB.split(',').map(Number),
                      sample:cache?[...cache.values()][0]:null,
                      ink:n.dataset.sourceAppliedTextRGB,geometry:[n.offsetLeft,n.offsetTop,n.offsetWidth,n.offsetHeight],
                      plates:[...root.querySelectorAll('[data-aidoku-image-ocr-overlay="source-readability-panel"]')].map(p=>getComputedStyle(p).backgroundColor),
                      text:n.textContent};})()
                    """) as? [String: Any])
                    let rgb = try #require(audit["background"] as? [Int])
                    #expect(rgb.count == 3)
                    let error = zip(rgb, fixture.expectedBackground).map { abs($0 - $1) }.max() ?? 255
                    let key = (before ? "before-" : "after-") + phase
                    counts[key, default: 0] += error <= 25 ? 1 : 0
                    counts["total-" + key, default: 0] += 1
                    if before { prior[phase] = audit }
                    else {
                        #expect(error <= 25, "Background error \(error) in \(name): \(rgb), expected \(fixture.expectedBackground)")
                        #expect(audit["ink"] as? String == prior[phase]?["ink"] as? String, "Background change recolored \(name)")
                        #expect(audit["geometry"] as? [Int] == prior[phase]?["geometry"] as? [Int], "Background change moved \(name)")
                    }
                    let stats = try #require(audit["stats"] as? [String: String])
                    #expect((Int(stats["sourceColorPixels"] ?? "") ?? Int.max) <= 393216)
                    var report = audit
                    report["id"] = fixture.id; report["name"] = name; report["split"] = fixture.split
                    report["expectedBackground"] = fixture.expectedBackground; report["error"] = error
                    reports.append(report)
                    if fixture.snapshot {
                        _ = try await web.callAsyncJavaScript("await new Promise(r=>requestAnimationFrame(()=>requestAnimationFrame(r)))",
                            arguments: [:], in: nil, contentWorld: .page)
                        let snapshot: UIImage = try await withCheckedThrowingContinuation { continuation in
                            web.takeSnapshot(with: nil) { image, error in
                                if let image { continuation.resume(returning: image) }
                                else { continuation.resume(throwing: error ?? URLError(.cannotDecodeContentData)) }
                            }
                        }
                        try snapshot.pngData()?.write(to: output.appendingPathComponent(name + ".png"))
                    }
                }
            }
            try JSONSerialization.data(withJSONObject: reports, options: [.prettyPrinted, .sortedKeys])
                .write(to: output.appendingPathComponent("results.json"))
        }
        try JSONSerialization.data(withJSONObject: counts, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("summary.json"))
        for phase in ["ocr", "ko"] {
            let total = try #require(counts["total-after-" + phase])
            let after = try #require(counts["after-" + phase])
            let before = try #require(counts["before-" + phase])
            #expect(total == fixtures.count)
            #expect(after >= before)
            #expect(after == total)
        }
    }
}
