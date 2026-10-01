import Testing
import UIKit
import WebKit
import CryptoKit

/// Repeated literal rotation observations: completeness/source assertions only.
/// All captures and pairwise comparisons remain visible; no favorable oracle is selected.
@MainActor
struct NativeSourceCanvasRotationRepeatDiagnosticCapture {
    private let page = CGRect(x: 0, y: 0, width: 320, height: 160)
    private let matrix = [cos(0.035), sin(0.035), -sin(0.035), cos(0.035), 0.0, 0.0]
    private let sourceHash = "ba555c281c4574a1edf76efe4ea1d60ecf485586f1474eed5bf4a778eb913e33"
    private static let sourceRecipe: Data = {
        var bytes: [UInt8] = []
        for y in 0..<20 { for x in 0..<20 { bytes.append(contentsOf: [UInt8(23 + x * 9), UInt8(17 + y * 10), 201, 255]) } }
        return Data(bytes)
    }()
    private enum Failure: Error { case invalidSource, invalidCapture, invalidPixels }
    private struct Pixels { let width: Int; let height: Int; let bytes: Data }
    private struct Observation { let id: String; let view: Int; let round: Int; let requested: Int; let pixels: Pixels }

    func run() async throws {
        let directory = URL.documentsDirectory.appendingPathComponent("NativeSourceCanvasRotationRepeatDiagnostic", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try writeJSON(["expectedCount": 12, "count": 0, "passed": false, "pixelParityAsserted": false, "reports": []],
                      to: directory.appendingPathComponent("report.json"))
        let recipeValid = hash(Self.sourceRecipe) == sourceHash
        #expect(recipeValid)
        guard recipeValid else { throw Failure.invalidSource }
        try Self.sourceRecipe.write(to: directory.appendingPathComponent("immutable-source-recipe.rgba"))
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIViewController(); window.overrideUserInterfaceStyle = .light
        window.backgroundColor = .clear; window.frame = page; window.makeKeyAndVisible(); window.frame = page
        defer { window.isHidden = true }
        let host = try #require(window.rootViewController?.view); host.frame = page; host.backgroundColor = .clear
        var reports: [[String: Any]] = [], failures: [String] = [], observations: [Observation] = [], doms: [[String: Any]] = []
        for viewIndex in 0..<3 {
            let output = directory.appendingPathComponent("fresh-view-\(viewIndex)", isDirectory: true)
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            let web = WKWebView(frame: page)
            web.overrideUserInterfaceStyle = .light; web.isOpaque = false; web.backgroundColor = .clear
            web.underPageBackgroundColor = .clear; web.scrollView.backgroundColor = .clear
            web.scrollView.contentInsetAdjustmentBehavior = .never
            host.insertSubview(web, at: 0)
            defer { web.stopLoading(); web.removeFromSuperview() }
            do {
                let waiter = SourceCanvasRotationRepeatNavigationWaiter(); try await waiter.load(in: web)
                // Verbatim script from the strict transform helper: including the
                // source readback before parent transform and exactly two RAFs.
                let raw = try await web.callAsyncJavaScript(Self.script, arguments: ["matrix": matrix], in: nil, contentWorld: .page)
                guard let json = raw as? String, let dom = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
                      let records = dom["records"] as? [[String: Any]], records.count == 2,
                      records.compactMap({ $0["id"] as? String }) == ["positive", "negative"],
                      dom["matrix"] as? [Double] == matrix else { throw Failure.invalidSource }
                try Data(json.utf8).write(to: output.appendingPathComponent("web-dom-and-saved-masks.json"))
                doms.append(dom)
                var sourceReports: [[String: Any]] = []
                for record in records {
                    guard let id = record["id"] as? String, let text = record["png"] as? String,
                          let comma = text.firstIndex(of: ","), let png = Data(base64Encoded: String(text[text.index(after: comma)...])),
                          let image = UIImage(data: png)?.cgImage else { throw Failure.invalidSource }
                    let source = try pixels(image), expected: [Double] = id == "positive" ? [10.25,10.5,93.25,77.75] : [-10.5,-10.5,100.25,99.25]
                    let valid = source.width == 20 && source.height == 20 && source.bytes == Self.sourceRecipe &&
                        record["raw"] as? [Double] == expected && record["used"] as? [Double] == expected
                    #expect(valid)
                    guard valid else { throw Failure.invalidSource }
                    try png.write(to: output.appendingPathComponent("source-\(id).png"))
                    try source.bytes.write(to: output.appendingPathComponent("source-\(id).rgba"))
                    sourceReports.append(["id": id, "sourcePNGHash": hash(png), "sourceRGBAHash": hash(source.bytes),
                        "canonicalSourceEqual": valid, "dimensions": [source.width, source.height], "raw": expected])
                }
                try writeJSON(sourceReports, to: output.appendingPathComponent("source-provenance.json"))
                // Match the strict helper's 160-before-320 schedule. Round two
                // does not mutate DOM, recreate canvases, read source, or select
                // a timing-dependent reference; it simply repeats both requests.
                for round in 0..<2 {
                    for requested in [160, 320] {
                        let id = "view-\(viewIndex)-round-\(round)-width-\(requested)"
                        do {
                            let configuration = WKSnapshotConfiguration()
                            configuration.rect = page; configuration.snapshotWidth = NSNumber(value: requested)
                            let snapshot: UIImage = try await withCheckedThrowingContinuation { continuation in
                                web.takeSnapshot(with: configuration) { image, error in
                                    if let error { continuation.resume(throwing: error) }
                                    else if let image { continuation.resume(returning: image) }
                                    else { continuation.resume(throwing: Failure.invalidCapture) }
                                }
                            }
                            let image = try #require(snapshot.cgImage), captured = try pixels(image)
                            guard let png = snapshot.pngData() else { throw Failure.invalidCapture }
                            try png.write(to: output.appendingPathComponent(id + ".png"))
                            try captured.bytes.write(to: output.appendingPathComponent(id + ".rgba"))
                            let width = Int((CGFloat(requested) * window.screen.scale).rounded())
                            let height = Int((CGFloat(requested) / page.width * page.height * window.screen.scale).rounded())
                            let validSize = captured.width == width && captured.height == height
                            if !validSize { failures.append("\(id): unexpected capture dimensions") }
                            observations.append(.init(id: id, view: viewIndex, round: round, requested: requested, pixels: captured))
                            let report: [String: Any] = ["id": id, "freshViewIndex": viewIndex, "round": round,
                                "requestedSnapshotWidth": requested, "width": captured.width, "height": captured.height,
                                "dimensionsValid": validSize, "RGBAHash": hash(captured.bytes), "PNGHash": hash(png),
                                "UIImageScale": snapshot.scale, "UIImageOrientation": snapshot.imageOrientation.rawValue,
                                "CGImage": ["bitsPerComponent": image.bitsPerComponent, "bitsPerPixel": image.bitsPerPixel,
                                    "bytesPerRow": image.bytesPerRow, "bitmapInfo": image.bitmapInfo.rawValue,
                                    "alphaInfo": image.alphaInfo.rawValue, "colorSpace": image.colorSpace?.name as String? ?? "nil",
                                    "shouldInterpolate": image.shouldInterpolate],
                                "screenScale": window.screen.scale, "viewport": viewport(web)]
                            reports.append(report); try writeJSON(report, to: output.appendingPathComponent(id + ".json"))
                        } catch { failures.append("\(id): \(error)") }
                    }
                }
            } catch { failures.append("fresh-view-\(viewIndex): \(error)") }
        }
        var comparisons: [[String: Any]] = []
        for i in observations.indices { for j in observations.indices where j > i && observations[j].requested == observations[i].requested {
            let a = observations[i], b = observations[j]
            var result = compare(a.pixels, b.pixels)
            result["referenceID"] = a.id; result["comparedID"] = b.id
            result["sameWKView"] = a.view == b.view; result["requestedSnapshotWidth"] = a.requested
            result["scope"] = "descriptive repeat comparison; no pixel acceptance assertion"
            comparisons.append(result)
        } }
        let domData = try doms.map { try JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys]) }
        let domEqual = domData.count == 3 && domData.dropFirst().allSatisfy { $0 == domData[0] }
        #expect(domEqual)
        if !domEqual { failures.append("fresh-view source/DOM/matrix metadata differed") }
        try writeJSON(["expectedCount": 12, "count": reports.count, "passed": reports.count == 12 && failures.isEmpty,
            "pixelParityAsserted": false, "scope": "3 fresh views, 2 consecutive 160→320 capture pairs each; unchanged source/DOM/literal rotation matrix",
            "sourceCanonicalRGBAHash": sourceHash, "freshViewDOMExactlyEqual": domEqual, "matrix": matrix,
            "reports": reports, "descriptivePairwiseComparisons": comparisons, "failures": failures,
            "scopeLimit": "No native candidate, no changed strict reference, no favorable-capture selection; repeat differences do not by themselves prove nondeterminism cause"],
            to: directory.appendingPathComponent("report.json"))
        #expect(reports.count == 12)
        #expect(failures.isEmpty, Comment(rawValue: failures.joined(separator: "\n")))
    }
    private func viewport(_ view: WKWebView) -> [String: Any] {
        ["bounds": [view.bounds.minX, view.bounds.minY, view.bounds.width, view.bounds.height],
         "safeArea": [view.safeAreaInsets.top, view.safeAreaInsets.right, view.safeAreaInsets.bottom, view.safeAreaInsets.left],
         "contentInset": [view.scrollView.contentInset.top, view.scrollView.contentInset.right, view.scrollView.contentInset.bottom, view.scrollView.contentInset.left],
         "adjustedContentInset": [view.scrollView.adjustedContentInset.top, view.scrollView.adjustedContentInset.right, view.scrollView.adjustedContentInset.bottom, view.scrollView.adjustedContentInset.left],
         "contentOffset": [view.scrollView.contentOffset.x, view.scrollView.contentOffset.y]]
    }
    private func pixels(_ image: CGImage) throws -> Pixels {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                  space: space, bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = context.data else { throw Failure.invalidPixels }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return .init(width: image.width, height: image.height, bytes: Data(bytes: data, count: image.width * image.height * 4))
    }
    private func compare(_ a: Pixels, _ b: Pixels) -> [String: Any] {
        guard a.width == b.width && a.height == b.height else { return ["dimensionsEqual": false, "exactRGBA": false] }
        var changed = 0, maximum = 0
        a.bytes.withUnsafeBytes { lhs in b.bytes.withUnsafeBytes { rhs in
            let x = lhs.bindMemory(to: UInt8.self), y = rhs.bindMemory(to: UInt8.self)
            for i in stride(from: 0, to: a.bytes.count, by: 4) {
                var differs = false
                for c in 0..<4 { let d = abs(Int(x[i + c]) - Int(y[i + c])); maximum = max(maximum, d); differs = differs || d != 0 }
                if differs { changed += 1 }
            }
        } }
        return ["dimensionsEqual": true, "exactRGBA": changed == 0, "changedPixels": changed, "maxChannelDelta": maximum,
                "referenceRGBAHash": hash(a.bytes), "comparedRGBAHash": hash(b.bytes)]
    }
    private func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private func writeJSON(_ value: Any, to file: URL) throws {
        try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]).write(to: file, options: .atomic)
    }
    private static let script = #"""
    document.body.replaceChildren();
    document.documentElement.style.background='rgb(41,65,87)';
    document.body.style.background='rgb(41,65,87)';
    const parent=document.createElement('div');
    Object.assign(parent.style,{position:'absolute',left:'0px',top:'0px',width:'320px',height:'160px',transformOrigin:'0px 0px',transform:'none'});
    document.body.appendChild(parent);const records=[];
    const make=(id,x,y,w,h)=>{
        const n=document.createElement('canvas');n.width=20;n.height=20;
        Object.assign(n.style,{position:'absolute',left:x+'px',top:y+'px',width:w+'px',height:h+'px'});
        const c=n.getContext('2d'),d=c.createImageData(20,20);
        for(let y=0;y<20;y++)for(let x=0;x<20;x++){
            const i=(y*20+x)*4;d.data[i]=23+x*9;d.data[i+1]=17+y*10;d.data[i+2]=201;d.data[i+3]=255;}
        c.putImageData(d,0,0);parent.appendChild(n);
        // Measure actual untransformed LayoutUnit geometry, before applying the
        // literal parent matrix. Native receives this local rect and same CTM.
        const r=n.getBoundingClientRect();records.push({id,raw:[x,y,w,h],used:[r.x,r.y,r.width,r.height],
            width:n.width,height:n.height,png:n.toDataURL('image/png')});
    };
    make('positive',10.25,10.5,93.25,77.75);make('negative',-10.5,-10.5,100.25,99.25);
    parent.style.transform='matrix('+matrix.join(',')+')';
    await new Promise(resolve=>requestAnimationFrame(()=>requestAnimationFrame(resolve)));
    for(let i=0;i<records.length;i++){
        const r=parent.children[i].getBoundingClientRect();records[i].transformedBounds=[r.x,r.y,r.width,r.height];
    }
    const p=parent.getBoundingClientRect(),style=getComputedStyle(parent);
    return JSON.stringify({records,matrix,parent:{bounds:[p.x,p.y,p.width,p.height],transform:style.transform,transformOrigin:style.transformOrigin},
        devicePixelRatio,innerWidth,innerHeight,scrollX,scrollY,
        visualViewport:visualViewport&&{width:visualViewport.width,height:visualViewport.height,scale:visualViewport.scale}});
    """#
}

@MainActor private final class SourceCanvasRotationRepeatNavigationWaiter: NSObject, WKNavigationDelegate {
    private var continuation: CheckedContinuation<Void, Error>?
    func load(in view: WKWebView) async throws {
        view.navigationDelegate = self
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            view.loadHTMLString("<html><head><meta name='viewport' content='width=device-width,initial-scale=1'>" +
                "<style>html,body{margin:0;background:transparent}</style></head><body></body></html>", baseURL: nil)
        }
    }
    func webView(_ view: WKWebView, didFinish navigation: WKNavigation!) { continuation?.resume(); continuation = nil }
    func webView(_ view: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        continuation?.resume(throwing: error); continuation = nil
    }
    func webView(_ view: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        continuation?.resume(throwing: error); continuation = nil
    }
}
