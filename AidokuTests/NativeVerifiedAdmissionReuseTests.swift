import CoreGraphics
import Testing
@testable import Aidoku

struct NativeVerifiedAdmissionReuseTests {
    @Test func unchangedVerifiedPeersReuseEffectsButMovedOwnerIsReprepared() throws {
        typealias P = NativeAOTTranslationPageComposer.TranslatedFillPrimitive
        let page=CGRect(x:0,y:0,width:240,height:160)
        let context=try #require(CGContext(data:nil,width:240,height:160,bitsPerComponent:8,
            bytesPerRow:960,space:CGColorSpaceCreateDeviceRGB(),
            bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray:1,alpha:1));context.fill(page)
        let restored=try #require(context.makeImage())
        var pixels=[UInt8](repeating:0,count:10*8*4)
        for i in 0..<80 {pixels[i*4+3]=255}
        let glyph=try NativeMandatoryDisplayStroke.image(pixels,width:10,height:8)
        var fills:[P]=[]
        for i in 0..<2 {
            var p=P(image:glyph,frame:CGRect(x:30+i*90,y:50,width:10,height:8),fontOutputPixels:16)
            p.ownerID="owner-\(i)";p.displayStrokeEndpoint=255;fills.append(p)
        }
        try NativeFixedFontRecovery.withMetrics {
            let metrics=try #require(NativeFixedFontRecovery.metrics)
            metrics.beginRecovery()
            let admitted=try NativeFinalTextPaintAdmission.place(fills,page:page)
            let first=try NativeAOTTranslationPageComposer.verifyFixedFontAdmission(restored:restored,admitted:admitted)
            let charged=metrics.cache.audit["conservativeChargedBytes"]
            let reused=try NativeAOTTranslationPageComposer.verifyFixedFontAdmission(restored:restored,admitted:admitted,reusing:first)
            #expect(metrics.cache.audit["conservativeChargedBytes"]==charged)
            let a=try NativeAOTTranslationPageComposer.mandatoryStrokeLayer(verified:first,expectedItems:2,textComplete:true)
            let b=try NativeAOTTranslationPageComposer.mandatoryStrokeLayer(verified:reused,expectedItems:2,textComplete:true)
            #expect(try NativeMandatoryDisplayStroke.rgba(a.image)==NativeMandatoryDisplayStroke.rgba(b.image))
            var moved=admitted.fills;moved[0].frame=moved[0].frame.offsetBy(dx:5,dy:0)
            let shifted=try NativeFinalTextPaintAdmission.place(moved,page:page)
            _=try NativeAOTTranslationPageComposer.verifyFixedFontAdmission(restored:restored,admitted:shifted,reusing:first)
            #expect((metrics.cache.audit["conservativeChargedBytes"] ?? 0)>(charged ?? 0))
        }
    }
}
