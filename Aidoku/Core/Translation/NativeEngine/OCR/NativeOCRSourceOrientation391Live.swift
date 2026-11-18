import Foundation
import CoreGraphics
import CryptoKit

/// Pure bridge over an ALREADY captured/prepared session. No frame/model/acquisition
/// calls, candidate admission, selection, graph mutation or new source-loss policy.
@available(iOS 18.0, *)
extension NativeOCRSourceOrientation391 {
    typealias F = NativeOCRSourceLocalJoint369

    static func generateFromLive(prior: NativeOCRCurrentPrior351.Resolution,
        graph: NativeOCRSourceLocalJoint369Capture.FinalGraph,
        measurement: F.M, live: F.LiveObservation) -> Result {
        func failure(_ reason:String)->Result {
            .init(offers:[],receipt:["family":"source-axis-orientation391","status":reason,
                "sourceOnly":true,"GTRead":false,"admissionGranted":false,
                "automaticSelection":false,"ownershipChanged":false,"nativeAdmissionSuiteRun":false])
        }
        let indices=[measurement.index]+prior.consumedIndices
        guard let actual=graph.prior(measurement.index),actual.polygon==prior.polygon,
              actual.consumedIndices==prior.consumedIndices,
              actual.inheritedAssociationKey==prior.inheritedAssociationKey,
              Set(indices).count==indices.count,!indices.isEmpty,indices.count<=64,
              live.sources.map(\.index)==indices,live.bodies.count==indices.count,
              liveQuad(prior.polygon) else {return failure("unavailable-actual-graph-prior-member-order")}
        let r=live.rgba,window=live.window
        guard r.width>0,r.height>0,r.width<=600_000/r.height,
              r.width<=Int.max/4,r.bytesPerRow>=r.width*4,r.height<=Int.max/r.bytesPerRow,
              r.bytes.count==r.bytesPerRow*r.height,
              r.origin==CGPoint(x:window.left,y:window.top),r.width==window.width,r.height==window.height,
              window.frameSize.width>0,window.frameSize.height>0,
              prior.polygon.allSatisfy({$0.x>=r.origin.x && $0.y>=r.origin.y &&
                  $0.x<=r.origin.x+CGFloat(r.width) && $0.y<=r.origin.y+CGFloat(r.height)}) else {
            return failure("unavailable-actual-shared-RGBA-window")
        }
        guard let root=live.sources.first,root.index==measurement.index,
              root.status==measurement.status,root.origin==measurement.origin,
              root.normal==measurement.normal,root.along==measurement.along,
              root.rect==measurement.rect,root.polygon==measurement.polygon else {
            return failure("unavailable-root-measurement-binding")
        }
        let rgbaSHA=SHA256.hash(data:Data(r.bytes)).map{String(format:"%02x",$0)}.joined()
        let shared=LocalRGBA(bytes:r.bytes,width:r.width,height:r.height,bytesPerRow:r.bytesPerRow,origin:r.origin)
        var sources:[Source]=[],body=[UInt8](repeating:0,count:r.width*r.height)
        for ordinal in indices.indices {
            let m=live.sources[ordinal],e=live.bodies[ordinal],p=e.prepared,b=e.sourceLocalRGBA
            // m.rect.width is the actual native Measurement width (exported as m.width).
            // No prior polygon width, private hull width, or inferred width substitutes it.
            let nativeWidth=Double(m.rect.width),fp=e.actualFullFootprint
            guard m.status=="measured",nativeWidth.isFinite,nativeWidth>0,
                  [m.origin,m.normal,m.along].allSatisfy({$0.x.isFinite && $0.y.isFinite}),
                  abs(hypot(m.normal.x,m.normal.y)-1)<1e-6,
                  abs(hypot(m.along.x,m.along.y)-1)<1e-6,
                  abs(m.normal.x*m.along.x+m.normal.y*m.along.y)<1e-6,
                  p.inherited==prior.polygon,p.sourceOrigin==m.origin,p.normal==m.normal,p.along==m.along,
                  p.sourceWidth==nativeWidth,
                  p.window.frameSize==window.frameSize,p.window.left==window.left,p.window.top==window.top,
                  p.window.width==window.width,p.window.height==window.height,
                  b.origin==r.origin,b.width==r.width,b.height==r.height,
                  b.bytesPerRow==r.bytesPerRow,b.bytes==r.bytes,
                  e.sourceAuthenticatedContrastBodyMask.count==body.count,
                  let retained=m.privateObservation,retained.missingPrivateRGBPixels==0,
                  let original=retained.footprint,fp.width>0,fp.height>0,
                  fp.width<=Int.max/fp.height,fp.scaleX.isFinite,fp.scaleY.isFinite,fp.scaleX>0,fp.scaleY>0,
                  !fp.cells.isEmpty,fp.cells.allSatisfy({$0>=0 && $0<fp.width*fp.height}),
                  fp.width==original.width,fp.height==original.height,
                  fp.scaleX==original.scaleX,fp.scaleY==original.scaleY,fp.cells==original.cells,
                  abs(CGFloat(fp.width)*fp.scaleX-CGFloat(window.frameSize.width))<=1e-6,
                  abs(CGFloat(fp.height)*fp.scaleY-CGFloat(window.frameSize.height))<=1e-6,
                  !e.actualPalettes.isEmpty,e.actualPalettes.count<=16,
                  e.actualPalettes.count==retained.palettes.count else {
                return failure("unavailable-actual-body-native-width-original-footprint-binding")
            }
            for (a,b) in zip(e.actualPalettes,retained.palettes) {
                guard a.rgb==b.rgb,a.bin==b.bin,a.sourceSeedBinCount==b.sourceSeedBinCount,
                      a.rgb.count==3,a.rgb.allSatisfy({(0...255).contains($0)}) else {
                    return failure("unavailable-actual-native-palette-binding")
                }
            }
            for i in body.indices where e.sourceAuthenticatedContrastBodyMask[i] != 0 {body[i]=1}
            sources.append(.init(tag:String(m.index),rgba:shared,width:nativeWidth,
                origin:m.origin,normal:m.normal,along:m.along,
                originalFootprintContains:{fp.contains($0)},originalFootprintComplete:true,
                nativePalettes:e.actualPalettes.map{$0.rgb},actualRGBA_SHA256:rgbaSHA,capturedRawSHA256:nil))
        }
        let generated=generate(prior:prior.polygon,root:sources[0],members:sources,sharedBody:body)
        var receipt=generated.receipt
        receipt["liveBinding"]=["actualSourceIndices":indices,"memberOrderMatchesActualGraph":true,
            "actualCurrentPrior":prior.polygon.map{[Double($0.x),Double($0.y)]},
            "actualAssociationKey":prior.inheritedAssociationKey.map{$0 as Any} ?? NSNull(),
            "bodyPreparedInheritedEqualsActualPrior":true,"exactSharedRGBA":true,
            "actualFullFootprintMatchesNativeMeasurement":true,"actualRGBA_SHA256":rgbaSHA,
            "capturedRawSHA256":NSNull(),"frameCalls":0,"sourceAcquisitionCalls":0,
            "automaticSelection":false,"admissionGranted":false,"ownershipChanged":false]
        return .init(offers:generated.offers,receipt:receipt)
    }

    private static func liveQuad(_ q:[CGPoint])->Bool {
        guard q.count==4,q.allSatisfy({$0.x.isFinite && $0.y.isFinite}) else{return false}
        let cross=(0..<4).map{i -> CGFloat in
            let a=q[i],b=q[(i+1)%4],c=q[(i+2)%4]
            return (b.x-a.x)*(c.y-b.y)-(b.y-a.y)*(c.x-b.x)
        }
        return cross.allSatisfy{$0>1e-9} || cross.allSatisfy{$0 < -1e-9}
    }
}
