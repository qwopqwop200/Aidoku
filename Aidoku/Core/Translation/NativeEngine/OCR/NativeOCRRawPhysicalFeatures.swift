import Foundation

/// Exact source-only ABI of agent29 raw-physical-sourcefeatures/extract.py +
/// uniform_cc.py. No model, GT, page catalog, OCR correction or recognition input.
/// This helper has no call sites/default activation; the new canonical caller
/// explicitly prepares ONE immutable raw inventory per source frame.
@available(iOS 18.0, *)
enum NativeOCRRawPhysicalFeatures {
    static let abi = "raw-physical-source-features181-v1"
    static let featureCount = 181
    static let featureNames: [String] = [
        "cc/primary/present",
        "cc/primary/insideCellFraction",
        "cc/primary/fullFootprintInsideFraction",
        "cc/primary/wholeCCInsideFraction",
        "cc/primary/missingCCFraction",
        "cc/primary/partialCCFraction",
        "cc/primary/supportDice",
        "cc/primary/competingDiceGap",
        "cc/primary/ambiguousFraction",
        "cc/primary/confidence",
        "cc/primary/normalLow/q01Grid",
        "cc/primary/normalLow/q10Grid",
        "cc/primary/normalLow/q50Grid",
        "cc/primary/normalLow/outsideMass",
        "cc/primary/normalLow/oneCellEdgeMass",
        "cc/primary/normalLow/twoCellEdgeMass",
        "cc/primary/normalLow/fullFootprintOutsideMass",
        "cc/primary/normalHigh/q01Grid",
        "cc/primary/normalHigh/q10Grid",
        "cc/primary/normalHigh/q50Grid",
        "cc/primary/normalHigh/outsideMass",
        "cc/primary/normalHigh/oneCellEdgeMass",
        "cc/primary/normalHigh/twoCellEdgeMass",
        "cc/primary/normalHigh/fullFootprintOutsideMass",
        "cc/primary/alongLow/q01Grid",
        "cc/primary/alongLow/q10Grid",
        "cc/primary/alongLow/q50Grid",
        "cc/primary/alongLow/outsideMass",
        "cc/primary/alongLow/oneCellEdgeMass",
        "cc/primary/alongLow/twoCellEdgeMass",
        "cc/primary/alongLow/fullFootprintOutsideMass",
        "cc/primary/alongHigh/q01Grid",
        "cc/primary/alongHigh/q10Grid",
        "cc/primary/alongHigh/q50Grid",
        "cc/primary/alongHigh/outsideMass",
        "cc/primary/alongHigh/oneCellEdgeMass",
        "cc/primary/alongHigh/twoCellEdgeMass",
        "cc/primary/alongHigh/fullFootprintOutsideMass",
        "cc/secondary/present",
        "cc/secondary/insideCellFraction",
        "cc/secondary/fullFootprintInsideFraction",
        "cc/secondary/wholeCCInsideFraction",
        "cc/secondary/missingCCFraction",
        "cc/secondary/partialCCFraction",
        "cc/secondary/supportDice",
        "cc/secondary/competingDiceGap",
        "cc/secondary/ambiguousFraction",
        "cc/secondary/confidence",
        "cc/secondary/normalLow/q01Grid",
        "cc/secondary/normalLow/q10Grid",
        "cc/secondary/normalLow/q50Grid",
        "cc/secondary/normalLow/outsideMass",
        "cc/secondary/normalLow/oneCellEdgeMass",
        "cc/secondary/normalLow/twoCellEdgeMass",
        "cc/secondary/normalLow/fullFootprintOutsideMass",
        "cc/secondary/normalHigh/q01Grid",
        "cc/secondary/normalHigh/q10Grid",
        "cc/secondary/normalHigh/q50Grid",
        "cc/secondary/normalHigh/outsideMass",
        "cc/secondary/normalHigh/oneCellEdgeMass",
        "cc/secondary/normalHigh/twoCellEdgeMass",
        "cc/secondary/normalHigh/fullFootprintOutsideMass",
        "cc/secondary/alongLow/q01Grid",
        "cc/secondary/alongLow/q10Grid",
        "cc/secondary/alongLow/q50Grid",
        "cc/secondary/alongLow/outsideMass",
        "cc/secondary/alongLow/oneCellEdgeMass",
        "cc/secondary/alongLow/twoCellEdgeMass",
        "cc/secondary/alongLow/fullFootprintOutsideMass",
        "cc/secondary/alongHigh/q01Grid",
        "cc/secondary/alongHigh/q10Grid",
        "cc/secondary/alongHigh/q50Grid",
        "cc/secondary/alongHigh/outsideMass",
        "cc/secondary/alongHigh/oneCellEdgeMass",
        "cc/secondary/alongHigh/twoCellEdgeMass",
        "cc/secondary/alongHigh/fullFootprintOutsideMass",
        "rawSeed/available",
        "rawSeed/completeCCScan",
        "rawSeed/components",
        "rawSeed/ambiguousComponents",
        "rawSeed/candidateComponents",
        "rawSeed/confidence",
        "rawSeed/cellAreaRatio",
        "rawSeed/runCount",
        "rawSeed/runAxisSlope",
        "rawSeed/normalLow",
        "rawSeed/normalHigh",
        "rawSeed/alongLow",
        "rawSeed/alongHigh",
        "rawSeed/medianComponentNormalSpan",
        "rawSeed/medianComponentAlongSpan",
        "rawSeed/normalWidthVariation",
        "physical/available",
        "physical/ambiguousQuery",
        "physical/normalCertificatePresent",
        "physical/alongCertificatePresent",
        "physical/normalComplete",
        "physical/alongComplete",
        "physical/terminalSourceInk",
        "physical/rimGreaterThanFill",
        "physical/sourceAxisSlopeDelta",
        "physical/observedNormalSpanRatio",
        "physical/observedAlongSpanRatio",
        "physical/residualNormalLow",
        "physical/residualNormalHigh",
        "physical/residualAlongLow",
        "physical/residualAlongHigh",
        "physical/diagnostic/completeNormalInk",
        "physical/diagnostic/completeAlongInk",
        "physical/diagnostic/axisSlope",
        "physical/diagnostic/axisSlopeFromActualRuns",
        "physical/diagnostic/medianDBWidth",
        "physical/diagnostic/nativeUnclipDistance",
        "physical/diagnostic/unclipRatio",
        "physical/diagnostic/privateRows",
        "physical/diagnostic/darkPixels",
        "physical/diagnostic/corePixelCount",
        "physical/diagnostic/completeSourceCCPixels",
        "physical/diagnostic/completeComponentPixels",
        "physical/diagnostic/completeComponents",
        "physical/diagnostic/rootComponents",
        "physical/diagnostic/closedNormalLines",
        "physical/diagnostic/occupiedNormalLines",
        "physical/diagnostic/observedOppositeRimComponents",
        "physical/diagnostic/geometryPadding",
        "physical/diagnostic/fillPixels",
        "physical/diagnostic/measuredWhiteRimPixels",
        "physical/diagnostic/finiteRimRayCount",
        "physical/diagnostic/componentCount",
        "physical/diagnostic/actualPrivateHitPixels",
        "physical/diagnostic/corePixels",
        "physical/diagnostic/coreComponents",
        "physical/diagnostic/observedDarkRimPixels",
        "physical/diagnostic/ringDarkFraction",
        "physical/diagnostic/rimAssociationRadius",
        "physical/diagnostic/glyphScale",
        "physical/diagnostic/enclosedBrightPixels",
        "physical/diagnostic/nearBlackPixels",
        "physical/diagnostic/nearBlackComponents",
        "physical/diagnostic/sourceContrastThreshold",
        "physical/diagnostic/sourcePolarityBright",
        "physical/diagnostic/normalSourcePolarityBright",
        "physical/diagnostic/rfTextBoundsWitnesses",
        "physical/diagnostic/recoveryV3MeasuredPrivateEndpointBridges",
        "physical/diagnosticPresent/completeNormalInk",
        "physical/diagnosticPresent/completeAlongInk",
        "physical/diagnosticPresent/axisSlope",
        "physical/diagnosticPresent/axisSlopeFromActualRuns",
        "physical/diagnosticPresent/medianDBWidth",
        "physical/diagnosticPresent/nativeUnclipDistance",
        "physical/diagnosticPresent/unclipRatio",
        "physical/diagnosticPresent/privateRows",
        "physical/diagnosticPresent/darkPixels",
        "physical/diagnosticPresent/corePixelCount",
        "physical/diagnosticPresent/completeSourceCCPixels",
        "physical/diagnosticPresent/completeComponentPixels",
        "physical/diagnosticPresent/completeComponents",
        "physical/diagnosticPresent/rootComponents",
        "physical/diagnosticPresent/closedNormalLines",
        "physical/diagnosticPresent/occupiedNormalLines",
        "physical/diagnosticPresent/observedOppositeRimComponents",
        "physical/diagnosticPresent/geometryPadding",
        "physical/diagnosticPresent/fillPixels",
        "physical/diagnosticPresent/measuredWhiteRimPixels",
        "physical/diagnosticPresent/finiteRimRayCount",
        "physical/diagnosticPresent/componentCount",
        "physical/diagnosticPresent/actualPrivateHitPixels",
        "physical/diagnosticPresent/corePixels",
        "physical/diagnosticPresent/coreComponents",
        "physical/diagnosticPresent/observedDarkRimPixels",
        "physical/diagnosticPresent/ringDarkFraction",
        "physical/diagnosticPresent/rimAssociationRadius",
        "physical/diagnosticPresent/glyphScale",
        "physical/diagnosticPresent/enclosedBrightPixels",
        "physical/diagnosticPresent/nearBlackPixels",
        "physical/diagnosticPresent/nearBlackComponents",
        "physical/diagnosticPresent/sourceContrastThreshold",
        "physical/diagnosticPresent/sourcePolarityBright",
        "physical/diagnosticPresent/normalSourcePolarityBright",
        "physical/diagnosticPresent/rfTextBoundsWitnesses",
        "physical/diagnosticPresent/recoveryV3MeasuredPrivateEndpointBridges",
    ]
    typealias Original = NativeOCRSourceOwnedRailPartition.Original
    typealias Measurement = NativeOCRSourcePaintGeometry.Measurement

    /// An explicit INPUT identity receipt, not a physical ownership claim.
    /// Caller obtains these fields from actualQuery sourceOriginal provenance.
    struct PhysicalObservation: Sendable {
        let originalDetectorIndex: Int
        let sourceMembers: [Int]
        let isSourceOriginal: Bool
        let actualQueryPolygon: [[Double]]
        let queryPolygon: [[Double]]
        let measurement: Measurement
    }
    struct Inventory: Sendable {
        fileprivate let originals: [Original]
        fileprivate let groups: [Group]
    }
    fileprivate struct V: Sendable {
        var x: Double, y: Double
        static func + (a: V,b: V) -> V { V(x:a.x+b.x,y:a.y+b.y) }
        static func - (a: V,b: V) -> V { V(x:a.x-b.x,y:a.y-b.y) }
        static func * (a: V,b: Double) -> V { V(x:a.x*b,y:a.y*b) }
        func dot(_ b: V) -> Double { x*b.x+y*b.y }
    }
    fileprivate struct Group: Sendable {
        let points: [V], labels: [Int], sizes: [Int]
        let sx: Double, sy: Double
        let bounds: [Double], probability: Double, ambiguous: Bool
    }
    private struct RunKey: Hashable { let x: Int, y: Int, count: Int }
    private struct GroupKey: Hashable { let sx: Double, sy: Double, runs: [[RunKey]] }
    private struct Frame {
        let center: V, axis: V, normal: V, bounds: [Double], scale: [Double]
    }
    private struct Option { let dice: Double, groupIndex: Int, distance: [[Double]], inside: [Bool] }

    /// Deduplicate identical COMPLETE sparse captures by exact scales and ordered
    /// component RLE. Never deduplicate by sourceIndex, parent or bbox overlap.
    static func prepare(rawInventory: [Original]) -> Inventory {
        var groups=[Group](),seen=Set<GroupKey>()
        for original in rawInventory {
            guard let s=original.detectorSeedEvidence,s.completeCCScan==true,
                  s.ownershipVersion==2,!s.components.isEmpty,
                  s.mapFullWidth>0,s.mapFullHeight>0,s.sourceWidth>0,s.sourceHeight>0 else { continue }
            let sx=Double(s.sourceWidth)/Double(s.mapFullWidth),sy=Double(s.sourceHeight)/Double(s.mapFullHeight)
            let token=GroupKey(sx:sx,sy:sy,runs:s.components.map{c in c.runs.map{RunKey(x:$0.x,y:$0.y,count:$0.count)}})
            if !seen.insert(token).inserted { continue }
            var points=[V](),labels=[Int](),sizes=[Int](),probabilitySum=0.0
            for c in s.components {
                let label=sizes.count,start=points.count
                for run in c.runs where run.count>0 {
                    for x in run.x..<(run.x+run.count) {
                        points.append(V(x:(Double(x)+0.5)*sx,y:(Double(run.y)+0.5)*sy));labels.append(label)
                    }
                }
                let count=points.count-start
                if count>0 { sizes.append(count);probabilitySum+=Double(count)*c.meanProbability }
            }
            guard !points.isEmpty else { continue }
            let b=[points.map(\.x).min()!-sx/2,points.map(\.y).min()!-sy/2,
                   points.map(\.x).max()!+sx/2,points.map(\.y).max()!+sy/2]
            groups.append(Group(points:points,labels:labels,sizes:sizes,sx:sx,sy:sy,bounds:b,
                probability:probabilitySum/Double(points.count),
                ambiguous:!(s.ambiguousComponents ?? []).isEmpty || !(s.candidateComponents ?? []).isEmpty))
        }
        return Inventory(originals:rawInventory,groups:groups)
    }

    /// Return training-NPZ Float32 values widened to Double, in featureNames order.
    /// Invalid raw input fails explicitly rather than fabricating a finite row.
    static func extract(rawIndex: Int, inventory: Inventory,
                        observations: [PhysicalObservation] = []) -> [Double]? {
        guard inventory.originals.indices.contains(rawIndex),
              frame(inventory.originals[rawIndex].polygon) != nil else { return nil }
        return extract(query: inventory.originals[rawIndex], queryOrdinal: rawIndex,
            inventory: inventory, observations: observations)
    }

    /// An independently observed detector query can use the same immutable raw
    /// CC inventory without adding itself to that inventory or inventing ownership.
    static func extract(query raw: Original, queryOrdinal: Int, inventory: Inventory,
                        observations: [PhysicalObservation] = []) -> [Double]? {
        guard queryOrdinal >= 0, let f=frame(raw.polygon) else { return nil }
        var result=uniform(raw.polygon,inventory.groups)
        result += seedFeatures(raw.detectorSeedEvidence,f)
        result += physical(rawIndex:queryOrdinal,raw:raw.polygon,frame:f,observations:observations)
        guard result.count==featureCount,result.allSatisfy(\.isFinite) else { return nil }
        return result.map { Double(Float($0)) }
    }

    private static func quad(_ q: [[Double]]) -> [V]? {
        guard q.count==4,q.allSatisfy({$0.count==2 && $0.allSatisfy(\.isFinite)}) else { return nil }
        return q.map{V(x:$0[0],y:$0[1])}
    }
    private static func sameQuad(_ a: [[Double]],_ b: [[Double]]) -> Bool {
        guard quad(a) != nil,quad(b) != nil else { return false }
        for reverse in [false,true] { for offset in 0..<4 {
            if (0..<4).allSatisfy({a[$0]==b[(offset+(reverse ? 4-$0:$0))%4]}) { return true }
        } }
        return false
    }
    private static func frame(_ q: [[Double]]) -> Frame? {
        guard let p=quad(q) else { return nil }
        let center=p.reduce(V(x:0,y:0),+)*0.25
        var best=0.0,axis=V(x:0,y:0)
        for i in 0..<4 {
            let e=p[(i+1)%4]-p[i],length=hypot(e.x,e.y)
            guard length>0 else { return nil }
            if length>best { best=length;axis=e*(1/length) }
        }
        if axis.y<0 || (axis.y==0 && axis.x<0) { axis=axis * -1 }
        let normal=V(x:axis.y,y:-axis.x)
        let ns=p.map{($0-center).dot(normal)},ts=p.map{($0-center).dot(axis)}
        let b=[ns.min()!,ns.max()!,ts.min()!,ts.max()!]
        let n=b[1]-b[0],t=b[3]-b[2]
        guard n>0,t>0 else { return nil }
        return Frame(center:center,axis:axis,normal:normal,bounds:b,scale:[n,n,t,t])
    }
    private static func project(_ p: [V],_ f: Frame) -> [Double] {
        let ns=p.map{($0-f.center).dot(f.normal)},ts=p.map{($0-f.center).dot(f.axis)}
        return [ns.min()!,ns.max()!,ts.min()!,ts.max()!]
    }
    /// NumPy's default linear quantile, including even-sample median.
    private static func quantile(_ v: [Double],_ q: Double) -> Double {
        guard !v.isEmpty else { return 0 }
        let s=v.sorted(),x=Double(s.count-1)*q,i=Int(x),j=min(i+1,s.count-1)
        return s[i]+(s[j]-s[i])*(x-Double(i))
    }
    private static func fraction(_ values: [Bool]) -> Double {
        Double(values.filter{$0}.count)/Double(values.count)
    }
    private static func uniform(_ q: [[Double]],_ groups: [Group]) -> [Double] {
        var out=[Double](repeating:0,count:76)
        guard let p=quad(q),let f=frame(q) else { return out }
        var inward=[V](),area=0.0
        for i in 0..<4 {
            let e=p[(i+1)%4]-p[i],length=hypot(e.x,e.y)
            var normal=V(x:-e.y/length,y:e.x/length)
            if (f.center-p[i]).dot(normal)<0 { normal=normal * -1 }
            inward.append(normal)
            area+=p[i].x*p[(i+1)%4].y-p[i].y*p[(i+1)%4].x
        }
        area=abs(area)/2
        func extremum(_ direction: V,_ maximum: Bool) -> Int {
            var selected=0
            for i in 1..<4 {
                let a=inward[i].dot(direction),b=inward[selected].dot(direction)
                if maximum ? a>b:a<b { selected=i }
            }
            return selected
        }
        let order=[extremum(f.normal,true),extremum(f.normal,false),extremum(f.axis,true),extremum(f.axis,false)]
        let qb=[p.map(\.x).min()!,p.map(\.y).min()!,p.map(\.x).max()!,p.map(\.y).max()!]
        var options=[Option]()
        for (index,g) in groups.enumerated() {
            if min(qb[2],g.bounds[2])<max(qb[0],g.bounds[0]) ||
                min(qb[3],g.bounds[3])<max(qb[1],g.bounds[1]) { continue }
            let units=inward.map{abs($0.x)*g.sx+abs($0.y)*g.sy}
            var distance=[[Double]](),inside=[Bool]()
            for cell in g.points {
                let d=(0..<4).map{(cell.dot(inward[$0])-p[$0].dot(inward[$0]))/units[$0]}
                distance.append(d);inside.append(d.allSatisfy{$0>=0})
            }
            let count=inside.filter{$0}.count
            guard count>0 else { continue }
            let dice=2*Double(count)/(Double(g.points.count)+area/(g.sx*g.sy))
            options.append(Option(dice:dice,groupIndex:index,distance:distance,inside:inside))
        }
        // Python's stable sort preserves raw inventory order on exact dice ties.
        options.sort{$0.dice == $1.dice ? $0.groupIndex<$1.groupIndex:$0.dice>$1.dice}
        for gi in 0..<min(2,options.count) {
            let o=options[gi],g=groups[o.groupIndex]
            var hit=[Int](repeating:0,count:g.sizes.count)
            for i in g.points.indices where o.inside[i] { hit[g.labels[i]]+=1 }
            let whole=hit.indices.filter{hit[$0]==g.sizes[$0]}.count
            let missing=hit.filter{$0==0}.count
            let partial=hit.indices.filter{hit[$0]>0 && hit[$0]<g.sizes[$0]}.count
            let next=options.count>gi+1 ? options[gi+1].dice:0
            var v=[1,fraction(o.inside),fraction(o.distance.map{$0.allSatisfy{$0>=0.5}}),
                   Double(whole)/Double(g.sizes.count),Double(missing)/Double(g.sizes.count),
                   Double(partial)/Double(g.sizes.count),o.dice,o.dice-next,g.ambiguous ? 1:0,g.probability]
            for edge in order {
                let d=o.distance.map{$0[edge]}
                v += [quantile(d,0.01),quantile(d,0.1),quantile(d,0.5),fraction(d.map{$0<0}),
                      fraction(d.map{abs($0)<=1}),fraction(d.map{abs($0)<=2}),fraction(d.map{$0<0.5})]
            }
            for j in v.indices { out[gi*38+j]=min(32,max(-32,v[j])) }
        }
        return out
    }

    private static func seedFeatures(_ s: NativeOCRDetectorSeedEvidence?,_ f: Frame) -> [Double] {
        let empty=[Double](repeating:0,count:16)
        guard let s,s.completeCCScan==true,s.ownershipVersion==2,!s.components.isEmpty,
              s.sourceWidth>0,s.sourceHeight>0,s.mapFullWidth>0,s.mapFullHeight>0 else { return empty }
        let sx=Double(s.sourceWidth)/Double(s.mapFullWidth),sy=Double(s.sourceHeight)/Double(s.mapFullHeight)
        var corners=[V](),centers=[V](),weights=[Double](),extents=[[Double]](),probabilities=[Double]()
        for cc in s.components {
            var cp=[V]()
            for run in cc.runs where run.count>0 {
                let x0=Double(run.x)*sx,x1=Double(run.x+run.count)*sx
                let y0=Double(run.y)*sy,y1=Double(run.y+1)*sy
                cp += [V(x:x0,y:y0),V(x:x1,y:y0),V(x:x1,y:y1),V(x:x0,y:y1)]
                centers.append(V(x:(x0+x1)/2,y:(y0+y1)/2));weights.append(Double(run.count))
            }
            if !cp.isEmpty {
                corners += cp
                let z=project(cp,f);extents.append([z[1]-z[0],z[3]-z[2]]);probabilities.append(cc.meanProbability)
            }
        }
        guard !corners.isEmpty else { return empty }
        let ext=project(corners,f),weight=weights.reduce(0,+)
        let ns=centers.map{($0-f.center).dot(f.normal)},ts=centers.map{($0-f.center).dot(f.axis)}
        var mn=0.0,mt=0.0
        for i in weights.indices { mn+=ns[i]*weights[i];mt+=ts[i]*weights[i] }
        mn/=weight;mt/=weight
        var covariance=0.0,variance=0.0
        for i in weights.indices {
            covariance+=weights[i]*(ns[i]-mn)*(ts[i]-mt);variance+=weights[i]*(ts[i]-mt)*(ts[i]-mt)
        }
        let widths=extents.map{$0[0]},lengths=extents.map{$0[1]},mean=widths.reduce(0,+)/Double(widths.count)
        let deviation=sqrt(widths.map{pow($0-mean,2)}.reduce(0,+)/Double(widths.count))
        var v=[1,1,Double(extents.count),Double((s.ambiguousComponents ?? []).count),
               Double((s.candidateComponents ?? []).count),probabilities.reduce(0,+)/Double(probabilities.count),
               weight*sx*sy/(f.scale[0]*f.scale[2]),Double(weights.count),variance>0 ? covariance/variance:0]
        v += (0..<4).map{(ext[$0]-f.bounds[$0])/f.scale[$0]}
        v += [quantile(widths,0.5)/f.scale[0],quantile(lengths,0.5)/f.scale[2],deviation/max(1e-9,mean)]
        return v
    }
    private static let diagnosticNames = Array(featureNames[107..<144]).map {
        String($0.dropFirst("physical/diagnostic/".count))
    }
    private static func physical(rawIndex: Int,raw: [[Double]],frame f: Frame,
                                 observations: [PhysicalObservation]) -> [Double] {
        var v=[Double](repeating:0,count:89)
        let matches=observations.filter {
            $0.isSourceOriginal && $0.originalDetectorIndex==rawIndex && $0.sourceMembers==[rawIndex] &&
                sameQuad($0.actualQueryPolygon,raw) && sameQuad($0.queryPolygon,raw)
        }
        guard matches.count==1 else { v[1]=matches.count>1 ? 1:0;return v }
        let m=matches[0].measurement,d=m.diagnostics
        guard let p=quad(m.polygon),let other=frame(m.polygon) else { return v }
        let ext=project(p,f),residual=(0..<4).map{(ext[$0]-f.bounds[$0])/f.scale[$0]}
        let angle=atan2(f.axis.x*other.axis.y-f.axis.y*other.axis.x,f.axis.dot(other.axis))
        let normal=(d["completeNormalInk"] ?? 0)>0
        let along=(d["completeAlongInk"] ?? 0)>0 || m.terminalEvidence == .completeSourceInk
        let rim=(d["measuredWhiteRimPixels"] != nil && d["fillPixels"] != nil && d["measuredWhiteRimPixels"]!>d["fillPixels"]!)
        v[0]=1;v[2]=d["completeNormalInk"] != nil ? 1:0
        v[3]=(d["completeAlongInk"] != nil || m.terminalEvidence != nil) ? 1:0
        v[4]=normal ? 1:0;v[5]=along ? 1:0;v[6]=m.terminalEvidence == .completeSourceInk ? 1:0;v[7]=rim ? 1:0
        v[8]=tan(angle);v[9]=(ext[1]-ext[0])/f.scale[0];v[10]=(ext[3]-ext[2])/f.scale[2]
        for i in 0..<4 { v[11+i]=residual[i] }
        for (i,k) in diagnosticNames.enumerated() { v[15+i]=d[k] ?? 0;v[52+i]=d[k] != nil ? 1:0 }
        return v
    }
}
