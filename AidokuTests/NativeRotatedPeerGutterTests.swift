import CoreGraphics
import CoreText
import Foundation
import Testing
@testable import Aidoku

@Suite(.serialized) @MainActor
struct NativeRotatedPeerGutterTests {
    private typealias N = NativeFinalTextPaintAdmission
    private typealias P = NativeAOTTranslationPageComposer.TranslatedFillPrimitive
    @Test func overlappingSourceUnionsCannotAuthorizeTouchingRotatedNativeGlyphs() throws {
        let page=CGRect(x:0,y:0,width:400,height:220)
        let font=CTFontCreateWithName("AppleSDGothicNeo-Regular" as CFString,28,nil)
        let words=try NativeWholeWordWrap.layout(text:"HH",font:font,size:28,width:100,
            color:CGColor(gray:0,alpha:1))
        let plan=try NativeWholeWordGlyphPainter.positionRetainedPitch(words,width:100,pitch:64,outwardExtent:6)
        var first=try NativeWholeWordGlyphPainter.raster(plan,origin:CGPoint(x:40,y:70),scale:1,pagePixels:page.size)
        first.ownerID="first";first.displayStrokeEndpoint=255
        let guide=NativeTextPlacementGuide(rectNormalized:[0.1,0.2,0.8,0.6],horizontal:.center,
            vertical:.center,sourceRotationRadians:.pi/18)
        first.textPlacementGuide=guide
        (first.image,first.frame)=try guide.rotatedRaster(first.image,frame:first.frame)
        let support=try N.retainedFootprint(first)
        var separation:CGFloat?
        for dx in 1...Int(ceil(support.bounds.width))+2 {
            if !N.intersects(support,support.translated(CGPoint(x:dx,y:0))) {separation=CGFloat(dx);break}
        }
        let shift=try #require(separation)
        var second=first;second.ownerID="second";second.frame=second.frame.offsetBy(dx:shift,dy:0)
        let peer=try N.retainedFootprint(second)
        #expect(!N.intersects(support,peer))
        let fixed=["first":support.bounds.origin,"second":peer.bounds.origin]
        #expect(throws:N.Failure.self) {
            try N.place([first,second],page:page,fixedOrigins:fixed)
        }
        // The real source-guided solver must repair spacing rather than drop
        // a word, change its font, or treat overlapping source unions as a pass.
        let repaired=try N.place([first,second],page:page)
        #expect(repaired.fills.count==2)
        #expect(repaired.fills.allSatisfy {$0.fontOutputPixels==28})
        try N.verifyRetainedPlacement(repaired.fills,
            footprints:repaired.fills.map {try N.retainedFootprint($0)},page:page)
    }
}
