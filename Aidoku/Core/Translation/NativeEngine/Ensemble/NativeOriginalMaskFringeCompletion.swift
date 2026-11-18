import CoreGraphics
import Foundation

/// Additive completion of tiny clipped original-ink components, not blanket
/// dilation or an RF-box erasure. Immutable base/protection define all votes.
enum NativeOriginalMaskFringeCompletion {
    /// Experimental source-color completion; cache identity must include this
    /// switch wherever the resulting removal mask can be reused.
    static var chromaticRuntimeEnabled: Bool {
        ProcessInfo.processInfo.environment["AIDOKU_MASK_CHROMATIC_FRINGE"] == "1"
    }
    /// Final-mask consumer identity, separate from neural segmentation outputs.
    /// Increment this version whenever chromatic admission or AA rules change.
    static var activePolicy: String? {
        chromaticRuntimeEnabled ? "source-color-connected-component-fringe-v1" : nil
    }
    /// Merge into render/resume projections ONLY. An absent/disabled experiment
    /// contributes no fields, retaining the existing default cache identity.
    static var cacheProjection: [String: String] {
        guard let activePolicy else { return [:] }
        return ["originalMaskChromaticFringePolicy": activePolicy]
    }
    struct Owner {
        let id: String
        let polygon: [CGPoint]
        let font: Double
        let background: [Double]
    }
    struct Result {
        let additions: Set<Int>
        let audit: [[String: Any]]
    }
    private static func nearby(_ input:[UInt8],width:Int,height:Int,radius:Int)->[UInt8] {
        var horizontal=input,result=input
        for y in 0..<height {
            var count=0
            for x in 0..<min(width,radius) {count += Int(input[y*width+x])}
            for x in 0..<width {
                if x+radius<width {count += Int(input[y*width+x+radius])}
                if x-radius-1>=0 {count -= Int(input[y*width+x-radius-1])}
                horizontal[y*width+x]=count>0 ? 1 : 0
            }
        }
        for x in 0..<width {
            var count=0
            for y in 0..<min(height,radius) {count += Int(horizontal[y*width+x])}
            for y in 0..<height {
                if y+radius<height {count += Int(horizontal[(y+radius)*width+x])}
                if y-radius-1>=0 {count -= Int(horizontal[(y-radius-1)*width+x])}
                result[y*width+x]=count>0 ? 1 : 0
            }
        }
        return result
    }
    static func isOpaque(original:CGImage,roi:CGRect)->Bool {
        if [CGImageAlphaInfo.none,.noneSkipFirst,.noneSkipLast].contains(original.alphaInfo) {return true}
        guard let crop=original.cropping(to:roi),crop.width>0,crop.height>0,
              crop.width<=1_000_000/crop.height else{return false}
        let n=crop.width*crop.height
        var rgba=[UInt8](repeating:0,count:n*4)
        let ok=rgba.withUnsafeMutableBytes { bytes->Bool in
            guard let c=CGContext(data:bytes.baseAddress,width:crop.width,height:crop.height,bitsPerComponent:8,
                bytesPerRow:crop.width*4,space:CGColorSpaceCreateDeviceRGB(),
                bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue|CGBitmapInfo.byteOrder32Big.rawValue) else{return false}
            c.setBlendMode(.copy);c.draw(crop,in:CGRect(x:0,y:0,width:crop.width,height:crop.height));return true
        }
        return ok && stride(from:3,to:rgba.count,by:4).allSatisfy{rgba[$0]==255}
    }
    static func apply(rgb: [UInt8], width: Int, height: Int, base: [UInt8], protection: [UInt8],
                      owners: [Owner], regions: [Ensemble100RFRegion], reach: Int,
                      includeChromatic: Bool = false,
                      verifyOpacity:(CGRect)->Bool) throws -> Result {
        guard width>0,height>0,width<=16_777_216/height,rgb.count==width*height*3,
              base.count==width*height,protection.count==base.count,(1...3).contains(reach) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        var additions=Set<Int>(),audit=[[String:Any]](),work=0
        let page=CGRect(x:0,y:0,width:width,height:height)
        for owner in owners {
            try Task.checkCancellation()
            guard owner.polygon.count>=3,owner.polygon.allSatisfy({$0.x.isFinite && $0.y.isFinite}),
                  owner.font.isFinite,owner.font>0,owner.background.count==3,
                  owner.background.allSatisfy({$0.isFinite && (0...255).contains($0)}) else {
                audit.append(["owner":owner.id,"status":"invalid-or-unknown-source-evidence"]);continue
            }
            let xs=owner.polygon.map(\.x),ys=owner.polygon.map(\.y)
            let box=CGRect(x:xs.min()!,y:ys.min()!,width:xs.max()!-xs.min()!,height:ys.max()!-ys.min()!)
            guard !box.isEmpty,page.contains(box) else{continue}
            let matches=regions.filter { region in
                guard region.classID==0,region.confidence.isFinite,region.confidence>=0.55 else{return false}
                let b=region.bounds
                guard [b.minX,b.minY,b.width,b.height].allSatisfy(\.isFinite),b.width>0,b.height>0 else{return false}
                let r=CGRect(x:b.minX*Double(width),y:b.minY*Double(height),
                             width:b.width*Double(width),height:b.height*Double(height))
                let intersection=box.intersection(r)
                return !intersection.isNull && intersection.width*intersection.height>=box.width*box.height*0.35
            }
            guard Set(matches.map(\.queryID)).count==1 else {
                audit.append(["owner":owner.id,"status":"missing-or-ambiguous-RF-text-support"]);continue
            }
            let roi=box.insetBy(dx:-ceil(owner.font*0.55)-3,dy:-ceil(owner.font*0.55)-3).integral.intersection(page)
            let x0=Int(roi.minX),y0=Int(roi.minY),w=Int(roi.width),h=Int(roi.height),n=w*h
            guard n>0,n<=1_000_000,work<=12_000_000-n else {
                audit.append(["owner":owner.id,"status":"optional-ROI-work-budget-retained-base"]);continue
            }
            work += n
            guard verifyOpacity(roi) else {
                audit.append(["owner":owner.id,"status":"source-ROI-opacity-unverified-retained-base"]);continue
            }
            // Match the existing chromatic completion's inclusive integer
            // source ownership, rather than silently switching to CG centers.
            let lattice=owner.polygon.map{CGPoint(x:Int($0.x),y:Int($0.y))}
            let path=CGMutablePath();path.addLines(between:lattice);path.closeSubpath()
            func owned(_ k:Int)->Bool {
                let point=CGPoint(x:x0+k%w,y:y0+k/w)
                for i in lattice.indices {
                    let a=lattice[i],b=lattice[(i+1)%lattice.count]
                    if (point.x-a.x)*(b.y-a.y)==(point.y-a.y)*(b.x-a.x),
                       point.x>=min(a.x,b.x),point.x<=max(a.x,b.x),
                       point.y>=min(a.y,b.y),point.y<=max(a.y,b.y) {return true}
                }
                return path.contains(point)
            }
            let bg=owner.background[0]*0.2126+owner.background[1]*0.7152+owner.background[2]*0.0722
            func global(_ k:Int)->Int{(y0+k/w)*width+x0+k%w}
            func contrast(_ k:Int)->Double {
                let p=global(k)*3
                return max(abs(Double(rgb[p])-owner.background[0]),
                    max(abs(Double(rgb[p+1])-owner.background[1]),abs(Double(rgb[p+2])-owner.background[2])))
            }
            let localBase=(0..<n).map{base[global($0)]==0 ? UInt8(0) : 1}
            let near=nearby(localBase,width:w,height:h,radius:reach)
            var accepted=0,vetoed=0,local=Set<Int>(),acceptedRecords=[[String:Any]]()
            for polarity in includeChromatic ? [-1.0,1.0,0.0] : [-1.0,1.0] {
                var core=[UInt8](repeating:0,count:n)
                for k in 0..<n {
                    let p=global(k)*3,r=Double(rgb[p]),g=Double(rgb[p+1]),b=Double(rgb[p+2])
                    let luminance=r*0.2126+g*0.7152+b*0.0722
                    let spread=max(r,max(g,b))-min(r,min(g,b))
                    if polarity == 0 {
                        if spread>=45,contrast(k)>=48 {core[k]=1}
                    } else if spread<=40,polarity*(luminance-bg)>=48 {core[k]=1}
                }
                for start in 0..<n where core[start] != 0 {
                    core[start]=0
                    var component=[start],cursor=0
                    while cursor<component.count {
                        let k=component[cursor],x=k%w,y=k/w;cursor += 1
                        for yy in max(0,y-1)...min(h-1,y+1) {for xx in max(0,x-1)...min(w-1,x+1) {
                            let q=yy*w+xx
                            if core[q] != 0 {core[q]=0;component.append(q)}
                        }}
                    }
                    let missing=component.filter{base[global($0)]==0}
                    guard !missing.isEmpty,component.count>=8,
                          Double(component.count-missing.count)>=0.8*Double(component.count),
                          Double(missing.count)<=max(4,0.2*owner.font*owner.font),
                          missing.allSatisfy({near[$0] != 0}) else{continue}
                    let cx=component.map{$0%w},cy=component.map{$0/w}
                    let componentWidth=cx.max()!-cx.min()!+1,componentHeight=cy.max()!-cy.min()!+1
                    let inside=component.filter{owned($0)}.count,masked=component.count-missing.count
                    guard cx.min()!>0,cy.min()!>0,cx.max()!<w-1,cy.max()!<h-1,
                          component.filter({base[global($0)] != 0 && owned($0)}).count>=8 else{continue}
                    let glyph=Double(max(componentWidth,componentHeight))<=1.7*owner.font &&
                        Double(component.count)<=1.1*owner.font*owner.font
                    // Existing chromatic tail admission reused for a neutral
                    // connected lettering chain. Dense planes/rails abstain.
                    let tail=Double(masked)>=0.95*Double(component.count) &&
                        Double(inside)>=0.95*Double(component.count) &&
                        Double(component.count)<=0.72*Double(componentWidth*componentHeight)
                    guard glyph || tail else{continue}
                    // Chromatic support has no semantic authority. Require the
                    // COMPLETE source component inside its actual owner, and a
                    // coherent observed pigment before filling any missing tip.
                    var pigment=[Double](repeating:0,count:3)
                    if polarity == 0 {
                        guard inside==component.count else{continue}
                        for k in component {for c in 0..<3 {pigment[c] += Double(rgb[global(k)*3+c])}}
                        pigment=pigment.map{$0/Double(component.count)}
                        guard component.allSatisfy({ k in
                            (0..<3).allSatisfy{abs(Double(rgb[global(k)*3+$0])-pigment[$0])<=32}
                        }) else{continue}
                    }
                    if component.contains(where:{protection[global($0)] != 0}) {vetoed += 1;continue}
                    func rfContains(_ k:Int)->Bool {
                        let point=CGPoint(x:Double(x0+k%w)+0.5,y:Double(y0+k/w)+0.5)
                        return matches.contains {r in CGRect(x:r.bounds.minX*Double(width),y:r.bounds.minY*Double(height),
                            width:r.bounds.width*Double(width),height:r.bounds.height*Double(height)).contains(point)}
                    }
                    guard (polarity == 0 ? component : missing).allSatisfy({rfContains($0)}) else{continue}
                    accepted += 1
                    if acceptedRecords.count<12 {
                        acceptedRecords.append(["kind":polarity == 0 ? "source-color-connected-component" :
                            (glyph ? "bounded-glyph-component" : "near-complete-lettering-tail"),
                            "bounds":[x0+cx.min()!,y0+cy.min()!,componentWidth,componentHeight],
                            "originalComponentPixels":component.count,"masked":masked,"owned":inside,
                            "missingCore":missing.count])
                    }
                    // A small original-contrast shell, bounded by the SAME
                    // immutable base-distance ring; never sequential growth.
                    for k in missing {
                        let x=k%w,y=k/w,halo=min(2,reach)
                        for yy in max(0,y-halo)...min(h-1,y+halo) {for xx in max(0,x-halo)...min(w-1,x+halo) {
                            let q=yy*w+xx,p=global(q)
                            if base[p]==0,near[q] != 0,protection[p]==0,contrast(q)>=8,rfContains(q) {
                                if polarity == 0 {
                                    guard owned(q), sourceColorMixture(rgb:rgb,offset:p*3,
                                        pigment:pigment,background:owner.background) else{continue}
                                }
                                local.insert(p)
                            }
                        }}
                    }
                }
            }
            additions.formUnion(local)
            audit.append(["owner":owner.id,"status":"original-component-fringe-proposal",
                "acceptedComponents":accepted,"protectedComponentVetoes":vetoed,"added":local.count,
                "reachOriginalPixels":reach,"roiPixels":n,"rfQueries":Set(matches.map(\.queryID)).sorted(),
                "chromaticEnabled":includeChromatic,
                "accepted":acceptedRecords,"acceptedDetailsTruncated":accepted>acceptedRecords.count,
                "authority":"original neutral contrast components mostly in immutable base; not glyph/semantic gold"])
        }
        return .init(additions:additions,audit:audit)
    }

    /// Original AA is a mixture of the observed pigment and local background.
    /// Reject unrelated saturated neighbors even when they touch the seed.
    static func sourceColorMixture(rgb:[UInt8],offset:Int,pigment:[Double],background:[Double])->Bool {
        let direction=(0..<3).map{pigment[$0]-background[$0]}
        let norm=direction.reduce(0){$0+$1*$1}
        guard norm>=48*48 else{return false}
        let sample=(0..<3).map{Double(rgb[offset+$0])-background[$0]}
        let fraction=zip(sample,direction).reduce(0){$0+$1.0*$1.1}/norm
        return fraction>=0.03 && fraction<=1.15 && (0..<3).allSatisfy{
            abs(sample[$0]-fraction*direction[$0])<=12
        }
    }
}
