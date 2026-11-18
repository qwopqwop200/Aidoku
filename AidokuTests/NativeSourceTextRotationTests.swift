import CoreGraphics
import CoreText
import Foundation
import Testing
@testable import Aidoku

@Suite(.serialized)
struct NativeSourceTextRotationTests {
    private let size = CGSize(width: 500, height: 280)
    private let radians = Double.pi / 22.5
    private func quad(x: Double, angle: Double) -> [[Double]] {
        [[-55.0, -28], [55, -28], [55, 28], [-55, 28]].map { p in
            [x + p[0] * cos(angle) - p[1] * sin(angle),
             120 + p[0] * sin(angle) + p[1] * cos(angle)]
        }
    }
    private func background() throws -> CGImage {
        let context = try #require(CGContext(data: nil, width: 500, height: 280,
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(origin: .zero, size: size))
        return try #require(context.makeImage())
    }
    private func options(cluster: Bool, inside: Bool, flat: Bool = false) -> [[String: Any]] {
        (0..<(cluster ? 2 : 1)).map { i in
            let x = i == 0 ? 130.0 : 370.0
            var guide: [String: Any] = ["rectNormalized": [(x - 65) / 500, 75.0 / 280, 130.0 / 500, 90.0 / 280],
                "horizontal": "center", "vertical": "center"]
            if flat { guide["sourceRotationRadians"] = 0.0 }
            let allowed = [0.02, 0.02, 0.96, 0.96]
            var row: [String: Any] = ["id": "owner-\(i)", "text": "WORD", "fontReference": 24.0,
                "textPlacementGuide": guide, "sourceMemberPolygons": [quad(x: x, angle: radians)],
                "textExpansionPolicy": ["allowedRectNormalized": allowed, "candidates": [allowed],
                    "maskCoverage": [1.0], "backgroundRisk": [0.0], "sourceFontPixels": 24.0,
                    "kind": inside ? "inside-balloon-mask" : "source-near-limited-expansion",
                    "maskRectNormalized": inside ? allowed as Any : NSNull(),
                    "maskSpansNormalized": inside ? [0.02, 0.98, 0.02, 0.98] as Any : NSNull()]]
            if cluster {
                row["sourceClusterAlignment"] = ["groupID": "source-group", "axis": "top", "anchorNormalized": 0.3,
                    "anchorPolicy": "source-near-final-alpha", "anchorsToSourceStart": true]
            }
            return row
        }
    }
    private func render(cluster: Bool, inside: Bool, flat: Bool = false) throws -> NativeAOTTranslationPageComposer.TextLayer {
        let rows = options(cluster: cluster, inside: inside, flat: flat)
        let items = rows.enumerated().map { i, row in
            NativeAOTRawTextPainter.Item(id: row["id"] as! String, text: "WORD",
                frame: CGRect(x: i == 0 ? 60 : 300, y: 70, width: 140, height: 110),
                fontSize: 24, lineHeight: 36, chosenFill: CGColor(gray: 0, alpha: 1), colorAuthority: "synthetic")
        }
        return try NativeAOTRawTextPainter.renderCentered(items: items, rawItems: rows,
            viewport: size, restored: background())
    }
    @Test func originalQuadAngleSurvivesCornerOrderAndRejectsConflictingDirections() throws {
        let q = quad(x: 130, angle: radians)
        for value in [q, Array(q.reversed()), Array(q.dropFirst()) + [q[0]]] {
            let observed = try #require(NativeSourceTextRotation.estimate([value]))
            #expect(abs(observed.radians - radians) < 1e-9)
        }
        #expect(NativeSourceTextRotation.estimate([q, quad(x: 370, angle: -radians)]) == nil)
        let unchanged = NativeSourceTextRotation.annotate(options(cluster: false, inside: false, flat: true))
        let guide = try #require(unchanged[0]["textPlacementGuide"] as? [String: Any])
        #expect(guide["sourceRotationRadians"] as? Double == 0)
    }
    @Test func clusteredGlyphsActuallyRotateBeforeNativeEffectAndPeerAdmission() throws {
        try verify(cluster: true, inside: false)
    }
    @Test func insideBalloonMaskGlyphActuallyRotatesAndRemainsInsideItsMask() throws {
        try verify(cluster: false, inside: true)
    }
    @Test func missingQuadUsesOriginalMaskedNativeInkAndRejectsAbsentForeground() throws {
        let font=CTFontCreateWithName("AppleSDGothicNeo-Regular" as CFString,24,nil)
        let words=try NativeWholeWordWrap.layout(text:"HHHHHHH",font:font,size:24,width:260,
            color:CGColor(gray:0,alpha:1))
        let plan=try NativeWholeWordGlyphPainter.positionRetainedPitch(words,width:260,pitch:64,outwardExtent:4)
        let primitive=try NativeWholeWordGlyphPainter.raster(plan,origin:CGPoint(x:100,y:100),scale:1,pagePixels:size)
        let angle = -Double.pi/12
        let rotating=NativeTextPlacementGuide(rectNormalized:[0.05,0.05,0.9,0.9],horizontal:.center,
            vertical:.center,sourceRotationRadians:angle)
        let (glyph,frame)=try rotating.rotatedRaster(primitive.image,frame:primitive.frame)
        let rgba=try NativeMandatoryDisplayStroke.rgba(glyph)
        var rgb=[UInt8](repeating:255,count:500*280*3),mask=[UInt8](repeating:0,count:500*280)
        for y in 0..<glyph.height {for x in 0..<glyph.width {
            let X=Int(frame.minX)+x,Y=Int(frame.minY)+y
            guard X>=0,Y>=0,X<500,Y<280 else{continue}
            let opacity=rgba[(y*glyph.width+x)*4+3],offset=Y*500+X
            mask[offset]=opacity>0 ? 255:0
            for channel in 0..<3 {rgb[offset*3+channel]=255-opacity}
        }}
        let rect=frame.intersection(CGRect(origin:.zero,size:size))
        let guide:[String:Any]=["rectNormalized":[rect.minX/500,rect.minY/280,rect.width/500,rect.height/280],
            "horizontal":"center","vertical":"center"]
        let row:[String:Any]=["id":"missing-source-quad","sourceMemberPolygons":[[[Double]]](),
            "sourceFontSize":24.0,"textPlacementGuide":guide,
            "sourcePredictedStyle":["sourceOnly":true,"fill":["rgb":[0.0,0,0]],"background":["rgb":[255.0,255,255]]]]
        let source=try #require(NativeSourcePhysicalInteriorContext(rgb:rgb,width:500,height:280,
            erased:mask,sourceIdentity:"native-mask-angle-fixture",sourceOpaque:true))
        let output=NativeSourceTextRotation.annotate([row],pixelObservation:{source.sourceTextRotation(raw:$0,guide:$1)})
        let observation=try #require(output[0]["sourceRotationObservation"]as?[String:Any])
        let measured=try #require(observation["radians"]as?Double)
        #expect(abs(measured-angle)<Double.pi/60)
        #expect(observation["maskRestricted"]as?Bool==true)
        let blank=try #require(NativeSourcePhysicalInteriorContext(rgb:rgb,width:500,height:280,
            erased:[UInt8](repeating:0,count:500*280),sourceIdentity:"no-owned-source-ink",sourceOpaque:true))
        #expect(blank.sourceTextRotation(raw:row,guide:guide)==nil)
    }
    @Test func sourceOpacityProofDoesNotDependOnClosedBarrierFeature() throws {
        #expect(NativeSourcePhysicalInteriorContext.opaqueSourceProof(try background()))
        let context=try #require(CGContext(data:nil,width:8,height:8,bitsPerComponent:8,
            bytesPerRow:32,space:CGColorSpaceCreateDeviceRGB(),
            bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
        context.clear(CGRect(x:0,y:0,width:8,height:8))
        #expect(!NativeSourcePhysicalInteriorContext.opaqueSourceProof(try #require(context.makeImage())))
    }
    @Test func diagonalSourceStartUsesOrientedCornerInsteadOfUnionTopLeft() {
        for angle in [-Double.pi/12,Double.pi/12] {
            let width=120.0,height=30.0,c=cos(angle),s=sin(angle)
            let bounds=CGRect(x:20,y:20,width:width*abs(c)+height*abs(s),height:width*abs(s)+height*abs(c))
            let guide=NativeTextPlacementGuide(rectNormalized:[0.2,0.2,0.6,0.5],horizontal:.left,vertical:.top,
                sourceRotationRadians:angle,rotationAnchorNormalized:[0.3,0.55])
            let shifted=bounds.offsetBy(dx:guide.preferredShift(bounds:bounds,page:CGRect(origin:.zero,size:size)).x,
                dy:guide.preferredShift(bounds:bounds,page:CGRect(origin:.zero,size:size)).y)
            let start=CGPoint(x:shifted.midX-width*c/2+height*s/2,y:shifted.midY-width*s/2-height*c/2)
            #expect(abs(start.x-150)<1 && abs(start.y-154)<1)
        }
    }
    private func verify(cluster: Bool, inside: Bool) throws {
        let actual = try render(cluster: cluster, inside: inside), flat = try render(cluster: cluster, inside: inside, flat: true)
        #expect(actual.complete && actual.expectedItems == actual.paintedItems)
        #expect(try NativeMandatoryDisplayStroke.rgba(actual.image) != NativeMandatoryDisplayStroke.rgba(flat.image))
        let rows = try #require(actual.audit["rawNativeItems"] as? [[String: Any]])
        for row in rows {
            let applied = try #require(row["sourceObservedRotationRadians"] as? Double)
            #expect(abs(applied - radians) < 1e-9)
            #expect(row["rotationBeforeFinalAlphaAdmission"] as? Bool == true)
            #expect(row["fontSize"] as? Double == 24 && row["sourceUTF16"] as? Int == row["visibleUTF16"] as? Int)
        }
        let admitted = try #require(actual.audit["finalPaintAdmission"] as? [[String: Any]])
        for owner in admitted {
            #expect(owner["pageContained"] as? Bool == true)
            #expect(owner["peerAlphaCollisions"] as? Int == 0)
            #expect(owner["domainContained"] as? Bool == true)
        }
    }
}
