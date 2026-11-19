import CoreGraphics
import Foundation
import Testing
@testable import Aidoku

@Suite struct NativeSourcePanelClipPaintTests {
    @Test func equalCoverageRetainsAnExplicitClipPath() throws {
        let frame=CGRect(x:117.34375,y:20.125,width:33.84375,height:59.359375)
        let fields:[String:Any] = ["id":"clip","text":"","x":frame.minX,"y":frame.minY,"width":frame.width,"height":frame.height,
            "fontSize":8,"lineHeight":10,"sourceBounds":[0.1,0.1,0.1,0.1],"sourceFrame":[0,0,200,100]]
        let item=try JSONDecoder().decode(NativeTranslationLayoutItem.self,from:JSONSerialization.data(withJSONObject:fields))
        let style=NativeTranslationTypography.Style(fontSize:8,foreground:NativeTranslationRenderer.color([0,0,0]))
        let typography=NativeTranslationTypography.layout(text:"",in:item.contentRect.size,style:style)
        var panel=NativeTranslationSourceStylePostPolish.Panel(rect:frame,background:[153,169,168],coverage:[frame]);panel.radius=3;panel.clipped=true
        var card=NativeTranslationRenderer.Card(item:item,typography:typography,style:style,sourcePanels:[panel],drawsPanel:false,
            background:NativeTranslationRenderer.color([153,169,168]),usesFallbackVeil:false,lightSurface:true,heavyStrokeWidth:0,finalFontSize:8)
        func pixels(_ paint:(CGContext)->Void)throws->[UInt8] {
            let scale=CGFloat(3192)/390,width=Int(ceil((frame.width+4)*scale)),height=Int(ceil((frame.height+4)*scale))
            var bytes=[UInt8](repeating:255,count:width*height*4)
            try bytes.withUnsafeMutableBytes { memory in
                let context=try #require(CGContext(data:memory.baseAddress,width:width,height:height,bitsPerComponent:8,bytesPerRow:width*4,
                    space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGBitmapInfo.byteOrder32Big.rawValue|CGImageAlphaInfo.premultipliedLast.rawValue))
                context.scaleBy(x:scale,y:scale);context.translateBy(x:2-frame.minX,y:2-frame.minY);paint(context)
            }
            return bytes
        }
        let actual=try pixels { NativeTranslationRenderer.draw(card,context:$0,opacity:1,paintsBackground:false,paintsText:false,paintsSourcePanels:true,pixelSnapScale:3) }
        let expected=try pixels { context in
            let painted=NativeTranslationPDFCapture.snappedRect(frame,deviceScale:3)
            let declaredClip=frame.offsetBy(dx:painted.minX-frame.minX,dy:painted.minY-frame.minY)
            context.clip(to:declaredClip)
            context.setFillColor(NativeTranslationRenderer.color([153,169,168]))
            context.addPath(NativeTranslationPDFCapture.roundedPath(frame,radius:3,deviceScale:3));context.fillPath()
        }
        card.sourcePanels[0].clipped=false
        let absent=try pixels { NativeTranslationRenderer.draw(card,context:$0,opacity:1,paintsBackground:false,paintsText:false,paintsSourcePanels:true,pixelSnapScale:3) }
        #expect(actual == expected)
        #expect(actual != absent)
    }

    @Test func retainedCoverageMetadataDoesNotRecreateARemovedClipPath() throws {
        let frame=CGRect(x:10.578125,y:10.53125,width:60.296875,height:70.484375)
        let fields:[String:Any] = ["id":"retained","text":"","x":frame.minX,"y":frame.minY,"width":frame.width,"height":frame.height,
            "fontSize":8,"lineHeight":10,"sourceBounds":[0.1,0.1,0.1,0.1],"sourceFrame":[0,0,100,100]]
        let item=try JSONDecoder().decode(NativeTranslationLayoutItem.self,from:JSONSerialization.data(withJSONObject:fields))
        let style=NativeTranslationTypography.Style(fontSize:8,foreground:NativeTranslationRenderer.color([0,0,0]))
        let typography=NativeTranslationTypography.layout(text:"",in:item.contentRect.size,style:style)
        var panel=NativeTranslationSourceStylePostPolish.Panel(rect:frame,background:[61,73,68],coverage:[frame.insetBy(dx:0.15,dy:0.1)])
        panel.radius=2;panel.clipped=false;panel.captionUnionClipped=true;panel.sourceBridgeClipped=true
        var card=NativeTranslationRenderer.Card(item:item,typography:typography,style:style,sourcePanels:[panel],drawsPanel:false,
            background:NativeTranslationRenderer.color([61,73,68]),usesFallbackVeil:false,lightSurface:true,heavyStrokeWidth:0,finalFontSize:8)
        func pixels(_ value:NativeTranslationRenderer.Card)throws->[UInt8] {
            let scale=CGFloat(3192)/390,width=Int(ceil((frame.width+4)*scale)),height=Int(ceil((frame.height+4)*scale))
            var bytes=[UInt8](repeating:255,count:width*height*4)
            try bytes.withUnsafeMutableBytes { memory in
                let context=try #require(CGContext(data:memory.baseAddress,width:width,height:height,bitsPerComponent:8,bytesPerRow:width*4,
                    space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGBitmapInfo.byteOrder32Big.rawValue|CGImageAlphaInfo.premultipliedLast.rawValue))
                context.scaleBy(x:scale,y:scale);context.translateBy(x:2-frame.minX,y:2-frame.minY)
                NativeTranslationRenderer.draw(value,context:context,opacity:1,paintsBackground:false,paintsText:false,paintsSourcePanels:true,pixelSnapScale:3)
            }
            return bytes
        }
        let actual=try pixels(card)
        card.sourcePanels[0].coverage=[frame]
        let plain=try pixels(card)
        card.sourcePanels[0]=panel;card.sourcePanels[0].clipped=true
        let explicit=try pixels(card)
        #expect(actual == plain)
        #expect(actual != explicit)
        #expect(panel.coverage != [frame] && panel.captionUnionClipped && panel.sourceBridgeClipped)
    }
}
