import Foundation

extension NativeAppearanceLateGradient.Engine {
    struct ShellRay {let origin:Int,primary:Int,outer:Int,component:Int,sector:Int,widths:[Double],delta:Double,white:[Double],whitePixel:Int
        func dictionary(_ width:Int)->D {["origin":[origin%width,origin/width],"primaryXY":[primary%width,primary/width],"outerXY":[outer%width,outer/width],
            "component":component,"sector":sector,"widthsPx":widths,"outerDeltaE":delta,"whiteRGB":white,"whiteXY":[whitePixel%width,whitePixel/width]]}
    }
    struct ShellScan {let rows:[ShellRay],counts:[String:Int]}
    func shellScan(_ core:[UInt8],primary:[Double]) throws -> ShellScan {
        typealias L=NativeAppearanceLateGradient
        if !core.contains(1) {return .init(rows:[],counts:[:])}
        let white=(0..<n).map {image[$0*3]>=90 && hypot(image[$0*3+1],image[$0*3+2])<=10},family=try self.family(primary)
        let dark=(0..<n).map {family[$0] != 0 && !white[$0]}
        let inside=try depth(core),outside=try depth(core.map {$0==0 ? 1:0})
        let signed=zip(inside,outside).map {$0-$1},smooth=try NativeAppearancePhysicalImage.gaussian(signed,width:w,height:h,sigma:1)
        let gradient=NativeAppearancePhysicalImage.gradient(smooth,width:w,height:h),eroded=try NativeAppearancePhysicalImage.erode(core,width:w,height:h)
        let edge=(0..<n).filter {core[$0] != 0 && eroded[$0]==0},points=take(edge,limit:900),cc=try component(core)
        let depthLimit=max(10,min(40,Int((font*0.4).rounded(.toNearestOrEven))))
        var rows:[ShellRay]=[],counts=[String:Int](),seen=Set<Int>()
        for origin in points {
            let nx = -Double(gradient.x[origin]),ny = -Double(gradient.y[origin]),norm=hypot(nx,ny)
            if norm<0.2 {continue}
            var coords:[Int]=[],tt:[Double]=[]
            for step in 0...(depthLimit*2) {
                let t=Double(step)*0.5,x=Int((Double(origin%w)+t*nx/norm).rounded(.toNearestOrEven)),y=Int((Double(origin/w)+t*ny/norm).rounded(.toNearestOrEven))
                if x<0 || y<0 || x>=w || y>=h {break}
                let p=y*w+x;if coords.last != p {coords.append(p);tt.append(t)}
            }
            if coords.count<5 {counts["crop-censored",default:0]+=1;continue}
            guard let start=coords.firstIndex(where:{core[$0]==0}) else {continue}
            counts["rays",default:0]+=1
            guard let band=(start..<coords.count).first(where:{tt[$0]-tt[start]<=4 && dark[coords[$0]]}) else {counts["no-attached-primary",default:0]+=1;continue}
            var end=band;while end<coords.count && dark[coords[end]] {end+=1}
            if end==coords.count {counts["primary-censored",default:0]+=1;continue}
            guard let bright=(end..<coords.count).first(where:{tt[$0]-tt[end]<=2 && white[coords[$0]]}) else {counts["no-white-after-primary",default:0]+=1;continue}
            if !seen.insert(coords[band]).inserted {continue}
            counts["eligible",default:0]+=1
            var finish=bright;while finish<coords.count && white[coords[finish]] {finish+=1}
            if finish==coords.count {counts["white-right-censored",default:0]+=1;continue}
            let tail=(finish..<coords.count).filter {tt[$0]<=tt[finish]+2}
            if tail.isEmpty || tt.last!<tt[finish]+2 {counts["exterior-censored",default:0]+=1;continue}
            if (bright...tail.last!).contains(where:{core[coords[$0]] != 0}) {counts["glyph-reentry",default:0]+=1;continue}
            if tail.contains(where:{white[coords[$0]] || dark[coords[$0]]}) {counts["unstable-exterior",default:0]+=1;continue}
            let whiteLab=L.median((bright..<finish).map {lab(coords[$0])}),delta=tail.map {L.d(lab(coords[$0]),whiteLab)}.min()!
            if delta<12 {counts["weak-outer-edge",default:0]+=1;continue}
            let first=(tt[max(0,band-1)]+tt[band])*0.5,middle=(tt[end-1]+tt[bright])*0.5,last=(tt[finish-1]+tt[finish])*0.5
            let pixels=Array(coords[bright..<finish]),median=L.median(pixels.map {rgb($0)}),medoid=pixels.min {L.d64(rgb($0),median)<L.d64(rgb($1),median)}!
            let sector=Int((atan2(ny,nx)+Double.pi)/(Double.pi/2))%4
            rows.append(.init(origin:origin,primary:coords[band],outer:coords[finish],component:Int(cc.labels[origin]),sector:sector,
                widths:[middle-first,last-middle],delta:delta,white:rgb(medoid),whitePixel:medoid))
        }
        return .init(rows:rows,counts:counts)
    }
    func shellSummary(_ scan:ShellScan)->D {
        typealias L=NativeAppearanceLateGradient
        let rows=scan.rows
        if rows.isEmpty {return ["profiles":0,"components":0,"opposing":0,"sectors":0,"support":0,"widthPx":NSNull(),"widthMAD":NSNull(),"coherence":0,"raySupport":0,"examples":[D]()]}
        let widths=(0..<2).map {c in L.q(rows.map {$0.widths[c]})}
        let mad=(0..<2).map {c in L.q(rows.map {abs($0.widths[c]-widths[c])},0.75)}
        let support=Double(rows.count)/Double(max(1,scan.counts["eligible"] ?? 0)),raySupport=Double(rows.count)/Double(max(1,scan.counts["rays"] ?? 0))
        let center=L.median(rows.map(\.white)),medoid=rows.indices.min {L.d64(rows[$0].white,center)<L.d64(rows[$1].white,center)}!
        let components=Set(rows.map(\.component)),opposing=components.filter {c in let s=Set(rows.filter {$0.component==c}.map(\.sector));return (s.contains(0)&&s.contains(2)) || (s.contains(1)&&s.contains(3))}.count
        return ["profiles":rows.count,"components":components.count,"opposing":opposing,"sectors":Set(rows.map(\.sector)).count,"support":support,"widthPx":widths,
            "widthMAD":mad,"raySupport":raySupport,"coherence":raySupport/(1+mad[1]/max(0.5,widths[1])),"whiteRGB":rows[medoid].white,
            "whiteRGBWitnessXY":point(rows[medoid].whitePixel),"examples":rows.prefix(8).map {$0.dictionary(w)}]
    }
    func shifted(_ core:[UInt8],dx:Int,dy:Int)->[UInt8] {
        var result=[UInt8](repeating:0,count:n)
        for y in 0..<h {for x in 0..<w where core[y*w+x] != 0 {
            let xx=x+dx,yy=y+dy;if xx>=0 && yy>=0 && xx<w && yy<h {result[yy*w+xx]=1}
        }}
        return result
    }
    func outerShell(_ prediction:D,diagnostic:D,threshold:Double) throws -> D {
        typealias L=NativeAppearanceLateGradient
        guard threshold.isFinite,threshold>=0 else {throw NativeOpenCV.Failure.native("Invalid outer shell threshold")}
        var out=prediction,outline=L.part(prediction,"outline")
        if let tag=outline["outerShellCorrection"] as? D {
            guard tag["version"] as? String==L.shellVersion,tag["previousObservedLayersPresent"] is Bool,tag["previousObservedLayersValue"] != nil else {throw NativeOpenCV.Failure.native("Invalid finite-secondary warm provenance")}
            if tag["previousObservedLayersPresent"] as? Bool == true {outline["observedLayers"]=tag["previousObservedLayersValue"]} else {outline.removeValue(forKey:"observedLayers")}
            outline.removeValue(forKey:"outerShellCorrection");out["outline"]=outline
        }
        let existing=outline["observedLayers"]
        if existing != nil && !(existing is NSNull) && !(existing is [Any]) {throw NativeOpenCV.Failure.native("Observed layers must be array or null")}
        if (existing as? [Any])?.count ?? 0 >= 2 {return out}
        if outline["present"] as? Bool != true {return out}
        let primary=L.vector(outline["rgb"]);if try labs([primary])[0][0]>80 {return out}
        let semantic=L.part(diagnostic,"semantic")
        if semantic.isEmpty {return out}
        let (core,certificates)=try confirmedBodies(diagnostic)
        if !core.contains(1) {return out}
        let scan=try shellScan(core,primary:primary),summary=shellSummary(scan),distance=max(8,Int((font*0.15).rounded(.toNearestOrEven)))
        var nulls:[D]=[]
        for (dx,dy) in [(distance,0),(-distance,0),(0,distance),(0,-distance)] {
            var candidate=shellSummary(try shellScan(shifted(core,dx:dx,dy:dy),primary:primary));candidate.removeValue(forKey:"examples")
            nulls.append(["dx":dx,"dy":dy,"summary":candidate])
        }
        let excess=L.number(summary["coherence"])-nulls.map {L.number(L.part($0,"summary")["coherence"])}.max()!
        let widths=L.vector(summary["widthPx"]),spread=L.vector(summary["widthMAD"])
        let recurrence=L.number(summary["profiles"])>=12 && L.number(summary["components"])>=3 && L.number(summary["opposing"])>=2 && L.number(summary["sectors"])>=3
        let structural=recurrence && widths.count==2 && widths.allSatisfy {$0>=0.5} && widths[1]<=max(3,font*0.15) && (0..<2).allSatisfy {spread[$0]<=max(0.75,widths[$0]*0.5)}
        if !structural || excess<=threshold {return out}
        let report:D=["version":L.shellVersion,"identified":true,"applied":true,"GTAtInference":false,"sourceContextExpanded":false,"threshold":threshold,
            "semantics":"Observed finite source-composite secondary band, not intrinsic pigment or nominal stroke width",
            "sourceVersion":diagnostic["version"] ?? NSNull(),"confirmedBodies":certificates.count,"summary":summary,"counts":scan.counts,
            "shiftedNulls":nulls,"excessCoherence":excess,"structural":structural,"reason":"observed-finite-secondary-layer"]
        let ranges=(0..<2).map {c in [0.25,0.75].map {L.q(scan.rows.map {$0.widths[c]},$0)}}
        let previous=outline["observedLayers"]
        outline["observedLayers"]=[["rgb":primary,"widthPx":widths[0],"observedWidthInterquartileRangePx":ranges[0]],
            ["rgb":summary["whiteRGB"]!,"widthPx":widths[1],"observedWidthInterquartileRangePx":ranges[1],"nativeRGBWitnessXY":summary["whiteRGBWitnessXY"]!]]
        outline["outerShellCorrection"]=["version":L.shellVersion,"previousObservedLayersPresent":previous != nil,
            "previousObservedLayersValue":previous ?? NSNull(),"sourceEvidence":report] as D
        out["outline"]=outline;return out
    }
}
