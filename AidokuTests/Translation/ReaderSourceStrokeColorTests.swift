import Testing
import UIKit
import WebKit
@testable import Aidoku

/// Frozen source pixels and stroke-only annotations; no OCR or provider calls.
@Suite(.serialized)
@MainActor
struct ReaderSourceStrokeColorTests {
    private nonisolated static var directory: URL { URL.documentsDirectory.appendingPathComponent("MangaQuality") }

    @Test(.enabled(if: FileManager.default.fileExists(atPath: directory.appendingPathComponent("stroke-replay.json").path)))
    func datasetStrokeColorsAndAbsentOutlineControlsInWebKit() async throws {
        struct Fixture: Decodable {
            let id: String
            let image: String
            let bounds: [Double]
            let expectedStroke: [Int]?
            let split: String
            let scored: Bool
        }
        let fixtures = try JSONDecoder().decode([Fixture].self,
            from: Data(contentsOf: Self.directory.appendingPathComponent("stroke-replay.json")))
        let baseline = try String(contentsOf: Self.directory.appendingPathComponent("stroke-baseline.js"), encoding: .utf8)
        let output = Self.directory.appendingPathComponent("stroke-results")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let host = UIWindow(windowScene: scene)
        host.rootViewController = UIViewController()
        host.makeKeyAndVisible()
        defer { host.isHidden = true }
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 430, height: 650))
        host.rootViewController?.view.addSubview(web)
        try await RegressionWebFixture.load("<meta name='viewport' content='width=device-width,initial-scale=1'><body style='margin:12px;background:#ddd;font:14px sans-serif'>", in: web)

        var rows: [[String: Any]] = []
        var beforeMatches = 0, afterMatches = 0, beforeStrokes = 0, afterStrokes = 0
        var regressions: [String] = []
        for fixture in fixtures {
            let data = try Data(contentsOf: Self.directory.appendingPathComponent(fixture.image))
            var row: [String: Any] = ["id": fixture.id, "split": fixture.split,
                "expectedStroke": fixture.expectedStroke as Any? ?? NSNull(), "scored": fixture.scored]
            for before in [true, false] {
                let script = (before ? baseline : BrowserSourceTextColor.script) + """
                const image=new Image();image.src='data:image/png;base64,'+encoded;await image.decode();
                const budget={pixels:393216,detailPixels:98304,remainingSamples:1};
                const sampler=aidokuSourceColorSampler(image,true,'ocr',budget),result=sampler.sample(bounds);
                const cached=sampler.sample(bounds);
                const translated=aidokuSourceColorSampler(image,true,'translation').sample(bounds);
                return {result,stats:sampler.stats,remaining:budget,cacheSame:cached===result,
                  phasesEqual:JSON.stringify(result)===JSON.stringify(translated)};
                """
                let report = try #require(try await web.callAsyncJavaScript(script,
                    arguments: ["encoded": data.base64EncodedString(), "bounds": fixture.bounds],
                    in: nil, contentWorld: .page) as? [String: Any])
                let palette = report["result"] as? [String: Any]
                let stroke = palette?["stroke"] as? [Int]
                let matched: Bool
                if let expected = fixture.expectedStroke {
                    matched = stroke?.count == 3 && zip(stroke ?? [], expected).allSatisfy { abs($0 - $1) <= 25 }
                } else { matched = stroke == nil }
                var enriched = report
                enriched["matched"] = matched
                row[before ? "before" : "after"] = enriched
                if fixture.scored && matched {
                    if before { beforeMatches += 1 } else { afterMatches += 1 }
                    if fixture.expectedStroke != nil {
                        if before { beforeStrokes += 1 } else { afterStrokes += 1 }
                    }
                }
                #expect(report["cacheSame"] as? Bool == true)
                #expect(report["phasesEqual"] as? Bool == true)
                let stats = try #require(report["stats"] as? [String: Any])
                #expect((stats["pixels"] as? Int ?? Int.max) <= 393_216)
                let remaining = try #require(report["remaining"] as? [String: Any])
                #expect((remaining["detailPixels"] as? Int ?? -1) >= 0)
            }
            rows.append(row)
            if fixture.scored,
               (row["before"] as? [String: Any])?["matched"] as? Bool == true,
               (row["after"] as? [String: Any])?["matched"] as? Bool != true {
                regressions.append(fixture.id)
            }
            // Inspect source crops with native WebKit measurements, including misses.
            if fixture.expectedStroke != nil || fixture.id == "d001" || fixture.id == "d006" {
                _ = try await web.callAsyncJavaScript("""
                document.body.replaceChildren();
                const title=document.createElement('p');title.textContent=label+' · 테두리 색상';document.body.appendChild(title);
                const image=new Image();image.src='data:image/png;base64,'+encoded;await image.decode();
                image.style.cssText='max-width:406px;max-height:440px;object-fit:contain';document.body.appendChild(image);
                for(const [name,color] of swatches){const line=document.createElement('div');line.textContent=name+': '+(color?color.join(','):'none');
                  line.style.cssText='margin:8px;padding:8px;border-left:24px solid '+(color?'rgb('+color.join(',')+')':'transparent');document.body.appendChild(line);}
                await new Promise(r=>requestAnimationFrame(()=>requestAnimationFrame(r)));
                """, arguments: ["label": fixture.id, "encoded": data.base64EncodedString(),
                    "swatches": [
                        ["reference", fixture.expectedStroke as Any? ?? NSNull()],
                        ["before", ((row["before"] as? [String: Any])?["result"] as? [String: Any])?["stroke"] ?? NSNull()],
                        ["after", ((row["after"] as? [String: Any])?["result"] as? [String: Any])?["stroke"] ?? NSNull()]
                    ]], in: nil, contentWorld: .page)
                let snapshot: UIImage = try await withCheckedThrowingContinuation { continuation in
                    web.takeSnapshot(with: nil) { image, error in
                        if let image { continuation.resume(returning: image) }
                        else { continuation.resume(throwing: error ?? URLError(.cannotDecodeContentData)) }
                    }
                }
                try snapshot.pngData()?.write(to: output.appendingPathComponent(fixture.id + ".png"))
            }
            try JSONSerialization.data(withJSONObject: row, options: [.prettyPrinted, .sortedKeys])
                .write(to: output.appendingPathComponent(fixture.id + ".json"))
        }
        let total = fixtures.filter(\.scored).count
        let summary: [String: Any] = ["total": total, "before": beforeMatches, "after": afterMatches,
            "beforeStrokes": beforeStrokes, "afterStrokes": afterStrokes,
            "regressions": regressions, "rows": rows]
        try JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("summary.json"))
        #expect(total >= 100)
        #expect(afterMatches > beforeMatches)
        #expect(afterStrokes >= beforeStrokes)
        #expect(regressions.isEmpty)
        #expect(Double(afterMatches) / Double(total) >= 0.8)
    }
}
