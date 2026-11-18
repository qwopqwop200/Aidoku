import Foundation

/// Original-crop normal-profile evidence shared by primary contour correction
/// and attached outline rings. No display widths or target labels enter it.
enum NativeAppearanceNormalProfiles {
    private struct Run { let color:Int; let start:Double; let end:Double }
    private struct Pair:Hashable {let first:Int;let second:Int}
    private struct Witness {let widths:[Double];let sector:Int;let contrast:Double}
    private struct PrimaryWitness {let sector:Int;let width:Double;let contrast:Double}
    private struct Profiles {
        let core:[UInt8]
        let samples:[Float]
        let valid:[Bool]
        let dx:[Float]
        let dy:[Float]
        let columns:Int
        var rows:Int {dx.count}
    }
    private static func color(_ prediction:[String:Any],_ role:String) throws -> [Double] {
        guard let rgb=(prediction[role] as? [String:Any])?["rgb"] as? [Double],rgb.count==3,rgb.allSatisfy(\.isFinite) else {
            throw NativeAppearanceModelHeads.Failure.invalidOutput("normal-profile "+role)
        }
        return rgb
    }
    private static func squared(_ a:[Float],_ b:[Float])->Float {
        let x=a[0]-b[0],y=a[1]-b[1],z=a[2]-b[2]
        return (x*x+y*y)+z*z
    }
    private static func profiles(input:SourceNativeInput,prediction:[String:Any],fontPixels:Double,
                                 ops:any NativeAppearanceImageOperations) throws -> Profiles? {
        guard let core=try NativeAppearancePhysicalImage.sourceCore(input,prediction:prediction,ops:ops) else {return nil}
        let w=input.width,h=input.height
        let inside=try ops.distance(core,width:w,height:h,maskSize:5)
        let outside=try ops.distance(core.map {$0==0 ? 1:0},width:w,height:h,maskSize:5)
        let signed=try NativeAppearancePhysicalImage.gaussian(zip(inside,outside).map(-),width:w,height:h,sigma:1)
        let gradient=NativeAppearancePhysicalImage.gradient(signed,width:w,height:h)
        let eroded=try NativeAppearancePhysicalImage.erode(core,width:w,height:h)
        var positions=core.indices.filter {core[$0] != 0 && eroded[$0]==0}
        guard positions.count>=40 else {return nil}
        if positions.count>1600 {
            let original=positions,step=Double(original.count-1)/1599
            positions=(0..<1600).map {original[$0==1599 ? original.count-1:Int(Double($0)*step)]}
        }
        var dx:[Float]=[],dy:[Float]=[],selected:[Int]=[]
        for p in positions {
            let norm=hypot(gradient.x[p],gradient.y[p])
            if norm>0.2 {selected.append(p);dx.append(-gradient.x[p]/norm);dy.append(-gradient.y[p]/norm)}
        }
        // np.arange(-4, depth, .5, dtype=float32), original crop coordinates.
        let depth=max(8,min(72,Int(fontPixels*0.3))),columns=(depth+4)*2
        guard !selected.isEmpty else {
            return Profiles(core:core,samples:[],valid:[],dx:[],dy:[],columns:columns)
        }
        var x=[Float](repeating:0,count:selected.count*columns),y=x
        for row in selected.indices {for column in 0..<columns {
            let step=Float(column)*0.5-4,index=row*columns+column
            x[index]=Float(selected[row]%w)+dx[row]*step
            y[index]=Float(selected[row]/w)+dy[row]*step
        }}
        let observed=try NativeAppearancePhysicalImage.sample(rgb:input.rgb,width:w,height:h,x:x,y:y,rows:selected.count,columns:columns)
        let samples=try ops.lab(rgb:observed.rgb,width:columns,height:selected.count)
        return Profiles(core:core,samples:samples,valid:observed.valid,dx:dx,dy:dy,columns:columns)
    }
    private static func observed(_ profiles:Profiles,_ row:Int,_ index:Int)->Bool {
        let low=index-2,high=index+3
        guard low>=0,high<=profiles.columns else {return false}
        return (low..<high).allSatisfy {profiles.valid[row*profiles.columns+$0]}
    }
    private static func sample(_ profiles:Profiles,_ row:Int,_ column:Int)->[Float] {
        let offset=(row*profiles.columns+column)*3
        return Array(profiles.samples[offset..<offset+3])
    }
    private static func contrast(_ profiles:Profiles,_ row:Int,_ index:Int)->Double {
        Double(sqrt(squared(sample(profiles,row,min(profiles.columns-1,index+2)),sample(profiles,row,max(0,index-2)))))
    }
    private static func sector(_ profiles:Profiles,_ row:Int)->Int {
        Int((atan2(profiles.dy[row],profiles.dx[row])+Float.pi)/(Float.pi/2))%4
    }
    private static func isMixture(_ fill:[Double],_ current:[Double],_ next:[Double],
                                  ops:any NativeAppearanceImageOperations) throws -> Bool {
        let a=zip(current,fill).map(-),b=zip(next,fill).map(-)
        let alpha=zip(a,b).reduce(0.0) {$0+$1.0*$1.1}/max(1,b.reduce(0.0) {$0+$1*$1})
        guard alpha>0.03,alpha<0.97 else {return false}
        let mixture=(0..<3).map {fill[$0]+alpha*b[$0]}
        let labs=try ops.lab(colors:[mixture,current])
        return sqrt(squared(labs[0],labs[1]))<=10
    }
    private static func removeMixtures(_ original:[Run],palette:[[Double]],ops:any NativeAppearanceImageOperations) throws -> [Run] {
        var runs=original,changed=true
        while changed,runs.count>=3 {
            changed=false
            for i in 1..<(runs.count-1) where runs[i].end-runs[i].start<=2.5 {
                if try isMixture(palette[runs[i-1].color],palette[runs[i].color],palette[runs[i+1].color],ops:ops) {
                    runs.remove(at:i);changed=true;break
                }
            }
        }
        return runs
    }

    /// discovery=true implements outline_layer_discovery.measure, including
    /// half-pixel color cores; false implements the accepted outline_layers.measure.
    static func measure(input:SourceNativeInput,packet:NativeAppearanceSourceFeatures209.Packet,prediction:[String:Any],
                        ops:any NativeAppearanceImageOperations,discovery:Bool=false,primaryOnly:Bool=false) throws -> [String:Any] {
        var result:[String:Any]=["version":discovery ? "source-normal-outline-order-discovery-v5":"source-normal-outline-rings-v4",
            "reliable":false,"layers":[[String:Any]](),"GTAtInference":false,"inputContextExpanded":false]
        guard (prediction["outline"] as? [String:Any])?["present"] as? Bool == true else {return result}
        guard let profiles=try profiles(input:input,prediction:prediction,fontPixels:packet.fontPixels,ops:ops) else {return result}
        result["unobservedCoordinateCount"]=profiles.valid.filter {!$0}.count
        result["profileCoordinateCount"]=profiles.valid.count
        var palette=[try color(prediction,"fill"),try color(prediction,"outline")]
        var candidates=try ops.lab(colors:palette)
        for color in packet.colors {
            let lab=try ops.lab(colors:[color])[0]
            if candidates.allSatisfy({sqrt(squared($0,lab))>10}) {palette.append(color);candidates.append(lab)}
        }
        var grouped:[Pair:[Witness]]=[:],order:[Pair]=[]
        var primaryGroups:[Int:[PrimaryWitness]]=[:],primaryOrder:[Int]=[],eligible=0
        for row in 0..<profiles.rows {
            var labels=[Int](repeating:-1,count:profiles.columns)
            for column in labels.indices {
                let value=sample(profiles,row,column)
                var best=0,delta=squared(value,candidates[0])
                for index in candidates.indices.dropFirst() {
                    let distance=squared(value,candidates[index])
                    if distance<delta {best=index;delta=distance}
                }
                if delta<=100,profiles.valid[row*profiles.columns+column] {labels[column]=best}
            }
            guard labels.prefix(12).contains(0) else {continue}
            var runs:[Run]=[],start=0
            for end in 1...labels.count {
                if end==labels.count || labels[end] != labels[start] {
                    if labels[start]>=0,Double(end-start)*0.5 >= (discovery ? 0.5:2) {
                        runs.append(.init(color:labels[start],start:Double(start)*0.5,end:Double(end)*0.5))
                    }
                    start=end
                }
            }
            if discovery {runs=try removeMixtures(runs,palette:palette,ops:ops)}
            guard runs.count>=2,runs[0].color==0 else {continue}
            let firstIndex=runs.indices.dropFirst().first {index in
                discovery ? (runs[index].color != 0 && sqrt(squared(candidates[runs[index].color],candidates[0]))>=20)
                    : runs[index].color==1
            }
            guard let firstIndex,runs[firstIndex].start-runs[0].end<=4 else {continue}
            eligible+=1
            let first=runs[firstIndex],boundary=Int(first.start*2),sector=sector(profiles,row)
            var firstContrast=0.0
            if discovery {
                guard observed(profiles,row,boundary) else {continue}
                firstContrast=contrast(profiles,row,boundary)
                if firstContrast>=15 {
                    if primaryGroups[first.color]==nil {primaryOrder.append(first.color)}
                    primaryGroups[first.color,default:[]].append(.init(sector:sector,width:first.end-first.start,contrast:firstContrast))
                }
                if primaryOnly {continue}
            }
            guard runs.count>firstIndex+1 else {continue}
            let second=runs[firstIndex+1]
            guard second.color != 0,second.color != (discovery ? first.color:1),second.start-first.end<=2 else {continue}
            if discovery,try isMixture(palette[0],palette[first.color],palette[second.color],ops:ops) {continue}
            guard second.end<Double(profiles.columns)*0.5-1,second.end-second.start >= (discovery ? 0.5:1.5) else {continue}
            if runs.count>firstIndex+2,(runs[firstIndex+2].color==0 || runs[firstIndex+2].color==(discovery ? first.color:1)) {continue}
            if discovery,firstContrast<15 {continue}
            let transition=second.start-first.end
            let widths=[first.end-first.start+0.5*(first.start-runs[0].end+transition),second.end-second.start+0.5*transition+0.5]
            guard widths.max()!<=widths.min()!*4 else {continue}
            let end=Int(second.end*2)
            guard observed(profiles,row,end) else {continue}
            let key=Pair(first:discovery ? first.color:1,second:second.color)
            if grouped[key]==nil {order.append(key)}
            grouped[key,default:[]].append(.init(widths:widths,sector:sector,contrast:contrast(profiles,row,end)))
        }
        result["eligibleProfiles"]=eligible
        if discovery,!primaryOrder.isEmpty {
            var chosen=primaryOrder[0]
            for key in primaryOrder.dropFirst() where primaryGroups[key]!.count>primaryGroups[chosen]!.count {chosen=key}
            let evidence=primaryGroups[chosen]!,count=primaryOrder.reduce(0) {$0+primaryGroups[$1]!.count}
            let support=Double(evidence.count)/Double(max(1,count)),directions=Set(evidence.map(\.sector)).count
            result["primaryContourProposal"]=["rgb":palette[chosen],"profiles":evidence.count,"directionalSectors":directions,
                "sharpProfileSupport":support,"sharpProfileCount":count,
                "reliable":evidence.count>=40 && directions>=3 && support>=0.65,
                "medianColourCoreWidthPx":NativeAppearanceNumeric.quantile(evidence.map(\.width),0.5)]
        }
        if discovery,primaryOnly {return result}
        guard !order.isEmpty else {return result}
        var chosen=order[0]
        for key in order.dropFirst() where grouped[key]!.count>grouped[chosen]!.count {chosen=key}
        let evidence=grouped[chosen]!,sectors=Set(evidence.map(\.sector)).count
        let support=Double(evidence.count)/Double(max(1,eligible))
        let outerDelta=NativeAppearanceNumeric.quantile(evidence.map(\.contrast),0.5)
        result.merge(["agreeingProfiles":evidence.count,"directionSectors":sectors,"profileSupport":support,
                      "medianOuterBoundaryDeltaE":outerDelta]) {_,new in new}
        let centers=(0..<2).map {i in NativeAppearanceNumeric.quantile(evidence.map {$0.widths[i]},0.5)}
        if discovery {result["proposedColors"]=[palette[chosen.first],palette[chosen.second]];result["proposedMedianWidthsPx"]=centers}
        guard evidence.count>=30,sectors>=3,support >= (discovery ? 0.05:0.1),outerDelta>=20 else {return result}
        let dispersion=(0..<2).map {i in NativeAppearanceNumeric.quantile(evidence.map {abs($0.widths[i]-centers[i])},0.75)}
        guard (0..<2).allSatisfy({dispersion[$0]<=max(1.5,centers[$0]*0.5)}) else {return result}
        let image=try ops.lab(rgb:input.rgb,width:input.width,height:input.height)
        let secondPaint=(0..<input.width*input.height).map {p in squared(Array(image[p*3..<p*3+3]),candidates[chosen.second])<=100}
        let refined=profiles.core.indices.map {profiles.core[$0] != 0 && !secondPaint[$0] ? UInt8(1):0}
        let distance=try ops.distance(refined.map {$0==0 ? 1:0},width:input.width,height:input.height,maskSize:5)
        let total=centers[0]+centers[1]
        var nearCount=0,nearPaint=0,farCount=0,farPaint=0
        for p in distance.indices {
            // NumPy compares float32 distance arrays with float32 weak scalars.
            if distance[p]>=Float(centers[0]),distance[p]<=Float(total) {nearCount+=1;if secondPaint[p] {nearPaint+=1}}
            if distance[p]>=Float(total+3),distance[p]<=Float(total+centers[1]+3) {farCount+=1;if secondPaint[p] {farPaint+=1}}
        }
        let near=nearCount>0 ? Double(nearPaint)/Double(nearCount):0
        let far=farCount>0 ? Double(farPaint)/Double(farCount):1,persistence=far/max(0.001,near)
        result.merge(["secondRingNearDensity":near,"secondRingFarDensity":far,"secondRingExteriorPersistence":persistence]) {_,new in new}
        guard near>=0.15,persistence<=0.5 else {return result}
        let colors=[chosen.first,chosen.second]
        result["reliable"]=true;result["totalWidthPx"]=total
        result["layers"]=(0..<2).map {i -> [String:Any] in
            ["rgb":palette[colors[i]],"widthPx":centers[i],"observedWidthInterquartileRangePx":[0.25,0.75].map {q in
                NativeAppearanceNumeric.quantile(evidence.map {$0.widths[i]},q)
            }]
        }
        return result
    }

    static func correctPrimary(input:SourceNativeInput,packet:NativeAppearanceSourceFeatures209.Packet,prediction:[String:Any],
                               heads:NativeAppearanceModelHeads,ops:any NativeAppearanceImageOperations,
                               roleRoot:String="appearance/model",roleConfiguration:[String:Any]?=nil) throws -> [String:Any] {
        guard (prediction["outline"] as? [String:Any])?["present"] as? Bool == true else {return prediction}
        let evidence=try measure(input:input,packet:packet,prediction:prediction,ops:ops,discovery:true,primaryOnly:true)
        guard let candidate=evidence["primaryContourProposal"] as? [String:Any],
              let profiles=candidate["profiles"] as? Int,profiles>=40,
              let directions=candidate["directionalSectors"] as? Int,directions>=3,
              let support=candidate["sharpProfileSupport"] as? Double,support>=0.8,
              let width=candidate["medianColourCoreWidthPx"] as? Double,width>=1.5,
              let rgb=candidate["rgb"] as? [Double] else {return prediction}
        let labs=try ops.lab(colors:[rgb,color(prediction,"outline")])
        guard sqrt(squared(labs[0],labs[1]))>10 else {return prediction}
        guard let index=packet.colors.firstIndex(of:rgb) else {throw NativeAppearanceModelHeads.Failure.invalidOutput("contour palette index")}
        var result=prediction,outline=result["outline"] as! [String:Any]
        outline["rankerRGB"]=outline["rgb"];outline["colorDecision"]="source-normal-contour-consensus"
        outline["primaryContourEvidence"]=candidate;outline["rgb"]=rgb
        result["outline"]=outline;result["outlineIndex"]=index
        let config=try roleConfiguration ?? heads.configuration(roleRoot)
        if index != prediction["outlineIndex"] as? Int,config["conditionedBackground"] as? Bool == true {
            guard let fill=result["fillIndex"] as? Int else {throw NativeAppearanceModelHeads.Failure.invalidOutput("contour fill index")}
            let scores=try heads.positive(roleRoot+"/background",packet.role("background",fill:fill,outline:index))
            guard !scores.isEmpty else {throw NativeAppearanceModelHeads.Failure.invalidOutput("contour background scores")}
            var best=0
            for i in scores.indices.dropFirst() where scores[i]>scores[best] {best=i}
            var background=result["background"] as! [String:Any]
            background["rgb"]=packet.colors[best];result["background"]=background;result["backgroundIndex"]=best
        }
        return result
    }
    static func attachLayers(input:SourceNativeInput,packet:NativeAppearanceSourceFeatures209.Packet,prediction:[String:Any],
                             ops:any NativeAppearanceImageOperations) throws -> [String:Any] {
        let evidence=try measure(input:input,packet:packet,prediction:prediction,ops:ops)
        guard evidence["reliable"] as? Bool == true else {return prediction}
        var result=prediction,outline=result["outline"] as! [String:Any]
        outline["observedLayers"]=evidence["layers"];outline["totalObservedRingWidthPx"]=evidence["totalWidthPx"]
        outline["sourceRingEvidence"]=evidence
        outline["layerWidthSemantics"]="Source-pixel ring thickness including half of adjacent antialias transitions"
        result["outline"]=outline
        return result
    }
}
