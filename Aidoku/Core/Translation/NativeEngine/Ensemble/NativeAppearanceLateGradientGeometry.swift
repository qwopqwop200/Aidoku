import Foundation

extension NativeAppearanceLateGradient.Engine {
    struct GradientBody {
        let seed:Int, body:[UInt8], positions:[Int], colors:[[Double]], colorPositions:[Int]
        let slope:[Double],axis:[Double],span:Double,residual:Double,r2:Double,validation:Double,seedPixels:Int
        var group:Int=0
    }
    // Jacobi eigensolver for the tiny symmetric covariance / least-square Gram.
    func eigen(_ matrix:[[Double]]) -> (values:[Double],vectors:[[Double]]) {
        var a=matrix,v=[[1.0,0,0],[0,1,0],[0,0,1]]
        for _ in 0..<60 {
            var p=0,q=1
            for i in 0..<3 {for j in (i+1)..<3 where abs(a[i][j])>abs(a[p][q]) {p=i;q=j}}
            if abs(a[p][q])<1e-12 {break}
            let angle=0.5*atan2(2*a[p][q],a[q][q]-a[p][p]),c=cos(angle),s=sin(angle)
            let app=a[p][p],aqq=a[q][q],apq=a[p][q]
            a[p][p]=c*c*app-2*s*c*apq+s*s*aqq;a[q][q]=s*s*app+2*s*c*apq+c*c*aqq;a[p][q]=0;a[q][p]=0
            for k in 0..<3 where k != p && k != q {
                let x=a[k][p],y=a[k][q];a[k][p]=c*x-s*y;a[p][k]=a[k][p];a[k][q]=s*x+c*y;a[q][k]=a[k][q]
            }
            for k in 0..<3 {let x=v[k][p],y=v[k][q];v[k][p]=c*x-s*y;v[k][q]=s*x+c*y}
        }
        return ((0..<3).map {a[$0][$0]},v)
    }
    func plane(_ positions:[Int]) -> [[Double]] {
        var gram=Array(repeating:Array(repeating:0.0,count:3),count:3),right=gram
        for p in positions {
            let row=[1.0,Double(p%w)/max(1,font),Double(p/w)/max(1,font)],l=lab(p)
            for i in 0..<3 {for j in 0..<3 {gram[i][j]+=row[i]*row[j];right[i][j]+=row[i]*l[j]}}
        }
        let e=eigen(gram),maximum=e.values.map(abs).max()!,cutoff=maximum*1e-12
        var fit=Array(repeating:Array(repeating:0.0,count:3),count:3)
        for k in 0..<3 where e.values[k]>cutoff {
            for channel in 0..<3 {
                let projection=(0..<3).reduce(0.0) {$0+e.vectors[$1][k]*right[$1][channel]}/e.values[k]
                for i in 0..<3 {fit[i][channel]+=e.vectors[i][k]*projection}
            }
        }
        return fit
    }
    func planeError(_ fit:[[Double]],_ p:Int) -> Double {
        let row=[1.0,Double(p%w)/max(1,font),Double(p/w)/max(1,font)],l=lab(p)
        return sqrt((0..<3).reduce(0.0) {sum,c in let delta=l[c]-(0..<3).reduce(0.0) {$0+row[$1]*fit[$1][c]};return sum+delta*delta})
    }
    func gradientGroups(_ prediction:D) throws -> [[GradientBody]] {
        typealias L=NativeAppearanceLateGradient
        let fill=L.part(prediction,"fill"),bg=L.part(prediction,"background"),outline=L.part(prediction,"outline")
        var colors=L.colors(fill["colors"]);if colors.isEmpty {colors=[L.vector(fill["rgb"])]}
        var competing=L.colors(bg["colors"]);if competing.isEmpty {competing=[L.vector(bg["rgb"])]}
        if outline["present"] as? Bool == true {competing.append(L.vector(outline["rgb"]))}
        let rivals=try labs(competing),targets=try labs(colors)
        var seed=[UInt8](repeating:0,count:n)
        for target in targets where rivals.map({L.d($0,target)}).min()!>=15 {
            for p in 0..<n where input.ownMask[p] != 0 && (input.memberPolygons.isEmpty || roi[p] != 0) {
                if L.d(lab(p),target)<=5 {seed[p]=1}
            }
        }
        let cc=try component(seed),minimum=max(6,Int(font*font*0.001))
        let order=NativeAppearanceNumeric.numpyArgSort(Array(cc.areas.dropFirst()).map {-Double($0)}).prefix(32).map {$0+1}
        var seen=[UInt8](repeating:0,count:n),trials:[GradientBody]=[]
        for identity in order where cc.areas[identity]>=minimum {
            let seeds=(0..<n).filter {cc.labels[$0]==Int32(identity)},p=seeds[seeds.count/2]
            if seen[p] != 0 {continue}
            guard let body=flood(p) else {continue}
            for k in 0..<n where body[k] != 0 {seen[k]=1}
            let seeded=(0..<n).filter {body[$0] != 0 && seed[$0] != 0}.count
            if seeded<minimum || body.filter({$0 != 0}).count<minimum*2 {continue}
            let distance=try depth(body),positions=(0..<n).filter {distance[$0]>1.5}
            if positions.count<max(12,minimum) {continue}
            let ll=positions.map {lab($0)},count=Double(ll.count)
            let center=(0..<3).map {c in Double(ll.reduce(Float(0)) {$0+Float($1[c])}/Float(ll.count))}
            var covariance=Array(repeating:Array(repeating:0.0,count:3),count:3)
            for l in ll {for i in 0..<3 {for j in 0..<3 {covariance[i][j]+=(l[i]-center[i])*(l[j]-center[j])/count}}}
            let e=eigen(covariance),largest=e.values.indices.max {e.values[$0]<e.values[$1]}!,axis=(0..<3).map {e.vectors[$0][largest]}
            let projection=ll.map {l in (0..<3).reduce(0.0) {$0+(l[$1]-center[$1])*axis[$1]}}
            let span=L.q(projection,0.9)-L.q(projection,0.1)
            if span<8 {continue}
            let fit=plane(positions),errors=positions.map {planeError(fit,$0)}
            let energy=ll.reduce(0.0) {sum,l in sum+(0..<3).reduce(0.0) {s,c in s+(l[c]-center[c])*(l[c]-center[c])}}/count
            let r2=1-errors.reduce(0.0) {$0+$1*$1}/count/max(1e-6,energy)
            let train=positions.filter {($0%w+$0/w)%2==0},test=positions.filter {($0%w+$0/w)%2 != 0}
            if train.count<4 || test.count<4 {continue}
            let validationFit=plane(train),validation=1-test.reduce(0.0) {$0+pow(planeError(validationFit,$1),2)}/Double(test.count)/max(1e-6,energy)
            var candidates:[[Double]]=[],witnesses:[Int]=[]
            for quantile in [0.1,0.5,0.9] {
                let value=L.q(projection,quantile);var ids=projection.indices.filter {abs(projection[$0]-value)<=1.5}
                if ids.isEmpty {ids=[projection.indices.min {abs(projection[$0]-value)<abs(projection[$1]-value)}!]}
                let median=L.median(ids.map {rgb(positions[$0])})
                let chosen=ids.min {L.d64(rgb(positions[$0]),median)<L.d64(rgb(positions[$1]),median)}!
                candidates.append(rgb(positions[chosen]));witnesses.append(positions[chosen])
            }
            if r2>=0.6 && validation>=0.6 {trials.append(.init(seed:p,body:body,positions:positions,colors:candidates,colorPositions:witnesses,
                slope:Array(fit.dropFirst()).flatMap {$0},axis:axis,span:span,residual:L.q(errors,0.75),r2:r2,validation:validation,seedPixels:seeded))}
        }
        var groups:[[GradientBody]]=[]
        for body in trials {
            let color=try labs([rgb(body.seed)])[0],length=max(1e-9,sqrt(body.slope.reduce(0) {$0+$1*$1})),slope=body.slope.map {$0/length}
            var found:Int?
            for i in groups.indices {
                let first=try labs([rgb(groups[i][0].seed)])[0]
                if L.d(color,first)<=15 && groups[i].allSatisfy({other in
                    let norm=max(1e-9,sqrt(other.slope.reduce(0) {$0+$1*$1}))
                    return zip(slope,other.slope).reduce(0.0) {$0+$1.0*$1.1/norm}>=0.8
                }) {found=i;break}
            }
            if let found {groups[found].append(body)} else {groups.append([body])}
        }
        return groups.filter {$0.count>=3}
    }
    func trusted(_ groups:[[GradientBody]],prediction:D) throws -> ([[GradientBody]],D) {
        typealias L=NativeAppearanceLateGradient
        let config=try heads.configuration("appearance/pixel-role-model")
        let reference=try NativeAppearanceInferenceGraph.featureContext(input:input,packet:packet,heads:heads,ops:ops)
        let model=try heads.model("appearance/pixel-role-model/classifier")
        guard let column=model.classes.firstIndex(of:0) else {throw NativeAppearanceModelHeads.Failure.invalidMetadata("fill class in pixel role model")}
        let thresholds=L.part(config,"roleProbabilityThresholds"),threshold=L.number(thresholds["fill"] ?? config["probabilityThreshold"])
        var accepted:[[GradientBody]]=[],evidence:[D]=[]
        for group in groups {
            let matrix=try NativeAppearancePixelFeatures71.extract(input,positions:group.map(\.seed),fill:L.vector(L.part(reference,"fill")["rgb"]),
                outline:L.vector(L.part(reference,"outline")["rgb"]),background:L.vector(L.part(reference,"background")["rgb"]),
                outlinePresent:L.part(reference,"outline")["present"] as? Bool == true,
                outlineProbability:L.number(L.part(reference,"outline")["probability"]),ops:ops)
            var confirmed:[GradientBody]=[],seeds:[D]=[]
            for (i,body) in group.enumerated() {
                let probability=try model.predictProbability(matrix[i].map(Double.init))[column],p=body.seed,rf=input.rf
                let owner=max(Double(rf[p*27+15])*Double(rf[p*27+16]),Double(rf[p*27+17])*Double(rf[p*27+18]))
                let keep=probability>=threshold && supported(p)
                if keep {confirmed.append(body)}
                seeds.append(["xy":point(p),"rawFillProbability":probability,"rfOwner":owner,"softSegmentation":Double(max(input.primary[p],input.boundary[p])),"ocrBox":Double(input.ocr[p*8]),"confirmed":keep])
            }
            if confirmed.count>=3 {accepted.append(confirmed)}
            evidence.append(["confirmedSeeds":confirmed.count,"seeds":seeds])
        }
        return(accepted,["sourceFillThreshold":threshold,"groups":evidence,"rawClassifierProbabilitiesChanged":false])
    }
    func boundaryPoints(_ body:[UInt8]) -> [Int] {
        guard let start=body.firstIndex(where:{$0 != 0}) else {return []}
        let directions=[(-1,0),(-1,1),(0,1),(1,1),(1,0),(1,-1),(0,-1),(-1,-1)]
        var current=start,back=(start%w-1,start/w),firstNext:Int?,points:[Int]=[]
        for _ in 0..<(n*8) {
            let x=current%w,y=current/w
            let begin=directions.firstIndex {x+$0.0==back.0 && y+$0.1==back.1} ?? 0
            var next:Int?,newBack=back
            for offset in 0..<8 {
                let index=(begin+offset)%8,xx=x+directions[index].0,yy=y+directions[index].1
                if xx>=0 && yy>=0 && xx<w && yy<h && body[yy*w+xx] != 0 {
                    next=yy*w+xx;let before=(index+7)%8;newBack=(x+directions[before].0,y+directions[before].1);break
                }
            }
            if let next,let firstNext,current==start && next==firstNext {break}
            points.append(current)
            guard let next else {break}
            if firstNext==nil {firstNext=next};current=next;back=newBack
        }
        return points
    }
    struct Band {let rgb:[Double],pixel:Int,band:[Int],component:Int,group:Int,sector:Int,drop:Double,exterior:[Double],samples:Int}
    func contourMeasure(_ groups:[[GradientBody]]) throws -> D {
        typealias L=NativeAppearanceLateGradient
        var bodies:[(Int,GradientBody)]=[],all=[UInt8](repeating:0,count:n)
        for (g,group) in groups.enumerated() {for body in group {bodies.append((g,body));for p in 0..<n where body.body[p] != 0 {all[p]=1}}}
        let depthLimit=max(6,min(16,Int((font*0.2).rounded(.toNearestOrEven))))
        var records:[Band]=[],reasons=[String:Int](),eligible=0
        func reject(_ reason:String) {reasons[reason,default:0]+=1;if !["outside-original-crop","insufficient-native-exterior","other-observed-fill-body","no-sharp-fill-boundary"].contains(reason) {eligible+=1}}
        for (ci,item) in bodies.enumerated() {
            let (gi,body)=item,inside=try depth(body.body),outside=try depth(body.body.map {$0==0 ? 1:0})
            let signed=zip(inside,outside).map {$0-$1},smooth=try NativeAppearancePhysicalImage.gaussian(signed,width:w,height:h,sigma:1)
            let gradient=NativeAppearancePhysicalImage.gradient(smooth,width:w,height:h)
            let allPoints=boundaryPoints(body.body)
            let points=allPoints.count>96 ? (0..<96).map {allPoints[$0*(allPoints.count-1)/95]}:allPoints
            for origin in points {
                let gx = -Double(gradient.x[origin]),gy = -Double(gradient.y[origin]),norm=hypot(gx,gy)
                if norm<0.2 {continue};let nx=gx/norm,ny=gy/norm
                var coords:[Int]=[],censored=false
                for t in 0...depthLimit {
                    let x=Int((Double(origin%w)+nx*Double(t)).rounded(.toNearestOrEven)),y=Int((Double(origin/w)+ny*Double(t)).rounded(.toNearestOrEven))
                    if x<0 || y<0 || x>=w || y>=h {censored=true;break}
                    let p=y*w+x;if coords.last != p {coords.append(p)}
                }
                if censored {reject("outside-original-crop");continue}
                guard let first=coords.firstIndex(where:{body.body[$0]==0}),first>0,coords.count-first>=5 else {reject("insufficient-native-exterior");continue}
                let samples=Array(coords.dropFirst(first)),base=lab(coords[first-1])
                if samples.prefix(5).contains(where:{all[$0] != 0 && body.body[$0]==0}) {reject("other-observed-fill-body");continue}
                if L.d(lab(samples[0]),base)<20 {reject("no-sharp-fill-boundary");continue}
                let k=(0..<3).min {image[samples[$0]*3]<image[samples[$1]*3]}!,drop=base[0]-lab(samples[k])[0]
                if drop<20 {reject("not-a-dark-primary-band");continue}
                var recovery:Int?
                let stop=min(k+4,samples.count-1)
                if k+1<stop {for j in (k+1)..<stop where lab(samples[j])[0]>=base[0]-5 && lab(samples[j])[0]-lab(samples[k])[0]>=20 && L.d(lab(samples[j]),lab(samples[j+1]))<=12 {recovery=j;break}}
                guard let recovery else {reject("no-sharp-stable-light-exterior");continue}
                if L.d(lab(samples[recovery]),lab(samples[recovery-1]))<20 {reject("soft-recovery-not-contour");continue}
                if k>0 {
                    let before=[coords[first-1]]+Array(samples.prefix(k+1))
                    if (1..<before.count).map({L.d(lab(before[$0]),lab(before[$0-1]))}).max()!<20 {reject("soft-entry-not-contour");continue}
                }
                let band=Array(samples.prefix(recovery)).filter {base[0]-lab($0)[0]>=20},median=L.median(band.map {lab($0)})
                let selected=band.min {L.d(lab($0),median)<L.d(lab($1),median)}!
                let sector=Int((atan2(ny,nx)+Double.pi)/(Double.pi/2))%4
                records.append(.init(rgb:rgb(selected),pixel:samples[k],band:band,component:ci,group:gi,sector:sector,drop:drop,exterior:rgb(samples[recovery]),samples:recovery));eligible+=1
            }
        }
        var proposals:[D]=[]
        for gi in groups.indices {
            let rows=records.filter {$0.group==gi};if rows.isEmpty {continue}
            let pixels=Set(rows.map(\.pixel)),sectors=Set(rows.map(\.sector)),components=Set(rows.map(\.component))
            let opposing=components.filter {c in let s=Set(rows.filter {$0.component==c}.map(\.sector));return (s.contains(0)&&s.contains(2)) || (s.contains(1)&&s.contains(3))}.count
            var seen=Set<Int>(),band:[Int]=[]
            for row in rows {for p in row.band where seen.insert(p).inserted {band.append(p)}}
            let ll=band.map {lab($0)},median=L.median(ll),best=band.min {L.d(lab($0),median)<L.d(lab($1),median)}!
            let chromatic=ll.filter {hypot($0[1],$0[2])>=8}
            let hue:Double
            if chromatic.isEmpty {hue=1} else {
                let a=chromatic.reduce(0.0) {$0+$1[1]/hypot($1[1],$1[2])}/Double(chromatic.count)
                let b=chromatic.reduce(0.0) {$0+$1[2]/hypot($1[1],$1[2])}/Double(chromatic.count);hue=hypot(a,b)
            }
            let coherent=chromatic.isEmpty || (Double(chromatic.count)/Double(ll.count)>=0.8 && hue>=0.9),support=Double(rows.count)/Double(max(1,eligible))
            let accepted=coherent && pixels.count>=12 && sectors.count>=3 && components.count>=3 && opposing>=2 && support>=0.5
            proposals.append(["rgb":rgb(best),"accepted":accepted,"nativePixels":pixels.count,"profiles":rows.count,"support":support,"components":components.count,
                "sectors":sectors.sorted(),"opposingComponents":opposing,"observedColourSamples":band.count,"hueAgreement":hue,
                "observedLABQ10Q90":[0.1,0.9].map {q in (0..<3).map {c in L.q(ll.map {$0[c]},q)}}])
        }
        proposals.sort {a,b in
            if (a["accepted"] as! Bool) != (b["accepted"] as! Bool) {return a["accepted"] as! Bool}
            if L.number(a["nativePixels"]) != L.number(b["nativePixels"]) {return L.number(a["nativePixels"])>L.number(b["nativePixels"])}
            return L.number(a["support"])>L.number(b["support"])
        }
        let best=proposals.first {$0["accepted"] as? Bool == true}
        return ["version":"native-gradient-body-primary-contour-v3","identified":best != nil,"rgb":best?["rgb"] ?? NSNull(),"proposals":proposals,
            "finiteFillBodies":bodies.count,"eligibleProfiles":eligible,"censoring":reasons,"GTAtInference":false,"sourceContextExpanded":false]
    }
}
