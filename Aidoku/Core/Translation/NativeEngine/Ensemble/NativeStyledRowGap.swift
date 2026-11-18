import CoreGraphics
import Foundation
import CryptoKit

/// Geometry only: complete nonzero styled-alpha row envelopes, independent of debug PNG capture.
enum NativeStyledRowGap {
    typealias N = NativeFinalTextPaintAdmission
    typealias Composer = NativeAOTTranslationPageComposer
    typealias Tuple = (fills:[Composer.TranslatedFillPrimitive],audit:[[String:Any]])
    static func enabled(in environment:[String:String])->Bool { (environment["AIDOKU_STYLED_ROW_GAP"] ?? "1") == "1" }
    static var enabled:Bool {enabled(in:ProcessInfo.processInfo.environment)}
    @TaskLocal static var incumbentPolicy = false
    @TaskLocal static var attemptMemo: AttemptMemo?
    static var v3Enabled:Bool {enabled && (ProcessInfo.processInfo.environment["AIDOKU_STYLED_ROW_GAP_V3"] ?? "1") == "1"}
    static var styledArbitrationEnabled:Bool {enabled && !incumbentPolicy}
    /// Single page/transaction only. No global cache, no replayed observer callback.
    final class AttemptMemo {
        struct Entry {let result:Result<Composer.TextLayer,Error>;let chargedBytes:Int}
        private var entries:[String:Entry]=[:]
        let capture=CompletedTupleCapture()
        private let byteLimit:Int,keyByteLimit:Int,entryLimit:Int
        private(set) var nativeAttempts=0,hits=0,chargedBytes=0
        private(set) var successfulNativeCalls=0,failedNativeCalls=0,cancelledNativeCalls=0
        private(set) var unkeyedRequests=0,oversizedKeyRequests=0,retentionBypasses=0,nativeCapRejections=0
        private(set) var maximumCanonicalKeyBytes=0
        enum Failure:Error {case budget}
        init(byteLimit:Int=128*1024*1024,keyByteLimit:Int=1024*1024,entryLimit:Int=4) {
            self.byteLimit=max(0,min(128*1024*1024,byteLimit))
            self.keyByteLimit=max(0,min(1024*1024,keyByteLimit))
            self.entryLimit=max(0,min(4,entryLimit))
        }
        /// Key/cap failures disable optional storage, never the original operation.
        private func key(legacy:Bool,raw:[String:[String:Any]])->String? {
            guard JSONSerialization.isValidJSONObject(raw),
                  let bytes=try? JSONSerialization.data(withJSONObject:raw,options:[.sortedKeys]) else {
                unkeyedRequests+=1;return nil
            }
            maximumCanonicalKeyBytes=max(maximumCanonicalKeyBytes,bytes.count)
            guard bytes.count<=keyByteLimit else {oversizedKeyRequests+=1;return nil}
            return (legacy ? "legacy:":"actual:")+SHA256.hash(data:bytes).map{String(format:"%02x",$0)}.joined()
        }
        func run(legacy:Bool,raw:[String:[String:Any]],operation:()throws->Composer.TextLayer)throws->Composer.TextLayer {
            let cacheKey=key(legacy:legacy,raw:raw)
            if let cacheKey,let entry=entries[cacheKey] {hits+=1;return try entry.result.get()}
            guard nativeAttempts<4 else {nativeCapRejections+=1;throw Failure.budget}
            nativeAttempts+=1
            let layer:Composer.TextLayer
            do {layer=try operation();successfulNativeCalls+=1}
            catch is CancellationError {cancelledNativeCalls+=1;throw CancellationError()}
            catch {
                failedNativeCalls+=1
                if let cacheKey,entries.count<entryLimit {entries[cacheKey]=Entry(result:.failure(error),chargedBytes:0)}
                throw error
            }
            let image=layer.image
            if let cacheKey,entries.count<entryLimit,image.height>0,
               image.bytesPerRow<=byteLimit/image.height {
                let charge=image.bytesPerRow*image.height
                if charge<=byteLimit-chargedBytes {
                    chargedBytes+=charge;entries[cacheKey]=Entry(result:.success(layer),chargedBytes:charge)
                    return layer
                }
            }
            // Success remains success even if no key/entry/byte capacity is available.
            retentionBypasses+=1
            return layer
        }
        var audit:[String:Any] {
            let successes=entries.values.reduce(0){n,e in if case .success=e.result {return n+1};return n}
            return ["nativeAttempts":nativeAttempts,"nativeAttemptCap":4,"memoHits":hits,
                "successfulNativeCalls":successfulNativeCalls,"failedNativeCalls":failedNativeCalls,
                "cancelledNativeCalls":cancelledNativeCalls,"nativeCapRejections":nativeCapRejections,
                "completedCompositeRowBytes":chargedBytes,"compositeByteCap":byteLimit,
                "compositeChargeScope":"per stored success entry bytesPerRow*height; duplicates charged per entry; excludes unretained native success and total heap",
                "memoEntries":entries.count,"memoEntryCap":entryLimit,"memoSuccessEntries":successes,
                "memoFailureEntries":entries.count-successes,"unkeyedRequests":unkeyedRequests,
                "oversizedKeyRequests":oversizedKeyRequests,"canonicalKeyByteCap":keyByteLimit,
                "maximumCanonicalKeyBytes":maximumCanonicalKeyBytes,"successfulNativeRetentionBypasses":retentionBypasses,
                "carrierCaptureChargedBytes":capture.stats().conservativeChargedBytes,
                "nudgeTrialCap":4,"scope":"one synchronous page; native attempt cap covers executed operations only; memo bytes cover retained completed-layer row payload only; key bypass is not native failure"]
        }
    }
    /// Same alpha support as horizontal rows, transposed for vertical peers.
    /// Bounded total support work is checked by measure before this loop.
    static func columns(_ support:N.Footprint)throws->[Envelope] {
        let x0=Int(support.bounds.minX),width=Int(support.bounds.width)
        guard width>0,width<=32768 else {throw N.Failure.invalidGeometry}
        var top=Array(repeating:Int.max,count:width),bottom=Array(repeating:Int.min,count:width)
        for run in support.runs {
            guard run.left>=x0,run.right<=x0+width else {throw N.Failure.invalidGeometry}
            for x in run.left..<run.right {let i=x-x0;top[i]=min(top[i],run.y);bottom[i]=max(bottom[i],run.y+1)}
        }
        return top.indices.compactMap{top[$0]==Int.max ? nil:Envelope(y:x0+$0,left:top[$0],right:bottom[$0])}
    }
    /// Composite images are weak. Only bounded native carrier rasters are retained.
    /// Parent observers are forwarded by the caller before this optional capture.
    final class CompletedTupleCapture {
        struct Stats:Equatable {
            let entries:Int
            let uniqueCarrierImages:Int
            let carrierPixels:Int
            let carrierRowBytes:Int
            let conservativeChargedBytes:Int
        }
        private final class Entry {
            weak var image:CGImage?
            let tuple:Tuple
            init(image:CGImage,tuple:Tuple) {self.image=image;self.tuple=tuple}
        }
        private var entries:[Entry]=[]
        private let entryLimit:Int,pixelLimit:Int,byteLimit:Int
        init(entryLimit:Int=8,pixelLimit:Int=16_777_216,byteLimit:Int=64*1024*1024) {
            self.entryLimit=max(0,min(8,entryLimit))
            self.pixelLimit=max(0,min(16_777_216,pixelLimit))
            self.byteLimit=max(0,min(64*1024*1024,byteLimit))
        }
        private func prune() {entries.removeAll{$0.image==nil}}
        private func cost(_ tuples:[Tuple])->Stats? {
            var identities=Set<ObjectIdentifier>(),pixels=0,bytes=0,charged=0
            for tuple in tuples {
                guard tuple.fills.count<=256,tuple.fills.count==tuple.audit.count,
                      tuple.audit.count<=byteLimit/4096,tuple.audit.count*4096<=byteLimit-charged else{return nil}
                charged+=tuple.audit.count*4096
                for fill in tuple.fills {
                    let raster=fill.image
                    guard identities.insert(ObjectIdentifier(raster)).inserted else{continue}
                    guard raster.width>0,raster.height>0,raster.height<=pixelLimit,
                          raster.width<=pixelLimit/max(1,raster.height) else{return nil}
                    let p=raster.width*raster.height
                    guard p<=pixelLimit-pixels,raster.bytesPerRow<=byteLimit/max(1,raster.height) else{return nil}
                    let b=raster.bytesPerRow*raster.height
                    guard b<=byteLimit-bytes,b<=byteLimit/4,b*4<=byteLimit-charged else{return nil}
                    pixels+=p;bytes+=b;charged+=b*4
                }
            }
            return Stats(entries:tuples.count,uniqueCarrierImages:identities.count,carrierPixels:pixels,carrierRowBytes:bytes,conservativeChargedBytes:charged)
        }
        @discardableResult func observe(_ image:CGImage,_ fills:[Composer.TranslatedFillPrimitive],
                                        _ audit:[[String:Any]])->Bool {
            prune()
            let ids=fills.compactMap(\.ownerID)
            guard ids.count==fills.count,Set(ids).count==ids.count,ids.allSatisfy({!$0.isEmpty}),
                  fills.count==audit.count,fills.indices.allSatisfy({audit[$0]["owner"]as?String==ids[$0]}),
                  fills.allSatisfy({$0.image !== image}) else{return false}
            let remaining=entries.filter{$0.image !== image}
            guard remaining.count<entryLimit,cost(remaining.map(\.tuple)+[(fills,audit)]) != nil else{return false}
            entries=remaining+[Entry(image:image,tuple:(fills,audit))]
            return true
        }
        func selectedTuple(for layer:Composer.TextLayer)->Tuple? {
            prune()
            guard layer.complete,let entry=entries.last(where:{$0.image === layer.image}),
                  layer.expectedItems==entry.tuple.fills.count,layer.paintedItems==entry.tuple.fills.count,
                  let admission=layer.audit["finalPaintAdmission"]as?[[String:Any]],
                  NSArray(array:admission).isEqual(to:entry.tuple.audit) else{return nil}
            return entry.tuple
        }
        func stats()->Stats {
            prune()
            return cost(entries.map(\.tuple)) ?? Stats(entries:entries.count,uniqueCarrierImages:0,carrierPixels:0,carrierRowBytes:0,conservativeChargedBytes:0)
        }
    }
    static func forwardingObserver(to outer:Composer.CompletedPaintObserver?,capture:CompletedTupleCapture)->Composer.CompletedPaintObserver {
        Composer.CompletedPaintObserver { image,fills,audit in
            outer?.observe(image,fills,audit)
            capture.observe(image,fills,audit)
        }
    }
    /// A source/physical translation must publish a new completed tuple metric.
    static func metricIsCurrent(_ value:Any?,admission:[[String:Any]])->Bool {
        guard let metric=value as?[String:Any],metric["complete"]as?Bool==true,
              let owners=metric["owners"]as?[[String:Any]],owners.count==admission.count else{return false}
        var byID:[String:[String:Any]]=[:]
        for row in admission {
            guard let id=row["owner"]as?String,byID[id]==nil else{return false}
            byID[id]=row
        }
        var seen=Set<String>()
        for row in owners {
            guard let id=row["owner"]as?String,seen.insert(id).inserted,let actual=byID[id],
                  let a=row["bounds"]as?[Any],let b=actual["finalFootprintOutputPixels"]as?[Any],a.count==4,b.count==4,
                  let p=row["pixels"]as?Int,let q=actual["paintedPixels"]as?Int,p==q else{return false}
            let x=a.compactMap{($0 as?NSNumber)?.doubleValue},y=b.compactMap{($0 as?NSNumber)?.doubleValue}
            guard x.count==4,y.count==4,x==y else{return false}
        }
        return seen==Set(byID.keys)
    }
    struct Envelope {let y:Int;var left:Int;var right:Int}
    static func envelopes<Rows: Sequence>(_ runs: Rows) -> [Envelope] where Rows.Element == N.Run {
        var rows:[Envelope]=[]
        for run in runs {
            if rows.last?.y==run.y {
                rows[rows.count-1].left=min(rows.last!.left,run.left)
                rows[rows.count-1].right=max(rows.last!.right,run.right)
            } else {rows.append(.init(y:run.y,left:run.left,right:run.right))}
        }
        return rows
    }
    static func horizontal(_ left:[Envelope],_ right:[Envelope])->(gap:Int,rows:Int,y:Int)? {
        var i=0,j=0,count=0,best=Int.max,bestY=0
        while i<left.count && j<right.count {
            if left[i].y<right[j].y {i+=1}
            else if right[j].y<left[i].y {j+=1}
            else {
                let gap=right[j].left-left[i].right
                if gap<best {best=gap;bestY=left[i].y}
                count+=1;i+=1;j+=1
            }
        }
        return count>0 ? (best,count,bestY):nil
    }
    static func measure(fills:[Composer.TranslatedFillPrimitive],layers:[NativeMandatoryDisplayStroke.Prepared],
                        audit:[[String:Any]], sourceStyleMemo:NativeSourceStylePaint.PlaneMemo?=nil,
                        verifiedSupport:[N.Footprint]?=nil)throws->[String:Any] {
        guard fills.count<=256,fills.count==layers.count,fills.count==audit.count else {throw N.Failure.invalidGeometry}
        let start=Date()
        let supports=try verifiedSupport ?? fills.indices.map { i in
            try N.footprint(layer:layers[i],style:fills[i].sourceStyle,fontPixels:fills[i].fontOutputPixels,
                sourceStyleMemo:sourceStyleMemo)
        }
        guard supports.count==fills.count else {throw N.Failure.invalidGeometry}
        let includeVertical = v3Enabled
        let rows=supports.map{envelopes($0.runs)}
        guard supports.reduce(0,{$0+$1.pixels})<=16_777_216 else {throw N.Failure.invalidGeometry}
        let columnRows = includeVertical ? try supports.map{try columns($0)}:[]
        var pairs:[[String:Any]]=[],owners:[[String:Any]]=[]
        for i in fills.indices {
            guard let id=fills[i].ownerID,audit[i]["owner"]as?String==id else{throw N.Failure.invalidGeometry}
            let b=supports[i].bounds
            owners.append(["owner":id,"bounds":[b.minX,b.minY,b.width,b.height],"pixels":supports[i].pixels,"rows":rows[i].count])
            if includeVertical {owners[owners.count-1]["columns"]=columnRows[i].count}
            for j in fills.indices where j>i {
                if includeVertical,let peer=fills[j].ownerID,supports[i].bounds.midY != supports[j].bounds.midY {
                    let upper=supports[i].bounds.midY<supports[j].bounds.midY ? i:j
                    let lower=upper==i ? j:i
                    if let gap=horizontal(columnRows[upper],columnRows[lower]) {
                        pairs.append(["owners":[id,peer].sorted(),"leadingOwner":fills[upper].ownerID!,
                            "axis":"vertical","minimumGapPixels":gap.gap,"overlappingStyledColumns":gap.rows,
                            "minimumGapColumnX":gap.y,"comparisonFontPixels":min(fills[i].fontOutputPixels,fills[j].fontOutputPixels)])
                    }
                }
                guard let peer=fills[j].ownerID,supports[i].bounds.midX != supports[j].bounds.midX else{continue}
                let left=supports[i].bounds.midX<supports[j].bounds.midX ? i:j
                let right=left==i ? j:i
                guard let gap=horizontal(rows[left],rows[right]) else{continue}
                pairs.append(["owners":[id,peer].sorted(),"leadingOwner":fills[left].ownerID!,
                    "axis":"horizontal","minimumGapPixels":gap.gap,"overlappingStyledRows":gap.rows,
                    "minimumGapRowY":gap.y,"comparisonFontPixels":min(fills[i].fontOutputPixels,fills[j].fontOutputPixels)])
            }
        }
        return ["version":1,"complete":true,"scope":"current completed paint admitted tuple; actual prepared styled alpha>0 Footprint.runs",
                "horizontalOnly":!includeVertical,"owners":owners,"pairs":pairs,"seconds":Date().timeIntervalSince(start)]
    }

    /// Existing native admission, retained anchors/Snapshots, source boundary and final-paint guards remain mandatory.
    static func nudge(layer:Composer.TextLayer,tuple:Tuple,restored:CGImage,
                      requests:[(String,String,Double)])throws->Composer.TextLayer? {
        guard enabled,!requests.isEmpty,requests.count<=256,tuple.fills.count==tuple.audit.count else{return nil}
        guard let context=NativeSourcePhysicalInteriorContext.current ?? NativeSourceCohortCenterBalance.currentBoundaryContext else{return nil}
        let page=CGRect(x:0,y:0,width:restored.width,height:restored.height)
        let before=try tuple.fills.map{try N.retainedFootprint($0)}
        let names=tuple.fills.compactMap(\.ownerID)
        guard names.count==tuple.fills.count,Set(names).count==names.count else{return nil}
        let anchors=try N.verifiedRetainedClusterAnchors(tuple.fills,footprints:before,audit:tuple.audit,page:page)
        var trials=0
        for request in requests {
            guard let ia=names.firstIndex(of:request.0),let ib=names.firstIndex(of:request.1) else{continue}
            let order=before[ia].bounds.midX<before[ib].bounds.midX ? [ib,ia]:[ia,ib]
            for moved in order {
                let peer=moved==ia ? ib:ia
                let sign:CGFloat=before[moved].bounds.midX>before[peer].bounds.midX ? 1:-1
                if let packet=tuple.fills[moved].sourceClusterAlignment,packet.axis != .top {continue}
                let delta=CGFloat(ceil(request.2))*sign
                guard abs(delta)>0,abs(delta)<=floor(tuple.fills[moved].fontOutputPixels * 0.5) else{continue}
                guard trials<4 else{return nil}
                trials+=1
                var origins=Dictionary(uniqueKeysWithValues:names.indices.map{(names[$0],before[$0].bounds.origin)})
                origins[names[moved]]!.x+=delta
                do {
                    var candidate=try N.place(tuple.fills,page:page,fixedOrigins:origins,retainedClusterAnchors:anchors)
                    candidate.audit=try NativeBalloonPlacement.RetainedState.preservingKnownSnapshots(
                        priorAudit:tuple.audit,admittedAudit:candidate.audit,unknownPolicy:.reject,inputPolicy:.retainedEffectivePacket)
                    candidate=try NativeSourceCohortCenterBalance.preservingReceipts(prior:tuple,admitted:candidate,page:page)
                    let after=try candidate.fills.map{try N.retainedFootprint($0)}
                    try N.verifyRetainedPlacement(candidate.fills,footprints:after,page:page,retainedClusterAnchors:anchors)
                    guard names.indices.allSatisfy({ i in
                        let shift=CGPoint(x:i==moved ? delta:0,y:0)
                        return NativeBodySourceAnchorRecovery.carrierPreserved(tuple.fills[i],candidate.fills[i],shift:shift)
                            && after[i].bounds.origin==origins[names[i]]
                    }) else{continue}
                    let evidence=context.boundaryClearance(before:before[moved],after:after[moved],maximumAllowedDecreasePixels:0)
                    let boundary=evidence.audit
                    guard evidence.allowed==true else{continue}
                    if let risk=N.retainedSourceRiskGate {
                        guard risk.evaluate(before[moved],after[moved])==true else{continue}
                    }
                    guard let oldPalette=try NativeBalloonReadabilityReflow.exteriorPaletteReceipt(tuple.fills[moved],restored:restored),
                          let newPalette=try NativeBalloonReadabilityReflow.exteriorPaletteReceipt(candidate.fills[moved],restored:restored),
                          NSDictionary(dictionary:oldPalette).isEqual(to:newPalette) else{continue}
                    var painted=try Composer.refineFinalReadability(layer:layer,fills:tuple.fills,restored:restored,
                        admittedOverride:candidate,forceRepaint:true)
                    var audit=painted.audit
                    audit["styledRowGapNudge"]=["owner":names[moved],"shiftPixels":[Double(delta),0],
                        "sameGlyphFontRowsAndSnapshot":true,"allPeersPinned":true,"sourceBoundary":boundary,
                        "finalGeometryAuthority":"finalPaintAdmission and completedStyledRowPairMetric; glyph witness when captured",
                        "rawFrameAuthority":"shape-production diagnostics with stage-dependent deltas; not canonical final geometry",
                        "requestedPair":[request.0,request.1]]
                    painted=Composer.TextLayer(image:painted.image,expectedItems:painted.expectedItems,
                        paintedItems:painted.paintedItems,complete:painted.complete,audit:audit)
                    return painted
                } catch is CancellationError {throw CancellationError()}
                catch {continue}
            }
        }
        return nil
    }
}
