import CoreGraphics
import Foundation

extension NativeEarlyMarginPaper {
    /// A retry transports a new canvas rather than mutating the old crop's
    /// dimensions. The caller retains the whole previous Patch for rollback.
    static func makePatch(item: NativeTranslationLayoutItem, fontSize: CGFloat,
                          previous: NativeRestorationCandidate, layout: NativeTranslationLayout,
                          reader: NativeSourcePixelReader, remaining: inout Int, cleanupClip: CGRect? = nil) -> NativeTranslationRestoration.Patch? {
        let bounds=item.sourceBounds.map(Double.init)
        let input=Input(imageSize:previous.imageSize,frame:previous.frame,bounds:bounds,
            auxiliary:item.auxiliaryInkRects.map { $0.map(Double.init) },
            otherBounds:layout.items.filter { $0.id != item.id }.flatMap { ([$0.sourceBounds]+$0.auxiliaryInkRects).map { $0.map(Double.init) } },
            sourceFontSize:item.sourceFontSize.map(Double.init),fontSize:Double(fontSize),
            vertical:item.sourceVertical,singleColumn:item.sourceSingleColumn)
        var repairedPixels: NativeRestorationPixels?
        let proposal=propose(input,remaining:&remaining,read:{ crop,w,h in
            try reader.read(x:Double(crop.minX),y:Double(crop.minY),sourceWidth:Double(crop.width),
                sourceHeight:Double(crop.height),width:w,height:h)
        },enclosedPaper:{ rgba,w,h,box,auxiliary,excluded in
            var source=NativeRestorationPixels(width:w,height:h);source.rgba=rgba
            guard let result=NativeRestorationPixels.enclosedPaper(source,box:box,auxiliary:auxiliary,excluded:excluded),
                  let safe=result.layoutSafe else { return nil }
            repairedPixels=result
            return Repair(rgba:result.rgba,safe:safe,sourceErasureVerified:result.sourceErasureVerified ?? false)
        })
        guard let proposal,var repaired=repairedPixels else { return nil }
        var original=NativeRestorationPixels(width:repaired.width,height:repaired.height);original.rgba=proposal.original
        let prepared=NativeSpatialSourceCrop.Prepared(pixels:original,crop:proposal.crop,
            source:proposal.core[0].offsetBy(dx:proposal.crop.minX,dy:proposal.crop.minY),box:proposal.core[0],
            auxiliary:Array(proposal.core.dropFirst()),excluded:proposal.excluded,marks:[],leadingRule:false,sx:1,sy:1,
            synthetic:[UInt8](repeating:0,count:repaired.count))
        // The frozen object replacement retains fields absent from Object.assign.
        // In particular remaining/core counts and method belong to the old proof.
        repaired.erasureComplete=true;repaired.glyphsVerified=true;repaired.localProposal=false
        repaired.method=previous.method;repaired.sourceRemainingInk=previous.sourceRemainingInk
        repaired.sourceCorePixels=previous.sourceCorePixels
        guard let next=NativeRestorationCandidate(prepared:prepared,repaired:repaired,luminance:proposal.luminance,
            imageSize:previous.imageSize,frame:previous.frame,item:item,
            sourceErasureVerified:proposal.repair.sourceErasureVerified) else { return nil }
        next.partialErasureCertified=true;next.provisional=true
        next.sourceResidualFilled=previous.sourceResidualFilled
        let oldSurface=previous.beginTrial()
        var surface=next.beginTrial();surface.surfaceRevision=previous.revision+1
        surface.coreClear=oldSurface.coreClear;surface.innerCoreClear=oldSurface.innerCoreClear
        surface.residualLettering=oldSurface.residualLettering
        guard next.commit(surface),let image=next.image() else { return nil }
        return NativeTranslationRestoration.Patch(image:image,rect:proposal.viewport,itemID:item.id,
            layoutSafe:next.safe,surfaceLuminance:next.luminance,surfaceQuality:next.surfaceQuality,candidate:next,
            rasterGeometry:.init(frame:previous.frame,imageSize:previous.imageSize,origin:proposal.crop.origin,scale:.init(width:1,height:1)),cleanupClip:cleanupClip)
    }
}
