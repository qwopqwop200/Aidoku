import CoreGraphics
import Foundation
import Testing
@testable import Aidoku

@Suite struct NativeForeignBackgroundGradientTests {
    struct Control: Sendable {
        let owner: [CGFloat], position: [CGFloat], size: [CGFloat], destination: [CGFloat], tile: [CGFloat]
    }
    // Independent WK PDF geometry controls, including negative local offsets
    // and partial border intersections. The owner is its actual used DOM box.
    static let controls: [Control] = [
        .init(owner: [10.578125,10.53125,60.296875,70.484375],position:[0.015390391,36.859375],size:[6.375234,17.578125],destination:[10.5,47.5,6.5,17.5],tile:[10.5,47.5,6.5,17.5]),
        .init(owner:[100,100.015625,80.296875,60.6875],position:[3.12,4.45],size:[20.18,18.33],destination:[103,104.5,20.5,18.5],tile:[103,104.5,20.5,18.5]),
        .init(owner:[200.375,10.375,60.1875,70.1875],position:[-3.19,-4.22],size:[30.7,24.9],destination:[200.5,10.5,27.5,20.5],tile:[197.5,6.5,30.5,25]),
        .init(owner:[300.28125,100.40625,60.21875,50.359375],position:[52.18,43.47],size:[20.12,18.56],destination:[352.5,144,8,7],tile:[352.5,144,20,18.5]),
        .init(owner:[10.25,200.125,60.5,80.75],position:[5.5,10.25],size:[20.5,30.25],destination:[16,210.5,20.5,30],tile:[16,210.5,20.5,30]),
        .init(owner:[120.21875,200.765625,70.1875,80.21875],position:[5.016,4.999],size:[1.023,1.079],destination:[125,206,1.5,1],tile:[125,206,1.5,1]),
        .init(owner:[-10.25,300.375,60.5,70.5],position:[12.39,13.28],size:[20.64,30.91],destination:[2,313.5,21,31],tile:[2,313.5,21,31]),
        .init(owner:[250.28125,250.359375,70.515625,80.515625],position:[1.29,2.31],size:[20.64,30.91],destination:[251.5,252.5,20.5,31],tile:[251.5,252.5,20.5,31])
    ]
    private func rect(_ v:[CGFloat])->CGRect { CGRect(x:v[0],y:v[1],width:v[2],height:v[3]) }
    @Test(arguments: controls) func literalNoRepeatTileGeometry(_ control: Control) throws {
        let geometry = try #require(NativeForeignBackgroundGradient.geometry(owner:rect(control.owner),
            position:CGPoint(x:control.position[0],y:control.position[1]),size:CGSize(width:control.size[0],height:control.size[1]),deviceScale:2))
        #expect(geometry.destination == rect(control.destination))
        #expect(geometry.tile == rect(control.tile))
        #expect(!geometry.usesPattern)
    }

    @Test(arguments: [false,true]) func actualPanelPainterRetainsDeclaredLayersAfterAnOwnerMove(_ live:Bool) throws {
        // Layer declarations came from a different owner origin. A later CSS
        // left/top change moves the background images with their owner.
        let owner = CGRect(x:300.25,y:300.375,width:70.5,height:70.5)
        let fields:[String:Any] = ["id":"foreign","text":"","x":300.25,"y":300.375,"width":70.5,"height":70.5,
            "fontSize":8,"lineHeight":10,"sourceBounds":[0.1,0.1,0.1,0.1],"sourceFrame":[0,0,400,400]]
        let item=try JSONDecoder().decode(NativeTranslationLayoutItem.self,from:JSONSerialization.data(withJSONObject:fields))
        let style=NativeTranslationTypography.Style(fontSize:8,foreground:NativeTranslationRenderer.color([0,0,0]))
        let typography=NativeTranslationTypography.layout(text:"",in:item.contentRect.size,style:style)
        var panel=NativeTranslationSourceStylePostPolish.Panel(rect:owner,background:[255,255,255],coverage:[owner]);panel.radius=0
        var card=NativeTranslationRenderer.Card(item:item,typography:typography,style:style,sourcePanels:[panel],drawsPanel:false,
            background:NativeTranslationRenderer.color([255,255,255]),usesFallbackVeil:false,lightSurface:true,heavyStrokeWidth:0,finalFontSize:8)
        card.foreignFills = [
            .init(rect:CGRect(x:15.12,y:20.32,width:20.75,height:30.5),color:[220,30,40],backgroundPosition:CGPoint(x:5.12,y:10.32),backgroundSize:CGSize(width:20.75,height:30.5)),
            .init(rect:CGRect(x:25.12,y:30.32,width:20.75,height:30.5),color:[30,40,220],backgroundPosition:CGPoint(x:15.12,y:20.32),backgroundSize:CGSize(width:20.75,height:30.5))]
        func pixels(_ paint:(CGContext)->Void)throws->[UInt8] {
            let scale=live ? CGFloat(2) : CGFloat(3192)/390,width=Int(ceil(owner.width*scale)),height=Int(ceil(owner.height*scale))
            var bytes=[UInt8](repeating:255,count:width*height*4)
            try bytes.withUnsafeMutableBytes { memory in
                let context=try #require(CGContext(data:memory.baseAddress,width:width,height:height,bitsPerComponent:8,bytesPerRow:width*4,
                    space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGBitmapInfo.byteOrder32Big.rawValue|CGImageAlphaInfo.premultipliedLast.rawValue))
                context.scaleBy(x:scale,y:scale);context.translateBy(x:-owner.minX,y:-owner.minY);paint(context)
            }
            return bytes
        }
        let actual=try pixels { NativeTranslationRenderer.draw(card,context:$0,opacity:1,paintsBackground:false,paintsText:false,paintsSourcePanels:true,pixelSnapScale:live ? nil : 2) }
        func reference(reverse:Bool)throws->[UInt8] {
            try pixels { context in
                let boxes=[CGRect(x:305.5,y:310.5,width:20.5,height:30.5),CGRect(x:315.5,y:320.5,width:20.5,height:30.5)]
                for i in (reverse ? [1,0] : [0,1]) {
                    context.saveGState();context.clip(to:boxes[i]);context.translateBy(x:boxes[i].minX,y:boxes[i].minY)
                    let space=CGColorSpace(name:CGColorSpace.sRGB)!,rgb=card.foreignFills[i].color.map { CGFloat(Float($0/255)) }
                    let color=CGColor(colorSpace:space,components:rgb+[1])!
                    let gradient=CGGradient(colorsSpace:space,colors:[color,color] as CFArray,locations:[0,1])!
                    context.drawLinearGradient(gradient,start:.zero,end:CGPoint(x:0,y:boxes[i].height),options:[.drawsBeforeStartLocation,.drawsAfterEndLocation]);context.restoreGState()
                }
            }
        }
        let expected=try reference(reverse:true),wrongOrder=try reference(reverse:false)
        #expect(actual == expected)
        #expect(actual != wrongOrder)
        #expect(card.foreignFills[0].backgroundPosition == CGPoint(x:5.12,y:10.32))
    }
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
