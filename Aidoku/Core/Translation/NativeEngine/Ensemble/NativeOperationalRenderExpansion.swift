import CoreGraphics
import Foundation

/// Live source/RF producer. No page identifiers, corpus files, GT masks or saved decisions.
enum NativeOperationalRenderExpansion {
    private static let generatedOrigin = "native-operational-render-expansion"

    /// Stage03 may certify a smaller/different body than the initial capacity
    /// proposal. Refresh only policies this invocation actually generated;
    /// user-authored policies and every unmarked item are returned unchanged.
    static func reannotateGenerated(items: [[String: Any]], viewport: CGSize,
                                    source: CGImage, regions: [Ensemble100RFRegion],
                                    simplePlacement: NativeSimpleRFBalloonPlacement? = nil) throws -> [[String: Any]] {
        guard NativeEnsembleLayoutContour.supportedEstimatedContourEnabled || simplePlacement != nil else { return items }
        let generated = items.indices.filter {
            items[$0]["renderExpansionPolicyOrigin"] as? String == generatedOrigin &&
                items[$0]["textExpansionPolicy"] != nil && items[$0]["renderExpansionBoundaryAuthority"] is String
        }
        guard !generated.isEmpty else { return items }
        var prepared = items
        for i in generated {
            prepared[i].removeValue(forKey: "textExpansionPolicy")
            prepared[i].removeValue(forKey: "renderExpansionBoundaryAuthority")
        }
        let refreshed = try annotate(items: prepared, viewport: viewport, source: source, regions: regions,
            simplePlacement: simplePlacement)
        var result = items
        for i in generated { result[i] = refreshed[i] }
        return result
    }
    private static let unit=CGRect(x:0,y:0,width:1,height:1)
    private static func array(_ r:CGRect)->[Double] { [Double(r.minX),Double(r.minY),Double(r.width),Double(r.height)] }
    private static func sourceRect(_ raw:[String:Any],viewport:CGSize)->CGRect? {
        if let r=raw["sourceBounds"] as? [Double],NativeTextExpansionPolicy.validRect(r) {
            return CGRect(x:r[0],y:r[1],width:r[2],height:r[3])
        }
        guard let x=(raw["x"] as? NSNumber)?.doubleValue,let y=(raw["y"] as? NSNumber)?.doubleValue,
              let w=(raw["width"] as? NSNumber)?.doubleValue,let h=(raw["height"] as? NSNumber)?.doubleValue,
              [x,y,w,h].allSatisfy(\.isFinite),w>0,h>0 else { return nil }
        let r=CGRect(x:x/viewport.width,y:y/viewport.height,width:w/viewport.width,height:h/viewport.height).intersection(unit)
        return !r.isNull && !r.isEmpty ? r : nil
    }
    private static func intervals(_ rings:[[CGPoint]],y:CGFloat)->[(CGFloat,CGFloat)] {
        var crosses:[CGFloat]=[]
        for ring in rings where ring.count>=3 {
            for i in ring.indices {
                let a=ring[i],b=ring[(i+1)%ring.count]
                if (a.y<=y && y<b.y)||(b.y<=y && y<a.y) { crosses.append(a.x+(y-a.y)*(b.x-a.x)/(b.y-a.y)) }
            }
        }
        crosses.sort();return stride(from:0,to:crosses.count-1,by:2).map { (crosses[$0],crosses[$0+1]) }
    }
    private static func mask(_ region:Ensemble100RFRegion,owner:CGRect)->(CGRect,[Double],Double,[[Double]]?)? {
        let rect=region.bounds.intersection(unit),rings=[region.exterior]+region.holes
        guard !rect.isEmpty,!rect.isNull,region.exterior.count>=3,
              rings.flatMap({ $0 }).allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return nil }
        var spans:[Double]=[],covered:CGFloat=0,allRows:[[Double]]=[]
        let count=128,step=rect.height/CGFloat(count),epsilon:CGFloat=1e-8
        for row in 0..<count {
            let lower=rect.minY+CGFloat(row)*step,upper=lower+step
            var ys=[lower+epsilon,upper-epsilon,(lower+upper)/2]
            for ring in rings { for p in ring where p.y>lower && p.y<upper { ys.append(max(lower+epsilon,p.y-epsilon));ys.append(min(upper-epsilon,p.y+epsilon)) } }
            var left=rect.minX,right=rect.maxX,safe:[(CGFloat,CGFloat)]=[(rect.minX,rect.maxX)]
            for y in ys {
                let sections=intervals(rings,y:y)
                safe=safe.flatMap { a in sections.compactMap { b -> (CGFloat,CGFloat)? in
                    let x=max(a.0,b.0),X=min(a.1,b.1)
                    return x<X ? (x,X):nil
                }}
                guard let best=sections.max(by: { a,b in
                    let x=max(0,min(a.1,owner.maxX)-max(a.0,owner.minX))
                    let z=max(0,min(b.1,owner.maxX)-max(b.0,owner.minX))
                    return x==z ? a.1-a.0<b.1-b.0 : x<z
                }) else { left=0;right=0;break }
                left=max(left,best.0);right=min(right,best.1)
            }
            if right<left { right=left }
            spans += [Double(max(0,min(1,left))),Double(max(0,min(1,right)))]
            allRows.append(safe.flatMap {[Double(max(0,min(1,$0.0))),Double(max(0,min(1,$0.1)))]})
            covered += max(0,min(upper,owner.maxY)-max(lower,owner.minY))*max(0,min(right,owner.maxX)-max(left,owner.minX))
        }
        let fraction=Double(covered/max(1e-12,owner.width*owner.height))
        let legacy=stride(from:0,to:spans.count,by:2).map { k in spans[k]<spans[k+1] ? [spans[k],spans[k+1]]:[] }
        return fraction>=0.7 ? (rect,spans,fraction,allRows==legacy ? nil:allRows) : nil
    }
    /// Union of every polygon section across a band, including both sides of
    /// vertices. Linear edges have their extrema at these endpoints. Safe-mask
    /// intersection would underapproximate an exclusion and allow intrusions.
    private static func exclusions(_ regions:[Ensemble100RFRegion])->(CGRect,[[Double]])? {
        let balloons=regions.filter {$0.classID==2 && $0.confidence>=0.5 && $0.exterior.count>=3 &&
            ([$0.exterior]+$0.holes).flatMap {$0}.allSatisfy {$0.x.isFinite && $0.y.isFinite}}
        guard let first=balloons.first else{return nil}
        let rect=balloons.dropFirst().reduce(first.bounds) {$0.union($1.bounds)}.intersection(unit)
        guard !rect.isNull,!rect.isEmpty else{return nil}
        let count=512,step=rect.height/CGFloat(count),epsilon:CGFloat=1e-10
        var rows:[[Double]]=[]
        for row in 0..<count {
            let low=rect.minY+CGFloat(row)*step,high=low+step
            var sections:[(CGFloat,CGFloat)]=[]
            for balloon in balloons where balloon.bounds.maxY>=low && balloon.bounds.minY<=high {
                let rings=[balloon.exterior]+balloon.holes
                var ys=[low+epsilon,high-epsilon,(low+high)/2]
                for ring in rings {for p in ring where p.y>=low && p.y<=high {
                    ys.append(max(low+epsilon,p.y-epsilon));ys.append(min(high-epsilon,p.y+epsilon))
                }}
                for y in ys {sections += intervals(rings,y:y)}
            }
            sections.sort {$0.0<$1.0}
            var merged:[(CGFloat,CGFloat)]=[]
            for pair in sections {
                let left=max(0,pair.0-epsilon),right=min(1,pair.1+epsilon)
                guard left<right else{continue}
                if let last=merged.last,left<=last.1 {merged[merged.count-1].1=max(last.1,right)}
                else {merged.append((left,right))}
            }
            if merged.count>512 {merged=[(merged.first!.0,merged.last!.1)]}
            rows.append(merged.flatMap {[Double($0.0),Double($0.1)]})
        }
        return (rect,rows)
    }
    static func annotate(items:[[String:Any]],viewport:CGSize,source:CGImage,regions:[Ensemble100RFRegion],
                         simplePlacement:NativeSimpleRFBalloonPlacement? = nil) throws -> [[String:Any]] {
        guard viewport.width>0,viewport.height>0 else { return items }
        try simplePlacement?.validate(original:source,viewport:viewport)
        let size=CGSize(width:source.width,height:source.height),scale=size.width/viewport.width
        let owners=items.map { sourceRect($0,viewport:viewport) }
        // A small numerical risk surface; it is never exported as a page preview.
        let factor=min(1,640/max(size.width,size.height)),w=max(1,Int(size.width*factor)),h=max(1,Int(size.height*factor))
        let ctx=CGContext(data:nil,width:w,height:h,bitsPerComponent:8,bytesPerRow:w*4,
            space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)
        ctx?.draw(source,in:CGRect(x:0,y:0,width:w,height:h))
        let pixels=ctx?.data.map { Array(UnsafeBufferPointer(start:$0.assumingMemoryBound(to:UInt8.self),count:w*h*4)) }
        func risk(_ r:CGRect,owner:CGRect)->Double {
            var sum:Double=0,n=0
            if let pixels {
                func luminance(_ x:Int,_ y:Int)->Double { let k=(y*w+x)*4;return Double(pixels[k])*0.2126+Double(pixels[k+1])*0.7152+Double(pixels[k+2])*0.0722 }
                for y in 0..<10 { for x in 0..<10 {
                    let p=CGPoint(x:r.minX+r.width*(CGFloat(x)+0.5)/10,y:r.minY+r.height*(CGFloat(y)+0.5)/10)
                    if owners.contains(where: { $0?.contains(p) == true }) { continue }
                    let xx=max(0,min(w-1,Int(p.x*CGFloat(w)))),yy=max(0,min(h-1,Int(p.y*CGFloat(h))))
                    sum += min(1,(abs(luminance(xx,yy)-luminance(max(0,xx-1),yy))+abs(luminance(xx,yy)-luminance(xx,max(0,yy-1))))/96);n+=1
                } }
            }
            var score=sum/Double(max(1,n))
            for region in regions where region.classID==1 && region.confidence>=0.7 {
                let own=owner.intersection(region.bounds),overlap=r.intersection(region.bounds)
                if own.isNull || own.width*own.height<min(owner.width*owner.height,region.bounds.width*region.bounds.height)*0.1,
                   !overlap.isNull { score += Double(overlap.width*overlap.height/max(1e-12,r.width*r.height))*4 }
            }
            return min(1,max(0,score))
        }
        var output=items
        for i in items.indices {
            let raw=items[i]
            guard raw["textExpansionPolicy"]==nil,raw["keptLettering"] as? Bool != true,
                  raw["sourceTextOnly"] as? Bool != true,let text=raw["text"] as? String,!text.isEmpty,
                  let owner=owners[i] else { continue }
            let font=(raw["sourceFontSize"] as? NSNumber)?.doubleValue ?? ((raw["fontSize"] as? NSNumber)?.doubleValue ?? 12)*Double(scale)
            guard font.isFinite,font>0 else { continue }
            let nx=CGFloat(font)/size.width,ny=CGFloat(font)/size.height
            var boundary:(CGRect,[Double],Double,[[Double]]?)?
            var boundaryAuthority="local-source-window"
            let simpleConstraint=try simplePlacement?.constraint(for:raw,viewport:viewport)
            // The final painter already enforces this connected source domain.
            // Proposing a larger RF instance first can send fitting into a sibling
            // lobe and trigger unnecessary shrinking before final admission.
            if let simpleConstraint {
                let capacity=simpleConstraint.capacity,r=capacity.rectNormalized
                boundary=(CGRect(x:r[0],y:r[1],width:r[2],height:r[3]),
                    capacity.primarySpans(owner:simpleConstraint.sourceOwnerBoundsNormalized),
                    simpleConstraint.ownerMaskCoverage,capacity.intervalRowsNormalized)
                boundaryAuthority="raw-rf-core-model-estimated-placement-only"
            } else if let contour=NativeRawBalloonCapacity.connectedContour(raw:raw,viewport:viewport) {
                let rect=CGRect(x:contour.rect.minX/viewport.width,y:contour.rect.minY/viewport.height,
                    width:contour.rect.width/viewport.width,height:contour.rect.height/viewport.height)
                boundary=(rect,contour.spans.flatMap { [Double($0.0/viewport.width),Double($0.1/viewport.width)] },0.7,nil)
                if NativeEnsembleLayoutContour.supportedEstimatedContourEnabled,
                   let measured = raw["balloonInterior"] as? [String: Any],
                   let r = measured["rect"] as? [Double], let spans = measured["spans"] as? [Double] {
                    // The connected parser already validated these exact source
                    // bands. Avoid viewport multiply/divide drift between the
                    // line-layout policy and the final placement certificate.
                    boundary = (CGRect(x: r[0], y: r[1], width: r[2], height: r[3]), spans, 0.7, nil)
                }
                boundaryAuthority="connected-source-contour"
            } else if !NativeEnsembleLayoutContour.supportedEstimatedContourEnabled {
                for r in regions where r.classID==2 && r.confidence>=0.5 {
                    if let proposal=mask(r,owner:owner),boundary==nil || proposal.2>boundary!.2 {
                        boundary=proposal;boundaryAuthority="source-associated-rf-contour"
                    }
                }
            }
            var allowed=boundary?.0 ?? owner.insetBy(dx:-3*nx,dy:-1.5*ny).intersection(unit)
            if boundary==nil {
                let limit=owner.insetBy(dx:-8*nx,dy:-4*ny).intersection(unit)
                for direction in 0..<4 {for _ in 0..<6 {
                    var x=allowed.minX,y=allowed.minY,X=allowed.maxX,Y=allowed.maxY
                    switch direction {
                    case 0:x=max(limit.minX,x-nx)
                    case 1:X=min(limit.maxX,X+nx)
                    case 2:y=max(limit.minY,y-ny*0.5)
                    default:Y=min(limit.maxY,Y+ny*0.5)
                    }
                    let proposed=CGRect(x:x,y:y,width:X-x,height:Y-y),area=allowed.width*allowed.height
                    let next=proposed.width*proposed.height,added=next-area
                    if added<1e-12 {break}
                    let shell=max(0,(risk(proposed,owner:owner)*Double(next)-risk(allowed,owner:owner)*Double(area))/Double(added))
                    if shell>0.12 {break}
                    allowed=proposed
                }}
                for frame in regions where frame.classID==3 && frame.confidence>=0.7 && frame.bounds.contains(CGPoint(x:owner.midX,y:owner.midY)) {
                    let inside=owner.intersection(frame.bounds)
                    if !inside.isNull && inside.width*inside.height>=owner.width*owner.height*0.95 {
                        let limited=allowed.intersection(frame.bounds)
                        if !limited.isNull && !limited.isEmpty { allowed=limited }
                    }
                }
            }
            guard !allowed.isNull,!allowed.isEmpty else { continue }
            let role=raw["role"] as? String ?? raw["semanticRole"] as? String ?? "dialogue"
            let narration=["narration","story_text","caption"].contains(role)
            let vertical=owner.height>owner.width*2
            output[i]["textAlignment"]=narration ? "left":"center"
            if var cluster=raw["sourceClusterAlignment"] as? [String:Any],cluster["anchorPolicy"]==nil {
                cluster["anchorPolicy"]="source-near-final-alpha";output[i]["sourceClusterAlignment"]=cluster
            }
            if raw["textPlacementGuide"]==nil { output[i]["textPlacementGuide"]=["rectNormalized":array(owner),"horizontal":narration && !vertical ? "left":"center","vertical":narration && !vertical ? "top":"center"] }
            var candidates=[owner],coverage:[Double]=[],risks:[Double]=[]
            func addColumns(_ values:[CGFloat]) {
                for columns in values {
                    let width=min(allowed.width,max(owner.width,nx*columns+nx*0.3))
                    let lines=ceil(CGFloat(text.count)/max(1,width/nx-0.3)),height=min(allowed.height,max(ny*1.6,lines*ny*1.5+ny*0.3))
                    let x=min(max(allowed.minX,owner.midX-width/2),allowed.maxX-width)
                    let y=min(max(allowed.minY,owner.midY-height/2),allowed.maxY-height)
                    candidates.append(CGRect(x:x,y:y,width:width,height:height))
                }
            }
            func addFractions(_ values:[CGFloat]) {
                for fraction in values {
                    let width=allowed.width*fraction,height=allowed.height
                    let x=min(max(allowed.minX,owner.midX-width/2),allowed.maxX-width)
                    candidates.append(CGRect(x:x,y:allowed.minY,width:width,height:height))
                }
            }
            addColumns(boundary==nil ? [3,4,5,6,8,10,12]:[1.5,2,3,4,5])
            addFractions([0.6,0.8,1])
            let ordinaryIndices=boundary==nil ? nil:Array(candidates.indices)
            if boundary != nil {addColumns([6,7,8]);addFractions([0.3,0.4,0.5])}
            for c in candidates { coverage.append(boundary?.2 ?? 1);risks.append(risk(c,owner:owner)) }
            // Exterior single lines may use the background-certified capacity
            // even without a typography family. Keep the existing height limit;
            // this is permission to fit at the source font, not forced widening.
            let widthScale: Double
            if raw["typographyGroupID"] != nil {
                widthScale=min(8,max(2,Double(allowed.width/owner.width)))
            } else if boundary==nil {
                widthScale=min(8,max(1.35,Double(allowed.width/owner.width)))
            } else {
                widthScale=1.35
            }
            let policy=NativeTextExpansionPolicy(allowedRectNormalized:array(allowed),candidates:candidates.map(array),
                maskCoverage:coverage,backgroundRisk:risks,sourceFontPixels:font,
                kind:boundary==nil ? "source-near-limited-expansion":"inside-balloon-mask",
                maskRectNormalized:boundary.map { array($0.0) },maskSpansNormalized:boundary?.1,
                sourceLineWidthScale:widthScale,
                sourceAnchorLimitEm:boundary==nil ? nil:3,
                maskIntervalRowsNormalized:boundary.flatMap {$0.3},ordinaryCandidateIndices:ordinaryIndices)
            guard policy.valid else { continue }
            output[i]["textExpansionPolicy"]=try JSONSerialization.jsonObject(with:JSONEncoder().encode(policy))
            output[i]["renderExpansionBoundaryAuthority"]=boundaryAuthority
            if NativeEnsembleLayoutContour.supportedEstimatedContourEnabled || simpleConstraint != nil {
                output[i]["renderExpansionPolicyOrigin"] = generatedOrigin
            }
        }
        // Missing/rejected segmentation does not erase a strong detector box.
        // Bound generated and supplied exterior policies identically; never
        // turn a box into contour/mask authority or remove the source extent.
        for i in output.indices {
            guard output[i]["keptLettering"]as?Bool != true,output[i]["sourceTextOnly"]as?Bool != true,
                  var rawPolicy=output[i]["textExpansionPolicy"]as?[String:Any],let owner=owners[i],
                  let policy=try NativeTextExpansionPolicy.decode(rawPolicy),!policy.insideBalloon else{continue}
            let source=CGRect(x:owner.minX*size.width,y:owner.minY*size.height,
                              width:owner.width*size.width,height:owner.height*size.height)
            var bounds:[CGRect]=[]
            for region in regions where region.classID==2 && region.confidence>=0.9 {
                let box=CGRect(x:region.bounds.minX*size.width,y:region.bounds.minY*size.height,
                               width:region.bounds.width*size.width,height:region.bounds.height*size.height)
                if let bound=NativeTextExpansionPolicy.sourceContainerBound(source:source,container:box,
                    confidence:Double(region.confidence),font:CGFloat(policy.sourceFontPixels),page:CGRect(origin:.zero,size:size)) {
                    bounds.append(CGRect(x:bound.minX/size.width,y:bound.minY/size.height,
                        width:bound.width/size.width,height:bound.height/size.height))
                }
            }
            guard let bound=bounds.min(by:{$0.width*$0.height<$1.width*$1.height})else{continue}
            let old=NativeTextExpansionPolicy.rect(policy.allowedRectNormalized,page:unit),limited=old.intersection(bound)
            guard !limited.isNull,!limited.isEmpty,limited.insetBy(dx:-1e-10,dy:-1e-10).contains(owner),
                  abs(old.minX-limited.minX)+abs(old.minY-limited.minY)+abs(old.width-limited.width)+abs(old.height-limited.height)>1e-9 else{continue}
            var proposals:[CGRect]=[],seen=Set<String>()
            for rect in policy.candidates.map({NativeTextExpansionPolicy.rect($0,page:unit).intersection(limited)})+[owner,limited] {
                guard !rect.isNull,!rect.isEmpty else{continue}
                let key=array(rect).map {String(format:"%.8f",$0)}.joined(separator:",")
                if seen.insert(key).inserted {proposals.append(rect)}
            }
            if proposals.count>32 {proposals=Array(proposals.prefix(30))+[owner,limited]}
            rawPolicy["allowedRectNormalized"]=array(limited)
            rawPolicy["candidates"]=proposals.map(array)
            rawPolicy["maskCoverage"]=proposals.map {_ in 1.0}
            rawPolicy["backgroundRisk"]=proposals.map {risk($0,owner:owner)}
            rawPolicy.removeValue(forKey:"ordinaryCandidateIndices")
            guard let updated=try NativeTextExpansionPolicy.decode(rawPolicy),updated.valid else{continue}
            output[i]["textExpansionPolicy"]=rawPolicy
            output[i]["renderExpansionBoundaryAuthority"]="source-associated-rf-box-expansion-bound"
        }
        // Also protect supplied policies: they bypass the generation loop.
        if let exclusion=exclusions(regions) {
            for i in output.indices {
                guard var policy=output[i]["textExpansionPolicy"] as? [String:Any],
                      policy["kind"] as? String == "source-near-limited-expansion",let owner=owners[i] else{continue}
                policy["forbiddenBalloonRectNormalized"]=array(exclusion.0)
                policy["forbiddenBalloonRowsNormalized"]=exclusion.1
                policy["balloonExclusionSourceRectNormalized"]=array(owner)
                output[i]["textExpansionPolicy"]=policy
            }
        }
        // The start anchor is a cohort decision. A balloon or an owner without
        // certified exterior capacity keeps the previous shared-centre policy.
        var groups:[String:[Int]]=[:]
        for i in output.indices {
            if let packet=output[i]["sourceClusterAlignment"] as? [String:Any],let group=packet["groupID"] as? String {
                groups[group,default:[]].append(i)
            }
        }
        for members in groups.values {
            let exterior=members.count>1 && members.allSatisfy {i in
                (output[i]["textExpansionPolicy"] as? [String:Any])?["kind"] as? String == "source-near-limited-expansion"
            }
            for i in members {
                var packet=output[i]["sourceClusterAlignment"] as! [String:Any]
                if exterior {packet["anchorsToSourceStart"]=true} else {packet.removeValue(forKey:"anchorsToSourceStart")}
                output[i]["sourceClusterAlignment"]=packet
            }
        }
        // Source-derived leading packets enter BEFORE Main captures its
        // authoritative source guides. A late display-only cluster would be
        // intentionally discarded by the source-font restoration pass.
        return NativeHorizontalSourceLeading.annotate(output, viewport: viewport,
            sourcePixelSize: CGSize(width: source.width, height: source.height)).items
    }
}
