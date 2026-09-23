import Testing
import UIKit
import WebKit
@testable import Aidoku

@Suite(.serialized)
@MainActor
struct ReaderColumnLayoutTests {
    private nonisolated static var directory: URL { URL.documentsDirectory.appendingPathComponent("ColumnLayout") }

    @Test func adjacentColumnsShareTypeSizeWithoutCrossingTheImageOrEachOther() throws {
        let sources = [CGRect(x: 4, y: 20, width: 12, height: 100),
                       CGRect(x: 40, y: 21, width: 14, height: 110),
                       CGRect(x: 82, y: 20, width: 16, height: 100)]
        let variants: [BrowserOverlayDisplayVariant] = ["안녕, 잘 지냈어?", "오늘 다시 만나서 반가워.", "앗, 고마워!"].map { .plain($0, vertical: false) }
        let bounds = CGRect(x: 0, y: 0, width: 430, height: 320)
        let layouts = BrowserOverlayColumnLayout.plan(sources: sources, variants: variants,
            eligible: [true, true, true], bounds: bounds, measurementCache: .init())
        #expect(layouts.count == 3)
        let ordered = try sources.indices.map { try #require(layouts[$0]) }
        #expect(Set(ordered.map(\.maximumFontSize)).count == 1)
        #expect(ordered.allSatisfy { bounds.contains($0.rect) && $0.maximumFontSize >= 7.5 })
        #expect(!BrowserOverlayCollisionGeometry.hasOverlap(in: ordered.map(\.rect)))
        #expect(ordered[0].rect.maxX < ordered[1].rect.minX)
        #expect(ordered[1].rect.maxX < ordered[2].rect.minX)
    }

    @Test func isolatedBalloonAndDifferentRowsKeepTheirOriginalPlanner() {
        let sources = [CGRect(x: 20, y: 20, width: 20, height: 100),
                       CGRect(x: 60, y: 120, width: 20, height: 100)]
        let variants = sources.map { _ in BrowserOverlayDisplayVariant.plain("괜찮아, 고마워.", vertical: false) }
        #expect(BrowserOverlayColumnLayout.plan(sources: sources, variants: variants, eligible: [true, true],
            bounds: CGRect(x: 0, y: 0, width: 430, height: 320), measurementCache: nil).isEmpty)
        #expect(BrowserOverlayColumnLayout.plan(sources: sources, variants: variants, eligible: [false, false],
            bounds: CGRect(x: 0, y: 0, width: 430, height: 320), measurementCache: nil).isEmpty)
    }

    @Test func compactPageNeverOffersColumnsBelowTheRenderedFontFloor() {
        let sources = [CGRect(x: 4, y: 10, width: 6, height: 60),
                       CGRect(x: 30, y: 10, width: 7, height: 60)]
        let variants = sources.map { _ in BrowserOverlayDisplayVariant.plain("앗, 네!", vertical: false) }
        let layouts = BrowserOverlayColumnLayout.plan(sources: sources, variants: variants,
            eligible: [true, true], bounds: CGRect(x: 0, y: 0, width: 215, height: 160), measurementCache: nil)
        #expect(layouts.isEmpty)
    }

    @Test func aSeparateCaptionInTheGapBlocksColumnExpansion() {
        let sources = [CGRect(x: 20, y: 20, width: 15, height: 100),
                       CGRect(x: 65, y: 20, width: 15, height: 100),
                       CGRect(x: 42, y: 45, width: 17, height: 12)]
        let variants = sources.map { _ in BrowserOverlayDisplayVariant.plain("괜찮아, 고마워.", vertical: false) }
        #expect(BrowserOverlayColumnLayout.plan(sources: sources, variants: variants, eligible: [true, true, false],
            bounds: CGRect(x: 0, y: 0, width: 430, height: 320), measurementCache: nil).isEmpty)
    }

    @Test func sourceEmphasisKeepsALargerSizeInsideTheSameColumns() throws {
        let sources = [CGRect(x: 12, y: 20, width: 15, height: 130),
                       CGRect(x: 58, y: 20, width: 15, height: 130),
                       CGRect(x: 104, y: 20, width: 15, height: 130)]
        let variants = ["오늘 다시 만났네.", "정말 반가워!", "멈춰!"].map {
            BrowserOverlayDisplayVariant.plain($0, vertical: false)
        }
        let normal = BrowserOverlayColumnLayout.plan(sources: sources, variants: variants,
            eligible: [true, true, true], bounds: CGRect(x: 0, y: 0, width: 430, height: 320), measurementCache: nil)
        let styled = BrowserOverlayColumnLayout.plan(sources: sources, variants: variants,
            eligible: [true, true, true], bounds: CGRect(x: 0, y: 0, width: 430, height: 320), measurementCache: nil,
            sourceSizes: [8, 8.2, 16])
        #expect(styled.count == 3)
        for index in sources.indices { #expect(styled[index]?.rect == normal[index]?.rect) }
        #expect(try #require(styled[2]).maximumFontSize > #require(styled[0]).maximumFontSize)
    }

    // Opt-in replay of manually annotated source captures and fixed translations.
    // This measures layout/rasterization, not OCR or provider accuracy.
    @Test(.enabled(if: FileManager.default.fileExists(atPath: directory.appendingPathComponent("fixtures.json").path)))
    func capturedPages() async throws {
        let manifest = Self.directory.appendingPathComponent("fixtures.json")
        guard FileManager.default.fileExists(atPath: manifest.path) else { return }
        struct Region: Decodable {
            let bounds: [Double]; let source: String; let translation: String
            let orientation: String?
        }
        struct Fixture: Decodable { let name: String; let regions: [Region]; let expectedColumns: Int? }
        let fixtures = try JSONDecoder().decode([Fixture].self, from: Data(contentsOf: manifest))
        let label = (try? String(contentsOf: Self.directory.appendingPathComponent("label.txt"), encoding: .utf8)) ?? "current"
        let output = Self.directory.appendingPathComponent(label.trimmingCharacters(in: .whitespacesAndNewlines))
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        // Same-binary A/B replay isolates anchoring from concurrent source-color
        // and inpainting work. This switch exists only in the opt-in test harness.
        let compareArtwork = FileManager.default.fileExists(atPath:
            Self.directory.appendingPathComponent("compare-artwork.txt").path)
        let compareErasure = FileManager.default.fileExists(atPath:
            Self.directory.appendingPathComponent("compare-certified-erasure.txt").path)
        let compareCompactPanels = FileManager.default.fileExists(atPath:
            Self.directory.appendingPathComponent("compare-compact-panels.txt").path)
        let compareAnchoring = compareErasure || compareArtwork || compareCompactPanels || FileManager.default.fileExists(atPath:
            Self.directory.appendingPathComponent("compare-source-anchor.txt").path)
        let anchorGate = compareErasure ? "if (true /* separate-erasure-backing */) {" : compareArtwork
            ? "if (opacity === 1 && items.length <= 256 && appearance?.preserveSourceBackgroundColor /* artwork-first */) {"
            : compareCompactPanels ? "if (opacity === 1 && items.length <= 256 && appearance?.preserveSourceBackgroundColor) {"
            : "if (opacity === 1 && items.length <= 256) {"
        if compareAnchoring {
            #expect(BrowserPageImageOverlayRenderer.renderScript.components(separatedBy: anchorGate).count == 2)
        }
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIViewController(); window.makeKeyAndVisible()
        defer { window.isHidden = true }
        for fixture in fixtures {
            let data = try Data(contentsOf: Self.directory.appendingPathComponent(fixture.name + ".png"))
            let image = try #require(UIImage(data: data))
            let size = CGSize(width: 430, height: 430 * image.size.height / image.size.width)
            let items = fixture.regions.enumerated().map { index, r in
                BrowserOverlayItem(stableRegionID: UInt64(index), rect: CGRect(
                    x: r.bounds[0] * image.size.width, y: r.bounds[1] * image.size.height,
                    width: r.bounds[2] * image.size.width, height: r.bounds[3] * image.size.height),
                    sourceText: r.source, translatedText: r.translation, confidence: 1,
                    sourceOrientation: .init(tolerantRawValue: r.orientation ?? "vertical"))
            }
            var previousColumns: [String: [Double]]?
            for sourceColors in [true, false] {
              var beforeArtwork: [[String: Any]]?
              var beforeRestorations: [String]?
              for anchoringEnabled in compareAnchoring ? [false, true] : [true] {
                let web = WKWebView(frame: CGRect(origin: .zero, size: size))
                web.scrollView.contentInsetAdjustmentBehavior = .never
                window.rootViewController?.view.addSubview(web)
                defer { web.removeFromSuperview() }
                web.loadHTMLString("<meta name='viewport' content='width=device-width,initial-scale=1'><style>body{margin:0}img{display:block;width:100%}</style><img id='reader-source-image' src='data:image/png;base64,\(data.base64EncodedString())'>", baseURL: nil)
                for _ in 0..<500 where web.isLoading { try await Task.sleep(for: .milliseconds(20)) }
                _ = try await web.callAsyncJavaScript("await document.getElementById('reader-source-image').decode()", arguments: [:], in: nil, contentWorld: .page)
                var settings = ReaderTranslationSettings.defaultOverlay
                settings.opacity = 1; settings.preserveSourceColors = sourceColors
                let payload = BrowserPageImageOverlayRenderer.layoutPayload(items: items, imageSize: image.size,
                    sourceRect: CGRect(origin: .zero, size: size), settings: settings, targetLanguage: "ko", viewport: size)
                let start = Date()
                let script = anchoringEnabled ? BrowserPageImageOverlayRenderer.renderScript :
                    BrowserPageImageOverlayRenderer.renderScript.replacingOccurrences(of: anchorGate, with: "if (false) {")
                _ = try await web.callAsyncJavaScript(script,
                    arguments: ["revision": "1", "session": fixture.name, "items": payload,
                        "appearance": ["opacity": 1, "preserveSourceTextColor": sourceColors,
                            "preserveSourceBackgroundColor": sourceColors, "inpaintingEnabled": true,
                            "minimumReadableFontSize": 5]], in: nil, contentWorld: .page)
                let audit = try #require(try await web.evaluateJavaScript(#"""
                [...document.querySelectorAll('[data-aidoku-image-ocr-overlay="item"]')].map(n=>{
                  const s=getComputedStyle(n),r=document.createRange();r.selectNodeContents(n);const b=r.getBoundingClientRect();
                  const walker=document.createTreeWalker(n,NodeFilter.SHOW_TEXT),rows=[];
                  const panel=[...n.parentNode.querySelectorAll('[data-aidoku-image-ocr-overlay="source-readability-panel"]')]
                    .find(p=>p.dataset.aidokuRegion===n.dataset.aidokuRegion&&p.dataset.sourceErasure!=='true');
                  const plate=panel?.getBoundingClientRect();
                  while(walker.nextNode()){
                    const text=walker.currentNode;
                    for(let offset=0;offset<text.length;){
                      const char=String.fromCodePoint(text.data.codePointAt(offset)),next=offset+char.length;
                      r.setStart(text,offset);r.setEnd(text,next);offset=next;
                      if(/\s/u.test(char))continue;
                      const rects=[...r.getClientRects()].filter(q=>q.width>0&&q.height>0),box=rects.at(-1);
                      if(!box)continue;
                      let row=rows.find(row=>Math.abs(row.top-box.top)<parseFloat(s.fontSize)*.4);
                      if(!row){row={top:box.top,text:''};rows.push(row);}row.text+=char;
                    }
                  }
                  return {...n.dataset,text:n.textContent,x:parseFloat(n.style.left),y:parseFloat(n.style.top),
                    width:parseFloat(n.style.width),height:parseFloat(n.style.height),
                    font:parseFloat(s.fontSize),vertical:s.writingMode!=='horizontal-tb',
                    readabilityPlate:plate?[plate.x,plate.y,plate.width,plate.height]:null,
                    lines:rows.map(row=>row.text),color:s.color,
                    ink:[b.x,b.y,b.width,b.height],overflow:n.scrollHeight>n.clientHeight+1||n.scrollWidth>n.clientWidth+1};})
                """#) as? [[String: Any]])
                #expect(audit.count == items.count)
                if compareArtwork || compareErasure {
                    if !anchoringEnabled { beforeArtwork = audit }
                    else {
                        for node in audit {
                            let id = try #require(node["aidokuRegion"] as? String)
                            let previous = try #require(beforeArtwork?.first { $0["aidokuRegion"] as? String == id })
                            #expect(node["text"] as? String == previous["text"] as? String)
                            if node["balloonFontFit"] == nil {
                                #expect(node["lines"] as? [String] == previous["lines"] as? [String])
                            }
                            if node["balloonFontFit"] == nil && (compareErasure || node["artworkFit"] == nil) {
                                #expect(node["font"] as? Double == previous["font"] as? Double)
                            }
                            if compareErasure && node["balloonFontFit"] == nil {
                                #expect(node["ink"] as? [Double] == previous["ink"] as? [Double])
                                for key in ["x", "y", "width", "height"] {
                                    #expect(node[key] as? Double == previous[key] as? Double)
                                }
                            }
                            // A smaller panel must never be obtained by leaving
                            // the original lettering visible beneath it.
                            #expect(node["sourceArtworkPreserved"] == nil)
                        }
                    }
                }
                var columns: [String: [Double]] = [:]
                for node in audit {
                    #expect(node["overflow"] as? Bool == false)
                    let id = try #require(node["aidokuRegion"] as? String)
                    if compareErasure && anchoringEnabled && sourceColors &&
                        ((fixture.name == "preserve4-diverse2-4539" && id == "13") ||
                         (fixture.name == "preserve4-diverse-0055" && id == "18")) {
                        #expect(node["balloonFontFit"] as? String == "restored-surface")
                    }
                    if let old = node["balloonOriginalFont"] as? String {
                        let original = try #require(Double(old)), font = try #require(node["font"] as? Double)
                        #expect(font >= max(7.5, original * 0.85) && font <= original)
                        #expect(node["sourceErasureRestored"] as? String == "true")
                        #expect(node["sourceBackgroundColor"] as? String == "inpainted")
                        #expect(node["readabilityPlate"] is NSNull)
                        let contrastValue = try #require(node["sourcePanelMinimumContrast"] as? String)
                        let contrast = try #require(Double(contrastValue))
                        #expect(contrast >= 4.5)
                    }
                    if let old = node["artworkOriginalFont"] as? String {
                        let original = try #require(Double(old))
                        let final = try #require(node["font"] as? Double)
                        #expect(final >= max(8.5, original * 0.8) && final < original)
                        #expect(node["artworkSourceErasure"] as? String ==
                            (node["artworkFit"] as? String == "restored-surface" ? "restored" : "covered"))
                        if node["artworkFit"] as? String == "smaller-caption" {
                            let beforeValue = try #require(node["artworkRiskBefore"] as? String)
                            let afterValue = try #require(node["artworkRiskAfter"] as? String)
                            let before = try #require(Double(beforeValue))
                            let after = try #require(Double(afterValue))
                            #expect(after <= before * 0.65)
                        }
                    }
                    if fixture.name == "page3", id == "3" {
                        let lines = try #require(node["lines"] as? [String])
                        // Font harmonization must not trade intact Korean words
                        // for an orphan hidden beside the next word on a line.
                        #expect(!lines.contains { $0.hasPrefix("는거야") || $0.hasPrefix("야할건") })
                    }
                    if let before = node["sourceContrastBefore"] as? String,
                       let after = node["sourceContrastAfter"] as? String {
                        #expect(try #require(Double(after)) >= #require(Double(before)))
                    }
                    if let saved = node["sourcePanelCoverage"] as? String {
                        let coverage = try #require(try JSONSerialization.jsonObject(with: Data(saved.utf8)) as? [[Double]])
                        let ink = try #require(node["ink"] as? [Double])
                        #expect(coverage.contains { r in
                            ink[0] >= r[0] - 0.04 && ink[1] >= r[1] - 0.04 &&
                            ink[0] + ink[2] <= r[0] + r[2] + 0.04 && ink[1] + ink[3] <= r[1] + r[3] + 0.04
                        })
                        if sourceColors && fixture.name == "preserve4-comic-8427" && id == "1" {
                            // The bold final D is connected to other ink and
                            // survives restoration. Its old backing must stay.
                            #expect(coverage.contains { r in
                                351 >= r[0] && 351 <= r[0] + r[2] && 28 >= r[1] && 28 <= r[1] + r[3]
                            })
                        }
                    }
                    if sourceColors && ((fixture.name == "expanded-comic-3472" && id == "16") ||
                        (fixture.name == "diverse-1178" && id == "9") ||
                        (fixture.name == "expanded-diverse-3222" && id == "5")) {
                      if let plate = node["readabilityPlate"] as? [Double] {
                        let coverage: [[Double]]
                        if let saved = node["sourcePanelCoverage"] as? String {
                            coverage = try #require(try JSONSerialization.jsonObject(with: Data(saved.utf8)) as? [[Double]])
                        } else { coverage = [plate] }
                        // Slanted effects and a small ruby glyph just outside
                        // their annotated source boxes must not reappear on trim.
                        let points = fixture.name == "diverse-1178" ? [[56.0, 591.0]] :
                            fixture.name == "expanded-diverse-3222" ? [[393.65, 275.0]] :
                            [[249.0, 91.0], [249.0, 136.0]]
                        for point in points {
                            #expect(coverage.contains { r in point[0] >= r[0] && point[1] >= r[1] &&
                                point[0] <= r[0] + r[2] && point[1] <= r[1] + r[3] })
                        }
                      } else {
                        // This ruby now has a verified erasure patch instead
                        // of an opaque strip. Both readings are pixel-checked below.
                        #expect(fixture.name == "diverse-1178" && id == "9")
                        #expect(node["sourceBackgroundColor"] as? String == "inpainted")
                      }
                    }
                    let original = try #require(payload.first { $0["id"].map { String(describing: $0) } == id })
                    #expect(node["text"] as? String == original["text"] as? String)
                    if let saved = node["sourceAnchorOriginalInk"] as? String,
                       let data = saved.data(using: .utf8),
                       let prior = try JSONSerialization.jsonObject(with: data) as? [Double] {
                        let ink = try #require(node["ink"] as? [Double])
                        let bounds = try #require(original["sourceBounds"] as? [CGFloat]).map { Double($0) }
                        let frame = try #require(original["sourceFrame"] as? [CGFloat]).map { Double($0) }
                        let centerX = frame[0] + (bounds[0] + bounds[2] / 2) * frame[2]
                        let centerY = frame[1] + (bounds[1] + bounds[3] / 2) * frame[3]
                        #expect(node["balancedColumn"] as? String != "true")
                        if node["balloonFontFit"] == nil {
                            let plate = try #require(node["readabilityPlate"] as? [Double])
                            #expect(abs(ink[2] - prior[2]) < 0.04 && abs(ink[3] - prior[3]) < 0.04)
                            #expect(abs(ink[0] + ink[2] / 2 - centerX) <= abs(prior[0] + prior[2] / 2 - centerX) + 0.04)
                            #expect(abs(ink[1] + ink[3] / 2 - centerY) <= abs(prior[1] + prior[3] / 2 - centerY) + 0.04)
                            #expect(ink[0] >= plate[0] + 2.96 && ink[1] >= plate[1] + 2.96)
                            #expect(ink[0] + ink[2] <= plate[0] + plate[2] - 2.96)
                            #expect(ink[1] + ink[3] <= plate[1] + plate[3] - 2.96)
                        } else {
                            // Certified balloon fitting intentionally removes
                            // this plate and may reflow type after anchoring.
                            // Preserve the committed center, allowing font
                            // ascender/line-height rounding, not repositioning.
                            let saved = try #require(node["balloonOriginalInk"] as? String)
                            let before = try #require(try JSONSerialization.jsonObject(with: Data(saved.utf8)) as? [Double])
                            #expect(abs(ink[0] + ink[2] / 2 - before[0] - before[2] / 2) <= 1.5)
                            #expect(abs(ink[1] + ink[3] / 2 - before[1] - before[3] / 2) <= 1.5)
                        }
                    }
                    if fixture.name == "round3-diverse-0914", id == "7", sourceColors, anchoringEnabled {
                        let ink = try #require(node["ink"] as? [Double])
                        let bounds = try #require(original["sourceBounds"] as? [CGFloat]).map { Double($0) }
                        #expect(abs(ink[0] + ink[2] / 2 - (bounds[0] + bounds[2] / 2) * size.width) < 1)
                        #expect(abs(ink[1] + ink[3] / 2 - (bounds[1] + bounds[3] / 2) * size.height) < 1)
                    }
                    if node["sourcePanelCoverage"] == nil, let saved = node["typographyInkFrame"] as? String,
                       let data = saved.data(using: .utf8),
                       let frame = try JSONSerialization.jsonObject(with: data) as? [String: Double],
                       let plate = node["readabilityPlate"] as? [Double] {
                        let pad = try #require(frame["pad"])
                        // DOM origins and extents are rounded separately on
                        // WebKit's subpixel grid; their sum can differ by just
                        // over 0.03pt (0.031095pt in expanded-diverse-1344).
                        let roundingTolerance = 0.04
                        // Source ink covered before font clustering must stay
                        // covered after a smaller font or a tighter line layout.
                        #expect(plate[0] <= max(0, try #require(frame["left"]) - pad) + roundingTolerance)
                        #expect(plate[1] <= max(0, try #require(frame["top"]) - pad) + roundingTolerance)
                        #expect(plate[0] + plate[2] >= min(size.width, try #require(frame["right"]) + pad) - roundingTolerance)
                        #expect(plate[1] + plate[3] >= min(size.height, try #require(frame["bottom"]) + pad) - roundingTolerance)
                    }
                    if node["balancedColumn"] as? String == "true" {
                        let column = try #require(original["columnLayout"] as? [String: Any])
                        let geometry = try ["x", "y", "width", "height"].map { key in
                            let value = try #require(node[key] as? Double)
                            #expect(abs(value - (try #require((column[key] as? NSNumber)?.doubleValue))) < 0.02)
                            return value
                        }
                        columns[id] = geometry
                    }
                }
                if let expected = fixture.expectedColumns { #expect(columns.count == expected) }
                if let previousColumns { #expect(columns == previousColumns) }
                previousColumns = columns
                if !sourceColors && !columns.isEmpty {
                    let erased = try #require(try await web.evaluateJavaScript("""
                    document.querySelectorAll('[data-aidoku-image-ocr-overlay="source-readability-panel"][data-source-erasure="true"]').length
                    """) as? Int)
                    #expect(erased >= columns.count)
                }
                let name = fixture.name + (sourceColors ? "-source" : "-white")
                let destination = compareAnchoring ? output.appendingPathComponent(anchoringEnabled ? "after" : "before") : output
                try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
                let panels = try #require(try await web.evaluateJavaScript(#"""
                [...document.querySelectorAll('[data-aidoku-image-ocr-overlay="source-readability-panel"], [data-aidoku-image-ocr-overlay="source-readability-backing"]')].map(n=>{
                  const r=n.getBoundingClientRect();return {...n.dataset,rect:[r.x,r.y,r.width,r.height],
                    color:n.style.backgroundColor,clip:n.style.clipPath,computedClip:getComputedStyle(n).clipPath};})
                """#) as? [[String: Any]])
                let restorations = try #require(try await web.evaluateJavaScript(#"""
                [...document.querySelectorAll('canvas[data-aidoku-image-ocr-overlay="source-panel-restoration"]')].map(n=>{
                  const pixels=n.getContext('2d').getImageData(0,0,n.width,n.height).data;
                  let hash=2166136261,painted=0;
                  for(let i=0;i<pixels.length;i++){hash=Math.imul(hash^pixels[i],16777619);if(i%4===3&&pixels[i])painted++;}
                  return JSON.stringify([n.width,n.height,n.style.left,n.style.top,n.style.width,n.style.height,painted,hash>>>0]);
                })
                """#) as? [String])
                if compareArtwork || compareErasure {
                    if !anchoringEnabled { beforeRestorations = restorations }
                    else { #expect(restorations == beforeRestorations) }
                }
                var rubyAudit: [String: Int] = [:]
                if ["diverse-1178", "expanded-comic-1424"].contains(fixture.name) && sourceColors {
                    rubyAudit = try #require(try await web.evaluateJavaScript(#"""
                    (()=>{
                      const image=document.getElementById('reader-source-image'),frame=image.getBoundingClientRect();
                      let original=0,remaining=0,regions=0;
                      const regionsToCheck=image.naturalWidth===1306?
                        [[1190,205,43,119],[156,1787,20,54]]:[[653,719,18,56]];
                      for(const [x,y,w,h] of regionsToCheck){
                        const canvas=document.createElement('canvas');canvas.width=w;canvas.height=h;const ctx=canvas.getContext('2d');
                        ctx.drawImage(image,x,y,w,h,0,0,w,h);const source=ctx.getImageData(0,0,w,h).data;
                        for(const patch of document.querySelectorAll('canvas[data-aidoku-image-ocr-overlay="source-panel-restoration"]')){
                          const r=patch.getBoundingClientRect(),sx=image.naturalWidth/frame.width,sy=image.naturalHeight/frame.height;
                          ctx.drawImage(patch,(r.left-frame.left)*sx-x,(r.top-frame.top)*sy-y,r.width*sx,r.height*sy);
                        }
                        const output=ctx.getImageData(0,0,w,h).data;let found=0;
                        for(let i=0;i<source.length;i+=4)if(Math.max(source[i],source[i+1],source[i+2])<110){
                          original++;found++;if(Math.min(output[i],output[i+1],output[i+2])<230)remaining++;
                        }
                        if(found>30)regions++;
                      }
                      return {original,remaining,regions};
                    })()
                    """#) as? [String: Int])
                    #expect((rubyAudit["original"] ?? 0) > 100)
                    #expect(rubyAudit["remaining"] == 0)
                    #expect(rubyAudit["regions"] == (fixture.name == "diverse-1178" ? 2 : 1))
                }
                try JSONSerialization.data(withJSONObject: ["items": audit, "planned": payload, "panels": panels,
                    "restorations": restorations, "rubyAudit": rubyAudit,
                    "milliseconds": Date().timeIntervalSince(start) * 1000], options: [.prettyPrinted, .sortedKeys])
                    .write(to: destination.appendingPathComponent(name + ".json"))
                _ = try await web.callAsyncJavaScript("await new Promise(r=>requestAnimationFrame(()=>requestAnimationFrame(r)))", arguments: [:], in: nil, contentWorld: .page)
                let snapshot = try await withCheckedThrowingContinuation { (c: CheckedContinuation<UIImage, Error>) in
                    web.takeSnapshot(with: nil) { image, error in
                        if let image { c.resume(returning: image) }
                        else { c.resume(throwing: error ?? URLError(.cannotDecodeContentData)) }
                    }
                }
                try #require(snapshot.pngData()).write(to: destination.appendingPathComponent(name + ".png"))
              }
            }
        }
    }
}
