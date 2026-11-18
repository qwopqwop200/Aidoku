import Foundation

enum NativeAppearanceNestedOutline {
    static func recover(_ input:SourceNativeInput,prediction:[String:Any],ops:any NativeAppearanceImageOperations) throws -> [String:Any] {
        guard var outline=prediction["outline"] as? [String:Any],outline["present"] as? Bool == false,
              let fill=(prediction["fill"] as? [String:Any])?["rgb"] as? [Double],let stroke=outline["rgb"] as? [Double] else {return prediction}
        let w=input.width,h=input.height,n=w*h,f=input.fontPriorSourcePixels
        let colors=try ops.lab(colors:[fill,stroke])
        guard NativeAppearancePhysicalImage.distance(colors[0],colors[1])>=25 else {return prediction}
        let image=try ops.lab(rgb:input.rgb,width:w,height:h),roi=try ops.raster(polygons:input.memberPolygons,width:w,height:h)
        let fillMask=(0..<n).map {NativeAppearancePhysicalImage.distance(Array(image[$0*3..<$0*3+3]),colors[0])<=10 ? UInt8(1):0}
        let ring=(0..<n).map {NativeAppearancePhysicalImage.distance(Array(image[$0*3..<$0*3+3]),colors[1])<=8 ? UInt8(1):0}
        let owned=(0..<n).map {fillMask[$0] != 0 && input.ownMask[$0] != 0 && roi[$0] != 0}
        let near=try ops.dilate(fillMask,width:w,height:h,radius:3,ellipse:true)
        let components=try NativeAppearancePhysicalImage.components(ring,width:w,height:h)
        var holeCount=0,candidates:[[String:Any]]=[],allCore=[UInt8](repeating:0,count:n)
        for id in 1..<components.areas.count {
            let rect=components.bounds[id],x=Int(rect.minX),y=Int(rect.minY),cw=Int(rect.width),ch=Int(rect.height)
            let area=components.areas[id]
            if x==0 || y==0 || x+cw>=w || y+ch>=h || Double(area)<max(20,f) {continue}
            var local=[UInt8](repeating:0,count:cw*ch)
            for yy in 0..<ch {for xx in 0..<cw {local[yy*cw+xx]=components.labels[(y+yy)*w+x+xx]==Int32(id) ? 1:0}}
            let filled=try ops.fillHoles(local,width:cw,height:ch)
            let rectangularity=Double(filled.filter {$0 != 0}.count)/Double(cw*ch)
            if rectangularity>0.8 {continue}
            var core=[UInt8](repeating:0,count:local.count),holes=0,seeds=0
            for yy in 0..<ch {for xx in 0..<cw {
                let q=yy*cw+xx,p=(y+yy)*w+x+xx
                if filled[q] != 0 && local[q]==0 {
                    holes+=1
                    if fillMask[p] != 0 {core[q]=1;if owned[p] {seeds+=1}}
                }
            }}
            let coreCount=core.filter {$0 != 0}.count
            if Double(seeds)<max(12,f*0.3) || Double(coreCount)/Double(max(1,holes))<0.5 {continue}
            let component=components.labels.map {$0==Int32(id) ? UInt8(1):0}
            let body=try ops.fillHoles(component,width:w,height:h),dilated=try ops.dilate(body,width:w,height:h,radius:1,ellipse:false)
            let exterior=(0..<n).filter {dilated[$0] != 0 && body[$0]==0}
            let support=Double(exterior.filter {near[$0] != 0}.count)/Double(max(1,exterior.count))
            if support<0.65 {continue}
            let sizes=try ops.componentSizes(core,width:cw,height:ch)
            holeCount+=sizes.filter {Double($0)>=max(12,f*0.3)}.count
            for yy in 0..<ch {for xx in 0..<cw where core[yy*cw+xx] != 0 {allCore[(y+yy)*w+x+xx]=1}}
            candidates.append(["bounds":[x,y,x+cw,y+ch],"fillPixels":coreCount,"ringPixels":area,
                "exteriorSameFillSupport":support,"filledComponentRectangularity":rectangularity])
        }
        guard holeCount>=3 else {return prediction}
        let coverage=Double((0..<n).filter {allCore[$0] != 0 && owned[$0]}.count)/Double(max(1,owned.filter {$0}.count))
        guard coverage>=0.35 else {return prediction}
        outline["present"]=true;outline["classifierPresent"]=false;outline["presenceDecision"]="bounded-source-contour-recovery"
        outline["probabilitySemantics"]="Raw classifier probability before source topology correction"
        outline["nestedContourEvidence"]=["version":"bounded-source-colour-ring-v2","reliable":true,
            "GTAtInference":false,"inputContextExpanded":false,"candidateCount":candidates.count,"enclosedCoreCount":holeCount,
            "candidates":candidates,"ownedFillEnclosedFraction":coverage,"ringRGB":stroke,"exteriorRGB":fill,
            "corePixels":allCore.filter {$0 != 0}.count] as [String:Any]
        var result=prediction;result["outline"]=outline;return result
    }
}
