import Testing
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
            let descriptor: [String: Any] = ["id": "cssom-\(index)", "text": text,
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
        #expect(failures.isEmpty, Comment(rawValue: "Vertical CSSOM unequal original indices: \(failures)"))
    }

    private static let html = #"<html><head><meta name='viewport' content='width=device-width,initial-scale=1'><style>html,body{margin:0;background:white}</style></head><body></body></html>"#
    private static let captureScript = #"""
(()=>{
 const jobs=[{"script": "han", "text": "天地玄黄宇宙洪荒", "font": 20, "pitch": 24, "width": 8.5, "height": 15, "pads": [1, 2, 1, 2], "clips": false, "balanced": false, "originalIndex": 396}, {"script": "han", "text": "天地玄黄宇宙洪荒", "font": 20, "pitch": 24, "width": 8.5, "height": 15, "pads": [1, 2, 1, 2], "clips": false, "balanced": true, "originalIndex": 397}, {"script": "han", "text": "天地玄黄宇宙洪荒", "font": 20.5, "pitch": 24.6, "width": 8.5, "height": 15, "pads": [1, 2, 1, 2], "clips": true, "balanced": false, "originalIndex": 414}, {"script": "han", "text": "天地玄黄宇宙洪荒", "font": 20.5, "pitch": 24.6, "width": 8.5, "height": 15, "pads": [1, 2, 1, 2], "clips": true, "balanced": true, "originalIndex": 415}, {"script": "han", "text": "天地玄黄宇宙洪荒", "font": 12, "pitch": 12, "width": 30.49, "height": 30.51, "pads": [2.99, 4.125, 3.49, 1.5], "clips": false, "balanced": false, "originalIndex": 424}, {"script": "han", "text": "天地玄黄宇宙洪荒", "font": 12, "pitch": 12, "width": 30.49, "height": 30.51, "pads": [2.99, 4.125, 3.49, 1.5], "clips": false, "balanced": true, "originalIndex": 425}, {"script": "han", "text": "天地玄黄宇宙洪荒", "font": 12, "pitch": 12, "width": 30.49, "height": 30.51, "pads": [2.99, 4.125, 3.49, 1.5], "clips": true, "balanced": false, "originalIndex": 426}, {"script": "han", "text": "天地玄黄宇宙洪荒", "font": 12, "pitch": 12, "width": 30.49, "height": 30.51, "pads": [2.99, 4.125, 3.49, 1.5], "clips": true, "balanced": true, "originalIndex": 427}, {"script": "han", "text": "天地玄黄宇宙洪荒", "font": 23.9999999, "pitch": 23.9999999, "width": 8.5, "height": 15, "pads": [1, 2, 1, 2], "clips": false, "balanced": false, "originalIndex": 444}, {"script": "han", "text": "天地玄黄宇宙洪荒", "font": 23.9999999, "pitch": 23.9999999, "width": 8.5, "height": 15, "pads": [1, 2, 1, 2], "clips": false, "balanced": true, "originalIndex": 445}];
 return JSON.stringify(jobs.map(a=>{
 const node=document.createElement('div'),item={clipsText:a.clips,balancedColumn:a.balanced};
 const x=0,y=0,scrollX=0,scrollY=0,width=a.width,height=a.height,fontSize=a.font,lineHeight=a.pitch;
 const paddingTop=a.pads[0],paddingRight=a.pads[1],paddingBottom=a.pads[2],paddingLeft=a.pads[3];
 const vertical=true,wrappingScript=a.script==='korean'?'korean':'cjk',displayedText=a.text;
 const fontFamily=a.script==='japanese'?"'Hiragino Sans','YuGothic','Noto Sans CJK JP',-apple-system,BlinkMacSystemFont,sans-serif":a.script==='han'?"'PingFang SC','PingFang TC','Noto Sans CJK SC',-apple-system,BlinkMacSystemFont,sans-serif":"'Apple SD Gothic Neo','Noto Sans CJK KR','Noto Sans KR',-apple-system,BlinkMacSystemFont,sans-serif";
 const surfaceGradient=null,surface='255,255,255',opacity=1,sampledBackground=null,veil='255,255,255',veilAlpha=.42,foreground='0,0,0';
        Object.assign(node.style, {
          position: 'absolute',
          zIndex: '2',
          left: `${x + scrollX}px`,
          top: `${y + scrollY}px`,
          width: `${width}px`, height: `${height}px`,
          boxSizing: 'border-box',
          overflow: Boolean(item.clipsText) ? 'hidden' : 'visible',
          display: 'flex', alignItems: 'center', justifyContent: 'center',
          padding: `${paddingTop}px ${paddingRight}px ` +
            `${paddingBottom}px ${paddingLeft}px`,
          margin: '0', borderRadius: '6px',
          border: '0',
          backgroundColor: surfaceGradient ? 'transparent' : `rgba(${surface},${opacity})`,
          backgroundImage: surfaceGradient || (sampledBackground ? 'none' :
            `linear-gradient(rgba(${veil},${veilAlpha}),` +
            `rgba(${veil},${veilAlpha}))`),
          color: `rgb(${foreground})`,
          fontFamily,
          fontWeight: vertical ? '800' : '700',
          fontSize: `${fontSize}px`,
          lineHeight: `${Math.max(fontSize, lineHeight)}px`,
          letterSpacing: '-0.012em', textAlign: 'center',
          webkitTextStroke: '0px transparent', paintOrder: 'normal',
          textShadow: 'none',
          boxShadow: 'none',
          backdropFilter: 'none', webkitBackdropFilter: 'none',
          webkitTextSizeAdjust: 'none', textSizeAdjust: 'none',
          contain: 'layout style',
          whiteSpace: 'pre-wrap', overflowWrap: 'anywhere',
          wordBreak: wrappingScript === 'korean' ? 'keep-all' : 'normal',
          // Balance short Korean dialogue without changing its words or card.
          // The cloned measurement node uses the same policy during font fitting.
          textWrap: !vertical && wrappingScript === 'korean' &&
            displayedText.length <= 180 && !/[\\r\\n]/.test(displayedText)
              ? 'balance' : 'wrap',
          lineBreak: wrappingScript === 'cjk' ? 'strict' : 'auto',
          hyphens: wrappingScript === 'word' ? 'auto' : 'manual',
          direction: wrappingScript === 'rightToLeft' ? 'rtl' : 'ltr',
          unicodeBidi: 'plaintext',
          writingMode: vertical ? 'vertical-rl' : 'horizontal-tb',
          textOrientation: 'mixed'
        });
 if(item.balancedColumn)node.style.alignItems='flex-start';
 node.textContent=a.text;document.body.append(node);
 const c=getComputedStyle(node),r=node.getBoundingClientRect(),range=document.createRange();range.selectNodeContents(node);
 const lines=Array.from(range.getClientRects(),r=>[r.x,r.y,r.width,r.height]);
 const chars=[];for(let i=0;i<a.text.length;i++){range.setStart(node.firstChild,i);range.setEnd(node.firstChild,i+1);let rr=range.getBoundingClientRect();chars.push([a.text[i],rr.x,rr.y,rr.width,rr.height]);}
 const clone=node.cloneNode(false),child=document.createElement('span');child.textContent=a.text;clone.append(child);document.body.append(clone);const childBox=child.getBoundingClientRect();const itemBox=[childBox.x,childBox.y,childBox.width,childBox.height];clone.remove();
 const result={a,itemBox,client:[node.clientWidth,node.clientHeight],scroll:[node.scrollWidth,node.scrollHeight],box:[r.x,r.y,r.width,r.height],padding:[c.paddingTop,c.paddingRight,c.paddingBottom,c.paddingLeft].map(parseFloat),font:c.font,pitch:parseFloat(c.lineHeight),lines,chars};node.remove();return result;
 }));})()

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
