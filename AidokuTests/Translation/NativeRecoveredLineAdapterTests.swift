import CoreGraphics
import Foundation
import Testing
@testable import Aidoku

@Suite struct NativeRecoveredLineAdapterTests {
    @Test func droppedRecoveredNodeSuppressesVectorSourceLayersAndRetainsRasterIdentity() throws {
        let frame = CGRect(x: 0,y: 0,width: 100,height: 100)
        func card(_ id: String, recovered: Bool) throws -> NativeTranslationRenderer.Card {
            let descriptor: [String: Any] = ["id": id,"text": "검증","x": 40,"y": 40,"width": 20,"height": 20,
                "fontSize": 12,"lineHeight": 14,"fontScript": "korean","wrappingScript": "korean",
                "sourceFrame": [0,0,100,100],"sourceBounds": [0.4,0.4,0.2,0.2],"recoveredLine": recovered]
            let item = try JSONDecoder().decode(NativeTranslationLayoutItem.self,from: JSONSerialization.data(withJSONObject: descriptor))
            let style = NativeTranslationTypography.Style(fontScript: "korean",fontSize: 12,lineHeight: 14)
            var card = NativeTranslationRenderer.Card(item: item,
                typography: NativeTranslationTypography.layout(text: item.text,in: item.contentRect.size,style: style),style: style,
                drawsPanel: true,background: CGColor(gray: 1,alpha: 1),usesFallbackVeil: false,
                lightSurface: true,heavyStrokeWidth: 0,finalFontSize: 12)
            card.sourcePanels = [.init(rect: frame,background: [255,255,255],coverage: [frame])]
            return card
        }
        let recovered = try card("recovered",recovered: true), normal = try card("normal",recovered: false)
        var cards = [recovered,normal]
        let context = try #require(CGContext(data: nil,width: 100,height: 100,bitsPerComponent: 8,bytesPerRow: 400,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: 0,alpha: 1));context.fill(frame)
        let layout = NativeTranslationLayout(imageSize: frame.size,sourceRect: frame,viewport: frame.size,items: cards.map(\.item))
        var settings = ReaderTranslationSettings.defaultOverlay
        settings.opacity = 1
        var gloss = NativeTranslationEffectGloss.Refinement()
        let result = try NativeTranslationRenderer.recoverLines(cards: &cards,gloss: &gloss,layout: layout,
            source: try #require(context.makeImage()),settings: settings)
        #expect(result.droppedIDs == [recovered.item.id])
        #expect(cards[0].sourceLayersSuppressed)
        #expect(cards[0].sourcePanels.isEmpty && cards[0].backings.isEmpty && !cards[0].drawsPanel)
        #expect(gloss.hiddenIDs == [recovered.item.id])
        // Raster repair identity survives; only the removed vector planes vanish.
        #expect(gloss.removedLayerIDs.isEmpty)
        #expect(!cards[1].sourceLayersSuppressed)
        #expect(cards[1].sourcePanels[0].rect == normal.sourcePanels[0].rect)
    }
    @Test func cleanupOffsetMapsRecoveredPlateToActualSourcePixels() throws {
        let oldFrame = CGRect(x:0,y:0,width:100,height:100)
        let cleanup = CGRect(x:100,y:0,width:100,height:100)
        let descriptor:[String:Any] = ["id":"cleanup-recovered","text":"검증","x":140,"y":40,"width":20,"height":20,
            "fontSize":12,"lineHeight":14,"sourceFrame":[0,0,100,100],"sourceBounds":[0.4,0.4,0.2,0.2],"recoveredLine":true]
        let item = try JSONDecoder().decode(NativeTranslationLayoutItem.self,from:JSONSerialization.data(withJSONObject:descriptor))
        let style = NativeTranslationTypography.Style(fontSize:12,lineHeight:14)
        var card = NativeTranslationRenderer.Card(item:item,
            typography:NativeTranslationTypography.layout(text:item.text,in:item.contentRect.size,style:style),style:style,
            drawsPanel:true,background:CGColor(gray:1,alpha:1),usesFallbackVeil:false,
            lightSurface:true,heavyStrokeWidth:0,finalFontSize:12)
        card.cleanupSourceFrame = cleanup
        card.sourcePanels = [.init(rect:cleanup,background:[255,255,255],coverage:[cleanup])]
        let context = try #require(CGContext(data:nil,width:100,height:100,bitsPerComponent:8,bytesPerRow:400,
            space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray:0,alpha:1)); context.fill(oldFrame)
        let layout = NativeTranslationLayout(imageSize:oldFrame.size,sourceRect:oldFrame,
            viewport:CGSize(width:200,height:100),items:[item])
        var settings = ReaderTranslationSettings.defaultOverlay; settings.opacity = 1
        var cards = [card], gloss = NativeTranslationEffectGloss.Refinement()
        let result = try NativeTranslationRenderer.recoverLines(cards:&cards,gloss:&gloss,layout:layout,
            source:try #require(context.makeImage()),settings:settings)
        #expect(result.droppedIDs == [item.id])
        #expect(result.shares.first(where: { $0.id == item.id })?.value.map { $0 > 0.02 } == true)
        #expect(cards[0].sourceLayersSuppressed && cards[0].sourcePanels.isEmpty)
        #expect(cards[0].item.sourceFrame == item.sourceFrame && cards[0].item.sourceBounds == item.sourceBounds)
    }

}
