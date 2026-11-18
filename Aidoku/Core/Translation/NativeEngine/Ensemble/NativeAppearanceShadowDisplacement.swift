import Foundation

enum NativeAppearanceShadowDisplacement {
    private struct Component {let width:Int;let height:Int;let local:[Bool];let occlusion:[Bool];let observed:[Bool]}
    static func estimate(_ input:SourceNativeInput,prediction:[String:Any],observedRGB:[Double]?,referenceWidth:Double,
                         ops:any NativeAppearanceImageOperations) throws -> [String:Any] {
        var result:[String:Any]=["version":"source-shadow-component-displacement-v2","identified":false,
            "offsetPx":NSNull(),"observedCompositeRGB":NSNull(),"intrinsicRGB":NSNull(),"GTAtInference":false,"contextExpanded":false]
        guard let observedRGB else {result["reason"]="No observed source-colour hypothesis";return result}
        guard let core=try NativeAppearancePhysicalImage.sourceCore(input,prediction:prediction,ops:ops) else {
            result["reason"]="No separated owned glyph core";return result
        }
        let w=input.width,h=input.height,font=input.fontPriorSourcePixels
        let components=try NativeAppearancePhysicalImage.components(core,width:w,height:h)
        let ids=Array((1..<components.areas.count).filter {Double(components.areas[$0])>=max(12,font*font*0.005)}.sorted {
            components.areas[$0]==components.areas[$1] ? $0<$1:components.areas[$0]>components.areas[$1]
        }.prefix(12))
        guard ids.count>=3 else {result["reason"]="Fewer than three independent source components";return result}
        let outlined=(prediction["outline"] as? [String:Any])?["present"] as? Bool == true
        let width=outlined ? referenceWidth:0,radius=max(3,min(12,Int((font*0.15).rounded(.toNearestOrEven))))
        let edt=try NativeAppearanceEuclideanDistance.transform(seed:core,width:w,height:h)
        let body=edt.values.map {$0<=width},owners=edt.nearest.map {components.labels[$0]}
        let lab=try ops.lab(rgb:input.rgb,width:w,height:h),color=try ops.lab(colors:[observedRGB])[0]
        let target=(0..<w*h).map {p in NativeAppearancePhysicalImage.distance(Array(lab[p*3..<p*3+3]),color)<=8 &&
            edt.values[p]>max(0.5,width-0.5) && edt.values[p]<=width+Double(radius)+2}
        var patches:[Component]=[],censored=0
        for identity in ids {
            let r=components.bounds[identity],pad=Int(ceil(width))+radius+2
            let x=Int(r.minX),y=Int(r.minY),cw=Int(r.width),ch=Int(r.height)
            if x-pad<0 || y-pad<0 || x+cw+pad>w || y+ch+pad>h {censored+=1;continue}
            let left=x-pad,top=y-pad,pw=cw+pad*2,ph=ch+pad*2
            var local=[UInt8](repeating:0,count:pw*ph),occlusion=[Bool](repeating:false,count:pw*ph),observed=occlusion
            for yy in 0..<ph {for xx in 0..<pw {
                let q=yy*pw+xx,p=(top+yy)*w+left+xx
                local[q]=components.labels[p]==Int32(identity) ? 1:0
                occlusion[q]=body[p];observed[q]=target[p] && owners[p]==Int32(identity)
            }}
            if observed.filter({$0}).count<8 {continue}
            let localEDT=try NativeAppearanceEuclideanDistance.transform(seed:local,width:pw,height:ph)
            patches.append(.init(width:pw,height:ph,local:localEDT.values.map {$0<=width},occlusion:occlusion,observed:observed))
        }
        guard patches.count>=3 else {
            result["reason"]="Insufficient component-local observed paint";result["components"]=patches.count;result["censoredComponents"]=censored
            return result
        }
        var offsets:[(Int,Int)]=[]
        for dy in -radius...radius {for dx in -radius...radius where dx != 0 || dy != 0 {offsets.append((dx,dy))}}
        let scores=patches.map {patch in
            offsets.map {dx,dy -> Double in
                var expected=0,overlap=0
                for y in 0..<patch.height {for x in 0..<patch.width {
                    let sx=x-dx,sy=y-dy,p=y*patch.width+x
                    if sx>=0,sx<patch.width,sy>=0,sy<patch.height,patch.local[sy*patch.width+sx],!patch.occlusion[p] {
                        expected+=1;if patch.observed[p] {overlap+=1}
                    }
                }}
                return Double(overlap*2)/Double(max(1,expected+patch.observed.filter {$0}.count))
            }
        }
        let train=scores.indices.filter {$0%2==0},validation=scores.indices.filter {$0%2==1}
        func mean(_ rows:[Int],_ column:Int)->Double {rows.reduce(0) {$0+scores[$1][column]}/Double(rows.count)}
        var selected=0
        for i in offsets.indices.dropFirst() where mean(train,i)>mean(train,selected) {selected=i}
        let (dx,dy)=offsets[selected],opposite=offsets.firstIndex(where:{$0.0 == -dx && $0.1 == -dy})!
        let training=mean(train,selected),valid=mean(validation,selected)
        let trainingRatio=training/max(0.01,mean(train,opposite)),validationRatio=valid/max(0.01,mean(validation,opposite))
        let agreement=Double(scores.filter {$0[selected]>=0.25}.count)/Double(scores.count)
        let accepted=training>=0.25 && valid>=0.25 && trainingRatio>=2 && validationRatio>=1.5 && agreement>=0.6
        result.merge(["identified":accepted,"reason":accepted ? "Component-held-out categorical displacement":"Displacement does not repeat on held-out source components",
            "components":patches.count,"censoredComponents":censored,"trainingComponents":train.count,"validationComponents":validation.count,
            "candidateOffsetPx":[dx,dy],"sourceTrainingF1":training,"sourceValidationF1":valid,
            "trainingOppositeRatio":trainingRatio,"validationOppositeRatio":validationRatio,"componentAgreement":agreement,
            "searchRadiusPx":radius,"offsetPx":accepted ? [dx,dy] as Any:NSNull(),
            "observedCompositeRGB":accepted ? observedRGB as Any:NSNull(),
            "note":"Observed categorical paint displacement; no intrinsic opacity or blur identification"]) {_,new in new}
        return result
    }
}
