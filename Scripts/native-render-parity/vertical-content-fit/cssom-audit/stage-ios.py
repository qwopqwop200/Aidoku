"""Stage only the ten original CSSOM controls as an independent iOS capture."""
from pathlib import Path
import hashlib,json,re
ROOT=Path(__file__).resolve().parents[4];HERE=Path(__file__).resolve().parent
BASE=ROOT/'build/native-render-parity/vertical-content-fit'
original=(BASE/'capture.js').read_text();web=json.loads((BASE/'dom.json').read_text())
indices=[r['index'] for r in json.loads((BASE/'current47-audit/shaping-report.json').read_text())['adapterMetricFailures']]
jobs=[]
for i in indices:
 a=dict(web[i]['a']);a['originalIndex']=i;jobs.append(a)
script=re.sub(r'const jobs=.*?;\n return JSON.stringify', 'const jobs='+json.dumps(jobs,ensure_ascii=False)+';\n return JSON.stringify',original,count=1,flags=re.S)
html="<html><head><meta name='viewport' content='width=device-width,initial-scale=1'><style>html,body{margin:0;background:white}</style></head><body></body></html>"
text='''import Testing
import UIKit
import WebKit
import CoreText
@testable import Aidoku

/// Actual-iOS CSSOM only; ten original macOS failure descriptors. No optical
/// countercontrol, fixture-specific native shaping, PDF job, or font override.
@MainActor
struct NativeVerticalCSSOMParityCapture {
    func run() async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIViewController()
        window.overrideUserInterfaceStyle = .light
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 700)
        window.makeKeyAndVisible()
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 700)
        defer { window.isHidden = true }
        let view = WKWebView(frame: window.bounds)
        view.overrideUserInterfaceStyle = .light
        view.scrollView.contentInsetAdjustmentBehavior = .never
        let host = try #require(window.rootViewController?.view)
        host.frame = window.bounds
        host.insertSubview(view, at: 0)
        defer { view.stopLoading(); view.removeFromSuperview() }
        let directory = URL.documentsDirectory.appendingPathComponent("NativeVerticalCSSOMParity", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["passed": false, "expectedCount": 10, "reports": []] as [String: Any])
            .write(to: directory.appendingPathComponent("report.json"), options: .atomic)
        let waiter = VerticalCSSOMNavigationWaiter()
        try await waiter.load(in: view, html: Self.html)
        let viewportRaw = try await view.callAsyncJavaScript("return JSON.stringify({innerWidth,innerHeight,dpr:devicePixelRatio,visualWidth:visualViewport.width,visualHeight:visualViewport.height});", arguments: [:], in: nil, contentWorld: .page)
        let viewport = try #require(viewportRaw as? String)
        try Data(viewport.utf8).write(to: directory.appendingPathComponent("viewport.json"))
        let raw = try await view.callAsyncJavaScript("await document.fonts.ready; return " + Self.captureScript,
            arguments: [:], in: nil, contentWorld: .page)
        let webJSON = try #require(raw as? String)
        try Data(webJSON.utf8).write(to: directory.appendingPathComponent("web-layout.json"))
        try Data(Self.html.utf8).write(to: directory.appendingPathComponent("input.html"))
        try Data(Self.captureScript.utf8).write(to: directory.appendingPathComponent("input.js"))
        let rows = try #require(JSONSerialization.jsonObject(with: Data(webJSON.utf8)) as? [[String: Any]])
        #expect(rows.count == 10)
        var reports: [[String: Any]] = [], nativeRows: [[String: Any]] = [], failures: [Int] = []
        for row in rows {
            let a = try #require(row["a"] as? [String: Any])
            let index = try #require(a["originalIndex"] as? Int)
            let text = try #require(a["text"] as? String)
            let font = try #require(a["font"] as? Double), pitch = try #require(a["pitch"] as? Double)
            let pads = try #require(a["pads"] as? [Double])
            let descriptor: [String: Any] = ["id": "cssom-\\(index)", "text": text,
                "width": a["width"]!, "height": a["height"]!, "fontSize": font, "lineHeight": pitch,
                "paddingTop": pads[0], "paddingRight": pads[1], "paddingBottom": pads[2], "paddingLeft": pads[3],
                "vertical": true, "clipsText": a["clips"]!, "balancedColumn": a["balanced"]!,
                "sourceBounds": [0, 0, 1, 1], "sourceFrame": [0, 0, 1, 1]]
            let item = try JSONDecoder().decode(NativeTranslationLayoutItem.self,
                from: JSONSerialization.data(withJSONObject: descriptor))
            let used = NativeTypographyPostPolish.usedLayoutItem(item)
            let style = NativeTranslationTypography.Style(fontScript: "han", fontSize: font,
                bold: true, vertical: true, lineHeight: pitch, alignsToTop: a["balanced"] as! Bool, strictLineBreak: true)
            let layout = NativeTranslationTypography.layout(text: text, in: used.contentRect.size, style: style)
            let metrics = try #require(NativeTypographyPostPolish.contentFitMetrics(item: item, typography: layout))
            let actual = [metrics.clientWidth, metrics.clientHeight, metrics.scrollWidth, metrics.scrollHeight]
            let expected = try #require(row["client"] as? [Int]) + (try #require(row["scroll"] as? [Int]))
            let equal = actual == expected
            if !equal { failures.append(index) }
            reports.append(["index": index, "web": expected, "native": actual, "exact": equal])
            nativeRows.append(["a": a, "metrics": actual, "lineCount": layout.lineCount,
                "lineAdvances": NativeTranslationTypography.verticalLineAdvances(layout: layout),
                "rangeBounds": layout.rangeBounds.map { [$0.minX, $0.minY, $0.width, $0.height] },
                "lineRanges": layout.lineRanges.map { [$0.location, $0.length] },
                "coreTextRows": NativeTranslationTypography.diagnosticRuns(layout: layout)])
        }
        try JSONSerialization.data(withJSONObject: nativeRows, options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appendingPathComponent("native-layout.json"))
        let summary: [String: Any] = ["scope": "actual-iOS original CSSOM vs production vertical shaper and Post metrics",
            "os": UIDevice.current.systemVersion, "screenScale": view.window?.screen.scale ?? 1,
            "expectedCount": 10, "reports": reports, "passed": reports.count == 10 && failures.isEmpty]
        try JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appendingPathComponent("report.json"), options: .atomic)
        #expect(failures.isEmpty, Comment(rawValue: "Vertical CSSOM unequal original indices: \\(failures)"))
    }

    private static let html = #"HTML"#
    private static let captureScript = #"""
SCRIPT
"""#
}

@MainActor
private final class VerticalCSSOMNavigationWaiter: NSObject, WKNavigationDelegate {
    private var continuation: CheckedContinuation<Void, Error>?
    func load(in view: WKWebView, html: String) async throws {
        view.navigationDelegate = self
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            view.loadHTMLString(html, baseURL: nil)
        }
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { continuation?.resume(); continuation = nil }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        continuation?.resume(throwing: error); continuation = nil
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        continuation?.resume(throwing: error); continuation = nil
    }
}
'''.replace('#"HTML"#','#"'+html+'"#').replace('\nSCRIPT\n','\n'+script+'\n')
p=HERE/'NativeVerticalCSSOMParityCapture.staged.swift';p.write_text(text)
(HERE/'ios-inputs.json').write_text(json.dumps(jobs,ensure_ascii=False,indent=2))
print(json.dumps(dict(staged=str(p.relative_to(ROOT)),cases=len(jobs),inputSHA256=hashlib.sha256(json.dumps(jobs,ensure_ascii=False,sort_keys=True).encode()).hexdigest(),originalStyleSHA256=hashlib.sha256(original[original.index('Object.assign(node.style'):original.index('if(item.balancedColumn)')].encode()).hexdigest()),indent=2))
