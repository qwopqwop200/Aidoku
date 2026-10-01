import Compression
import CoreGraphics
import Foundation
import Testing
@testable import Aidoku

private final class NativeGlyphCoverFixtureBundle: NSObject {}

@Suite(.serialized)
struct NativeGlyphCoverTests {
    private enum Failure: Error { case fixture }
    private func fixtures() throws -> [[String: Any]] {
        let bundle = Bundle(for: NativeGlyphCoverFixtureBundle.self)
        let name = "native-glyph-cover-fixtures.json.deflate"
        let direct = bundle.url(forResource: "native-glyph-cover-fixtures.json", withExtension: "deflate")
        let nested = bundle.resourceURL.flatMap { FileManager.default.enumerator(at: $0, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL }.first { $0.lastPathComponent == name } }
        let url = try #require(direct ?? nested)
        let bytes = try Data(contentsOf: url)
        guard bytes.count > 8 else { throw Failure.fixture }
        let size = bytes.prefix(8).enumerated().reduce(UInt64(0)) { $0 | UInt64($1.element) << ($1.offset * 8) }
        guard size > 0 && size < 32 * 1_024 * 1_024 else { throw Failure.fixture }
        let decodedSize = Int(size)
        var decoded = [UInt8](repeating: 0, count: decodedSize)
        let count = decoded.withUnsafeMutableBytes { target in bytes.withUnsafeBytes { source in
            compression_decode_buffer(target.bindMemory(to: UInt8.self).baseAddress!, decodedSize,
                source.bindMemory(to: UInt8.self).baseAddress!.advanced(by: 8), bytes.count-8, nil, COMPRESSION_ZLIB)
        } }
        guard count == decoded.count, let manifest = try JSONSerialization.jsonObject(with: Data(decoded)) as? [String: Any],
              manifest["version"] as? Int == 1, let cases = manifest["cases"] as? [[String: Any]], cases.count == 20 else { throw Failure.fixture }
        return cases
    }
    private func numbers(_ value: Any?) -> [Double] { (value as? [NSNumber])?.map(\.doubleValue) ?? [] }
    private func rect(_ v: [Double]) -> CGRect { CGRect(x: v[0], y: v[1], width: v[2], height: v[3]) }
    private func entry(_ f: [String: Any]) throws -> NativeGlyphCover.Entry {
        let p = try #require(f["plate"] as? [String: Any]), size = numbers(p["size"]), origin = numbers(p["origin"])
        var plate = NativeGlyphCover.Plate(rect: rect(numbers(p["rect"])), size: CGSize(width: size[0], height: size[1]),
            origin: CGPoint(x: origin[0], y: origin[1]), transformOrigin: .zero, backgroundRGBA: [200, 180, 150], nodeIsChild: true, ownedNodeCount: 1)
        if let matrix = f["matrix"] as? [String: Double] { plate.transform = .init(a: matrix["a"]!, b: matrix["b"]!, c: matrix["c"]!, d: matrix["d"]!) }
        if let style = f["style"] as? [String: String] { plate.hasShadow = style["boxShadow"] != nil }
        if let coverage = f["coverage"] as? [[NSNumber]] { plate.clipped = true; plate.coverage = coverage.map { $0.map(\.doubleValue) } }
        plate.frameLines = f["frameLines"] as? Bool ?? false
        return .init(id: "one", text: f["text"] as? String ?? "ABC", mode: f["mode"] as? String ?? "readability-panel",
            record: f["record"] as? [String: Any], sampledInk: numbers(f["sampled"]), displayGroup: f["displayGroup"] as? Bool ?? false,
            sourceBounds: numbers(f["bounds"]), sourceFrame: numbers(f["frame"]), sourceFontSize: f["glyph"] as? Double,
            fontSize: 20, plate: plate)
    }
    private func json(_ value: Any) throws -> Data { try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) }

    @Test func allFrozenArtworkCoversMatchEveryMaskAndPaintByte() throws {
        let cases = try fixtures()
        var accepted = 0, curves = 0
        for c in cases {
            let f = try #require(c["input"] as? [String: Any]), expected = try #require(c["expected"] as? [String: Any])
            let width = try #require(f["width"] as? Int), height = try #require(f["height"] as? Int)
            let raw = try #require(f["rgba"] as? [NSNumber]).map(\.uint8Value)
            let scene = NativeGlyphCover.Scene(opacity: f["opacity"] as? Double ?? 1, imageSize: CGSize(width: width, height: height), itemCount: 1)
            let budget = NativeGlyphCover.Budget()
            let result = try NativeGlyphCover.attempt(entry: entry(f), scene: scene, budget: budget) { crop, w, h in
                var bytes = [UInt8](repeating: 0, count: w*h*4)
                for y in 0..<h { for x in 0..<w {
                    let sx = Int(crop.minX) + Int(floor((Double(x)+0.5)*Double(crop.width)/Double(w)))
                    let sy = Int(crop.minY) + Int(floor((Double(y)+0.5)*Double(crop.height)/Double(h)))
                    for ch in 0..<4 { bytes[(y*w+x)*4+ch] = raw[(sy*width+sx)*4+ch] }
                } }; return bytes
            }
            let payload: Any
            if let r = result.result {
                accepted += 1; if r.metadata["fit"] as? String == "curve" { curves += 1 }
                payload = ["width": r.width, "height": r.height, "rgba": r.rgba, "cover": r.cover, "letters": r.letters, "art": r.art,
                    "sourceCrop": [r.sourceCrop.minX, r.sourceCrop.minY, r.sourceCrop.width, r.sourceCrop.height],
                    "metadata": r.metadata, "foreground": r.foreground, "outline": r.outline, "outlineWidth": r.outlineWidth] as [String: Any]
            } else { payload = NSNull() }
            let actual: [String: Any] = ["id": f["id"]!, "result": payload, "rejection": result.rejection as Any? ?? NSNull(),
                "budget": ["pixels": budget.pixels, "analysed": budget.analysed, "covers": budget.covers], "error": NSNull()]
            #expect(try json(actual) == json(expected), Comment(rawValue: f["id"] as? String ?? "fixture"))
        }
        #expect(accepted == 9 && curves == 3)
    }

    private func adapterFixture(_ name: String) throws -> ([String: Any], [String: Any], NativeTranslationLayout, NativeTranslationRenderer.Card, CGImage) {
        let c = try #require(try fixtures().first { ($0["input"] as? [String: Any])?["id"] as? String == name })
        let f = try #require(c["input"] as? [String: Any]), expected = try #require(c["expected"] as? [String: Any])
        let width = try #require(f["width"] as? Int), height = try #require(f["height"] as? Int)
        let itemJSON: [String: Any] = ["id": "one", "text": "ABC", "sourceBounds": f["bounds"]!, "sourceFrame": f["frame"]!,
            "sourceFontSize": 40, "x": 56, "y": 40, "width": 88, "height": 60, "fontSize": 20, "lineHeight": 24,
            "sourceColorEligible": true, "clipsText": true]
        let item = try JSONDecoder().decode(NativeTranslationLayoutItem.self, from: json(itemJSON))
        let layout = NativeTranslationLayout(imageSize: CGSize(width: width, height: height), sourceRect: CGRect(x: 0, y: 0, width: width, height: height),
            viewport: CGSize(width: width, height: height), items: [item])
        let style = NativeTranslationTypography.Style(fontScript: "", fontSize: 20, foreground: NativeTranslationRenderer.color([20, 20, 20]), lineHeight: 24)
        let typography = NativeTranslationTypography.layout(text: "ABC", in: item.contentRect.size, style: style)
        let panel = NativeTranslationSourceStylePostPolish.Panel(rect: item.rect, background: [200, 180, 150], coverage: [item.rect])
        let card = NativeTranslationRenderer.Card(item: item, typography: typography, style: style, clusterRGB: [21, 21, 21],
            outlinedRecord: f["record"] as? [String: Any], sourcePanels: [panel], drawsPanel: false,
            background: NativeTranslationRenderer.color([200, 180, 150]), usesFallbackVeil: false, lightSurface: true, heavyStrokeWidth: 0, finalFontSize: 20)
        var pixels = NativeRestorationPixels(width: width, height: height)
        pixels.rgba = try #require(f["rgba"] as? [NSNumber]).map(\.uint8Value)
        return (f, expected, layout, card, try #require(pixels.image()))
    }
    private func settings() -> IPhoneOverlaySettings {
        var s = IPhoneOverlaySettings(visible: true, mode: .translateOnly, colorMode: .white, opacity: 1,
            textPlacement: .replace, subtitlePosition: .bottom, subtitleMaxLines: 3, subtitleContextSentences: 0)
        s.preserveSourceColors = true
        return s
    }
    @Test func actualRendererAdapterCommitsArtworkWithoutClaimingErasureProof() throws {
        let (_, expected, layout, card, image) = try adapterFixture("smooth-gradient")
        var cards = [card], restoration = NativeTranslationRestoration.Result()
        restoration.appearances["one"] = .init(foreground: card.style.foreground, background: card.background, restored: false,
            sourceSample: ["foreground": [20.0, 20, 20]])
        NativeTranslationRenderer.applyGlyphCover(cards: &cards, restoration: &restoration, layout: layout, source: image, settings: settings(), gloss: .init())
        let target = try #require(expected["result"] as? [String: Any]), patch = try #require(restoration.patches.first)
        let paint = try #require(target["rgba"] as? [NSNumber]).map(\.uint8Value)
        let patchData = try #require(patch.image.dataProvider?.data) as Data
        #expect(restoration.patches.count == 1 && patchData == Data(paint))
        #expect(patch.layoutSafe == nil && patch.candidate == nil && !patch.finalForcedErasure)
        #expect(cards[0].glyphCoverPatch?.image === patch.image && cards[0].glyphCoverPatch?.rect == patch.rect)
        #expect(restoration.appearances["one"]?.erasureComplete == false)
        #expect(cards[0].sourcePanels.isEmpty && cards[0].clusterRGB == nil && cards[0].strokePreserved)
        let retainedOwner = try #require(cards[0].glyphCoverOwnerPanel)
        #expect(retainedOwner.rect == card.sourcePanels[0].rect && retainedOwner.coverage == card.sourcePanels[0].coverage)
        #expect(!retainedOwner.sourceErasure && retainedOwner.sourceFrameImage == nil)
        // Frozen late force selects extant readability owners even after their
        // background becomes transparent; artwork repair is not certification.
        #expect(NativeTranslationRenderer.readabilityOwnerPanel(cards[0])?.rect == retainedOwner.rect)
        #expect(cards[0].sourceBackgroundKind == card.sourceBackgroundKind && cards[0].sourceStrokeKind == "preserved")
        #expect(!cards[0].glyphPlateReleased && cards[0].item.clipsText)
        #expect(cards[0].item.rect == card.item.rect && cards[0].style.fontSize == card.style.fontSize)
        #expect(try json(try #require(cards[0].glyphCoverRecord)) == json(try #require(target["metadata"])))
        #expect(cards[0].style.outlineWidth == (target["outlineWidth"] as? Double).map { CGFloat($0) })
    }
    @Test func actualOwnerSelectionUsesConnectedParentAndUniqueDetachedPlate() throws {
        let (_, _, layout, initial, image) = try adapterFixture("smooth-gradient")
        for isChild in [false, true] {
            var card = initial
            card.captionParentPlate = isChild
            var cards = [card], restoration = NativeTranslationRestoration.Result()
            NativeTranslationRenderer.applyGlyphCover(cards: &cards, restoration: &restoration,
                layout: layout, source: image, settings: settings(), gloss: .init())
            #expect(restoration.patches.count == 1 && cards[0].glyphCoverRecord != nil)
            #expect(cards[0].captionParentPlate == isChild)
            #expect(cards[0].glyphCoverOwnerPanel?.rect == initial.sourcePanels[0].rect)
        }
        var ambiguous = initial
        ambiguous.sourcePanels.append(initial.sourcePanels[0])
        var cards = [ambiguous], restoration = NativeTranslationRestoration.Result()
        NativeTranslationRenderer.applyGlyphCover(cards: &cards, restoration: &restoration,
            layout: layout, source: image, settings: settings(), gloss: .init())
        #expect(restoration.patches.isEmpty && cards[0].glyphCoverReject == "owner")
        #expect(cards[0].sourcePanels.count == 2 && cards[0].glyphCoverOwnerPanel == nil)
        #expect(cards[0].style.foreground == initial.style.foreground)
        // A real caption parent remains authoritative despite another detached
        // region plate. Foreign children on that parent still veto the repair.
        ambiguous.captionParentPlate = true
        cards = [ambiguous]
        NativeTranslationRenderer.applyGlyphCover(cards: &cards, restoration: &restoration,
            layout: layout, source: image, settings: settings(), gloss: .init())
        #expect(restoration.patches.count == 1 && cards[0].sourcePanels.count == 1)
        ambiguous.sourcePanels[1].hasForeignChildren = true
        cards = [ambiguous]; restoration = .init()
        NativeTranslationRenderer.applyGlyphCover(cards: &cards, restoration: &restoration,
            layout: layout, source: image, settings: settings(), gloss: .init())
        #expect(restoration.patches.isEmpty && cards[0].glyphCoverReject == "shared")
    }

    @Test func actualRendererAdapterRetainsOpaqueOwnerWhenSourceTextureRefusesRepair() throws {
        let (_, _, layout, card, image) = try adapterFixture("texture-veto")
        var cards = [card], restoration = NativeTranslationRestoration.Result()
        NativeTranslationRenderer.applyGlyphCover(cards: &cards, restoration: &restoration, layout: layout, source: image, settings: settings(), gloss: .init())
        #expect(restoration.patches.isEmpty && cards[0].glyphCoverRecord == nil && cards[0].glyphCoverReject == "texture")
        #expect(cards[0].glyphCoverOwnerPanel == nil)
        #expect(cards[0].sourcePanels.count == 1 && cards[0].sourcePanels[0].rect == card.sourcePanels[0].rect)
        #expect(cards[0].style.foreground == card.style.foreground && cards[0].style.outlineWidth == card.style.outlineWidth)
    }
}
