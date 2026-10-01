import CoreGraphics
import Foundation
import Testing
@testable import Aidoku

@Suite struct NativeCaptionPolishKeptZoneTests {
    @Test(arguments: [false, true])
    func subtractedKeptOwnershipPreventsTheCapturedLateCaptionShift(real15: Bool) throws {
        let frame = CGRect(x: 0,y: 212.30263157894737,width: 390,height: 275.39473684210526)
        let node = real15 ? CGRect(x: 317.921875,y: 236.953125,width: 35.734375,height: 54.234375)
            : CGRect(x: 276.921875,y: 358.234375,width: 46.390625,height: 57.671875)
        let owner = real15 ? node : CGRect(x: 275.5625,y: 356.03125,width: 49.125,height: 61.078125)
        let pad: CGFloat = real15 ? 3 : 2.828125
        let source: [Double] = real15 ? [0.8358395989974937,0.1002661934338953,0.05106516290726817,0.17524401064773737]
            : [0.7142857142857143,0.5328305235137534,0.1105889724310777,0.20008873114463177]
        let rawKept = real15 ? CGRect(x: 348.214285714286,y: 217.678571428571,width: 27.490601503759,height: 47.772556390977)
            : CGRect(x: 283.94736842105266,y: 341.56954887218046,width: 41.296992481203,height: 24.558270676692)
        let fields: [String: Any] = ["id":"caption", "text": real15 ? "왜... 왜 알몸으로.........윽!" : "제 미사용 애널의 용도를 써주셔서 기뻐요……",
            "x":node.minX,"y":node.minY,"width":node.width,"height":node.height,
            "paddingTop":pad,"paddingRight":pad,"paddingBottom":pad,"paddingLeft":pad,
            "fontSize":8.5,"lineHeight":10.1435546875,"fontScript":"korean","wrappingScript":"korean",
            "sourceTextOnly":false,"sourceBounds":source,"sourceFrame":[frame.minX,frame.minY,frame.width,frame.height]]
        let item = try JSONDecoder().decode(NativeTranslationLayoutItem.self,from: JSONSerialization.data(withJSONObject: fields))
        let style = NativeTranslationTypography.Style(fontScript:"korean",fontSize:8.5,tracking:-8.5*0.012,
            lineHeight:10.1435546875,horizontalWrapping:.keepAllWithEmergency)
        var card = NativeTranslationRenderer.Card(item:item,
            typography:NativeTranslationTypography.layout(text:item.text,in:item.contentRect.size,style:style),style:style,
            sourcePanels:[.init(rect:owner,background:[61,73,68],coverage:[owner],clipped:!real15,captionUnionClipped:!real15)],drawsPanel:false,
            background:CGColor(gray:1,alpha:1),usesFallbackVeil:false,lightSurface:true,heavyStrokeWidth:0,finalFontSize:8.5)
        card.captionParentPlate = real15
        card.authoredTextOrigin = node.origin
        let before = try #require(NativeTranslationRenderer.cardWholeRangeRect(card))
        #expect(abs(before.minY - (real15 ? 248.0625 : 361.0625)) < 0.000001)
        let painted = try #require(NativeKeptSourceRestoration.sourceRect(item))
        let zones = NativeKeptSourceRestoration.zones(kept:[.init(id:"kept",rect:rawKept,sourceFontSize:real15 ? 17.857142857142858 : 18.38643268121129)],painted:[painted]).map(\.rect)
        #expect(!zones.isEmpty)
        let keptFields: [String:Any] = ["id":"kept","text":"original","keptLettering":true,
            "x":rawKept.minX,"y":rawKept.minY,"width":rawKept.width,"height":rawKept.height,"fontSize":8,"lineHeight":10,
            "sourceBounds":[(rawKept.minX-frame.minX)/frame.width,(rawKept.minY-frame.minY)/frame.height,rawKept.width/frame.width,rawKept.height/frame.height],
            "sourceFrame":[frame.minX,frame.minY,frame.width,frame.height]]
        let kept = try JSONDecoder().decode(NativeTranslationLayoutItem.self,from: JSONSerialization.data(withJSONObject:keptFields))
        let layout = NativeTranslationLayout(imageSize:frame.size,sourceRect:frame,viewport:CGSize(width:390,height:700),items:[item,kept])
        let settings = IPhoneOverlaySettings(visible:true,mode:.translateOnly,colorMode:.white,opacity:1,textPlacement:.replace,
            subtitlePosition:.bottom,subtitleMaxLines:3,subtitleContextSentences:0)
        var correct = [card]
        NativeTranslationRenderer.polishCaptionPanels(cards:&correct,glossCards:[],gloss:.init(),layout:layout,settings:settings,source:nil,keptZones:zones)
        #expect(correct[0].item.rect == node)
        // A legitimate panel trim also invokes frozen detach(e), even
        // when the complete caption remains at its original position.
        if correct[0].captionParentPlate != real15 {
            #expect(real15 && !correct[0].captionParentPlate && correct[0].textZ == 3)
            #expect(correct[0].textRootOrder != nil)
        }
        // The former raw fallback reproduces the precise BUILD42 error.
        // An actual accepted move also detaches the node from its owner.
        var raw = [card]
        NativeTranslationRenderer.polishCaptionPanels(cards:&raw,glossCards:[],gloss:.init(),layout:layout,settings:settings,source:nil)
        #expect(Double(real15 ? raw[0].item.x : raw[0].item.y) == (real15 ? 315.09375 : 364.046875))
        if real15 {
            #expect(!raw[0].captionParentPlate && raw[0].captionParentOwner == nil)
            #expect(raw[0].textZ == 3 && raw[0].textRootOrder != nil)
        }
        #expect(raw[0].item.sourceBounds == item.sourceBounds && raw[0].item.sourceFrame == item.sourceFrame)
    }
}
