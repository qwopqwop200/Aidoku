import CoreGraphics
import Foundation

/// Original image is retained explicitly. Restored pixels never enter the observer.
/// Call observe before constructing any attributed string / shaped artifact.
final class NativeOriginalSourcePalette {
    struct Observation {
        let originalFill: [Double]?
        let originalStroke: [Double]?
        let evidence: NativeSourceInkSelection.Evidence?
        let selected: NativeSourceInkSelection.Selection
        let rawPrediction: [String: Any]?
        let unknownReason: String?

        func display(restored: CGImage, owner: CGRect, fontPixels: CGFloat,
                     pixelsPerPoint: CGFloat) throws -> NativeExplicitDisplayStrokePolicy.Decision? {
            guard let rgb = selected.color else { return nil }
            return try NativeExplicitDisplayStrokePolicy.decide(
                chosenFill: CGColor(red: rgb[0]/255, green: rgb[1]/255, blue: rgb[2]/255, alpha: 1),
                restored: restored, ownerOutputPixels: owner, fontOutputPixels: fontPixels,
                outputPixelsPerLayoutPoint: pixelsPerPoint, sourceAppearance: rawPrediction)
        }
    }

    private let original: CGImage
    // This observer owns one immutable original image. Keep observations, never
    // pixel buffers, while testing several contiguous partitions of its owners.
    private var memberObservations=[Data:Observation]()

    init(original: CGImage) {
        self.original = original
    }

    // Opt-in until original/current/candidate image comparison is complete.
    static func ownedGlyphRecoveryEnabled(_ geometry:[String:Any]) -> Bool {
        if geometry["sourceOwnedGlyphPaletteRecoverySuppressed"] as? Bool == true {return false}
        return geometry["sourceOwnedGlyphPaletteRecovery"] as? Bool == true ||
            ProcessInfo.processInfo.environment["AIDOKU_SOURCE_OWNED_GLYPH_PALETTE_RECOVERY"] == "1" ||
            (geometry["sourceChromaticShellPaletteRecoverySuppressed"] as? Bool != true &&
                (geometry["sourceChromaticShellPaletteRecovery"] as? Bool == true ||
                 ProcessInfo.processInfo.environment["AIDOKU_SOURCE_CHROMATIC_SHELL_PALETTE_RECOVERY"] == "1")) ||
            openRimGlyphRecoveryEnabled(geometry)
    }

    static func openRimGlyphRecoveryEnabled(_ geometry:[String:Any]) -> Bool {
        if geometry["sourceOwnedGlyphPaletteRecoverySuppressed"] as? Bool == true {return false}
        return geometry["sourceOpenRimGlyphPaletteRecovery"] as? Bool == true ||
            ProcessInfo.processInfo.environment["AIDOKU_SOURCE_OPEN_RIM_GLYPH_PALETTE_RECOVERY"] == "1"
    }

    /// A local stroke cross-section, not a closed connected component or a
    /// bbox mode. Both rays must reach OWN bright pixels without crossing a
    /// darker core, alpha, or ownership boundary. Repeated stable minima can
    /// survive open rims and anti-aliasing without borrowing a peer endpoint.
    static func openRimGlyphMeasurement(rgba:[UInt8],width:Int,height:Int,ownership:[UInt8]) -> [String:Any]? {
        guard width>=8,height>=8,height<=262144,width<=262144/height,
              rgba.count==width*height*4,ownership.count==width*height else{return nil}
        func color(_ p:Int)->[Double] {(0..<3).map{Double(rgba[p*4+$0])}}
        func distance(_ a:[Double],_ b:[Double])->Double {zip(a,b).map{abs($0-$1)}.max()!}
        func valid(_ p:Int)->Bool {ownership[p] != 0 && rgba[p*4+3]>=250}
        let axes=[(1,0),(0,1),(1,1),(1,-1)]
        var profiles=[(rgb:[Double],rim:[Double],pixel:Int,axis:Int)]()
        for y in 1..<(height-1) {for x in 1..<(width-1) {
            let p=y*width+x
            guard valid(p) else{continue}
            let c=color(p)
            guard c.max()!<=205,c.max()!-c.min()!>=28,
                  [p-1,p+1,p-width,p+width].filter({valid($0) && distance(color($0),c)<=18}).count>=2 else{continue}
            for (axis,direction) in axes.enumerated() {
                var rims=[[Double]]()
                for sign in [-1,1] {
                    for step in 1...6 {
                        let xx=x+direction.0*step*sign,yy=y+direction.1*step*sign
                        guard xx>=0,yy>=0,xx<width,yy<height else{break}
                        let q=yy*width+xx
                        guard valid(q) else{break}
                        let v=color(q)
                        if v.min()!>=225,v.max()!-v.min()!<=32 {
                            rims.append(v);break
                        }
                        // A profile is a local observed minimum, not a ray
                        // passing over a second, darker neighbouring stroke.
                        if v.reduce(0,+)<c.reduce(0,+)-18 {break}
                    }
                }
                if rims.count==2 {
                    profiles.append((c,(0..<3).map{(rims[0][$0]+rims[1][$0])/2},p,axis));break
                }
            }
        }}
        guard profiles.count>=24 else{return nil}
        var bins=[Int:[Int]]()
        for (i,p) in profiles.enumerated() {
            let c=p.rgb.map{Int($0)/24}
            bins[c[0]*121+c[1]*11+c[2],default:[]].append(i)
        }
        let centers=bins.keys.sorted().map { key in
            (0..<3).map { channel in
                bins[key]!.reduce(0.0){$0+profiles[$1].rgb[channel]}/Double(bins[key]!.count)
            }
        }
        var ranked:[[Int]]=centers.map { center -> [Int] in
            profiles.indices.filter{distance(profiles[$0].rgb,center)<=24}
        }
        ranked.sort { a,b in
            if a.count != b.count {return a.count>b.count}
            return (a.first ?? 0)<(b.first ?? 0)
        }
        guard let selected=ranked.first,selected.count>=24 else{return nil}
        func tiles(_ indices:[Int])->Set<Int> {
            Set(indices.map { let p=profiles[$0].pixel;return ((p/width)*6/height)*6+(p%width)*6/width })
        }
        let spatial=tiles(selected)
        let cells=Set(selected.map{let p=profiles[$0].pixel;return (p/width/3)*width+p%width/3})
        let orientations=Set(selected.map{profiles[$0].axis})
        guard spatial.count>=6,cells.count>=12,orientations.count>=2 else{return nil}
        // Independently repeated, incompatible emphasis must remain unknown.
        let chosenSet=Set(selected)
        guard !ranked.contains(where:{ candidate in
            candidate.count>=max(24,selected.count/2) && tiles(candidate).count>=4 &&
                Set(candidate).isDisjoint(with:chosenSet)
        }) else{return nil}
        let fill=(0..<3).map{c in
            (selected.reduce(0.0){$0+profiles[$1].rgb[c]}/Double(selected.count)).rounded()
        }
        let rim=(0..<3).map{c in
            (selected.reduce(0.0){$0+profiles[$1].rim[c]}/Double(selected.count)).rounded()
        }
        return ["foreground":fill,"stroke":rim,"selectedEndpoint":"foreground","version":1,
            "boundaryRole":"opposing bright source boundary; source outline versus surrounding surface unresolved",
            "profiles":selected.count,"observedProfiles":profiles.count,"tiles":spatial.count,
            "independentCells":cells.count,"orientations":orientations.count,
            "authority":"owned stable chromatic minima with opposing owned bright boundaries; no peer, bbox mode or restored pixels"]
    }

    /// Each vote is a separately enclosed ORIGINAL component, never a bbox
    /// histogram, a peer colour, or a display/restoration sample. A white rim
    /// must disconnect the component from the crop exterior. Six independently
    /// flat chromatic cores must repeat across four owned spatial tiles. The
    /// symmetric neutral policy measures white counters bounded by dark ink;
    /// its selected ink is the independently observed enclosing contour.
    static func enclosedGlyphMeasurement(rgba:[UInt8],width:Int,height:Int,ownership:[UInt8],neutral:Bool=false,
                                         chromaticShell:Bool=false) -> [String:Any]? {
        guard width>=8,height>=8,height<=262144,width<=262144/height,
              rgba.count==width*height*4,ownership.count==width*height else{return nil}
        let n=width*height
        func color(_ p:Int)->[Double] {(0..<3).map{Double(rgba[p*4+$0])}}
        func distance(_ a:[Double],_ b:[Double])->Double {zip(a,b).map{abs($0-$1)}.max()!}
        func white(_ p:Int)->Bool {
            let c=color(p)
            if chromaticShell {
                // Saturation identifies a possible enclosing contour, not ink
                // truth. Its own stable plateau must subsequently repeat around
                // independently enclosed pale glyph components.
                return ownership[p] != 0 && rgba[p*4+3]>=250 && c.max()!-c.min()!>=90 && c.min()!<=140
            }
            return rgba[p*4+3]>=250 && (neutral
                ? c.max()!<=40 && c.max()!-c.min()!<=20
                : c.min()!>=235 && c.max()!-c.min()!<=24)
        }
        let rim=(0..<n).map{white($0)}
        var seen=[Bool](repeating:false,count:n)
        var witnesses=[(rgb:[Double],stroke:[Double],pixels:Int,rimPixels:Int,tile:Int)]()
        var chromaticCores=[[Int]](),chromaticContours=[[Int]]()
        let limit=max(32,min(4096,n/20))
        for seed in 0..<n where !seen[seed] && !rim[seed] {
            seen[seed]=true
            var queue=[seed],cursor=0,external=false,edges=[Int]()
            while cursor<queue.count {
                let p=queue[cursor];cursor+=1
                let x=p%width,y=p/width
                if x==0 || y==0 || x==width-1 || y==height-1 || rgba[p*4+3]<250 {external=true}
                for q in [x>0 ? p-1:-1,x+1<width ? p+1:-1,y>0 ? p-width:-1,y+1<height ? p+width:-1] where q>=0 {
                    if rim[q] {if edges.count<16384 {edges.append(q)}}
                    else if !seen[q] {seen[q]=true;queue.append(q)}
                }
            }
            guard !external,(6...limit).contains(queue.count),edges.count>=8,
                  queue.allSatisfy({ownership[$0] != 0}) else{continue}
            var bins=[Int:[Int]]()
            for p in queue {
                let c=color(p)
                guard (neutral || chromaticShell) ? c.min()!>=225 && c.max()!-c.min()!<=24
                    : c.max()!<=205 && c.max()!-c.min()!>=28 else{continue}
                let x=p%width,y=p/width
                let peers=[x>0 ? p-1:-1,x+1<width ? p+1:-1,y>0 ? p-width:-1,y+1<height ? p+width:-1]
                guard peers.filter({$0>=0 && distance(color($0),c)<=18}).count>=2 else{continue}
                let key=(Int(c[0])/16)*256+(Int(c[1])/16)*16+Int(c[2])/16
                bins[key,default:[]].append(p)
            }
            guard let key=bins.keys.sorted(by:{bins[$0]!.count == bins[$1]!.count ? $0<$1:bins[$0]!.count>bins[$1]!.count}).first,
                  let pixels=bins[key],pixels.count>=6,
                  Double(pixels.count)>=Double(queue.count)*0.35 else{continue}
            let rgb=(0..<3).map{channel in pixels.reduce(0.0){$0+Double(rgba[$1*4+channel])}/Double(pixels.count)}
            var measuredEdges=edges
            if chromaticShell {
                // AA edges are not source endpoints. Retain only owned, flat
                // contour pixels and require one consistent plateau per core.
                var pool=Set(edges),edgeFrontier=Array(pool)
                for _ in 0..<3 {
                    var next=[Int]()
                    for p in edgeFrontier {
                        let x=p%width,y=p/width,c=color(p),chroma=c.max()!-c.min()!
                        for q in [x>0 ? p-1:-1,x+1<width ? p+1:-1,y>0 ? p-width:-1,y+1<height ? p+width:-1]
                            where q>=0 && rim[q] && !pool.contains(q) {
                            let v=color(q)
                            if v.max()!-v.min()!>=chroma-6 {pool.insert(q);next.append(q)}
                        }
                    }
                    edgeFrontier=next
                }
                // Walk through the inner AA fringe to the observed saturated
                // plateau. Blended edge pixels must not dilute the endpoint.
                let maximumChroma=pool.map{p -> Double in let c=color(p);return c.max()!-c.min()!}.max() ?? 0
                let stable=pool.sorted().filter { p in
                    let c=color(p),x=p%width,y=p/width
                    guard c.max()!-c.min()!>=maximumChroma-12 else{return false}
                    return [x>0 ? p-1:-1,x+1<width ? p+1:-1,y>0 ? p-width:-1,y+1<height ? p+width:-1]
                        .filter{$0>=0 && rim[$0] && distance(color($0),c)<=12}.count>=2
                }
                guard stable.count>=8 else{continue}
                var centers=[Int:[Double]]()
                for p in stable {
                    let c=color(p),key=(Int(c[0])/16)*256+(Int(c[1])/16)*16+Int(c[2])/16
                    if centers[key]==nil {centers[key]=c}
                }
                let clusters=centers.keys.sorted().map{key in stable.filter{distance(color($0),centers[key]!)<=16}}
                guard let strongest=clusters.max(by:{$0.count<$1.count}),
                      strongest.count>=8,Double(strongest.count)>=Double(stable.count)*0.8 else{continue}
                measuredEdges=strongest
            }
            let stroke=(0..<3).map{channel in
                measuredEdges.reduce(0.0){$0+Double(rgba[$1*4+channel])}/Double(measuredEdges.count)
            }
            if chromaticShell {
                // Count only contour connected to these certified cores, never
                // all matching background pixels in the owner rectangle.
                var contour=Set(measuredEdges),frontier=measuredEdges
                for _ in 0..<6 {
                    var next=[Int]()
                    for p in frontier {
                        let x=p%width,y=p/width
                        for q in [x>0 ? p-1:-1,x+1<width ? p+1:-1,y>0 ? p-width:-1,y+1<height ? p+width:-1]
                            where q>=0 && rim[q] && !contour.contains(q) && distance(color(q),stroke)<=16 {
                            contour.insert(q);next.append(q)
                        }
                    }
                    frontier=next
                }
                guard contour.count<=limit*4 else{continue}
                chromaticCores.append(pixels);chromaticContours.append(contour.sorted())
            }
            let cx=pixels.reduce(0){$0+$1%width}/pixels.count,cy=pixels.reduce(0){$0+$1/width}/pixels.count
            witnesses.append((rgb,stroke,pixels.count,Set(measuredEdges.filter{ownership[$0] != 0}).count,
                (cy*6/height)*6+cx*6/width))
        }
        let ranked=witnesses.indices.map { index -> [Int] in
            witnesses.indices.filter{distance(witnesses[$0].rgb,witnesses[index].rgb)<=20}
        }.sorted { a,b in
            if a.count != b.count {return a.count>b.count}
            return (a.first ?? 0)<(b.first ?? 0)
        }
        guard let selected=ranked.first,selected.count>=6,
              Set(selected.map{witnesses[$0].tile}).count>=4 else{return nil}
        if chromaticShell {
            // White cores alone cannot certify mutually incompatible contours.
            for a in selected {for b in selected where a<b {
                guard distance(witnesses[a].stroke,witnesses[b].stroke)<=24 else{return nil}
            }}
        }
        // A competing independently repeated ink is uncertainty, not a vote
        // to erase emphasis. No relaxed consensus threshold is used here.
        guard !ranked.contains(where: { candidate in
            candidate.count>=max(3,selected.count/2) && Set(candidate).isDisjoint(with:Set(selected))
        }) else{return nil}
        let pixels=selected.reduce(0){$0+witnesses[$1].pixels}
        let fill=(0..<3).map{channel in
            (selected.reduce(0.0){$0+witnesses[$1].rgb[channel]*Double(witnesses[$1].pixels)}/Double(pixels)).rounded()
        }
        let stroke=(0..<3).map{channel in
            (selected.reduce(0.0){$0+witnesses[$1].stroke[channel]}/Double(selected.count)).rounded()
        }
        if chromaticShell {
            let cores=Set(selected.flatMap{chromaticCores[$0]})
            let contours=Set(selected.flatMap{chromaticContours[$0]})
            return ["foreground":fill,"stroke":stroke,"components":selected.count,"corePixels":cores.count,
                "ownedRimPixels":contours.count,"tiles":Set(selected.map{witnesses[$0].tile}).count,
                "selectedEndpoint":Double(contours.count)>Double(cores.count)*1.2 ? "stroke":"foreground","version":1,
                "dominanceAuthority":"unique enclosed stable pale-core pixels versus connected stable chromatic contour pixels within six native pixels",
                "authority":"independently enclosed repeated owned original pale cores and stable chromatic contours; no peer or background mode"]
        }
        return ["foreground":fill,"stroke":stroke,"components":selected.count,"corePixels":pixels,
            "ownedRimPixels":selected.reduce(0){$0+witnesses[$1].rimPixels},
            "selectedEndpoint":neutral ? "stroke":"foreground",
            "tiles":Set(selected.map{witnesses[$0].tile}).count,"version":2,
            "authority":neutral
                ? "independently enclosed repeated owned original white counters and adjacent measured dark contours; no peer or background mode"
                : "independently enclosed repeated owned original chromatic cores and adjacent measured white rims; no peer or background mode"]
    }

    func ownedGlyphObservation(sourceBounds:[Double],originalGeometry:[String:Any]) -> Observation? {
        guard sourceBounds.count==4,sourceBounds.allSatisfy(\.isFinite),
              sourceBounds[0]>=0,sourceBounds[1]>=0,sourceBounds[2]>0,sourceBounds[3]>0,
              sourceBounds[0]+sourceBounds[2]<=1.000001,sourceBounds[1]+sourceBounds[3]<=1.000001 else{return nil}
        let iw=Double(original.width),ih=Double(original.height)
        let x=max(0,floor(sourceBounds[0]*iw)-4),y=max(0,floor(sourceBounds[1]*ih)-4)
        let w=Int(min(iw,ceil((sourceBounds[0]+sourceBounds[2])*iw)+4)-x)
        let h=Int(min(ih,ceil((sourceBounds[1]+sourceBounds[3])*ih)+4)-y)
        guard w>=8,h>=8,h<=262144,w<=262144/h,
              let crop=original.cropping(to:CGRect(x:x,y:y,width:Double(w),height:Double(h))) else{return nil}
        var rgba=[UInt8](repeating:0,count:w*h*4)
        let captured=rgba.withUnsafeMutableBytes { bytes -> Bool in
            guard let c=CGContext(data:bytes.baseAddress,width:w,height:h,bitsPerComponent:8,bytesPerRow:w*4,
                space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else{return false}
            c.interpolationQuality = .none
            c.draw(crop,in:CGRect(x:0,y:0,width:w,height:h));return true
        }
        let polygon=originalGeometry["sourcePolygon"] as? [[Double]] ?? [
            [sourceBounds[0],sourceBounds[1]],[sourceBounds[0]+sourceBounds[2],sourceBounds[1]],
            [sourceBounds[0]+sourceBounds[2],sourceBounds[1]+sourceBounds[3]],[sourceBounds[0],sourceBounds[1]+sourceBounds[3]]]
        guard captured,polygon.count>=3,polygon.allSatisfy({$0.count==2 && $0.allSatisfy(\.isFinite)}) else{return nil}
        let path=CGMutablePath()
        path.addLines(between:polygon.map{CGPoint(x:$0[0]*iw-x,y:$0[1]*ih-y)});path.closeSubpath()
        var owned=[UInt8](repeating:0,count:w*h)
        for yy in 0..<h {for xx in 0..<w {
            if path.contains(CGPoint(x:Double(xx)+0.5,y:Double(yy)+0.5)) {owned[yy*w+xx]=1}
        }}
        let open=Self.openRimGlyphRecoveryEnabled(originalGeometry)
            ? Self.openRimGlyphMeasurement(rgba:rgba,width:w,height:h,ownership:owned):nil
        let closed=open ?? Self.enclosedGlyphMeasurement(rgba:rgba,width:w,height:h,ownership:owned,neutral:true)
            ?? Self.enclosedGlyphMeasurement(rgba:rgba,width:w,height:h,ownership:owned)
        let shellEnabled=originalGeometry["sourceOwnedGlyphPaletteRecoverySuppressed"] as? Bool != true &&
            originalGeometry["sourceChromaticShellPaletteRecoverySuppressed"] as? Bool != true &&
            (originalGeometry["sourceChromaticShellPaletteRecovery"] as? Bool == true ||
             ProcessInfo.processInfo.environment["AIDOKU_SOURCE_CHROMATIC_SHELL_PALETTE_RECOVERY"] == "1")
        let shell=shellEnabled
            ? Self.enclosedGlyphMeasurement(rgba:rgba,width:w,height:h,ownership:owned,chromaticShell:true):nil
        guard let measured=shell ?? closed,
              let fill=measured["foreground"] as? [Double],let stroke=measured["stroke"] as? [Double] else{return nil}
        let useStroke=measured["selectedEndpoint"] as? String == "stroke"
        // Open profiles establish the core, not whether the bright boundary
        // is a painted outline or the surrounding source surface.
        return Observation(originalFill:fill,originalStroke:shell != nil || open == nil ? stroke:nil,evidence:nil,
            selected:.init(color:useStroke ? stroke:fill,
                role:shell != nil ? (useStroke ? "sourceStrokeOwnedChromaticShell":"sourceFillOwnedChromaticShell"):
                    (open != nil ? "sourceFillOwnedOpenRimGlyphs":
                        (useStroke ? "sourceStrokeOwnedEnclosedGlyphs":"sourceFillOwnedEnclosedGlyphs")),neutralExteriorSuppressed:shell == nil),
            rawPrediction:[shell != nil ? "ownedChromaticShellRecovery":
                (open != nil ? "ownedOpenRimGlyphRecovery":"ownedEnclosedGlyphRecovery"):measured],
            unknownReason:open != nil && shell == nil ? "owned opposing-boundary core estimate; source outline unresolved; not gold":
                "bounded independent enclosed glyph witness; source colour estimate, not gold")
    }

    /// Exact observer dependencies only. Display font/text/restoration never
    /// belong in an original-color key; group members and policy do.
    static func memoDependencies(_ geometry:[String:Any]) throws -> Data? {
        func group(_ raw:[String:Any],depth:Int,inheritedRecovery:Bool=false,inheritedOpen:Bool=false,
                   inheritedShell:Bool=false,inheritedConnected:Bool=false) throws -> Any {
            guard depth<8 else {throw NSError(domain:"SourcePaletteDependencyDepth",code:1)}
            let ownedRecovery=inheritedRecovery || ownedGlyphRecoveryEnabled(raw)
            let open=inheritedOpen || openRimGlyphRecoveryEnabled(raw)
            let shell=inheritedShell || (raw["sourceOwnedGlyphPaletteRecoverySuppressed"] as? Bool != true &&
                (raw["sourceChromaticShellPaletteRecovery"] as? Bool == true ||
                 ProcessInfo.processInfo.environment["AIDOKU_SOURCE_CHROMATIC_SHELL_PALETTE_RECOVERY"] == "1"))
            var openDependency:[String:Any]=open ? ["openRimGlyphRecovery":true,"openRimGlyphVersion":1]:[:]
            let connected=inheritedConnected || raw["sourceOwnConnectedBoundaryRecovery"] as? Bool == true
            if connected {openDependency["ownConnectedBoundaryVersion"]=1}
            if shell {openDependency["chromaticShellRecovery"]=true;openDependency["chromaticShellVersion"]=1}
            guard raw["sourceTextBlockMemberPalette"] as? Bool == true,
                  let members=raw["agent02MemberItems"] as? [[String:Any]],(2...6).contains(members.count) else {
                return ownedRecovery || !openDependency.isEmpty ? ["version":10,"ownedGlyphRecovery":ownedRecovery,"ownedGlyphVersion":3]
                    .merging(openDependency,uniquingKeysWith:{$1}) as [String:Any]:NSNull()
            }
            return ["version":10,"ownedGlyphRecovery":ownedRecovery,"ownedGlyphVersion":3,
                "inkOnly":raw["sourceTextBlockInkOnlyAdmission"] as? Bool == true,
                "stackedContinuation":raw["sourceStackedContinuation"] as? Bool == true,
                "columnPeerShell":raw["sourceTextBlockColumnPeerShell"] as? Bool == true,
                "nativePeerRecovery":raw["sourceTextBlockNativePeerRecovery"] as? Bool == true,
                "measuredEvidenceRecovery":raw["sourceTextBlockMeasuredEvidenceRecovery"] as? Bool == true,
                "members":try members.map { member -> [String:Any] in
                    ["id":member["id"] ?? NSNull(),
                     "bounds":(member["sourceBounds"] as? [Double] ?? []).map(\.bitPattern),
                     "polygon":(member["sourcePolygon"] as? [[Double]]).map{$0.map{$0.map(\.bitPattern)}} as Any? ?? NSNull(),
                     "group":try group(member,depth:depth+1,inheritedRecovery:ownedRecovery,inheritedOpen:open,
                        inheritedShell:shell,inheritedConnected:connected)]
                }].merging(openDependency,uniquingKeysWith:{$1}) as [String:Any]
        }
        let descriptor=try group(geometry,depth:0)
        if descriptor is NSNull {return nil}
        return try JSONSerialization.data(withJSONObject:descriptor,options:[.sortedKeys])
    }

    func observeCached(context:NativeMainEnsembleCacheContext?,originalGeometry:[String:Any]) -> Observation {
        let bounds=originalGeometry["sourceBounds"] as? [Double] ?? []
        let polygon=originalGeometry["sourcePolygon"] as? [[Double]]
        let dependencies:Data?
        do {dependencies=try Self.memoDependencies(originalGeometry)}
        catch {return observe(sourceBounds:bounds,originalGeometry:originalGeometry)}
        return NativeMainEnsembleCacheContext.sourcePalette(context:context,original:original,
            bounds:bounds,polygon:polygon,opaqueDependencies:dependencies) {
                observe(sourceBounds:bounds,originalGeometry:originalGeometry)
            }
    }

    /// One representative ORIGINAL observation, with every member endpoint
    /// retained. Ink-only admission is opt-in for the mandatory BW display
    /// stroke path; it does not claim the source outlines were identical.
    static func corroboratedStackedMembers(_ observations:[Observation]) -> [Observation] {
        guard observations.count==2 else{return observations}
        return observations.enumerated().map { index,observation in
            guard let fill=observation.originalFill,fill.count==3,fill.min()!>=225,
                  observation.originalStroke==nil,
                  let native=(observation.rawPrediction?["multiscale"] as? [String:Any])?["native"] as? [String:Any],
                  let core=native["foreground"] as? [Double],core.count==3,
                  zip(fill,core).allSatisfy({abs($0-$1)<=24}),
                  let shell=native["gradientShellRecovery"] as? [String:Any],
                  (shell["rays"] as? NSNumber)?.doubleValue ?? 0 >= 24,
                  (shell["spatialSupport"] as? NSNumber)?.doubleValue ?? 0 >= 4,
                  let stroke=shell["rgb"] as? [Double],stroke.count==3,
                  stroke.allSatisfy({$0.isFinite && (0...255).contains($0)}),
                  stroke.max()!-stroke.min()!>=90,
                  let peer=observations[1-index].selected.color,peer.count==3,
                  zip(stroke,peer).allSatisfy({abs($0-$1)<=24}),
                  let topology=native["sourceInkDominance"] as? [String:Any] else{return observation}
            let keys=["fillPixels","strokePixels","fillShapePixels","strokeShapePixels",
                      "fillRepeatedTiles","strokeRepeatedTiles","fillEnclosedPixels","strokeEnclosedPixels"]
            let numbers=keys.compactMap{(topology[$0] as? NSNumber)?.doubleValue}
            guard numbers.count==8,numbers.allSatisfy({$0.isFinite && $0>=0}),
                  numbers[3]>=12,numbers[5]>=4 else{return observation}
            let evidence=NativeSourceInkSelection.Evidence(fillPixels:numbers[0],strokePixels:numbers[1],
                fillShapePixels:numbers[2],strokeShapePixels:numbers[3],fillRepeatedTiles:numbers[4],
                strokeRepeatedTiles:numbers[5],fillEnclosedPixels:numbers[6],strokeEnclosedPixels:numbers[7])
            let selection=NativeSourceInkSelection.select(fill:core,stroke:stroke,evidence:evidence)
            guard selection.role=="sourceStroke" else{return observation}
            var raw=native
            raw["stackedPeerShellCorroboration"]=["prior":observation.rawPrediction ?? [:],
                "peerSelectedOriginalInk":peer,"authority":"native repeated original core-shell rays + independent peer ink; not display color"]
            return Observation(originalFill:core,originalStroke:stroke,evidence:evidence,
                selected:selection,rawPrediction:raw,unknownReason:"native shell corroborated by independent continuation owner")
        }
    }

    static func corroboratedGroupCores(_ observations:[Observation]) -> [Observation] {
        observations.enumerated().map { index,observation in
            guard observation.selected.role=="sourceStroke",
                  let fill=observation.originalFill,let stroke=observation.originalStroke,
                  fill.count==3,stroke.count==3,stroke.max()!-stroke.min()!<90,
                  let evidence=observation.evidence,evidence.fillShapePixels>=12,evidence.fillRepeatedTiles>=4,
                  observations.enumerated().contains(where: { peerIndex,peer in
                      guard peerIndex != index,let color=peer.selected.color,color.count==3 else{return false}
                      return zip(fill,color).allSatisfy{abs($0-$1)<=24}
                  }) else{return observation}
            var raw=observation.rawPrediction ?? [:]
            raw["peerCoreCorroboration"]=["priorSelectedInk":observation.selected.color as Any? ?? NSNull(),
                "authority":"owned repeated source core matches independently selected peer; low-chroma shell is not paragraph emphasis"]
            return Observation(originalFill:fill,originalStroke:stroke,evidence:evidence,
                selected:.init(color:fill,role:"sourceFillPeerCorroborated",neutralExteriorSuppressed:true),
                rawPrediction:raw,unknownReason:observation.unknownReason)
        }
    }

    /// Recover only measured native endpoints corroborated by an unchanged
    /// peer selection. The input array is immutable: recoveries never vote for
    /// later recoveries, and an already agreeing group is left untouched.
    static func corroboratedNativePeerMembers(_ observations:[Observation]) -> [Observation] {
        func valid(_ rgb:[Double]?) -> Bool {
            guard let rgb,rgb.count==3 else{return false}
            return rgb.allSatisfy{$0.isFinite && (0...255).contains($0)}
        }
        let colors=observations.compactMap{valid($0.selected.color) ? $0.selected.color : nil}
        if colors.count==observations.count,
           (0..<3).allSatisfy({ channel in
               let values=colors.map{$0[channel]}
               return (values.max() ?? 0)-(values.min() ?? 0)<=24
           }) {return observations}
        let keys=["fillPixels","strokePixels","fillShapePixels","strokeShapePixels",
                  "fillRepeatedTiles","strokeRepeatedTiles","fillEnclosedPixels","strokeEnclosedPixels"]
        return observations.enumerated().map { index,observation in
            guard let native=(observation.rawPrediction?["multiscale"] as? [String:Any])?["native"] as? [String:Any],
                  let topology=native["sourceInkDominance"] as? [String:Any],
                  let confidence=native["confidence"] as? [String:Any] else{return observation}
            let numbers=keys.compactMap{(topology[$0] as? NSNumber)?.doubleValue}
            let confidences=["foreground","stroke"].compactMap{(confidence[$0] as? NSNumber)?.doubleValue}
                .filter{$0.isFinite && (0...1).contains($0)}
            guard numbers.count==8,numbers.allSatisfy({$0.isFinite && $0>=0}),
                  (confidences.max() ?? 0)>=0.5 else{return observation}
            let fill=(native["foreground"] as? [Double]).flatMap{valid($0) ? $0 : nil}
            let stroke=(native["stroke"] as? [Double]).flatMap{valid($0) ? $0 : nil}
            let evidence=NativeSourceInkSelection.Evidence(fillPixels:numbers[0],strokePixels:numbers[1],
                fillShapePixels:numbers[2],strokeShapePixels:numbers[3],fillRepeatedTiles:numbers[4],
                strokeRepeatedTiles:numbers[5],fillEnclosedPixels:numbers[6],strokeEnclosedPixels:numbers[7])
            let selected=NativeSourceInkSelection.select(fill:fill,stroke:stroke,evidence:evidence)
            guard valid(selected.color),let color=selected.color,
                  color != observation.selected.color else{return observation}
            let usesStroke=selected.role=="sourceStroke" || selected.role=="sourceStrokeOnly"
            guard (usesStroke ? evidence.strokeShapePixels : evidence.fillShapePixels)>=12,
                  (usesStroke ? evidence.strokeRepeatedTiles : evidence.fillRepeatedTiles)>=4 else{return observation}
            let peers=observations.indices.filter { peer in
                guard peer != index,valid(observations[peer].selected.color),
                      let prior=observations[peer].selected.color else{return false}
                return zip(color,prior).allSatisfy{abs($0-$1)<=24}
            }
            guard !peers.isEmpty else{return observation}
            var raw=native
            raw["nativePeerCorroboration"]=[
                "nativeMeasurement":native,
                "priorCoarse":["originalFill":observation.originalFill as Any? ?? NSNull(),
                    "originalStroke":observation.originalStroke as Any? ?? NSNull(),
                    "selectedOriginalInk":observation.selected.color as Any? ?? NSNull(),
                    "selectedRole":observation.selected.role,"rawPrediction":observation.rawPrediction ?? [:]],
                "peerIndices":peers,
                "peerOriginalSelectedInk":peers.map{observations[$0].selected.color!},
                "authority":"native original endpoint topology + unchanged independent peer selection; not copied peer colour"]
            return Observation(originalFill:fill,originalStroke:stroke,evidence:evidence,
                selected:selected,rawPrediction:raw,
                unknownReason:"native original measurement corroborated by unchanged peer ink; not source colour gold")
        }
    }

    /// Re-evaluate one owner's measured native endpoints without any peer input.
    /// Component/ray recovery adds evidence AFTER the sampler's confidence was
    /// computed. That stale confidence must not veto a separately proven pair,
    /// but neither a zero score nor an unranked pale endpoint is itself proof.
    static func recoveredMeasuredOriginal(_ observation:Observation) -> Observation? {
        func rgb(_ value:Any?) -> [Double]? {
            guard let color=value as? [Double],color.count==3,
                  color.allSatisfy({$0.isFinite && (0...255).contains($0)}) else{return nil}
            return color
        }
        func number(_ value:Any?) -> Double? {
            guard let value=(value as? NSNumber)?.doubleValue,value.isFinite,value>=0 else{return nil}
            return value
        }
        func distance(_ a:[Double],_ b:[Double]) -> Double {zip(a,b).map{abs($0-$1)}.max()!}
        guard let raw=observation.rawPrediction,
              let native=(raw["multiscale"] as? [String:Any])?["native"] as? [String:Any],
              let fill=rgb(native["foreground"]),let stroke=rgb(native["stroke"]),
              let background=rgb(native["background"]),
              let sampling=native["sourceSamplingPolicy"] as? [String:Any],
              let scale=number(sampling["sampleScale"]),(1...2).contains(scale),
              let pixels=number(sampling["capturedPixels"]),(64...4_194_304).contains(pixels),
              let topology=native["sourceInkDominance"] as? [String:Any] else{return nil}
        let keys=["fillPixels","strokePixels","fillShapePixels","strokeShapePixels",
                  "fillRepeatedTiles","strokeRepeatedTiles","fillEnclosedPixels","strokeEnclosedPixels"]
        let n=keys.compactMap{number(topology[$0])}
        guard n.count==8,n[0]+n[1]<=pixels,n[2]<=n[0],n[3]<=n[1],
              n[6]<=n[0],n[7]<=n[1],n[2]>=12,n[3]>=12,
              (4...36).contains(n[4]),(4...36).contains(n[5]),
              distance(fill,stroke)>=48,distance(fill,background)>=48,
              distance(stroke,background)>=32 else{return nil}
        let evidence=NativeSourceInkSelection.Evidence(fillPixels:n[0],strokePixels:n[1],
            fillShapePixels:n[2],strokeShapePixels:n[3],fillRepeatedTiles:n[4],strokeRepeatedTiles:n[5],
            fillEnclosedPixels:n[6],strokeEnclosedPixels:n[7])
        let selection=NativeSourceInkSelection.select(fill:fill,stroke:stroke,evidence:evidence)
        let witness:String
        if let recovery=native["endpointRecovery"] as? [String:Any],
           let components=number(recovery["components"]),components>=6,
           fill.max()!<80,fill.max()!-fill.min()!<24,
           stroke.min()!>=225,stroke.max()!-stroke.min()!<24,
           selection.role=="sourceFill" {
            // The dark enclosed-component pass has its own component quorum
            // and owned topology; do not borrow the unused stroke confidence.
            witness="native-dark-enclosed-components-and-owned-repetition"
        } else if let shell=native["gradientShellRecovery"] as? [String:Any],
                  let rays=number(shell["rays"]),rays>=24,
                  let support=number(shell["spatialSupport"]),(4...36).contains(support),
                  let shellRGB=rgb(shell["rgb"]),distance(shellRGB,stroke)<=1,
                  let priorFill=rgb(observation.originalFill),distance(fill,priorFill)<=24,
                  let confidence=native["confidence"] as? [String:Any],
                  let foreground=number(confidence["foreground"]),(0.4...1).contains(foreground),
                  observation.selected.role=="unknown" || observation.selected.role=="sourceStroke" {
            // Ordered core-shell-surface rays reject AA interpolation and
            // establish a missing shell. Rank occupancy within this scale only.
            witness="native-ordered-shell-and-owned-endpoint-topology"
        } else {return nil}
        var corrected=raw
        corrected["foreground"]=fill;corrected["stroke"]=stroke;corrected["outline"]=stroke
        corrected["sourceInkDominance"]=topology
        corrected["sourceSamplingPolicy"]=sampling
        corrected["originalEvidenceRecovery"]=["witness":witness,"nativeMeasurement":native,
            "priorOriginalFill":observation.originalFill as Any? ?? NSNull(),
            "priorOriginalStroke":observation.originalStroke as Any? ?? NSNull(),
            "priorSelectedInk":observation.selected.color as Any? ?? NSNull(),
            "priorSelectedRole":observation.selected.role,"priorPrediction":raw,
            "authority":"independent owned original native endpoints; no peer colour, display fallback or restored pixels"]
        return Observation(originalFill:fill,originalStroke:stroke,evidence:evidence,selected:selection,
            rawPrediction:corrected,unknownReason:"independent native endpoint witness; not source colour gold")
    }

    static func combineMembers(_ initialObservations:[Observation],members:[[String:Any]],inkOnly:Bool,
                               recoverStackedShell:Bool=false,recoverColumnShell:Bool=false,
                               recoverNativePeers:Bool=false,recoverMeasuredEvidence:Bool=false) -> Observation {
        let coreObservations=inkOnly ? corroboratedGroupCores(initialObservations) : initialObservations
        func valid(_ rgb:[Double]?) -> Bool {
            guard let rgb,rgb.count==3 else{return false}
            return rgb.allSatisfy{$0.isFinite && (0...255).contains($0)}
        }
        func agrees(_ colors:[[Double]?]) -> Bool {
            let known=colors.compactMap{$0}
            guard known.allSatisfy({valid($0)}) else{return false}
            if known.count<2 {return true}
            return (0..<3).allSatisfy { c in
                let values=known.map{$0[c]}
                return values.max()!-values.min()! <= 24
            }
        }
        // Never recolour an already agreeing column group. Recovery can only
        // reconsider a former palette veto, not perturb established consensus.
        let baselineAgreement=coreObservations.allSatisfy{valid($0.selected.color)} &&
            agrees(coreObservations.map(\.selected.color))
        let columnRecoveryAttempted=recoverColumnShell && !baselineAgreement
        // Geometry admission has already established column membership. The
        // same independently observed repeated shell witness is usable there;
        // peer colour alone still cannot create a missing original outline.
        var observations=(recoverStackedShell || columnRecoveryAttempted)
            ? corroboratedStackedMembers(coreObservations) : coreObservations
        let nativeRecoveryAttempted=recoverNativePeers && !(
            observations.allSatisfy{valid($0.selected.color)} && agrees(observations.map(\.selected.color)))
        var nativeRecoveredIndices=[Int]()
        if nativeRecoveryAttempted {
            // Anchor to pre-core/pre-shell selections, never to recovered peers.
            let native=corroboratedNativePeerMembers(initialObservations)
            for index in observations.indices where native[index].selected.color != initialObservations[index].selected.color {
                observations[index]=native[index]
                nativeRecoveredIndices.append(index)
            }
        }
        let measuredRecoveryAttempted=recoverMeasuredEvidence && inkOnly &&
            (2...6).contains(observations.count) && observations.count==members.count && !(
                observations.allSatisfy{valid($0.selected.color)} && agrees(observations.map(\.selected.color)))
        var measuredRecoveredIndices=[Int]()
        if measuredRecoveryAttempted {
            for index in observations.indices {
                // Every owner must establish its own witness. Simultaneous
                // corrections cannot certify one another, even if both were unknown.
                if let recovered=recoveredMeasuredOriginal(initialObservations[index]) {
                    observations[index]=recovered
                    measuredRecoveredIndices.append(index)
                }
            }
        }
        let shapeValid=(2...6).contains(observations.count) && observations.count==members.count
        let fillAgreement=agrees(observations.map(\.originalFill))
        let strokeAgreement=agrees(observations.map(\.originalStroke))
        let selectedAgreement=shapeValid && observations.allSatisfy{valid($0.selected.color)} && agrees(observations.map(\.selected.color))
        let accepted=shapeValid && selectedAgreement && (inkOnly || (fillAgreement && strokeAgreement))
        var audit:[String:Any]=["accepted":accepted,"memberCount":observations.count,
            "stackedNativeShellRecoveryEnabled":recoverStackedShell,
            "columnNativeShellRecoveryEnabled":recoverColumnShell,
            "columnNativeShellRecoveryAttempted":columnRecoveryAttempted,
            "nativePeerRecoveryEnabled":recoverNativePeers,
            "nativePeerRecoveryAttempted":nativeRecoveryAttempted,
            "measuredEvidenceRecoveryEnabled":recoverMeasuredEvidence,
            "measuredEvidenceRecoveryAttempted":measuredRecoveryAttempted,
            "measuredEvidenceRecoveredMembers":measuredRecoveredIndices.map{members[$0]["id"] ?? NSNull()},
            "nativePeerRecoveredMembers":nativeRecoveredIndices.map{members.indices.contains($0) ? members[$0]["id"] ?? NSNull() : NSNull()},
            "admissionPolicy":inkOnly ? "selected-original-ink;display-stroke-is-independent-BW" : "all-source-endpoint-agreement",
            "selectedInkAgreement":selectedAgreement,
            "sourceFillAgreement":observations.filter{$0.originalFill != nil}.count >= 2 ? fillAgreement as Any : NSNull(),
            "sourceStrokeAgreement":observations.filter{$0.originalStroke != nil}.count >= 2 ? strokeAgreement as Any : NSNull(),
            "maximumChannelSpread":24,
            "fillMeasuredMembers":observations.filter{$0.originalFill != nil}.count,
            "strokeMeasuredMembers":observations.filter{$0.originalStroke != nil}.count,
            "authority":"independent original owner observations; one observed representative, no merged bbox resampling; missing endpoints remain unknown"]
        if observations.count==members.count {
            audit["members"]=observations.enumerated().map { i,observation in
                ["id":members[i]["id"] ?? "","sourceBounds":members[i]["sourceBounds"] ?? [],
                 "nativePeerRecovered":nativeRecoveredIndices.contains(i),
                 "measuredEvidenceRecovered":measuredRecoveredIndices.contains(i),
                 "measuredEvidenceRecovery":measuredRecoveredIndices.contains(i)
                    ? observation.rawPrediction?["originalEvidenceRecovery"] as Any? ?? NSNull() : NSNull(),
                 "nativePeerRecovery":nativeRecoveredIndices.contains(i)
                    ? observation.rawPrediction?["nativePeerCorroboration"] as Any? ?? NSNull() : NSNull(),
                 "fill":observation.originalFill as Any? ?? NSNull(),"stroke":observation.originalStroke as Any? ?? NSNull(),
                 "selected":observation.selected.color as Any? ?? NSNull(),"role":observation.selected.role] as [String:Any]
            }
        }
        guard accepted else {
            return Observation(originalFill:nil,originalStroke:nil,evidence:nil,
                selected:.init(color:nil,role:"unknown",neutralExteriorSuppressed:false),
                rawPrediction:["memberPaletteConsensus":audit],
                unknownReason:"merged original ink or required endpoints disagree/are unknown; retain separate owners")
        }
        let colors=observations.map{$0.selected.color!}
        let index=colors.indices.min { a,b in
            func distance(_ i:Int) -> Double {
                colors.reduce(0) { sum,rgb in sum+zip(colors[i],rgb).reduce(0){$0+abs($1.0-$1.1)} }
            }
            return distance(a)<distance(b)
        }!
        let chosen=observations[index]
        audit["selectedMember"]=index
        var evidence=chosen.rawPrediction ?? [:]
        evidence["memberPaletteConsensus"]=audit
        return Observation(originalFill:chosen.originalFill,originalStroke:chosen.originalStroke,
            evidence:chosen.evidence,selected:chosen.selected,rawPrediction:evidence,
            unknownReason:inkOnly && !(fillAgreement && strokeAgreement)
                ? "original ink agrees; source endpoints vary and remain recorded; display outline is independently BW"
                : "member-consensus source estimate; not human gold or per-run rich text")
    }

    func observe(sourceBounds: [Double], originalGeometry: [String: Any]) -> Observation {
        let baseline=observeBaseline(sourceBounds:sourceBounds,originalGeometry:originalGeometry)
        guard originalGeometry["sourceOwnConnectedBoundaryRecovery"] as? Bool == true,
              baseline.selected.color == nil else {return baseline}
        if originalGeometry["sourceTextBlockMemberPalette"] as? Bool == true,
           let members=originalGeometry["agent02MemberItems"] as? [[String:Any]],(2...6).contains(members.count) {
            let observations=members.map { raw -> Observation in
                var member=raw;member["sourceOwnConnectedBoundaryRecovery"]=true
                return observe(sourceBounds:member["sourceBounds"] as? [Double] ?? [],originalGeometry:member)
            }
            let recovered=Self.combineMembers(observations,members:members,
                inkOnly:originalGeometry["sourceTextBlockInkOnlyAdmission"] as? Bool == true,
                recoverStackedShell:originalGeometry["sourceStackedContinuation"] as? Bool == true,
                recoverColumnShell:originalGeometry["sourceTextBlockColumnPeerShell"] as? Bool == true,
                recoverNativePeers:originalGeometry["sourceTextBlockNativePeerRecovery"] as? Bool == true,
                recoverMeasuredEvidence:originalGeometry["sourceTextBlockMeasuredEvidenceRecovery"] as? Bool == true)
            return (recovered.rawPrediction?["memberPaletteConsensus"] as? [String:Any])?["accepted"] as? Bool == true
                ? recovered : baseline
        }
        return NativeCausalParagraphPaletteCompatibility.refineUnknownOwnInk(original:original,
            geometry:originalGeometry,baseline:baseline,enabled:true).observation
    }

    private func observeBaseline(sourceBounds: [Double], originalGeometry: [String: Any]) -> Observation {
        let shellEnabled=originalGeometry["sourceOwnedGlyphPaletteRecoverySuppressed"] as? Bool != true &&
            originalGeometry["sourceChromaticShellPaletteRecoverySuppressed"] as? Bool != true &&
            (originalGeometry["sourceChromaticShellPaletteRecovery"] as? Bool == true ||
             ProcessInfo.processInfo.environment["AIDOKU_SOURCE_CHROMATIC_SHELL_PALETTE_RECOVERY"] == "1")
        if shellEnabled, originalGeometry["sourceTextBlockMemberPalette"] as? Bool != true {
            var prior=originalGeometry
            prior["sourceChromaticShellPaletteRecoverySuppressed"]=true
            let incumbent=observeBaseline(sourceBounds:sourceBounds,originalGeometry:prior)
            // A new shell policy must not activate the old neutral recovery
            // on every solo owner, nor recolour an already supported endpoint.
            guard incumbent.selected.color == nil,
                  let measured=ownedGlyphObservation(sourceBounds:sourceBounds,originalGeometry:originalGeometry),
                  measured.rawPrediction?["ownedChromaticShellRecovery"] != nil else{return incumbent}
            return measured
        }
        if originalGeometry["sourceTextBlockMemberPalette"] as? Bool == true,
           let members=originalGeometry["agent02MemberItems"] as? [[String:Any]],(2...6).contains(members.count) {
            let observations=members.map { rawMember -> Observation in
                var member=rawMember
                // Recovery must not overturn an already accepted independent
                // consensus or recolor normal groups. Observe baseline first.
                if Self.ownedGlyphRecoveryEnabled(originalGeometry) {
                    member["sourceOwnedGlyphPaletteRecoverySuppressed"]=true
                }
                let bounds=member["sourceBounds"] as? [Double] ?? []
                guard originalGeometry["sourceTextBlockPartitionRecovery"] as? Bool == true else {
                    return observeBaseline(sourceBounds:bounds,originalGeometry:member)
                }
                let key:Data?
                do {
                    let dependencies=try Self.memoDependencies(member)
                    key=try JSONSerialization.data(withJSONObject:["id":member["id"] ?? NSNull(),
                        "bounds":bounds,"polygon":member["sourcePolygon"] ?? NSNull(),
                        "groupDependencies":dependencies?.base64EncodedString() as Any? ?? NSNull()],options:[.sortedKeys])
                } catch { key=nil }
                if let key,let cached=memberObservations[key] {return cached}
                let observed=observeBaseline(sourceBounds:bounds,originalGeometry:member)
                if let key,memberObservations.count<256 {memberObservations[key]=observed}
                return observed
            }
            func combine(_ observed:[Observation]) -> Observation {
                Self.combineMembers(observed,members:members,
                    inkOnly:originalGeometry["sourceTextBlockInkOnlyAdmission"] as? Bool == true,
                    recoverStackedShell:originalGeometry["sourceStackedContinuation"] as? Bool == true,
                    recoverColumnShell:originalGeometry["sourceTextBlockColumnPeerShell"] as? Bool == true,
                    recoverNativePeers:originalGeometry["sourceTextBlockNativePeerRecovery"] as? Bool == true,
                    recoverMeasuredEvidence:originalGeometry["sourceTextBlockMeasuredEvidenceRecovery"] as? Bool == true)
            }
            let baseline=combine(observations)
            guard Self.ownedGlyphRecoveryEnabled(originalGeometry),
                  (baseline.rawPrediction?["memberPaletteConsensus"] as? [String:Any])?["accepted"] as? Bool != true
                else{return baseline}
            let measured=members.enumerated().map { index,member in
                var candidate=member
                if Self.openRimGlyphRecoveryEnabled(originalGeometry) {candidate["sourceOpenRimGlyphPaletteRecovery"]=true}
                if originalGeometry["sourceChromaticShellPaletteRecovery"] as? Bool == true {
                    candidate["sourceChromaticShellPaletteRecovery"]=true
                }
                return ownedGlyphObservation(sourceBounds:member["sourceBounds"] as? [Double] ?? [],originalGeometry:candidate)
                    ?? observations[index]
            }
            let recovered=combine(measured)
            guard (recovered.rawPrediction?["memberPaletteConsensus"] as? [String:Any])?["accepted"] as? Bool == true
                else{return baseline}
            return recovered
        }
        let raw = NativeSourceROIObservation.observe(original: original, bounds: sourceBounds, geometry: originalGeometry)
        if Self.ownedGlyphRecoveryEnabled(originalGeometry),
           let recovered=ownedGlyphObservation(sourceBounds:sourceBounds,originalGeometry:originalGeometry) {
            var trace=recovered.rawPrediction ?? [:]
            trace["priorOriginalEvidence"]=raw as Any? ?? NSNull()
            return Observation(originalFill:recovered.originalFill,originalStroke:recovered.originalStroke,
                evidence:recovered.evidence,selected:recovered.selected,rawPrediction:trace,unknownReason:recovered.unknownReason)
        }
        func endpoint(_ key: String) -> [Double]? {
            guard let rgb = raw?[key] as? [Double], rgb.count == 3,
                  rgb.allSatisfy({ $0.isFinite && (0...255).contains($0) }) else { return nil }
            return rgb
        }
        let fill = endpoint("foreground"), stroke = endpoint("stroke")
        let confidence = raw?["confidence"] as? [String:Any]
        let backgroundConfidence = (confidence?["background"] as? NSNumber)?.doubleValue ?? 0
        let ambiguousPaleEndpoint = fill.map { $0.min()! >= 225 } == true && stroke == nil && backgroundConfidence < 0.5
        let keys = ["fillPixels", "strokePixels", "fillShapePixels", "strokeShapePixels",
                    "fillRepeatedTiles", "strokeRepeatedTiles", "fillEnclosedPixels", "strokeEnclosedPixels"]
        let payload = raw?["sourceInkDominance"] as? [String: Any]
        let values = keys.compactMap { (payload?[$0] as? NSNumber)?.doubleValue }
        let evidence: NativeSourceInkSelection.Evidence?
        if values.count == keys.count, values.allSatisfy({ $0.isFinite && $0 >= 0 }) {
            evidence = .init(fillPixels: values[0], strokePixels: values[1],
                fillShapePixels: values[2], strokeShapePixels: values[3],
                fillRepeatedTiles: values[4], strokeRepeatedTiles: values[5],
                fillEnclosedPixels: values[6], strokeEnclosedPixels: values[7])
        } else { evidence = nil }
        // Missing topology cannot silently become invented zero observations.
        let selected: NativeSourceInkSelection.Selection
        if ambiguousPaleEndpoint {
            selected = .init(color:nil,role:"unknown",neutralExteriorSuppressed:false)
        } else if let evidence {
            selected = NativeSourceInkSelection.select(fill: fill, stroke: stroke, evidence: evidence)
        } else {
            selected = .init(color: fill ?? stroke,
                role: fill != nil ? "sourceFillUnranked" : (stroke != nil ? "sourceStrokeOnly" : "unknown"),
                neutralExteriorSuppressed: false)
        }
        return Observation(originalFill: fill, originalStroke: stroke, evidence: evidence,
            selected: selected, rawPrediction: raw,
            unknownReason: raw == nil ? "source-observation-unavailable" :
                (ambiguousPaleEndpoint ? "pale-endpoint-without-independent-stroke-or-surface-support" :
                    (evidence == nil ? "owned-topology-unavailable" : nil)))
    }
}
