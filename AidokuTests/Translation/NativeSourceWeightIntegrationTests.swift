import CoreGraphics
import CoreText
import Foundation
import Testing
@testable import Aidoku

/// Packaged heads and actual native extraction from synthetic source pixels.
@Suite struct NativeSourceWeightIntegrationTests {
    @Test func sourceMixedWeightRetainsRegularTranslationBeforeShaping() throws {
        let width=70,height=116,em=30.0
        var rgb=[UInt8](repeating:0,count:width*height*3)
        var own=[UInt8](repeating:0,count:width*height)
        func paint(_ x:Int,_ y:Int,_ w:Int,_ h:Int) {
            for py in y..<y+h { for px in x..<x+w {
                let index=py*width+px;own[index]=1
                rgb[index*3]=255;rgb[index*3+1]=255;rgb[index*3+2]=255
            }}
        }
        for (x,stroke) in [(12,1),(44,7)] {
            for y in [12,44,76] {
                paint(x,y,12,stroke);paint(x,y+20-stroke,12,stroke)
                paint(x+(12-stroke)/2,y,stroke,20)
            }
        }
        let polygon=[CGPoint(x:8,y:8),CGPoint(x:62,y:8),CGPoint(x:62,y:102),CGPoint(x:8,y:102)]
        var source=SourceNativeInput(width:width,height:height,rgb:rgb,
            rf:[Float](repeating:0,count:width*height*27),coarseRF:[Float](repeating:0,count:width*height*4),
            affinityScores:[Float](repeating:0,count:5),
            rfModelWeightsSHA256:NativeRFDETRLayoutResource.highresSourceWeightsSHA256,
            memberPolygons:[polygon],mergedPolygon:polygon,bbox:CGRect(x:8,y:8,width:54,height:94),
            fontPriorSourcePixels:em,crop:CGRect(x:0,y:0,width:width,height:height),
            pageSize:CGSize(width:width,height:height),sourceIdentity:String(repeating:"1",count:64),
            sourceText:"III",confidence:0.95,role:"dialogue")
        source.primary=own.map(Float.init);source.boundary=own.map(Float.init)
        source.rawNative=own;source.completed=own;source.ownMask=own;source.contextMask=own
        source.observationValid=[UInt8](repeating:1,count:width*height)
        source.ocr=[Float](repeating:0,count:width*height*8)
        let style:[String:Any]=["fill":["rgb":[255,255,255]],"background":["rgb":[0,0,0]],
            "outline":["present":false,"rgb":[0,0,0],"widthPx":0.0,"probability":0.0],
            "shadow":["present":false,"probability":0.0]]
        try source.validateWeightObservations()
        let heads=try NativeAppearanceModelHeads(bundle:.main)
        #expect(try NativeAcceptedSourceWeightInference.productionEnabled(heads:heads))
        let font=try NativeAcceptedSourceFontInference(heads:heads)
        let normalized=try font.estimate([source],styles:[style],returnContext:true,geometry:.bboxOnly)
        let context=try #require(normalized.context)
        let measurements=try font.weightMeasurements(context,styles:[style])
        #expect(measurements.mixed == [true], "normalized source em: \(context.finalSourceEMs)")
        #expect(measurements.physicalReferenceAvailable.count == 3)
        if !measurements.physicalReferenceAvailable[1] {
            #expect(measurements.paired48[0][16..<32].allSatisfy { $0 == 0 })
        }
        let weight=try NativeAcceptedSourceWeightInference(heads:heads,font:font)
        let result=try #require(weight.estimate(context,styles:[style]).first)
        #expect(result["sourceWeight"] as? String == "mixed")
        #expect(result["renderBold"] as? Bool == false)
        #expect(result["requiresTranslationSpanAlignment"] as? Bool == true)
        let regular=try NativeAOTRawTextPainter.sourceFontName(raw:result)
        #expect(regular == "AppleSDGothicNeo-Regular")
        #expect(!CTFontGetSymbolicTraits(CTFontCreateWithName(regular as CFString,30,nil)).contains(.boldTrait))
        let bold=try NativeAOTRawTextPainter.sourceFontName(raw:["sourceFontWeight":"bold","renderBold":true])
        #expect(CTFontGetSymbolicTraits(CTFontCreateWithName(bold as CFString,30,nil)).contains(.boldTrait))
    }
}
