import Compression
import CoreGraphics
import Foundation
import Testing
@testable import Aidoku

private final class NativeLatePlateTrimFixtureBundle: NSObject {}

@Suite(.serialized)
struct NativeLatePlateTrimTests {
    private enum Failure: Error { case fixture }
    private func fixtures() throws -> [[String: Any]] {
        let bundle = Bundle(for: NativeLatePlateTrimFixtureBundle.self)
        let name = "native-late-plate-trim-fixtures.json.deflate"
        let direct = bundle.url(forResource: "native-late-plate-trim-fixtures.json", withExtension: "deflate")
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
              manifest["version"] as? Int == 1, let cases = manifest["cases"] as? [[String: Any]], cases.count == 40 else { throw Failure.fixture }
        return cases
    }
    private func ds(_ any:Any?) -> [Double] { (any as? [NSNumber])?.map(\.doubleValue) ?? [] }
    private func rect(_ any:Any?) -> CGRect { let a=ds(any);return .init(x:a[0],y:a[1],width:a[2],height:a[3]) }
    private func ar(_ r:CGRect)->[Double] { [Double(r.minX),Double(r.minY),Double(r.width),Double(r.height)] }
    private func num(_ any:Any?,_ fallback:Double)->Double { (any as? NSNumber)?.doubleValue ?? fallback }
    private func flag(_ any:Any?,_ fallback:Bool=false)->Bool { any as? Bool ?? fallback }

    @Test func completeFrozenPlateTrimPreservesSourceFringeAndRollback() throws {
        let cases = try fixtures()
        var accepted = 0
        for c in cases {
            let f = try #require(c["input"] as? [String:Any])
            let expected = try #require(c["expected"] as? [String:Any])
 let flags=f["flags"] as! [String:Any],validation=f["validation"] as! [String:Any],rgba=(f["rgba"] as! [NSNumber]).map(\.uint8Value),width=Int(num(f["width"],0)),height=Int(num(f["height"],0))
 let source=NativeLatePlateTrim.Source(id:"one",bounds:ds(f["bounds"]),auxiliary:(f["auxiliary"] as? [[NSNumber]])?.map { $0.map(\.doubleValue) } ?? [],font:(f["sourceFont"] as? NSNumber)?.doubleValue,vertical:flag(f["vertical"]),rotation:num(f["rotation"],0))
 let caption=NativeLatePlateTrim.Caption(ink:rect(f["ink"]),font:num(f["font"],16),visible:!flag(flags["hidden"]),transformed:flag(flags["captionTransformed"]),displayCardGrowth:flag(flags["displayCardGrowth"]),sampledForeground:f["foreground"] is NSNull ? nil:ds(f["foreground"]),sampledStroke:nil,outlined:f["outlined"] as? [String:Any],sample:f["sample"] as? [String:Any] ?? [:])
 let coverage=(f["coverage"] as? [[NSNumber]])?.map { rect($0) }
 let plate=NativeLatePlateTrim.Plate(rect:rect(f["plate"]),coverage:coverage,background:ds(f["plateRGB"]),sourceErasure:flag(flags["sourceErasure"]),sourcePreservedCaption:flag(flags["sourcePreservedCaption"]),transformed:flag(flags["transformed"]),visible:!flag(flags["hidden"]),hasBackgroundImage:flag(flags["hasBackgroundImage"]),hasBacking:flag(flags["hasBacking"]),otherChildren:flag(flags["otherChildren"]),clipped:flag(flags["clippedWithoutCoverage"]))
 let scene=NativeLatePlateTrim.Scene(opacity:num(f["opacity"],1),itemCount:1+(f["others"] as! [Any]).count,frame:rect(f["frame"]),imageSize:.init(width:width,height:height),imageComplete:flag(f["imageComplete"],true))
 let others=(f["others"] as! [[String:Any]]).map { NativeLatePlateTrim.Source(id:$0["id"] as! String,bounds:ds($0["bounds"]),auxiliary:[],font:($0["font"] as? NSNumber)?.doubleValue,vertical:flag($0["vertical"])) }
 let budget=NativeLatePlateTrim.Budget();budget.samples=Int(num(f["budget"],1_048_576));var calls:[[Int]]=[]
 let result=NativeLatePlateTrim.trim(source:source,caption:caption,plate:plate,scene:scene,budget:budget,otherSources:others,otherCaptionInks:(f["otherInks"] as! [Any]).map(rect),restoration:f["restoration"].map(rect),readSource:{ crop,w,h in
  let x=Int(crop.minX),y=Int(crop.minY);calls.append([x,y,w,h]);if flag(f["throwRead"]) { throw NSError(domain:"read",code:1) }
  var out=[UInt8](repeating:0,count:w*h*4);for yy in 0..<h { for xx in 0..<w { for c in 0..<4 { out[(yy*w+xx)*4+c]=rgba[((y+yy)*width+x+xx)*4+c] } } };return out
 },validate:{ p in
  let d=num(validation["shift"],0);return .init(ink:caption.ink.offsetBy(dx:d,dy:d),fits:flag(validation["fits"],true),clipSupported:!p.clipped || flag(validation["clipSupported"],true))
 })
 let r:Any=result.map { ["rect":ar($0.rect),"coverage":$0.coverage.map { $0.map(ar) } as Any? ?? NSNull(),"clipped":$0.clipped,"areas":[$0.oldArea,$0.newArea]] as [String:Any] } ?? NSNull()
 let actual = ["id":f["id"]!,"result":r,"budget":budget.samples,"calls":calls,"error":NSNull()] as [String:Any]
            if result != nil { accepted += 1 }
            let a = try JSONSerialization.data(withJSONObject: actual, options: [.sortedKeys])
            let e = try JSONSerialization.data(withJSONObject: expected, options: [.sortedKeys])
            #expect(a == e, Comment(rawValue: f["id"] as? String ?? "fixture"))
        }
        #expect(accepted == 24)
    }

    private func adapterFixture() throws -> (NativeTranslationLayout,NativeTranslationRenderer.Card,CGImage,IPhoneOverlaySettings) {
        let itemJSON: [String:Any] = ["id":"one","text":"ABC","sourceBounds":[0.3125,1.0/3,0.1875,25.0/120],
            "sourceFrame":[0,0,160,120],"sourceFontSize":16,"sourceColorEligible":true,
            "x":48,"y":37,"width":40,"height":26,"fontSize":16,"lineHeight":19.2]
        let item = try JSONDecoder().decode(NativeTranslationLayoutItem.self,from: JSONSerialization.data(withJSONObject:itemJSON))
        let layout = NativeTranslationLayout(imageSize:CGSize(width:160,height:120),sourceRect:CGRect(x:0,y:0,width:160,height:120),
            viewport:CGSize(width:160,height:120),items:[item])
        let style = NativeTranslationTypography.Style(fontScript:"",fontSize:16,foreground:NativeTranslationRenderer.color([20,20,20]),lineHeight:19.2)
        let typography = NativeTranslationTypography.layout(text:"ABC",in:item.contentRect.size,style:style)
        let old = CGRect(x:20,y:20,width:100,height:70)
        let panel = NativeTranslationSourceStylePostPolish.Panel(rect:old,background:[240,240,240],coverage:[old])
        let card = NativeTranslationRenderer.Card(item:item,typography:typography,style:style,sourcePanels:[panel],drawsPanel:false,
            background:NativeTranslationRenderer.color([240,240,240]),usesFallbackVeil:false,lightSurface:true,heavyStrokeWidth:0,finalFontSize:16)
        var pixels = NativeRestorationPixels(width:160,height:120)
        pixels.rgba = [UInt8](repeating:240,count:160*120*4)
        for p in stride(from:3,to:pixels.rgba.count,by:4) { pixels.rgba[p] = 255 }
        var settings = IPhoneOverlaySettings(visible:true,mode:.translateOnly,colorMode:.white,opacity:1,textPlacement:.replace,
            subtitlePosition:.bottom,subtitleMaxLines:3,subtitleContextSentences:0)
        settings.preserveSourceColors = true
        return (layout,card,try #require(pixels.image()),settings)
    }
    @Test(arguments: [0.0, 12.0], [false, true])
    func actualAdapterShrinksOnlyPanelAndRetainsEveryCaptionMetric(offset: Double, captionUnionClipped: Bool) throws {
        let (layout,initial,image,settings) = try adapterFixture()
        var card = initial
        card.item.y += offset
        for i in card.sourcePanels.indices {
            card.sourcePanels[i].rect = card.sourcePanels[i].rect.offsetBy(dx: 0, dy: offset)
            card.sourcePanels[i].coverage = card.sourcePanels[i].coverage.map { $0.offsetBy(dx: 0, dy: offset) }
            card.sourcePanels[i].captionUnionClipped = captionUnionClipped
        }
        var restoration = NativeTranslationRestoration.Result()
        restoration.cleanupGeometry = .init(frame: layout.sourceRect.offsetBy(dx: 0, dy: offset), clip: layout.sourceRect)
        #expect(card.typography.fits)
        var cards = [card]
        let beforeInk = NativeTranslationRenderer.cardInkRect(card)
        let records = NativeTranslationRenderer.applyLatePlateTrim(cards:&cards,gloss:.init(),layout:layout,
            restoration:restoration,source:image,settings:settings,milliseconds:{0},collectDiagnostics:true)
        let areas = try #require(records["one"])
        let trace = try #require(cards[0].latePlateTrimTrace.first)
        #expect(cards[0].latePlateTrimTrace.count == card.sourcePanels.count)
        #expect(trace["accepted"] as? Bool == true)
        #expect(trace["before"] as? [Double] == ar(card.sourcePanels[0].rect))
        #expect(trace["after"] as? [Double] == ar(cards[0].sourcePanels[0].rect))
        #expect(trace["area"] as? [Int] == areas)
        #expect(areas[0] == 7000 && areas[1] < areas[0])
        #expect(cards[0].sourcePanels[0].rect != card.sourcePanels[0].rect)
        #expect(card.sourcePanels[0].rect.contains(cards[0].sourcePanels[0].rect))
        #expect(cards[0].item == card.item && cards[0].textShift == card.textShift && cards[0].lineOffsets == card.lineOffsets)
        #expect(cards[0].style.fontSize == card.style.fontSize && cards[0].style.lineHeight == card.style.lineHeight)
        #expect(NativeTranslationRenderer.cardInkRect(cards[0]) == beforeInk)
        #expect(cards[0].sourcePanels[0].coverage == [cards[0].sourcePanels[0].rect])
        #expect(!cards[0].sourcePanels[0].clipped && !cards[0].glyphPlateReleased)
        #expect(cards[0].sourcePanels[0].captionUnionClipped == captionUnionClipped)
        #expect(cards[0].item.sourceFrame == initial.item.sourceFrame)
        if offset != 0 {
            var baseline = [initial]
            NativeTranslationRenderer.applyLatePlateTrim(cards:&baseline,gloss:.init(),layout:layout,
                restoration:.init(),source:image,settings:settings,milliseconds:{0})
            #expect(cards[0].sourcePanels[0].rect == baseline[0].sourcePanels[0].rect.offsetBy(dx: 0, dy: offset))
        }
    }
    @Test func actualAdapterPreservesSharedPanelAndHonorsStageDeadline() throws {
        let (layout,card,image,settings) = try adapterFixture()
        var foreign = card
        foreign.sourcePanels[0].hasForeignChildren = true
        var cards = [foreign]
        let skipped = NativeTranslationRenderer.applyLatePlateTrim(cards:&cards,gloss:.init(),layout:layout,
            restoration:.init(),source:image,settings:settings,milliseconds:{0})
        #expect(skipped.isEmpty && cards[0].sourcePanels[0].rect == card.sourcePanels[0].rect)
        cards = [card]
        var ticks = 0
        let late = NativeTranslationRenderer.applyLatePlateTrim(cards:&cards,gloss:.init(),layout:layout,
            restoration:.init(),source:image,settings:settings,milliseconds:{ ticks += 1; return ticks == 1 ? 0:61 })
        #expect(late.isEmpty && cards[0].sourcePanels[0].rect == card.sourcePanels[0].rect)
    }
    @Test(arguments: [false, true])
    func actualTrimUsesOnlyTranslatedSourceObstacles(kept: Bool) throws {
        let (layout,card,image,settings) = try adapterFixture()
        // This source box spans the complete old owner. A translated caption
        // must keep it erased; a kept original belongs to keptZones instead.
        let fields: [String: Any] = ["id":"other","text":"original","keptLettering":kept,
            "sourceBounds":[0.125,1.0/6,0.625,7.0/12],"sourceFrame":[0,0,160,120],
            "x":20,"y":20,"width":100,"height":70,"fontSize":10,"lineHeight":12]
        let other = try JSONDecoder().decode(NativeTranslationLayoutItem.self,
            from: JSONSerialization.data(withJSONObject:fields))
        let input = NativeTranslationLayout(imageSize:layout.imageSize,sourceRect:layout.sourceRect,
            viewport:layout.viewport,items:[card.item,other])
        var cards = [card]
        let records = NativeTranslationRenderer.applyLatePlateTrim(cards:&cards,gloss:.init(),layout:input,
            restoration:.init(),source:image,settings:settings,milliseconds:{0},collectDiagnostics:true)
        if kept {
            #expect(records[card.item.id] != nil)
            #expect(cards[0].sourcePanels[0].rect.width < card.sourcePanels[0].rect.width)
        } else {
            #expect(records.isEmpty && cards[0].sourcePanels[0].rect == card.sourcePanels[0].rect)
            let trace = try #require(cards[0].latePlateTrimTrace.first)
            #expect(trace["sampleBudgetBefore"] as? Int == trace["sampleBudgetAfter"] as? Int)
        }
        #expect(cards[0].item == card.item && cards[0].typography.shapedText == card.typography.shapedText)
    }

    @Test func keptOwnershipDoesNotConsumeTheTranslatedItemCountGuard() throws {
        let (layout,card,image,settings) = try adapterFixture()
        let fields: [String: Any] = ["id":"kept","text":"original","keptLettering":true,
            "sourceBounds":[0.125,1.0/6,0.625,7.0/12],"sourceFrame":[0,0,160,120],
            "x":20,"y":20,"width":100,"height":70,"fontSize":10,"lineHeight":12]
        let kept = try JSONDecoder().decode(NativeTranslationLayoutItem.self,
            from: JSONSerialization.data(withJSONObject:fields))
        let input = NativeTranslationLayout(imageSize:layout.imageSize,sourceRect:layout.sourceRect,
            viewport:layout.viewport,items:[card.item]+Array(repeating:kept,count:257))
        var cards = [card]
        let records = NativeTranslationRenderer.applyLatePlateTrim(cards:&cards,gloss:.init(),layout:input,
            restoration:.init(),source:image,settings:settings,milliseconds:{0})
        #expect(records[card.item.id] != nil)
        #expect(cards[0].sourcePanels[0].rect.width < card.sourcePanels[0].rect.width)
    }

}
