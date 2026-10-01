import Testing
import UIKit
import WebKit
import CryptoKit
@testable import Aidoku

/// Independent literal CSS background layers versus the actual source-panel
/// renderer. No canvas pixels, resampler, or inferred expected geometry.
@MainActor
struct NativeForeignBackgroundPaintParityCapture {
    private let page = CGRect(x: 0, y: 0, width: 320, height: 160)
    private struct Layer: Decodable { let position: [Double]; let size: [Double]; let color: [Double] }
    private struct Control: Decodable { let name: String; let originalOwner: [Double]; let finalOwner: [Double]; let base: [Double]; let layers: [Layer] }
    private struct Pixels { let width: Int; let height: Int; let bytes: Data }
    private enum Failure: Error { case invalidControl, invalidCapture, invalidPixels }

    func run() async throws {
        let directory = URL.documentsDirectory.appendingPathComponent("NativeForeignBackgroundPaintParity", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try writeJSON(["expectedCount": 4, "count": 0, "passed": false, "reports": []], to: directory.appendingPathComponent("report.json"))
        let inputData = Data(Self.inputs.utf8)
        let controls = try JSONDecoder().decode([Control].self, from: inputData)
        #expect(controls.count == 4)
        guard controls.count == 4 else { throw Failure.invalidControl }
        try inputData.write(to: directory.appendingPathComponent("literal-inputs.json"))
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIViewController(); window.overrideUserInterfaceStyle = .light
        window.frame = page; window.backgroundColor = .clear; window.makeKeyAndVisible(); window.frame = page
        defer { window.isHidden = true }
        let host = try #require(window.rootViewController?.view)
        host.frame = page; host.backgroundColor = .clear
        let web = WKWebView(frame: page)
        web.overrideUserInterfaceStyle = .light; web.isOpaque = true
        web.backgroundColor = UIColor(red: 41 / 255, green: 65 / 255, blue: 87 / 255, alpha: 1)
        web.underPageBackgroundColor = web.backgroundColor!; web.scrollView.backgroundColor = web.backgroundColor
        web.scrollView.contentInsetAdjustmentBehavior = .never
        host.addSubview(web)
        defer { web.stopLoading(); web.removeFromSuperview() }
        let waiter = ForeignBackgroundNavigationWaiter()
        try await waiter.load(in: web)
        var reports: [[String: Any]] = [], failures: [String] = []
        let literals = try #require(try JSONSerialization.jsonObject(with: inputData) as? [[String: Any]])
        for (index, control) in controls.enumerated() {
            let output = directory.appendingPathComponent(control.name, isDirectory: true)
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            do {
                let encoded = try JSONSerialization.data(withJSONObject: literals[index], options: [.sortedKeys])
                let returned = try await web.callAsyncJavaScript(Self.script,
                    arguments: ["inputJSON": String(decoding: encoded, as: UTF8.self)], in: nil, contentWorld: .page)
                let text = try #require(returned as? String)
                let dom = try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
                try Data(text.utf8).write(to: output.appendingPathComponent("web-dom.json"))
                let observedFinal = try #require(dom["usedFinalOwner"] as? [Double])
                let observedOriginal = try #require(dom["usedOriginalOwner"] as? [Double])
                let expectedFinal = NativeTranslationRenderer.usedRect(rect(control.finalOwner))
                let expectedOriginal = NativeTranslationRenderer.usedRect(rect(control.originalOwner))
                let beforeMove = try #require(dom["declaredBeforeMove"] as? [String: String])
                let afterMove = try #require(dom["declaredAfterMove"] as? [String: String])
                let declarationsRetained = beforeMove == afterMove
                let literalsMatch = observedFinal == values(expectedFinal) && observedOriginal == values(expectedOriginal) &&
                    (dom["sourceInputJSON"] as? String) == String(decoding: encoded, as: UTF8.self) &&
                    (dom["borderRadius"] as? String) == "0px" && declarationsRetained
                #expect(literalsMatch)
                guard literalsMatch else { throw Failure.invalidControl }
                let config = WKSnapshotConfiguration(); config.rect = page; config.snapshotWidth = 320
                let snapshot: UIImage = try await withCheckedThrowingContinuation { continuation in
                    web.takeSnapshot(with: config) { image, error in
                        if let error { continuation.resume(throwing: error) }
                        else if let image { continuation.resume(returning: image) }
                        else { continuation.resume(throwing: Failure.invalidCapture) }
                    }
                }
                // Preserve the public Web capture before any native comparison.
                let webPixels = try save(try #require(snapshot.cgImage), prefix: "web-live", output: output)
                let card = try makeCard(control)
                let format = UIGraphicsImageRendererFormat()
                format.scale = window.screen.scale; format.preferredRange = .standard; format.opaque = true
                var contextMetadata: [String: Any] = [:]
                let image = UIGraphicsImageRenderer(size: page.size, format: format).image { value in
                    let context = value.cgContext
                    contextMetadata = metadata(context)
                    context.setFillColor(NativeTranslationRenderer.color([41,65,87]))
                    context.fill(context.boundingBoxOfClipPath)
                    NativeTranslationRenderer.draw(card, context: context, opacity: 1,
                        paintsBackground: false, paintsText: false, paintsSourcePanels: true, pixelSnapScale: nil)
                }
                let nativePixels = try save(try #require(image.cgImage), prefix: "native-live", output: output)
                var report = compare(webPixels, nativePixels)
                report["scene"] = control.name; report["screenScale"] = window.screen.scale
                report["requestedSnapshotWidth"] = 320; report["UIImageScale"] = snapshot.scale
                report["UIImageOrientation"] = snapshot.imageOrientation.rawValue
                report["nativeWholePageResize"] = false
                report["consumer"] = "production NativeTranslationRenderer.draw: source-panels true, text/background false, pixelSnapScale nil"
                report["nativeCGContext"] = contextMetadata; report["viewport"] = viewport(web)
                report["sourceInputHash"] = hash(encoded); report["literalInputMatchesDOM"] = literalsMatch; report["declarationsRetainedAfterMove"] = declarationsRetained
                report["panelRadius"] = 0; report["baseColor"] = control.base
                report["nativePanelRect"] = values(card.sourcePanels[0].rect)
                report["declarationOrder"] = control.layers.map(\.color)
                report["originalGlobalEvidence"] = card.foreignFills.map { values($0.rect) }
                report["retainedPositions"] = card.foreignFills.map { [$0.backgroundPosition!.x, $0.backgroundPosition!.y] }
                report["retainedSizes"] = card.foreignFills.map { [$0.backgroundSize!.width, $0.backgroundSize!.height] }
                reports.append(report)
                try writeJSON(report, to: output.appendingPathComponent("comparison.json"))
                if report["exactRGBA"] as? Bool != true { failures.append("\(control.name): \(report["changedPixels"] ?? "dimension mismatch") pixels differ") }
            } catch { failures.append("\(control.name): \(error)") }
        }
        try writeJSON(["expectedCount": 4, "count": reports.count, "passed": reports.count == 4 && failures.isEmpty,
            "scope": "actual iOS literal CSS source-panel base and no-repeat constant-gradient layers vs production live draw; strict zero RGBA tolerance",
            "inputsHash": hash(inputData), "screenScale": window.screen.scale, "os": UIDevice.current.systemVersion,
            "reports": reports, "failures": failures], to: directory.appendingPathComponent("report.json"))
        #expect(reports.count == 4)
        #expect(failures.isEmpty, Comment(rawValue: failures.joined(separator: "\n")))
    }
    private func makeCard(_ control: Control) throws -> NativeTranslationRenderer.Card {
        let owner = NativeTranslationRenderer.usedRect(rect(control.finalOwner))
        let original = NativeTranslationRenderer.usedRect(rect(control.originalOwner))
        let fields: [String: Any] = ["id": control.name, "text": "", "x": owner.minX, "y": owner.minY,
            "width": owner.width, "height": owner.height, "fontSize": 8, "lineHeight": 10,
            "sourceBounds": [0.1,0.1,0.1,0.1], "sourceFrame": [0,0,320,160]]
        let item = try JSONDecoder().decode(NativeTranslationLayoutItem.self, from: JSONSerialization.data(withJSONObject: fields))
        let style = NativeTranslationTypography.Style(fontSize: 8, foreground: NativeTranslationRenderer.color([0,0,0]))
        let typography = NativeTranslationTypography.layout(text: "", in: item.contentRect.size, style: style)
        var panel = NativeTranslationSourceStylePostPolish.Panel(rect: owner, background: control.base, coverage: [owner])
        panel.radius = 0
        var card = NativeTranslationRenderer.Card(item: item, typography: typography, style: style,
            sourcePanels: [panel], drawsPanel: false, background: NativeTranslationRenderer.color(control.base.map { CGFloat($0) }),
            usesFallbackVeil: false, lightSurface: true, heavyStrokeWidth: 0, finalFontSize: 8)
        card.foreignFills = control.layers.map { layer in
            NativeCaptionPacking.ForeignFill(rect: CGRect(x: original.minX + layer.position[0], y: original.minY + layer.position[1],
                               width: layer.size[0], height: layer.size[1]), color: layer.color,
                  backgroundPosition: CGPoint(x: layer.position[0], y: layer.position[1]),
                  backgroundSize: CGSize(width: layer.size[0], height: layer.size[1]))
        }
        return card
    }
    private func rect(_ a: [Double]) -> CGRect { CGRect(x: a[0], y: a[1], width: a[2], height: a[3]) }
    private func values(_ r: CGRect) -> [Double] { [r.minX,r.minY,r.width,r.height] }
    private func viewport(_ web: WKWebView) -> [String: Any] {
        ["bounds": values(web.bounds), "safeArea": [web.safeAreaInsets.top,web.safeAreaInsets.right,web.safeAreaInsets.bottom,web.safeAreaInsets.left],
         "contentInset": [web.scrollView.contentInset.top,web.scrollView.contentInset.right,web.scrollView.contentInset.bottom,web.scrollView.contentInset.left],
         "adjustedContentInset": [web.scrollView.adjustedContentInset.top,web.scrollView.adjustedContentInset.right,web.scrollView.adjustedContentInset.bottom,web.scrollView.adjustedContentInset.left],
         "contentOffset": [web.scrollView.contentOffset.x,web.scrollView.contentOffset.y]]
    }
    private func metadata(_ c: CGContext) -> [String: Any] {
        ["width": c.width,"height": c.height,"bitsPerComponent": c.bitsPerComponent,"bitsPerPixel": c.bitsPerPixel,
         "bytesPerRow": c.bytesPerRow,"bitmapInfo": c.bitmapInfo.rawValue,"alphaInfo": c.alphaInfo.rawValue,
         "colorSpace": c.colorSpace?.name as String? ?? "nil","dataAvailable": c.data != nil,
         "CTM": [c.ctm.a,c.ctm.b,c.ctm.c,c.ctm.d,c.ctm.tx,c.ctm.ty]]
    }
    private func pixels(_ image: CGImage) throws -> Pixels {
        let context = try #require(CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue))
        let pointer = try #require(context.data)
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return .init(width: image.width, height: image.height, bytes: Data(bytes: pointer, count: image.width * image.height * 4))
    }
    private func save(_ image: CGImage, prefix: String, output: URL) throws -> Pixels {
        guard let png = UIImage(cgImage: image).pngData() else { throw Failure.invalidPixels }
        try png.write(to: output.appendingPathComponent(prefix + ".png"))
        let p = try pixels(image); try p.bytes.write(to: output.appendingPathComponent(prefix + ".rgba")); return p
    }
    private func compare(_ a: Pixels, _ b: Pixels) -> [String: Any] {
        guard a.width == b.width && a.height == b.height && a.bytes.count == b.bytes.count else {
            return ["exactRGBA": false,"webSize": [a.width,a.height],"nativeSize": [b.width,b.height]]
        }
        var count = 0, maxDelta = 0, bytes = 0
        a.bytes.withUnsafeBytes { lhs in b.bytes.withUnsafeBytes { rhs in
            let left = lhs.bindMemory(to: UInt8.self), right = rhs.bindMemory(to: UInt8.self)
            for offset in stride(from: 0, to: a.bytes.count, by: 4) {
                var differs = false
                for channel in 0..<4 {
                    let d = abs(Int(left[offset+channel])-Int(right[offset+channel])); maxDelta = max(maxDelta,d)
                    if d != 0 { differs = true; bytes += 1 }
                }
                if differs { count += 1 }
            }
        } }
        return ["exactRGBA": count == 0,"changedPixels": count,"changedBytes": bytes,"maxChannelDelta": maxDelta,
                "width": a.width,"height": a.height,"webRGBAHash": hash(a.bytes),"nativeRGBAHash": hash(b.bytes)]
    }
    private func hash(_ d: Data) -> String { SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined() }
    private func writeJSON(_ object: Any, to url: URL) throws {
        try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted,.sortedKeys]).write(to: url, options: .atomic)
    }
    private static let inputs = #"""
    [
      {"name":"positive-offset","originalOwner":[10.578125,10.53125,60.296875,70.484375],"finalOwner":[10.578125,10.53125,60.296875,70.484375],"base":[237,232,215],"layers":[{"position":[3.12,4.45],"size":[20.18,18.33],"color":[220,30,40]}]},
      {"name":"negative-clipped-offset","originalOwner":[200.125,10.125,60.1875,70.1875],"finalOwner":[200.125,10.125,60.1875,70.1875],"base":[237,232,215],"layers":[{"position":[-3,-4],"size":[30,24],"color":[30,40,220]}]},
      {"name":"owner-move","originalOwner":[10.25,10.375,70.5,70.5],"finalOwner":[150.25,30.375,70.5,70.5],"base":[237,232,215],"layers":[{"position":[5.12,10.32],"size":[20.75,30.5],"color":[220,30,40]}]},
      {"name":"overlapping-layer-order","originalOwner":[100.25,70.375,70.5,70.5],"finalOwner":[100.25,70.375,70.5,70.5],"base":[237,232,215],"layers":[{"position":[5.12,10.32],"size":[20.75,30.5],"color":[220,30,40]},{"position":[15.12,20.32],"size":[20.75,30.5],"color":[30,40,220]}]}
    ]
    """#
    private static let script = #"""
    document.body.replaceChildren();document.documentElement.style.background='rgb(41,65,87)';document.body.style.background='rgb(41,65,87)';
    const input=JSON.parse(inputJSON),panel=document.createElement('div');
    const cssRGB=c=>'rgb('+c.join(',')+')';
    Object.assign(panel.style,{position:'absolute',left:input.originalOwner[0]+'px',top:input.originalOwner[1]+'px',
      width:input.originalOwner[2]+'px',height:input.originalOwner[3]+'px',borderRadius:'0px',border:'0',padding:'0',
      backgroundColor:cssRGB(input.base),backgroundImage:input.layers.map(l=>'linear-gradient('+cssRGB(l.color)+','+cssRGB(l.color)+')').join(','),
      backgroundPosition:input.layers.map(l=>l.position.map(v=>v+'px').join(' ')).join(','),
      backgroundSize:input.layers.map(l=>l.size.map(v=>v+'px').join(' ')).join(','),backgroundRepeat:'no-repeat'});
    document.body.appendChild(panel);const rect=r=>[r.x,r.y,r.width,r.height];
    const usedOriginalOwner=rect(panel.getBoundingClientRect()),before=getComputedStyle(panel),declaredBeforeMove={
      image:panel.style.backgroundImage,position:panel.style.backgroundPosition,size:panel.style.backgroundSize,repeat:panel.style.backgroundRepeat};
    panel.style.left=input.finalOwner[0]+'px';panel.style.top=input.finalOwner[1]+'px';
    panel.style.width=input.finalOwner[2]+'px';panel.style.height=input.finalOwner[3]+'px';
    await new Promise(resolve=>requestAnimationFrame(()=>requestAnimationFrame(resolve)));
    const style=getComputedStyle(panel);
    return JSON.stringify({sourceInputJSON:inputJSON,usedOriginalOwner,usedFinalOwner:rect(panel.getBoundingClientRect()),
      declaredBeforeMove,declaredAfterMove:{image:panel.style.backgroundImage,position:panel.style.backgroundPosition,size:panel.style.backgroundSize,repeat:panel.style.backgroundRepeat},
      backgroundImage:style.backgroundImage,backgroundPosition:style.backgroundPosition,backgroundSize:style.backgroundSize,
      backgroundRepeat:style.backgroundRepeat,backgroundColor:style.backgroundColor,borderRadius:style.borderRadius,
      devicePixelRatio,innerWidth,innerHeight,scrollX,scrollY,
      visualViewport:visualViewport&&{width:visualViewport.width,height:visualViewport.height,scale:visualViewport.scale}});
    """#
}
@MainActor private final class ForeignBackgroundNavigationWaiter: NSObject, WKNavigationDelegate {
    private var continuation: CheckedContinuation<Void, Error>?
    func load(in view: WKWebView) async throws {
        view.navigationDelegate = self
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            view.loadHTMLString("<html><head><meta name='viewport' content='width=device-width,initial-scale=1'>" +
                "<style>html,body{margin:0;background:rgb(41,65,87)}</style></head><body></body></html>", baseURL: nil)
        }
    }
    func webView(_ web: WKWebView, didFinish navigation: WKNavigation!) { continuation?.resume(); continuation = nil }
    func webView(_ web: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { continuation?.resume(throwing: error); continuation = nil }
    func webView(_ web: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { continuation?.resume(throwing: error); continuation = nil }
}
