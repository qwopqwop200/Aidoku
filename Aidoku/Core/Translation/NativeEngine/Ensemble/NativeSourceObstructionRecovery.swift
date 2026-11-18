import CoreGraphics
import Foundation

/// Optional quality planning strictly AFTER an actual successful complete native
/// paint. No failure/unknown here can replace that incumbent with a failed page.
enum NativeSourceObstructionRecovery {
    typealias P=NativeAOTTranslationPageComposer.TranslatedFillPrimitive
    typealias L=NativeAOTTranslationPageComposer.TextLayer
    typealias T=(fills:[P],audit:[[String:Any]])
    @TaskLocal static var sourceContext:NativeSourcePhysicalInteriorContext?
    @TaskLocal static var current:Session?
    struct Measurement {
        let supports:[String:NativeFinalTextPaintAdmission.Footprint]
        let costs:[String:Int]
        let audit:[[String:Any]]
        var total:Int {costs.values.reduce(0,+)}
    }
    final class Session: @unchecked Sendable {
        let source:NativeSourcePhysicalInteriorContext
        let initial:[String:P]
        let before:Measurement
        let material:Set<String>
        let unrelated:Set<String>
        private let rasterLock = NSLock()
        private var incumbentRasters: [String: [UInt8]] = [:]
        private var retainedRasterBytes = 0
        private let rasterByteLimit = 8 * 1024 * 1024

        init(source:NativeSourcePhysicalInteriorContext,initial:[P],before:Measurement,material:Set<String>,unrelated:Set<String>) {
            self.source=source;self.initial=Dictionary(uniqueKeysWithValues:initial.map{($0.ownerID!,$0)})
            self.before=before;self.material=material;self.unrelated=unrelated
        }
        func measure(_ fills:[P],page:CGRect)->Measurement? {
            NativeSourceObstructionRecovery.measure(fills,source:source,page:page)
        }
        func prefer(original:T,polished:T,page:CGRect)->T {
            guard let a=measure(original.fills,page:page),let b=measure(polished.fills,page:page) else{return polished}
            return a.total<b.total ? original:polished
        }

        // The incumbent is immutable for the lifetime of this recovery session.
        // Never cache a candidate's pixels or a failed decode.
        func incumbentRGBA(owner id: String, decode: (CGImage) throws -> [UInt8] = NativeMandatoryDisplayStroke.rgba) throws -> [UInt8]? {
            guard let image = initial[id]?.image else { return nil }
            rasterLock.lock()
            defer { rasterLock.unlock() }
            if let bytes = incumbentRasters[id] { return bytes }
            let bytes = try decode(image)
            if bytes.count <= rasterByteLimit - retainedRasterBytes {
                incumbentRasters[id] = bytes
                retainedRasterBytes += bytes.count
            }
            return bytes
        }

        func admissible(_ fills:[P],page:CGRect)->(Bool,[String:Any]) {
            guard let measured=measure(fills,page:page),Set(measured.costs.keys)==Set(before.costs.keys)else{return(false,["reason":"source-observation-unknown"])}
            var proofs:[[String:Any]]=[]
            for p in fills {
                guard let id=p.ownerID,let old=initial[id],let a=before.supports[id],let b=measured.supports[id]else{return(false,["reason":"owner-binding"])}
                if unrelated.contains(id) {
                    guard old.fontOutputPixels==p.fontOutputPixels,old.frame.size==p.frame.size,
                        let oldRGBA=try? incumbentRGBA(owner:id),
                        let newRGBA=try? NativeMandatoryDisplayStroke.rgba(p.image),oldRGBA==newRGBA else {
                        return(false,["reason":"unrelated-owner-raster-or-font-changed","owner":id])
                    }
                    if let guide=old.textPlacementGuide,guide.valid {
                        let source=guide.rect(in:page)
                        func cost(_ r:CGRect)->CGFloat {
                            let x:CGFloat
                            if old.sourceClusterAlignment?.axis == .left {x=r.minX-source.minX}
                            else {switch guide.horizontal {case .left:x=r.minX-source.minX;case .right:x=r.maxX-source.maxX;case .center:x=r.midX-source.midX}}
                            let y:CGFloat
                            if old.sourceClusterAlignment?.axis == .top {y=r.minY-source.minY}
                            else {switch guide.vertical {case .top:y=r.minY-source.minY;case .bottom:y=r.maxY-source.maxY;case .center:y=r.midY-source.midY}}
                            return hypot(x,y)
                        }
                        guard cost(b.bounds)<=cost(a.bounds)+0.000001 else{return(false,["reason":"unrelated-source-anchor-growth","owner":id])}
                    } else if p.frame != old.frame {return(false,["reason":"unrelated-motion-without-guide","owner":id])}
                }
                // Tolerate at most a one-em linear amount of new boundary contact;
                // a known raw component veto or missing observation NEVER waives.
                let tolerance=Int(ceil(max(old.fontOutputPixels,p.fontOutputPixels)))
                guard measured.costs[id]! <= before.costs[id]!+tolerance,
                    !material.contains(id) || measured.costs[id]!<=tolerance else{return(false,["reason":"material-obstruction-remains","owner":id,"costs":measured.costs])}
                let proof=source.qualityShapeClearance(incumbent:old,before:a,after:b,page:page,minimumChannelContrast:32)
                var record=proof.audit;record["owner"]=id
                let small=proof.allowed == false && proof.audit["status"]as?String=="new-alpha-preserved-source-boundary-veto" &&
                    proof.audit["observationComplete"]as?Bool==true && (proof.audit["adverseNewAlphaPixels"]as?Int ?? Int.max)<=tolerance
                record["smallObservedContactTolerated"]=small;record["maximumSmallContactPixels"]=tolerance
                proofs.append(record)
                guard proof.allowed==true || small else{return(false,["reason":"new-source-contact-or-unknown","proofs":proofs])}
            }
            return(measured.total<before.total,["beforeCosts":before.costs,"afterCosts":measured.costs,"proofs":proofs,
                "allMaterialOwnersBelowSmallContact":true,"physicalContainmentCertified":false])
        }
    }
    static func measure(_ fills:[P],source:NativeSourcePhysicalInteriorContext,page:CGRect)->Measurement? {
        guard !fills.isEmpty,fills.count<=256,Set(fills.compactMap(\.ownerID)).count==fills.count,
              fills.reduce(0,{$0+$1.image.width*$1.image.height})<=8_000_000 else{return nil}
        var supports:[String:NativeFinalTextPaintAdmission.Footprint]=[:],costs:[String:Int]=[:],audit:[[String:Any]]=[]
        for p in fills {
            guard let id=p.ownerID,let s=try? NativeFinalTextPaintAdmission.retainedFootprint(p)else{return nil}
            let result=source.obstructionExposure(s,page:page)
            guard let pixels=result.pixels else{return nil}
            supports[id]=s;costs[id]=pixels;var a=result.audit;a["owner"]=id;audit.append(a)
        }
        return Measurement(supports:supports,costs:costs,audit:audit)
    }
    private static func palette(_ layer:L)->[String:[Double]]? {
        guard let rows=layer.audit["rawNativeItems"]as?[[String:Any]]else{return nil}
        var values:[String:[Double]]=[:]
        for r in rows {
            guard let id=r["id"]as?String,let fill=r["finalDisplayFill"]as?[NSNumber],let stroke=r["finalDisplayStroke"]as?[NSNumber]else{return nil}
            values[id]=fill.map(\.doubleValue)+stroke.map(\.doubleValue)
        }
        return values
    }
    static func refine(incumbent:L,fills:[P],items:[NativeAOTRawTextPainter.Item],families:[NativeCohortFitPlanner.Family],
        minimumFont:Double,outputScale:CGFloat,source:NativeSourcePhysicalInteriorContext,page:CGRect,
        render:([NativeAOTRawTextPainter.Item])throws->L,completed:(CGImage)->[P]?)throws->L? {
        try Task.checkCancellation()
        guard current==nil,fills.count==items.count,let initial=measure(fills,source:source,page:page)else{try Task.checkCancellation();return nil}
        let material=Set(fills.compactMap {p->String? in
            guard let id=p.ownerID,let n=initial.costs[id],Double(n)>Double(p.fontOutputPixels*p.fontOutputPixels)else{return nil};return id
        })
        guard !material.isEmpty else{return nil}
        let affectedFamilies=families.filter {!$0.locked && !$0.owners.filter {material.contains($0)}.isEmpty}
        let affected=Set(affectedFamilies.flatMap(\.owners))
        let unrelated=Set(items.map(\.id)).subtracting(affected)
        let session=Session(source:source,initial:fills,before:initial,material:material,unrelated:unrelated)
        let start=Date();var attempts:[[String:Any]]=[]
        func result(_ layer:L,_ status:String,_ extra:[String:Any]=[:])->L {
            var a=layer.audit
            var receipt:[String:Any]=["status":status,"incumbentAuthority":"fresh actual completed native paint from this call",
                "initialSuccessPreservedOnUnknownOrBudget":true,"materialOwners":material.sorted(),"affectedFamilyOwners":affected.sorted(),"unrelatedOwnersPinnedInFontAndRaster":unrelated.sorted(),"initialCosts":initial.costs,
                "materialThreshold":"greater than one actual glyph-em squared; small contacts remain allowed",
                "requestScales":NativeCohortFitPlanner.scales,"maxRequests":7,"combinationSlice":8,
                "wallTimeAuthority":"audit-only; deterministic requests/combinations/pixels are authoritative","attempts":attempts,"seconds":Date().timeIntervalSince(start),
                "sourceRGBTruth":"authenticated original source and effective erasure via explicit typed quality permission",
                "historicalSubstitution":false,"sourcePacketsModified":false,"wholeQualityAccepted":false]
            receipt.merge(extra){_,new in new};a["sourceObstructionRecovery"]=receipt
            return L(image:layer.image,expectedItems:layer.expectedItems,paintedItems:layer.paintedItems,complete:layer.complete,audit:a)
        }
        for scale in NativeCohortFitPlanner.scales.dropFirst() {
            try Task.checkCancellation()
            var proposed=items,changed=false,readable=true
            for f in affectedFamilies {
                for i in f.indices {
                    let old=items[i],font=old.fontSize*CGFloat(scale)
                    guard font*outputScale>=CGFloat(minimumFont)else{readable=false;continue}
                    proposed[i] = .init(id:old.id,text:old.text,frame:old.frame,fontSize:font,
                        lineHeight:old.lineHeight*CGFloat(scale),chosenFill:old.chosenFill,colorAuthority:old.colorAuthority)
                    changed=true
                }
            }
            guard changed,readable else{continue}
            do {
                let candidate=try $current.withValue(session){try render(proposed)}
                guard candidate.complete,candidate.paintedItems==items.count,let actual=completed(candidate.image),actual.count==items.count,
                    palette(candidate)==palette(incumbent),palette(incumbent) != nil else {
                    attempts.append(["scale":scale,"status":"actual-tuple-or-palette-unavailable"]);continue
                }
                let beforeRows=Dictionary(uniqueKeysWithValues:(incumbent.audit["rawNativeItems"]as?[[String:Any]] ?? []).compactMap {r in (r["id"]as?String).map{($0,r)}})
                let afterRows=Dictionary(uniqueKeysWithValues:(candidate.audit["rawNativeItems"]as?[[String:Any]] ?? []).compactMap {r in (r["id"]as?String).map{($0,r)}})
                let unrelatedCutsPreserved=unrelated.allSatisfy {id in
                    guard let a=beforeRows[id],let b=afterRows[id],let aq=a["horizontalFlowQuality"]as?[String:Any],
                        let bq=b["horizontalFlowQuality"]as?[String:Any],let ac=aq["wordCuts"]as?Int,let bc=bq["wordCuts"]as?Int else{return false}
                    return bc<=ac && a["interiorWordRetainedFace"]as?String==b["interiorWordRetainedFace"]as?String
                }
                guard unrelatedCutsPreserved else {attempts.append(["scale":scale,"status":"unrelated-wordcut-or-face-regression"]);continue}
                let checked=session.admissible(actual,page:page)
                attempts.append(["scale":scale,"status":checked.0 ? "native-and-source-quality-admitted":"source-quality-rejected","evidence":checked.1])
                try Task.checkCancellation()
                if checked.0 {return result(candidate,"source-obstruction-recovered",["selectedScale":scale,"selectedFonts":Dictionary(uniqueKeysWithValues:proposed.map{($0.id,Double($0.fontSize))}),"selectedLineHeights":Dictionary(uniqueKeysWithValues:proposed.map{($0.id,Double($0.lineHeight))}),"evidence":checked.1])}
            } catch is CancellationError {throw CancellationError()}
            catch {attempts.append(["scale":scale,"status":"native-candidate-rejected-incumbent-preserved","error":String(reflecting:error)])}
        }
        try Task.checkCancellation()
        return result(incumbent,"incumbent-retained-no-proved-quality-improvement")
    }
}
