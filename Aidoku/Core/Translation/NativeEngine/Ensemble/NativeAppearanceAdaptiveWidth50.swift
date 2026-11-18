import Foundation

/// Native adaptive_normal_width.measure/features: actual finite native rays,
/// equal component/sector budgets, independent of nominal predicted width.
enum NativeAppearanceAdaptiveWidth50 {
    struct Ray {
        let width:Double
        let sector:Int
        let component:Int
        let exteriorContrast:Double
        let transition:Double
    }
    struct Evidence {
        let features:[Double]
        let rays:[Ray]
        let identified:Bool
        let width:Double?
    }
    static let reasons=["outside-crop","no-native-fill-anchor","no-adjacent-primary-core","unstable-fill-boundary",
        "unresolved-fill-primary-transition","other-fill-component","fill-return-or-concavity","unresolved-primary-exterior-gap",
        "unresolved-primary-exterior-transition","nonpositive-band","outside-crop-before-exit","depth-without-observed-exit"]
    private static func summary(_ values:[Double])->[Double] {
        let median=NativeAppearanceNumeric.quantile(values,0.5)
        return [median,NativeAppearanceNumeric.quantile(values,0.25),NativeAppearanceNumeric.quantile(values,0.75),
            NativeAppearanceNumeric.quantile(values.map {abs($0-median)},0.5)]
    }
    private static func evidence(_ rays:[Ray],attempted:Int,censoring:[String:Int],font:Double)->Evidence {
        let medians=Set(rays.map(\.component)).sorted().compactMap {component -> Double? in
            let values=rays.filter {$0.component==component}.map(\.width)
            return values.count>=3 ? NativeAppearanceNumeric.quantile(values,0.5):nil
        }
        let sectors=(0..<8).map {sector in rays.filter {$0.sector==sector}.map(\.width)}
        let supported=sectors.filter {$0.count>=2}.count
        let identified=rays.count>=12 && supported>=3 && !medians.isEmpty
        let width=identified ? NativeAppearanceNumeric.quantile(medians,0.5):0
        let attempts=Double(max(1,attempted)),s=summary(rays.map(\.width))
        let iqr=NativeAppearanceNumeric.quantile(medians,0.75)-NativeAppearanceNumeric.quantile(medians,0.25)
        var vector=[identified ? 1.0:0,width,width/max(1,font),log1p(Double(attempted)),Double(rays.count)/attempts,
            Double(medians.count),Double(supported)]+s+[iqr,NativeAppearanceNumeric.quantile(rays.map(\.exteriorContrast),0.5),
            NativeAppearanceNumeric.quantile(rays.map(\.transition),0.5)]
        vector += reasons.map {Double(censoring[$0,default:0])/attempts}
        for values in sectors {
            let s=summary(values);vector += [Double(values.count)/attempts,s[0],s[3]]
        }
        return .init(features:vector,rays:rays,identified:identified,width:identified ? width:nil)
    }

    static func measure(_ input:SourceNativeInput,fill:[Double],primary:[Double],present:Bool,
                        ops:any NativeAppearanceImageOperations) throws -> Evidence {
        let font=input.fontPriorSourcePixels,w=input.width,h=input.height,n=w*h
        let empty=evidence([],attempted:0,censoring:[:],font:font)
        guard present else {return empty}
        let image=try ops.lab(rgb:input.rgb,width:w,height:h),colors=try ops.lab(colors:[fill,primary])
        let a=colors[0],b=colors[1],contrast=Double(NativeAppearancePhysicalImage.distance(a,b))
        guard contrast>=16 else {return empty}
        let ftol=min(14,contrast*0.3),otol=min(14,contrast*0.3)
        let core=(0..<n).map {p in
            NativeAppearancePhysicalImage.distance(Array(image[p*3..<p*3+3]),a)<=Float(ftol) && input.ownMask[p] != 0 ? UInt8(1):0
        }
        let seeds=try ops.raster(polygons:input.memberPolygons,width:w,height:h)
        let components=try NativeAppearancePhysicalImage.components(core,width:w,height:h)
        var seeded=[Int](repeating:0,count:components.areas.count)
        for p in 0..<n where seeds[p] != 0 {seeded[Int(components.labels[p])]+=1}
        let ids=Array((1..<components.areas.count).filter {components.areas[$0]>=20 && seeded[$0]>=3}.sorted {
            components.areas[$0]==components.areas[$1] ? $0<$1:components.areas[$0]>components.areas[$1]
        }.prefix(12))
        guard !ids.isEmpty else {return empty}
        let keep=Set(ids),selected=components.labels.map {keep.contains(Int($0)) ? UInt8(1):0}
        let inside=try ops.distance(selected,width:w,height:h,maskSize:5)
        let outside=try ops.distance(selected.map {$0==0 ? 1:0},width:w,height:h,maskSize:5)
        let signed=try NativeAppearancePhysicalImage.gaussian(zip(inside,outside).map {$0-$1},width:w,height:h,sigma:1)
        let gradient=NativeAppearancePhysicalImage.gradient(signed,width:w,height:h)
        let eroded=try NativeAppearancePhysicalImage.erode(selected,width:w,height:h)
        let depth=max(32,min(96,Int(ceil(font*0.8))))
        var records:[Ray]=[],attempted=0,censoring:[String:Int]=[:]
        for identity in ids {
            var points:[(x:Int,y:Int,nx:Float,ny:Float,sector:Int)]=[]
            for p in 0..<n where selected[p] != 0 && eroded[p]==0 && components.labels[p]==Int32(identity) {
                let gx=gradient.x[p],gy=gradient.y[p],norm=hypot(gx,gy)
                guard norm>0.2 else {continue}
                let nx = -gx/norm,ny = -gy/norm
                let sector=Int(floor((atan2(ny,nx)+Float.pi)/(Float.pi/4)))%8
                points.append((p%w,p/w,nx,ny,sector))
            }
            for sector in 0..<8 {
                let candidates=points.indices.filter {points[$0].sector==sector},count=min(6,candidates.count)
                guard count>0 else {continue}
                for i in 0..<count {
                    let position=count==1 ? 0:Int(Double(i)*Double(candidates.count-1)/Double(count-1))
                    let point=points[candidates[position]];attempted+=1
                    let result=ray(image:image,labels:components.labels,width:w,height:h,identity:identity,
                        x:point.x,y:point.y,nx:point.nx,ny:point.ny,depth:depth,fill:a,primary:b,ftol:ftol,otol:otol)
                    if let record=result.0 {records.append(record)} else {censoring[result.1,default:0]+=1}
                }
            }
        }
        return evidence(records,attempted:attempted,censoring:censoring,font:font)
    }

    private static func ray(image:[Float],labels:[Int32],width w:Int,height h:Int,identity:Int,
                            x:Int,y:Int,nx:Float,ny:Float,depth:Int,fill:[Float],primary:[Float],
                            ftol:Double,otol:Double)->(Ray?,String) {
        var xy:[(Int,Int)]=[],t:[Double]=[]
        var clipped=false
        for k in 0..<((depth+3)*2+1) {
            let step = -3+Double(k)*0.5
            let xx=Int((Double(x)+step*Double(nx)).rounded(.toNearestOrEven))
            let yy=Int((Double(y)+step*Double(ny)).rounded(.toNearestOrEven))
            if let last=xy.last,last.0==xx,last.1==yy {continue}
            let distance=Double(xx-x)*Double(nx)+Double(yy-y)*Double(ny)
            if xx<0 || xx>=w || yy<0 || yy>=h {
                if distance>=0 {clipped=true;break}
                continue
            }
            xy.append((xx,yy));t.append(distance)
        }
        guard t.count>=7 else {return(nil,"outside-crop")}
        let colors=xy.map {Array(image[($0.1*w+$0.0)*3..<($0.1*w+$0.0)*3+3])}
        let df=colors.map {NativeAppearancePhysicalImage.distance($0,fill)}
        let dp=colors.map {NativeAppearancePhysicalImage.distance($0,primary)}
        let fillMatch=df.map {$0<=Float(ftol)},primaryMatch=df.indices.map {dp[$0]<=Float(otol) && dp[$0]<df[$0]}
        guard let anchor=t.indices.last(where:{t[$0]>=(-2.5) && t[$0]<=0.75 && fillMatch[$0]}) else {
            return(nil,"no-native-fill-anchor")
        }
        let starts=t.indices.filter {$0>anchor && primaryMatch[$0] && t[$0]<=6}
        guard let start=starts.first else {return(nil,"no-adjacent-primary-core")}
        let observed=colors[starts.min(by:{dp[$0]<dp[$1]})!]
        if start>anchor+1,(anchor+1..<start).contains(where:{fillMatch[$0]}) {return(nil,"unstable-fill-boundary")}
        guard let entry=crossing(t,colors,first:anchor,last:start,a:fill,b:primary) else {return(nil,"unresolved-fill-primary-transition")}
        guard start+1<t.count-2 else {return(nil,clipped ? "outside-crop-before-exit":"depth-without-observed-exit")}
        for j in (start+1)..<(t.count-2) {
            let owner=Int(labels[xy[j].1*w+xy[j].0])
            if owner>0 && owner != identity {return(nil,"other-fill-component")}
            if fillMatch[j] {return(nil,"fill-return-or-concavity")}
            let window=Array(colors[j..<j+3])
            let reference=(0..<3).map {c in Float(NativeAppearanceNumeric.quantile(window.map {Double($0[c])},0.5))}
            let contrast=Double(NativeAppearancePhysicalImage.distance(reference,observed))
            if contrast<3 {continue}
            if (j..<j+3).contains(where:{fillMatch[$0]}) {continue}
            let spread=min(8,max(0.75,0.3*contrast))
            if window.map({Double(NativeAppearancePhysicalImage.distance($0,reference))}).max()!>spread {continue}
            if window.map({Double(NativeAppearancePhysicalImage.distance($0,observed))}).min()!<0.6*contrast {continue}
            if (j..<j+3).contains(where:{let owner=Int(labels[xy[$0].1*w+xy[$0].0]);return owner>0 && owner != identity}) {
                return(nil,"other-fill-component")
            }
            guard let last=(start..<j).last(where:{Double(NativeAppearancePhysicalImage.distance(colors[$0],observed))<=min(otol,max(0.75,0.3*contrast))}) else {continue}
            if t[j]-t[last]>4 {return(nil,"unresolved-primary-exterior-gap")}
            guard let exit=crossing(t,colors,first:last,last:j,a:observed,b:reference) else {return(nil,"unresolved-primary-exterior-transition")}
            let width=exit-entry
            if width<=0 {return(nil,"nonpositive-band")}
            let sector=Int((atan2(ny,nx)+Float.pi)/(Float.pi/4))%8
            return(.init(width:width,sector:sector,component:identity,exteriorContrast:contrast,
                         transition:(t[start]-t[anchor])+(t[j]-t[last])),"")
        }
        return(nil,clipped ? "outside-crop-before-exit":"depth-without-observed-exit")
    }
    private static func crossing(_ t:[Double],_ values:[[Float]],first:Int,last:Int,a:[Float],b:[Float])->Double? {
        let vector=zip(b,a).map {$0-$1},denominator=max(1e-6,vector.reduce(Float(0)) {$0+$1*$1})
        let alpha=(first...last).map {i in zip(zip(values[i],a).map {$0-$1},vector).reduce(Float(0)) {$0+$1.0*$1.1}/denominator}
        guard alpha.count>=2 else {return nil}
        for k in 0..<(alpha.count-1) where alpha[k]<=0.5 && alpha[k+1]>=0.5 {
            let fraction=min(1,max(0,(0.5-alpha[k])/max(1e-6,alpha[k+1]-alpha[k])))
            return t[first+k]+Double(fraction)*(t[first+k+1]-t[first+k])
        }
        return nil
    }
}
