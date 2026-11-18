import CoreGraphics
import CoreText
import Foundation

/// Joint source-width planning with actual completed native tuple validation.
/// Width alternatives are real native glyphs at the incumbent font and pitch.
enum NativeJointSourceWidthPacking {
    typealias P = NativeAOTTranslationPageComposer.TranslatedFillPrimitive
    typealias L = NativeAOTTranslationPageComposer.TextLayer
    typealias N = NativeFinalTextPaintAdmission
    typealias Tuple = (fills:[P],audit:[[String:Any]])
    typealias Make = (String,CGFloat,CGFloat) throws -> (P,[String:Any])?
    enum Failure: Error {case invalid(String)}
    static var enabled:Bool {ProcessInfo.processInfo.environment["AIDOKU_EXPERIMENT_JOINT_SOURCE_WIDTH"] != "0"}
    final class Scope: @unchecked Sendable {
        struct Entry {let image:CGImage;let owners:Int;let cost:Int;let apply:(L)throws->L}
        var entries:[ObjectIdentifier:Entry]=[:]
        var pixels=0
        func record(_ layer:L,carrierPixels:Int=0,apply:@escaping(L)throws->L) {
            let cost=layer.image.width*layer.image.height+carrierPixels
            let key=ObjectIdentifier(layer.image)
            if let prior=entries.removeValue(forKey:key) {pixels-=prior.cost}
            // A partial recovery cannot be the selected complete-page output.
            // Release its captured closures/images before charging the full tuple.
            for id in Array(entries.keys) where entries[id]!.owners<layer.expectedItems {
                pixels-=entries.removeValue(forKey:id)!.cost
            }
            guard carrierPixels>=0,entries.count<16,cost<=64_000_000,pixels<=64_000_000-cost else{return}
            pixels+=cost
            entries[key]=Entry(image:layer.image,owners:layer.expectedItems,cost:cost,apply:apply)
        }
    }
    @TaskLocal static var scope:Scope?
    static func afterSelection(_ operation:()throws->L)throws->L {
        guard enabled else{return try operation()}
        let capture=Scope()
        let chosen=try $scope.withValue(capture,operation:operation)
        guard let entry=capture.entries[ObjectIdentifier(chosen.image)],entry.image === chosen.image else {
            return annotate(chosen,["status":"no-exact-selected-prephysical-tuple","changedOwners":[],"captureEntries":capture.entries.count,"capturePixels":capture.pixels,"selectedOwners":chosen.expectedItems,"capturedOwners":capture.entries.values.map(\.owners)])
        }
        do {return try entry.apply(chosen)}
        catch is CancellationError {throw CancellationError()}
        catch {
            try Task.checkCancellation()
            return annotate(chosen,["status":"whole-page-incumbent-retained","changedOwners":[],"reason":String(reflecting:error)])
        }
    }
    static func annotate(_ layer:L,_ detail:[String:Any])->L {
        var audit=layer.audit;audit["jointSourceWidthPacking"]=detail
        return .init(image:layer.image,expectedItems:layer.expectedItems,paintedItems:layer.paintedItems,complete:layer.complete,audit:audit)
    }
    static func json(_ value:Any)throws->Data {try JSONSerialization.data(withJSONObject:["v":value],options:.sortedKeys)}
    /// Compare REAL completed typed carriers; no dependency on debug witnesses.
    static func verifyPinnedPeers(before:Tuple,after:Tuple,beforeLayer:L,afterLayer:L,changed:Set<String>)throws->[String:Any] {
        func bound(_ tuple:Tuple,_ layer:L)throws {
            let ids=tuple.fills.compactMap(\.ownerID)
            guard layer.complete,ids.count==tuple.fills.count,Set(ids).count==ids.count,
                  ids.count==tuple.audit.count,ids.count==layer.expectedItems,ids.count==layer.paintedItems,
                  let rows=layer.audit["finalPaintAdmission"] as? [[String:Any]],
                  try json(rows)==json(tuple.audit),
                  tuple.audit.indices.allSatisfy({tuple.audit[$0]["owner"] as? String==ids[$0]}) else {
                throw Failure.invalid("typed-completed-paint-binding")
            }
        }
        try bound(before,beforeLayer);try bound(after,afterLayer)
        let oldIDs=before.fills.compactMap(\.ownerID),newIDs=after.fills.compactMap(\.ownerID)
        guard oldIDs==newIDs,changed.isSubset(of:Set(oldIDs)) else{throw Failure.invalid("typed-peer-inventory")}
        var pinned:[String]=[]
        let stateKey=NativeBalloonPlacement.RetainedState.auditKey
        for i in oldIDs.indices {
            guard try json(before.audit[i][stateKey] ?? NSNull())==json(after.audit[i][stateKey] ?? NSNull()) else {
                throw Failure.invalid("typed-full-Snapshot:"+oldIDs[i])
            }
            if changed.contains(oldIDs[i]) {continue}
            let a=before.fills[i],b=after.fills[i]
            guard NativeBodySourceAnchorRecovery.carrierPreserved(a,b,shift:.zero),
                  a.frame==b.frame,a.image.width==b.image.width,a.image.height==b.image.height,
                  try NativeMandatoryDisplayStroke.rgba(a.image)==NativeMandatoryDisplayStroke.rgba(b.image) else {
                throw Failure.invalid("typed-pinned-peer-frame-RGBA-carrier:"+oldIDs[i])
            }
            let x=try N.retainedFootprint(a),y=try N.retainedFootprint(b)
            guard x.bounds==y.bounds,x.pixels==y.pixels,x.runs.count==y.runs.count,
                  zip(x.runs,y.runs).allSatisfy({$0.y==$1.y && $0.left==$1.left && $0.right==$1.right}) else {
                throw Failure.invalid("typed-pinned-effect-support:"+oldIDs[i])
            }
            pinned.append(oldIDs[i])
        }
        // Extra evidence only: absent PNG receipts never skip mandatory checks.
        let wa=(beforeLayer.audit["finalGlyphWitnesses"] as? [String:Any])?["owners"] as? [[String:Any]]
        let wb=(afterLayer.audit["finalGlyphWitnesses"] as? [String:Any])?["owners"] as? [[String:Any]]
        var pngChecks=0
        if let wa,let wb {
            guard wa.count==oldIDs.count,wb.count==oldIDs.count else{throw Failure.invalid("optional-PNG-inventory")}
            for owner in pinned {
                guard let a=wa.first(where:{$0["ownerID"] as? String==owner}),
                      let b=wb.first(where:{$0["ownerID"] as? String==owner}),try json(a)==json(b) else {
                    throw Failure.invalid("optional-PNG-pinned-peer:"+owner)
                }
                pngChecks+=1
            }
        }
        let page=CGRect(x:0,y:0,width:beforeLayer.image.width,height:beforeLayer.image.height)
        var trades:[[String:Any]]=[]
        for i in oldIDs.indices where changed.contains(oldIDs[i]) {
            guard let guide=before.fills[i].textPlacementGuide else{continue}
            let source=guide.rect(in:page),old=try N.retainedFootprint(before.fills[i]),new=try N.retainedFootprint(after.fills[i])
            let a=old.bounds.midX-source.midX,b=new.bounds.midX-source.midX,font=before.fills[i].fontOutputPixels
            trades.append(["owner":oldIDs[i],"beforeLateralDriftPixels":a,"afterLateralDriftPixels":b,
                "beforeSquaredEm":pow(Double(a/font),2),"afterSquaredEm":pow(Double(b/font),2),
                "individualDistanceIncreased":abs(b)>abs(a)+1e-7])
        }
        return ["authority":"actual-typed-completed-paint-tuple","actualPostphysicalSourceTrades":trades,
            "sourceCostPolicy":"group trade explicitly allowed; no per-owner nonincrease claim","pinnedOwners":pinned,
            "typedPeerChecks":pinned.count,"fullSnapshotChecks":oldIDs.count,
            "actualFramesRGBAAndCarriersVerified":true,"debugCaptureRequired":false,
            "optionalPNGChecks":pngChecks,"phase":"plain-selected-joint-before-round-before-new-cohort-receipts"]
    }
    struct SearchBudget {
        var factoryCalls=128
        var proofChecks=128
        var admissions=64
        var valid:Bool {(0...128).contains(factoryCalls) && (0...128).contains(proofChecks) && (0...64).contains(admissions)}
    }
    static func number(_ value:Any?)->Double? {
        guard let value,let n=value as? NSNumber,CFGetTypeID(n) != CFBooleanGetTypeID() else{return nil}
        let d=n.doubleValue
        return d.isFinite ? d:nil
    }
    static func validatedRanges(_ row:[String:Any],owner:String,text:String)throws->[NSRange] {
        guard row["id"] as? String==owner,!text.isEmpty,
              row["sourceUTF16"] as? Int==text.utf16.count,row["visibleUTF16"] as? Int==text.utf16.count,
              let pairs=row["lineRangesUTF16"] as? [[Int]],!pairs.isEmpty,pairs.count<=4096,
              let lines=row["actualCoreTextLineStrings"] as? [String],lines.count==pairs.count else {
            throw Failure.invalid("row-inventory:"+owner)
        }
        // Native validator checks pair shape/bounds using subtraction before
        // any NSRange/NSString use. Translate errors, never Swift integer traps.
        do {_ = try NativeAOTRawTextPainter.capacitySegmentation(text:text,ranges:pairs,lines:lines)}
        catch is CancellationError {throw CancellationError()}
        catch {throw Failure.invalid("native-row-ranges:"+owner)}
        let ranges=pairs.map{NSRange(location:$0[0],length:$0[1])}
        guard NativeBalloonReadabilityReflow.validOwnership(text,ranges) else {
            throw Failure.invalid("native-grapheme-ownership:"+owner)
        }
        return ranges
    }
    static func rect(_ b:CGRect)->[CGFloat] {[b.minX,b.minY,b.width,b.height]}
    struct Shape {let fill:P;let row:[String:Any];let support:N.Footprint;let rows:Int;let width:CGFloat}
    struct Trial {let indices:[Int];let origins:[CGFloat];let rank:Double;var pinned:Set<Int>=[]}
    static func sourceRuns(_ fills:[P],page:CGRect,supports:[N.Footprint]?=nil)->[[Int]] {
        // Full declared packet group is considered first. Splitting changes no
        // packet/group ID; complete-group native anchor validation still applies.
        let groups=Dictionary(grouping:fills.indices.filter{fills[$0].sourceClusterAlignment != nil},by:{fills[$0].sourceClusterAlignment!.groupID})
        var runs:[[Int]]=[]
        for group in groups.keys.sorted() {
            let members=groups[group]!
            guard members.count>=2,members.count<=16,members.allSatisfy({i in
                let f=fills[i]
                return f.sourceClusterAlignment?.axis == .top && f.sourceClusterAlignment?.anchorsToSourceStart == true &&
                    f.textPlacementGuide?.valid == true && f.textExpansionPolicy?.valid == true &&
                    f.textExpansionPolicy?.insideBalloon == false && f.balloonPlacement == nil && !f.hasFinalEffects
            }) else{continue}
            let sorted=members.sorted {fills[$0].textPlacementGuide!.rect(in:page).midX < fills[$1].textPlacementGuide!.rect(in:page).midX}
            var run:[Int]=[]
            for i in sorted {
                if let last=run.last {
                    let a=fills[last].textPlacementGuide!.rect(in:page),b=fills[i].textPlacementGuide!.rect(in:page)
                    let gap=b.minX-a.maxX,unit=max(fills[last].fontOutputPixels,fills[i].fontOutputPixels)
                    let overlap=min(a.maxY,b.maxY)-max(a.minY,b.minY)
                    let paintedGap=supports.map {$0[i].bounds.minX-$0[last].bounds.maxX}
                    let actualCoupled=paintedGap.map {$0<=ceil(unit*0.35)} ?? false
                    if gap>4*unit && !actualCoupled || overlap<=0 {runs.append(run);run=[]}
                }
                run.append(i)
            }
            if !run.isEmpty {runs.append(run)}
        }
        return runs
    }
    static func refine(layer:L,baseline:Tuple,texts:[String:String],page:CGRect,restored:CGImage,budget:SearchBudget = .init(),recoveredSelection:Bool=false,make:Make)throws
        ->(layer:L,baseline:Tuple,changed:Set<String>) {
        try Task.checkCancellation()
        let ids=baseline.fills.compactMap(\.ownerID)
        guard budget.valid,baseline.fills.count<=256,page==CGRect(x:0,y:0,width:restored.width,height:restored.height),
              baseline.fills.allSatisfy({$0.fontOutputPixels.isFinite && $0.fontOutputPixels>0 && $0.fontOutputPixels<=4096 &&
                $0.frame==($0.frame.integral) && page.contains($0.frame) &&
                $0.frame.width==CGFloat($0.image.width) && $0.frame.height==CGFloat($0.image.height)}),
              Set(texts.keys)==Set(ids),ids.allSatisfy({!$0.isEmpty}),ids.count==baseline.fills.count,ids.count==baseline.audit.count,Set(ids).count==ids.count,
              let rows=layer.audit["rawNativeItems"] as? [[String:Any]],rows.count==ids.count else{throw Failure.invalid("inventory")}
        // Typed fills/audits/raw rows share the producer's stable owner order.
        // Source runs sort INDICES geometrically; they never reorder these arrays.
        guard baseline.audit.compactMap({$0["owner"] as? String})==ids else{throw Failure.invalid("typed-owner-order")}
        guard rows.compactMap({$0["id"] as? String})==ids else{throw Failure.invalid("raw-owner-order")}
        var carrierPixels=0
        for fill in baseline.fills {
            guard fill.image.height>0,fill.image.width>0,fill.image.width<=4_000_000/fill.image.height else{throw Failure.invalid("owner-raster-budget")}
            let pixels=fill.image.width*fill.image.height
            guard carrierPixels<=16_000_000-pixels else{throw Failure.invalid("page-carrier-budget")}
            carrierPixels+=pixels
        }
        // Validate EVERY raw owner before filtering eligibility or making a factory call.
        for (i,id) in ids.enumerated() {
            _ = try validatedRanges(rows[i],owner:id,text:texts[id]!)
            guard let pitch=number(rows[i]["retainedLinePitchOutputPixels"]),pitch>0,
                  let font=number(rows[i]["fontSize"]),font>0,
                  number(rows[i]["appliedTrackingPixels"]) != nil else {
                throw Failure.invalid("finite-typography:"+id)
            }
        }
        let original=try baseline.fills.map{try N.retainedFootprint($0)}
        let runs=sourceRuns(baseline.fills,page:page,supports:original)
        var current=baseline,currentLayer=layer,changed=Set<String>(),outcomes:[[String:Any]]=[],admissions=0,shapeAttempts:[String:Int]=[:]
        let originalBoundary=NativeSourceCohortCenterBalance.currentBoundaryContext
        var baselineExposure:[Int:Int]=[:]
        var factoryCalls=0,proofChecks=0,stoppedByBudget=false
        runSearch: for run in runs {
            try Task.checkCancellation()
            if admissions>=budget.admissions || factoryCalls>=budget.factoryCalls || proofChecks>=budget.proofChecks {
                stoppedByBudget=true
                outcomes.append(["owners":run.map{ids[$0]},"status":"search-budget-exhausted-before-run"])
                break
            }
            // Snapshot the CURRENT committed transaction before this run.
            // Original alpha below is immutable source evidence only, never a
            // pin/metadata target for owners committed by an earlier run.
            let currentSupports=try current.fills.map{try N.retainedFootprint($0)}
            guard let currentRows=currentLayer.audit["rawNativeItems"] as? [[String:Any]],
                  currentRows.compactMap({$0["id"] as? String})==ids,
                  current.fills.compactMap(\.ownerID)==ids,
                  current.audit.compactMap({$0["owner"] as? String})==ids else{throw Failure.invalid("current-owner-order")}
            let records=Dictionary(uniqueKeysWithValues:currentRows.map{($0["id"] as! String,$0)})
            let anchors=try N.verifiedRetainedClusterAnchors(current.fills,footprints:currentSupports,audit:current.audit,page:page)
            guard run.count>=2,run.count<=16 else{outcomes.append(["owners":run.map{ids[$0]},"status":"pinned-singleton-or-run-budget"]);continue}
            let sources=run.map{current.fills[$0].textPlacementGuide!.rect(in:page)}
            let oldCost=zip(run,sources).reduce(0.0){s,p in s+pow(Double((currentSupports[p.0].bounds.midX-p.1.midX)/current.fills[p.0].fontOutputPixels),2)}
            guard oldCost>1 else{outcomes.append(["owners":run.map{ids[$0]},"status":"no-material-lateral-debt","cost":oldCost]);continue}
            var shapes:[[Shape]]=[],generation:[[String:Any]]=[]
            for (k,i) in run.enumerated() {
                let old=current.fills[i],id=ids[i],source=sources[k]
                guard let row=records[id],let text=texts[id],let pitch=number(row["retainedLinePitchOutputPixels"]),pitch>0,let face=row["interiorWordRetainedFace"] as? String else{throw Failure.invalid("row-binding")}
                let oldRanges=try validatedRanges(row,owner:id,text:text)
                let ranges=row["lineRangesUTF16"] as! [[Int]]
                let capacity=NativeTextExpansionPolicy.rect(old.textExpansionPolicy!.allowedRectNormalized,page:page)
                let availableHeight=max(currentSupports[i].bounds.height,
                    min(page.maxY-1,capacity.maxY)-currentSupports[i].bounds.minY)
                let rowQuotient=floor(availableHeight/CGFloat(pitch))
                guard rowQuotient.isFinite,rowQuotient>=0,rowQuotient<=4095 else{throw Failure.invalid("bounded-row-budget")}
                let maximumRows=max(ranges.count,Int(rowQuotient)+1)
                let oldTracking=number(row["appliedTrackingPixels"])!
                let descriptor=NativeBalloonReadabilityReflow.Descriptor(text:text,ranges:oldRanges)
                let font=CTFontCreateWithName(face as CFString,old.fontOutputPixels,nil)
                let attributed=NSAttributedString(string:text,attributes:[.init(kCTFontAttributeName as String):font])
                let maxWidth=currentSupports[i].bounds.width
                // Same measured lexical endpoints used by fixed-font recovery;
                // reserve narrow alternatives rather than selecting only widest.
                let lexicalWidths=NativeRenderWrapQuality.lexicalLineWidths(attributed,minimumWidth:old.fontOutputPixels,
                    maximumWidth:maxWidth,limit:32).sorted()
                // Spend the same seven raster slots on native lexical plans
                // that can fit the retained pitch/height, rather than mostly
                // sampling widths already known to require too many rows.
                let effectHeight=currentSupports[i].bounds.height-CGFloat(ranges.count-1)*CGFloat(pitch)
                let fittingQuotient=floor(max(0,availableHeight-effectHeight)/CGFloat(pitch))
                guard effectHeight.isFinite,fittingQuotient.isFinite,(0...4095).contains(fittingQuotient) else {
                    throw Failure.invalid("finite-effect-row-budget")
                }
                let fittingRows=max(ranges.count,Int(fittingQuotient)+1)
                var widths:[CGFloat]=[]
                if recoveredSelection {
                for lexical in lexicalWidths {
                    try Task.checkCancellation()
                    let width=ceil(lexical)+1
                    do {
                        let plan=try NativeWholeWordWrap.layout(text:text,font:font,size:old.fontOutputPixels,
                            width:width,tracking:CGFloat(oldTracking),necessaryCJK:true)
                        if plan.completeOwnership,plan.unresolvedGlyphRanges.isEmpty,
                           plan.requiredWidth<=width+0.01,plan.rows.count<=fittingRows,
                           NativeBalloonReadabilityReflow.qualityAllows(descriptor,plan.rows.map(\.ownedRange)) {
                            widths.append(lexical)
                        }
                    } catch is CancellationError {throw CancellationError()}
                    catch {continue}
                }
                } else {widths=lexicalWidths}
                generation.append(["owner":id,"nativeLexicalWidthPreflights":lexicalWidths.count,
                    "heightAndQualityEligibleWidths":widths,"maxEffectHeightRows":fittingRows])
                var chosen:[CGFloat]=[]
                let left=k>0 ? (sources[k-1].midX+source.midX)/2:source.midX-(sources[k+1].midX-source.midX)/2
                let right=k+1<sources.count ? (sources[k+1].midX+source.midX)/2:source.midX+(source.midX-sources[k-1].midX)/2
                let sourceCorridor=max(old.fontOutputPixels,min(maxWidth,max(source.width,right-left-old.fontOutputPixels*0.35)))
                chosen.append(ceil(sourceCorridor))
                if !widths.isEmpty {
                    for n in 0..<6 {
                        let index=Int((Double(n)*Double(widths.count-1)/5).rounded())
                        let w=ceil(widths[index])+1
                        if !chosen.contains(w){chosen.append(w)}
                    }
                }
                var alternatives=[Shape(fill:old,row:row,support:currentSupports[i],rows:ranges.count,width:maxWidth)]
                var seen=Set([String(describing:ranges)])
                for width in chosen.prefix(7) {
                    try Task.checkCancellation()
                    if factoryCalls>=budget.factoryCalls {
                        stoppedByBudget=true;outcomes.append(["owners":run.map{ids[$0]},"status":"factory-budget-exhausted"]);break runSearch
                    }
                    shapeAttempts[id,default:1]+=1;factoryCalls+=1
                    do {
                        guard let (painted,newRow)=try make(id,width,CGFloat(pitch)) else{continue}
                        let newRanges=try validatedRanges(newRow,owner:id,text:text)
                        let rr=newRow["lineRangesUTF16"] as! [[Int]]
                        guard newRow["interiorWordRetainedFace"] as? String==face,
                              let newPitch=number(newRow["retainedLinePitchOutputPixels"]),newPitch>0,abs(newPitch-pitch)<1e-7,
                              let newTracking=number(newRow["appliedTrackingPixels"]),newTracking==oldTracking,
                              number(newRow["fontSize"])==number(row["fontSize"]),
                              painted.fontOutputPixels==old.fontOutputPixels,
                              NativeBalloonReadabilityReflow.qualityAllows(descriptor,newRanges) else{
                            generation.append(["owner":id,"width":width,"reason":"typography-or-native-quality","newPitch":newRow["retainedLinePitchOutputPixels"] ?? NSNull(),"oldPitch":pitch,"newRows":rr.count]);continue
                        }
                        if let oldOrphans=(row["horizontalFlowQuality"] as? [String:Any])?["softOrphans"] as? Int {
                            guard let newOrphans=(newRow["horizontalFlowQuality"] as? [String:Any])?["softOrphans"] as? Int,
                                  newOrphans<=oldOrphans else{continue}
                        }
                        let signature=String(describing:rr)
                        guard seen.insert(signature).inserted else{continue}
                        guard painted.frame==painted.frame.integral,page.contains(painted.frame),
                              painted.frame.width==CGFloat(painted.image.width),painted.frame.height==CGFloat(painted.image.height),
                              painted.image.height>0,painted.image.width>0,painted.image.width<=4_000_000/painted.image.height else {
                            throw Failure.invalid("candidate-finite-raster-geometry")
                        }
                        var fill=old;fill.image=painted.image;fill.frame=painted.frame
                        fill.sourceStyle=try NativeSourceStylePaint.transferringDeferredContour(from:old.sourceStyle,shaped:painted.sourceStyle)
                        let support=try N.retainedFootprint(fill)
                        guard support.bounds.width<=maxWidth,support.bounds.height<=availableHeight,
                              rr.count<=maximumRows,
                              let a=try NativeBalloonReadabilityReflow.exteriorPaletteReceipt(old,restored:restored),
                              let b=try NativeBalloonReadabilityReflow.exteriorPaletteReceipt(fill,restored:restored),try json(a)==json(b) else{
                            generation.append(["owner":id,"width":width,"reason":"support-height-row-budget-or-palette","support":rect(support.bounds),"heightLimit":availableHeight,"newRows":rr.count,"maximumRows":maximumRows]);continue
                        }
                        alternatives.append(.init(fill:fill,row:newRow,support:support,rows:rr.count,width:width))
                    } catch is CancellationError {throw CancellationError()}
                    catch {generation.append(["owner":id,"width":width,"reason":String(reflecting:error)])}
                }
                shapes.append(alternatives)
                generation.append(["owner":id,"attempts":shapeAttempts[id] ?? 1,"shapes":alternatives.map{["width":$0.width,"bounds":rect($0.support.bounds),"rows":$0.rows] as [String:Any]}])
            }
            // <=8^8 cheap combinations are NOT allowed: bounded beam before
            // native admission, deterministic source cost + modest row cost.
            var combinations:[[Int]]=[[]]
            for options in shapes {
                try Task.checkCancellation()
                var next:[(indices:[Int],score:Double)]=[]
                for (n,prefix) in combinations.enumerated() {
                    if n%64==0 {try Task.checkCancellation()}
                    let prior=prefix.enumerated().reduce(0.0){$0+Double(shapes[$1.offset][$1.element].support.bounds.width)}
                    for index in options.indices {next.append((prefix+[index],prior+Double(options[index].support.bounds.width)))}
                }
                next.sort {$0.score == $1.score ? $0.indices.lexicographicallyPrecedes($1.indices):$0.score<$1.score}
                try Task.checkCancellation()
                combinations=next.prefix(4096).map(\.indices)
            }
            var trials:[Trial]=[]
            for (combinationIndex,indices) in combinations.enumerated() {
                if combinationIndex%64==0 {try Task.checkCancellation()}
                var opts:[NativeSourceCohortPacking.Option]=[],valid=true
                for k in run.indices {
                    let i=run[k],f=shapes[k][indices[k]],source=sources[k],capacity=NativeTextExpansionPolicy.rect(current.fills[i].textExpansionPolicy!.allowedRectNormalized,page:page)
                    let preferred=source.midX-f.support.bounds.width/2
                    var lower=max(1,capacity.minX),upper=min(page.maxX-1,capacity.maxX)-f.support.bounds.width
                    if indices[k]==0,current.fills[i].textPlacementGuide?.horizontal == .center {
                        let delta=currentSupports[i].bounds.midX-source.midX,unit=current.fills[i].fontOutputPixels
                        if delta < -unit*(recoveredSelection ? 2.5:0.25) {upper=min(upper,floor(source.midX-f.support.bounds.width/2))}
                        if delta > unit*(recoveredSelection ? 2.5:0.25) {lower=max(lower,ceil(source.midX-f.support.bounds.width/2))}
                    }
                    let option=NativeSourceCohortPacking.Option(index:indices[k],extent:f.support.bounds.width,
                        lower:lower,upper:upper,
                        preferred:preferred,unit:current.fills[i].fontOutputPixels,cost:0)
                    // Top-source anchor, not Euclidean vertical-source midpoint.
                    let incumbentDebt=abs(currentSupports[i].bounds.midX-source.midX)/current.fills[i].fontOutputPixels
                    guard let bounded=NativeSourceCohortPacking.sourceNearOption(option,sourceCentre:source.midX,anchorDelta:0,
                        maximumMotionEm:max(2.5,incumbentDebt)) else{valid=false;break}
                    opts.append(bounded)
                }
                guard valid else{continue}
                let gaps=run.dropFirst().enumerated().map{k,i in max(ceil(min(current.fills[run[k]].fontOutputPixels,current.fills[i].fontOutputPixels)*0.12)+(recoveredSelection ? 0:1),
                    min(max(0,currentSupports[i].bounds.minX-currentSupports[run[k]].bounds.maxX),
                        ceil(min(current.fills[run[k]].fontOutputPixels,current.fills[i].fontOutputPixels)*0.35)))}
                guard let origins=NativeSourceCohortPacking.quadraticOrigins(opts,gaps:gaps) else{continue}
                let cost=run.indices.reduce(0.0){s,k in s+pow(Double((origins[k]+opts[k].extent/2-sources[k].midX)/opts[k].unit),2)}
                guard cost<oldCost-1 else{continue}
                let extra=run.indices.reduce(0){s,k in s+max(0,shapes[k][indices[k]].rows-shapes[k][0].rows)}
                trials.append(.init(indices:indices,origins:origins,rank:cost+Double(extra)*0.25))
            }
            trials.sort{ $0.rank == $1.rank ? $0.indices.lexicographicallyPrecedes($1.indices):$0.rank<$1.rank }
            var attempts:[[String:Any]]=[],selected=false
            let currentRGBA=try current.fills.map{try NativeMandatoryDisplayStroke.rgba($0.image)}
            var queue=Array(trials.prefix(max(0,budget.proofChecks-proofChecks))),queueIndex=0
            while queueIndex<queue.count {
                let trial=queue[queueIndex];queueIndex+=1
                try Task.checkCancellation()
                if admissions>=budget.admissions || proofChecks>=budget.proofChecks {
                    stoppedByBudget=true;outcomes.append(["owners":run.map{ids[$0]},"status":"admission-or-proof-budget-exhausted"]);break runSearch
                }
                proofChecks+=1
                var stage="assigned-domain",vetoUnchanged:Int?
                var measurement:[String:Any]=["shapes":trial.indices,"origins":trial.origins,"rank":trial.rank,"pinnedIndices":trial.pinned.sorted()]
                do {
                    var trialFills=current.fills
                    var fixed=Dictionary(uniqueKeysWithValues:ids.indices.map{(ids[$0],currentSupports[$0].bounds.origin)})
                    var expected=currentSupports
                    for k in run.indices {
                        let i=run[k],shape=shapes[k][trial.indices[k]],f=current.fills[i]
                        let origin=CGPoint(x:trial.origins[k],y:currentSupports[i].bounds.minY)
                        let projected=shape.support.translated(.init(x:origin.x-shape.support.bounds.minX,y:origin.y-shape.support.bounds.minY))
                        guard projected.runs.allSatisfy({r in let box=CGRect(x:r.left,y:r.y,width:r.right-r.left,height:1);return (f.textExpansionPolicy?.allows(box,page:page) ?? false) && (f.placementDomain?(box) ?? true)}) else{throw Failure.invalid("assigned-alpha-domain:\(ids[i])")}
                        stage="original-boundary"
                        guard let context=originalBoundary else{throw Failure.invalid("source-context-unknown")}
                        let gate=context.qualityShapeClearance(incumbent:baseline.fills[i],before:original[i],
                            after:projected,page:page,minimumChannelContrast:32)
                        var boundaryRecord=gate.audit
                        var sourceAllowed=gate.allowed==true
                        if recoveredSelection,!sourceAllowed,f.textExpansionPolicy?.insideBalloon==false,
                           gate.allowed==false,
                           gate.audit["status"] as? String=="new-alpha-preserved-source-boundary-veto",
                           gate.audit["observationComplete"] as? Bool==true {
                            // Outside-body quality trade only. A known component
                            // veto or incomplete source evidence never enters here.
                            let beforeExposure:Int?
                            if let cached=baselineExposure[i] {beforeExposure=cached}
                            else {
                                beforeExposure=context.obstructionExposure(original[i],page:page).pixels
                                if let measured=beforeExposure {baselineExposure[i]=measured}
                            }
                            let afterExposure=context.obstructionExposure(projected,page:page)
                            let contact=gate.audit["adverseNewAlphaPixels"] as? Int
                            let linearEm=Int(ceil(f.fontOutputPixels))
                            if let old=beforeExposure,let new=afterExposure.pixels,let contact {
                                let small=contact<=linearEm && new<=old
                                let reduction=new<old
                                let materialLateralDebt=run.contains {j in abs(original[j].bounds.midX-baseline.fills[j].textPlacementGuide!.rect(in:page).midX)>baseline.fills[j].fontOutputPixels*2.5}
                                let glyphArea=Double(f.fontOutputPixels*f.fontOutputPixels)
                                let boundedLocalTrade=materialLateralDebt && Double(contact)<=glyphArea*0.5 && Double(new-old)<=glyphArea*0.2
                                sourceAllowed=small || reduction || boundedLocalTrade
                                boundaryRecord["boundedLocalPlacementTrade"]=boundedLocalTrade
                                boundaryRecord["maxNewContactGlyphEmSquared"]=0.5
                                boundaryRecord["maxExposureGrowthGlyphEmSquared"]=0.2
                                boundaryRecord["outsideQualityExposureBefore"]=old
                                boundaryRecord["outsideQualityExposureAfter"]=new
                                boundaryRecord["outsideQualityNewContactPixels"]=contact
                                boundaryRecord["outsideQualityLinearEmPixels"]=linearEm
                                boundaryRecord["outsideQualityTradeAccepted"]=sourceAllowed
                                boundaryRecord["outsideQualityTradePolicy"]="complete observed outside-body exposure: no-growth plus <=1em new contact, OR strict absolute exposure reduction, OR bounded local <=0.5em² contact and <=0.2em² exposure growth only with material source drift; complete-run exposure must decrease and individual source position must not regress >0.25em; known component veto never waived"
                                boundaryRecord["physicalContainmentCertified"]=false
                            }
                            boundaryRecord["outsideQualityExposureMeasurement"]=afterExposure.audit
                        }
                        measurement[ids[i]+"Boundary"]=boundaryRecord
                        guard sourceAllowed else{
                            vetoUnchanged=k
                            throw Failure.invalid("original-boundary:\(ids[i]):\(gate.audit["status"] ?? "unknown")")
                        }
                        if let risk=N.retainedSourceRiskGate,risk.evaluate(original[i],projected) != true{throw Failure.invalid("retained-source-risk")}
                        trialFills[i]=shape.fill;fixed[ids[i]]=origin;expected[i]=projected
                    }
                    if recoveredSelection {
                    stage="source-nearness-and-total-exposure-nonregression"
                    guard let context=originalBoundary else{throw Failure.invalid("source-context-unknown")}
                    var beforeExposure=0,afterExposure=0
                    for i in run {
                        guard let a=context.obstructionExposure(original[i],page:page).pixels,
                              let b=context.obstructionExposure(expected[i],page:page).pixels else{throw Failure.invalid("complete-run-exposure-unknown")}
                        beforeExposure+=a;afterExposure+=b
                        let reference=baseline.fills[i].textPlacementGuide!.rect(in:page)
                        guard abs(expected[i].bounds.midX-reference.midX)<=abs(original[i].bounds.midX-reference.midX)+baseline.fills[i].fontOutputPixels*0.25 else{throw Failure.invalid("individual-source-position-regression:"+ids[i])}
                    }
                    guard afterExposure<beforeExposure else{throw Failure.invalid("complete-run-exposure-not-reduced")}
                    measurement["sourceExposureBefore"]=beforeExposure;measurement["sourceExposureAfter"]=afterExposure
                    }
                    stage="complete-native-fixed-origin-admission";admissions+=1
                    var admitted=try N.place(trialFills,page:page,fixedOrigins:fixed,retainedClusterAnchors:anchors)
                    guard admitted.fills.compactMap(\.ownerID)==ids,
                          admitted.audit.compactMap({$0["owner"] as? String})==ids else{throw Failure.invalid("admitted-owner-order")}
                    let supports=try admitted.fills.map{try N.retainedFootprint($0)}
                    for i in ids.indices {
                        var normalized=admitted.fills[i]
                        normalized.image=trialFills[i].image;normalized.frame=trialFills[i].frame
                        guard NativeBodySourceAnchorRecovery.carrierPreserved(trialFills[i],normalized,shift:.zero) else {
                            throw Failure.invalid("native-carrier-drift")
                        }
                        guard supports[i].bounds==expected[i].bounds,supports[i].pixels==expected[i].pixels,
                              supports[i].runs.count==expected[i].runs.count,
                              zip(supports[i].runs,expected[i].runs).allSatisfy({$0.y==$1.y && $0.left==$1.left && $0.right==$1.right}),
                              admitted.fills[i].balloonTargetRelaxed==current.fills[i].balloonTargetRelaxed,
                              admitted.audit[i]["balloonBodyPlaced"] as? Bool==current.audit[i]["balloonBodyPlaced"] as? Bool else{throw Failure.invalid("actual-support-or-state")}
                        let a=trialFills[i],b=admitted.fills[i]
                        let inputSupport=run.contains(i) ? try N.retainedFootprint(a):currentSupports[i]
                        let oldRGBA=run.contains(i) ? try NativeMandatoryDisplayStroke.rgba(a.image):currentRGBA[i]
                        let newRGBA=try NativeMandatoryDisplayStroke.rgba(b.image)
                        let oldCount=stride(from:3,to:oldRGBA.count,by:4).filter{oldRGBA[$0]>0}.count
                        let newCount=stride(from:3,to:newRGBA.count,by:4).filter{newRGBA[$0]>0}.count
                        guard oldCount==newCount else{throw Failure.invalid("glyph-RGBA-pixel-loss")}
                        guard let oldPalette=try NativeBalloonReadabilityReflow.exteriorPaletteReceipt(current.fills[i],restored:restored),
                              let newPalette=try NativeBalloonReadabilityReflow.exteriorPaletteReceipt(b,restored:restored),
                              try json(oldPalette)==json(newPalette) else{throw Failure.invalid("placed-final-palette")}
                        for y in 0..<b.image.height {
                            if y%32==0 {try Task.checkCancellation()}
                            for x in 0..<b.image.width {
                            let off=(y*b.image.width+x)*4
                            if newRGBA[off+3]>0 {
                                let px=Int(b.frame.minX)+x-Int(a.frame.minX)-Int(fixed[ids[i]]!.x-inputSupport.bounds.minX)
                                let py=Int(b.frame.minY)+y-Int(a.frame.minY)-Int(fixed[ids[i]]!.y-inputSupport.bounds.minY)
                                guard px>=0,py>=0,px<a.image.width,py<a.image.height else{throw Failure.invalid("glyph-RGBA-native-crop")}
                                let from=(py*a.image.width+px)*4
                                guard newRGBA[off]==oldRGBA[from],newRGBA[off+1]==oldRGBA[from+1],
                                      newRGBA[off+2]==oldRGBA[from+2],newRGBA[off+3]==oldRGBA[from+3] else{throw Failure.invalid("glyph-RGBA-native-crop")}
                            }
                        }}
                        if !run.contains(i) {
                            guard admitted.fills[i].frame==current.fills[i].frame,
                                  try NativeMandatoryDisplayStroke.rgba(admitted.fills[i].image)==NativeMandatoryDisplayStroke.rgba(current.fills[i].image) else{throw Failure.invalid("pinned-peer")}
                        }
                    }
                    stage="native-retained-placement"
                    try N.verifyRetainedPlacement(admitted.fills,footprints:supports,page:page,retainedClusterAnchors:anchors)
                    stage="full-known-Snapshot-lineage"
                    admitted.audit=try NativeBalloonPlacement.RetainedState.preservingKnownSnapshots(priorAudit:current.audit,admittedAudit:admitted.audit,unknownPolicy:.preservePriorUncertainty)
                    var metadata=currentLayer.audit,updated=currentRows
                    for k in run.indices {
                        let i=run[k],shape=shapes[k][trial.indices[k]],id=ids[i]
                        guard let rowIndex=updated.firstIndex(where:{$0["id"] as? String==id}) else{throw Failure.invalid("row-owner")}
                        var row=shape.row
                        let dx=supports[i].bounds.minX-shape.support.bounds.minX,dy=supports[i].bounds.minY-shape.support.bounds.minY
                        for key in ["frameOutputTopLeft","retainedFillBoundsOutput"] {
                            if var b=row[key] as? [CGFloat],b.count==4 {b[0]+=dx;b[1]+=dy;row[key]=b}
                        }
                        updated[rowIndex].merge(row){_,new in new}
                        updated[rowIndex]["jointSourceWidthPacking"]=true
                    }
                    metadata["rawNativeItems"]=updated
                    let held=L(image:currentLayer.image,expectedItems:currentLayer.expectedItems,paintedItems:currentLayer.paintedItems,complete:currentLayer.complete,audit:metadata)
                    stage="actual-final-native-compositing"
                    let paintedLayer=try NativeAOTTranslationPageComposer.refineFinalReadability(layer:held,fills:current.fills,restored:restored,admittedOverride:admitted,forceRepaint:true)
                    guard let decisions=paintedLayer.audit["endpointDecisions"] as? [[String:Any]],decisions.count==ids.count else{throw Failure.invalid("paint-palette-receipts")}
                    for i in ids.indices {
                        guard let palette=try NativeBalloonReadabilityReflow.exteriorPaletteReceipt(current.fills[i],restored:restored),
                              NativeBalloonReadabilityReflow.paintDecisionMatches(decisions[i],palette:palette) else{throw Failure.invalid("actual-paint-palette")}
                    }
                    currentLayer=paintedLayer;current=admitted;selected=true
                    for i in run {
                        let oldBytes=try NativeMandatoryDisplayStroke.rgba(baseline.fills[i].image)
                        let newBytes=try NativeMandatoryDisplayStroke.rgba(admitted.fills[i].image)
                        if baseline.fills[i].frame != admitted.fills[i].frame || oldBytes != newBytes {changed.insert(ids[i])}
                    }
                    measurement["status"]="selected";measurement["stage"]=stage;attempts.append(measurement);break
                } catch is CancellationError {throw CancellationError()}
                catch {
                    measurement["stage"]=stage;measurement["status"]="rejected";measurement["reason"]=String(reflecting:error);attempts.append(measurement)
                    // A real original-boundary veto pins that unchanged raster;
                    // re-solve the other origins without relaxing the gate.
                    if recoveredSelection,let k=vetoUnchanged,!trial.pinned.contains(k),proofChecks<budget.proofChecks {
                        let pinned=trial.pinned.union([k])
                        let step=ceil(current.fills[run[k]].fontOutputPixels*0.125)
                        let delta=trial.origins[k]-currentSupports[run[k]].bounds.minX
                        let proposedOffsets=trial.indices[k]==0 ?
                            [CGFloat(0),delta,delta+step,delta-step,delta+step*2,delta-step*2,delta+step*4,delta-step*4]:
                            [CGFloat(0),step,step*2,step*4,step*6,step*8,-step,-step*2]
                        var seenOffsets=Set<CGFloat>()
                        let offsets=proposedOffsets.filter {seenOffsets.insert($0).inserted}
                        for offset in offsets.reversed() {
                        var opts:[NativeSourceCohortPacking.Option]=[],valid=true
                        for j in run.indices {
                            let i=run[j],shape=shapes[j][trial.indices[j]],source=sources[j]
                            let capacity=NativeTextExpansionPolicy.rect(current.fills[i].textExpansionPolicy!.allowedRectNormalized,page:page)
                            let x=currentSupports[i].bounds.minX+(j==k ? offset:0)
                            var lower=max(1,capacity.minX),upper=min(page.maxX-1,capacity.maxX)-shape.support.bounds.width
                            if trial.indices[j]==0,current.fills[i].textPlacementGuide?.horizontal == .center {
                                let delta=currentSupports[i].bounds.midX-source.midX,unit=current.fills[i].fontOutputPixels
                                if delta < -unit*(recoveredSelection ? 2.5:0.25) {upper=min(upper,floor(source.midX-shape.support.bounds.width/2))}
                                if delta > unit*(recoveredSelection ? 2.5:0.25) {lower=max(lower,ceil(source.midX-shape.support.bounds.width/2))}
                            }
                            if pinned.contains(j) {lower=max(lower,x);upper=min(upper,x)}
                            let option=NativeSourceCohortPacking.Option(index:trial.indices[j],extent:shape.support.bounds.width,
                                lower:lower,upper:upper,
                                preferred:source.midX-shape.support.bounds.width/2,unit:current.fills[i].fontOutputPixels,cost:0)
                            let debt=abs(currentSupports[i].bounds.midX-source.midX)/current.fills[i].fontOutputPixels
                            guard let bounded=NativeSourceCohortPacking.sourceNearOption(option,sourceCentre:source.midX,anchorDelta:0,maximumMotionEm:max(2.5,debt))else{valid=false;break}
                            opts.append(bounded)
                        }
                        let gaps=run.dropFirst().enumerated().map{j,i in max(ceil(min(current.fills[run[j]].fontOutputPixels,current.fills[i].fontOutputPixels)*0.12)+(recoveredSelection ? 0:1),
                            min(max(0,currentSupports[i].bounds.minX-currentSupports[run[j]].bounds.maxX),
                                ceil(min(current.fills[run[j]].fontOutputPixels,current.fills[i].fontOutputPixels)*0.35)))}
                        if valid,let origins=NativeSourceCohortPacking.quadraticOrigins(opts,gaps:gaps) {
                            let cost=run.indices.reduce(0.0){$0+pow(Double((origins[$1]+opts[$1].extent/2-sources[$1].midX)/opts[$1].unit),2)}
                            if cost<oldCost-1 {queue.insert(.init(indices:trial.indices,origins:origins,rank:cost,pinned:pinned),at:queueIndex)}
                        }
                        }
                    }
                }
            }
            outcomes.append(["owners":run.map{ids[$0]},"status":selected ? "selected":"incumbent-retained", "sourceLateralCostBefore":oldCost,"generation":generation,"rankedCombinations":trials.count,"attempts":attempts])
        }
        // Report ACTUAL original-to-final inventory, not only tentative commits.
        changed=[]
        let finalRows=currentLayer.audit["rawNativeItems"] as! [[String:Any]]
        for i in ids.indices {
            try Task.checkCancellation()
            let oldBytes=try NativeMandatoryDisplayStroke.rgba(baseline.fills[i].image)
            let newBytes=try NativeMandatoryDisplayStroke.rgba(current.fills[i].image)
            let rangesChanged=try json(rows[i]["lineRangesUTF16"]!) != json(finalRows[i]["lineRangesUTF16"]!)
            if baseline.fills[i].frame != current.fills[i].frame || oldBytes != newBytes || rangesChanged {changed.insert(ids[i])}
        }
        let details:[String:Any]=["version":"joint-source-width-v4-recovered-placement","recoveredSelection":recoveredSelection,"changedOwners":changed.sorted(),"sourceRuns":runs.map{$0.map{ids[$0]}},"maxShapesPerOwner":8,"maxCompleteAdmissions":budget.admissions,"completeAdmissions":admissions,
            "factoryCalls":factoryCalls,"maxFactoryCalls":budget.factoryCalls,"proofChecks":proofChecks,"maxProofChecks":budget.proofChecks,
            "stoppedByBudget":stoppedByBudget,"rowTradePolicy":"retained font/pitch; native quality nonregression; height <=max(incumbent,allowed/page-inset1 remaining height); final actual alpha/domain/page gates; +0.25 per extra row rank",
            "sourceCostPolicy":"group lateral squared-em gain; per-owner growth permitted and reported; not a physical certificate","shapeAttempts":shapeAttempts,"runs":outcomes,"originalBoundaryContrast":32,"unknownPhysicalNotCertified":true,"sourcePacketsEdited":false]
        return(annotate(currentLayer,details),current,changed)
    }
}
