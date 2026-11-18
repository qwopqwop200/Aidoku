import CoreGraphics
import Foundation

/// Bounded original-only capture. Does not own removal masks or consume reconstructed pixels.
enum NativeSourceROIObservation {
    static func observe(original: CGImage, bounds: [Double], geometry: [String: Any]) -> [String: Any]? {
        let coarse = capture(original: original, bounds: bounds, geometry: geometry, pixelLimit: 24576)
        guard bounds.count == 4 else { return nil }
        let area = bounds[2] * Double(original.width) * bounds[3] * Double(original.height)
        let seed = NativeSourceColorSampler.rgb(coarse?["foreground"])
        let pale = seed.map { $0.min()! >= 225 } ?? true
        guard area > 16000 || pale else { return coarse }
        let native = capture(original: original, bounds: bounds, geometry: geometry,
            pixelLimit: 4194304, guide: seed, magnification: pale && area < 16000 ? 2 : 1)
        // Scale changes component occupancy, so preserve the coarse role evidence.
        // Native core refinement changes only a corroborated endpoint, never role or display policy.
        var result = coarse ?? native
        if let refinement = native?["nativeCoreRefinement"] as? [String:Any],
           let core = refinement["rgb"] as? [Double], coarse != nil {
            result?["foreground"] = core
            result?["nativeCoreRefinement"] = refinement
        }
        result?["multiscale"] = ["coarse": coarse ?? [:], "native": native ?? [:],
            "selection": "coarse-owned-role-with-native-corroborated-core",
            "nativeEvidenceRanking": "diagnostic; scale occupancy is not comparable"]
        return result
    }

    static func capture(original: CGImage, bounds: [Double], geometry: [String: Any], pixelLimit: Double, guide: [Double]? = nil, magnification: Double = 1) -> [String: Any]? {
        guard bounds.count == 4, bounds.allSatisfy(\.isFinite), bounds[0] >= 0, bounds[1] >= 0,
              bounds[2] > 0, bounds[3] > 0, bounds[0]+bounds[2] <= 1.000001,
              bounds[1]+bounds[3] <= 1.000001 else { return nil }
        let iw = Double(original.width), ih = Double(original.height)
        let margin = max(4,min(16,ceil(min(bounds[2]*iw,bounds[3]*ih)*0.5)))
        let x = max(0,floor(bounds[0]*iw)-margin), y = max(0,floor(bounds[1]*ih)-margin)
        let sw = min(iw,ceil((bounds[0]+bounds[2])*iw)+margin)-x
        let sh = min(ih,ceil((bounds[1]+bounds[3])*ih)+margin)-y
        let scale = min(magnification,sqrt(pixelLimit/(sw*sh)))
        let w = max(1,Int(floor(sw*scale))), h = max(1,Int(floor(sh*scale)))
        guard w >= 8, h >= 8 else { return nil }
        var rgba = [UInt8](repeating:0,count:w*h*4)
        let ok = rgba.withUnsafeMutableBytes { bytes -> Bool in
            guard let c = CGContext(data:bytes.baseAddress,width:w,height:h,bitsPerComponent:8,
                bytesPerRow:w*4,space:CGColorSpace(name:CGColorSpace.sRGB)!,
                bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            c.interpolationQuality = .high
            guard let crop = original.cropping(to:CGRect(x:x,y:y,width:sw,height:sh)) else { return false }
            c.draw(crop,in:CGRect(x:0,y:0,width:w,height:h))
            return true
        }
        guard ok else { return nil }
        // Raster ownership is strictly source geometry; no display frame or bbox colour mode.
        let polygon = geometry["sourcePolygon"] as? [[Double]] ?? [
            [bounds[0],bounds[1]],[bounds[0]+bounds[2],bounds[1]],
            [bounds[0]+bounds[2],bounds[1]+bounds[3]],[bounds[0],bounds[1]+bounds[3]]]
        guard polygon.count >= 3, polygon.allSatisfy({ $0.count == 2 && $0.allSatisfy(\.isFinite) }) else { return nil }
        let points = polygon.map { CGPoint(x:($0[0]*iw-x)*Double(w)/sw,y:($0[1]*ih-y)*Double(h)/sh) }
        let path = CGMutablePath(); path.addLines(between:points); path.closeSubpath()
        var owned = [UInt8](repeating:0,count:w*h)
        for yy in 0..<h { for xx in 0..<w {
            if path.contains(CGPoint(x:Double(xx)+0.5,y:Double(yy)+0.5)) { owned[yy*w+xx] = 1 }
        }}
        var prediction = NativeSourceColorSampler.estimate(rgba:rgba,width:w,height:h,ownership:owned)
        // Independent repeated outlined-glyph evidence may recover a lost endpoint.
        // This primitive is an original ROI observer, not the legacy renderer/stage.
        let opaque = stride(from:3,to:rgba.count,by:4).allSatisfy { rgba[$0] >= 250 }
        let recovered = NativeCaptionSourcePalette.recoverOutlinedColor(rgba:rgba,width:w,height:h,
            result:nil,allowDark:false,opaque:opaque)
        let initialFill = NativeSourceColorSampler.rgb(prediction?["foreground"])
        let alreadyChromatic = initialFill.map { $0.max()!-$0.min()! >= 28 } ?? false
        let initialConfidence = (prediction?["confidence"] as? [String: Any])?["foreground"] as? Double ?? 0
        // Chroma alone is not proof of glyph ink: a weak pink surface/AA
        // estimate must not veto independently repeated outlined source cores.
        let weakUnoutlined = initialConfidence < 0.6 && NativeSourceColorSampler.rgb(prediction?["stroke"]) == nil
        let recoverableCore = initialFill == nil || initialConfidence < 0.6 ||
            initialFill.map { $0.min()! >= 225 } == true
        if let recovered, let core = NativeSourceColorSampler.rgb(recovered["foreground"]),
           recoverableCore, (!alreadyChromatic || weakUnoutlined), core.max()!-core.min()! >= 28,
           let edge = NativeSourceColorSampler.rgb(recovered["stroke"]) {
            let support = topology(rgba:rgba,width:w,height:h,ownership:owned,fill:core,stroke:edge)
            let body = (support["fillShapePixels"] as? Int) ?? 0
            let repeated = (support["fillRepeatedTiles"] as? Int) ?? 0
            if body >= 12, repeated >= 4 {
                prediction = prediction ?? [:]
                prediction?["foreground"] = core; prediction?["stroke"] = edge
                prediction?["endpointRecovery"] = ["authority":"repeated original outlined components plus owned shape/repetition",
                    "components":recovered["components"] ?? 0,
                    "replacedWeakChromaticEstimate":alreadyChromatic && weakUnoutlined,
                    "priorForeground":initialFill as Any? ?? NSNull(),
                    "priorForegroundConfidence":initialConfidence]
            }
        }
        let prior = NativeSourceColorSampler.rgb(prediction?["foreground"])
        if prior == nil || prior!.min()! >= 225,
           let dark = NativeCaptionSourcePalette.recoverOutlinedColor(rgba:rgba,width:w,height:h,
                result:prediction,allowDark:true,opaque:opaque),
           let core = NativeSourceColorSampler.rgb(dark["foreground"]),core.max()! < 80,
           let edge = NativeSourceColorSampler.rgb(dark["stroke"]) {
            let support = topology(rgba:rgba,width:w,height:h,ownership:owned,fill:core,stroke:edge)
            if (support["fillShapePixels"] as? Int ?? 0) >= 12,
               (support["fillRepeatedTiles"] as? Int ?? 0) >= 4 {
                prediction = prediction ?? [:]
                prediction?["foreground"] = core; prediction?["stroke"] = edge
                prediction?["endpointRecovery"] = ["authority":"repeated original dark enclosed components plus owned shape/repetition",
                    "components":dark["components"] ?? 0]
            }
        }
        guard var result = prediction, let fill = NativeSourceColorSampler.rgb(result["foreground"]) else { return nil }
        if let background=NativeSourceColorSampler.rgb(result["background"]),
           let shell=NativeGradientShell.recover(rgba:rgba,width:w,height:h,ownership:owned,fill:fill,
                background:background,stroke:NativeSourceColorSampler.rgb(result["stroke"])) {
            result["stroke"]=shell["rgb"];result["outline"]=shell["rgb"]
            result["gradientShellRecovery"]=shell
        }
        let stroke = NativeSourceColorSampler.rgb(result["stroke"])
        result["sourceInkDominance"] = topology(rgba:rgba,width:w,height:h,ownership:owned,fill:fill,stroke:stroke)
        // A short reversed caption can have white ink and no independent stroke.
        // Certify its backing from matched opposite original side strips, never bbox mode.
        if fill.min()! >= 225, stroke == nil {
            let box = CGRect(x:(bounds[0]*iw-x)*Double(w)/sw,
                y:(bounds[1]*ih-y)*Double(h)/sh,
                width:bounds[2]*iw*Double(w)/sw,height:bounds[3]*ih*Double(h)/sh)
            if let surface = NativeCaptionSourcePalette.observedSourceSurface(
                rgba:rgba,width:w,height:h,box:box,result:result),
               let rgb = surface["color"] as? [Double],rgb.max()! < 48,rgb.max()!-rgb.min()! < 16,
               let support = result["sourceInkDominance"] as? [String:Any],
               (support["fillShapePixels"] as? Int ?? 0) >= 12,
               (support["fillRepeatedTiles"] as? Int ?? 0) >= 4 {
                var confidence = result["confidence"] as? [String:Any] ?? [:]
                confidence["background"] = 0.75
                result["confidence"] = confidence
                result["independentOriginalSurface"] = surface
            }
        }

        if let guide, guide.max()!-guide.min()! >= 28,
           let core = stableCore(rgba:rgba,width:w,height:h,ownership:owned,guide:guide) {
            result["nativeCoreRefinement"] = core
        }
        result["sourceSamplingPolicy"] = ["sampleScale":scale,"capturedPixels":w*h,
            "sourceROIPixels":sw*sh,"authority":"fresh original sRGB ROI; native estimator; no display/restored state"]
        return result
    }

    /// Repeated native plateau pixels near the independently observed chromatic endpoint.
    /// Histogram bins are restricted to this endpoint, not whole-box background modes.
    static func stableCore(rgba:[UInt8],width:Int,height:Int,ownership:[UInt8],guide:[Double]) -> [String:Any]? {
        guard width >= 3, height >= 3, width <= 4_194_304 / height, rgba.count == width * height * 4,
              ownership.count == width * height, guide.count == 3,
              guide.allSatisfy({ $0.isFinite && (0...255).contains($0) }) else { return nil }
        var counts=[Int:Int](), sums=[Int:[Double]](), tiles=[Int:Set<Int>]()
        func rgb(_ p:Int)->[Double] {(0..<3).map {Double(rgba[p*4+$0])}}
        func dist(_ a:[Double],_ b:[Double])->Double {zip(a,b).map {abs($0-$1)}.max()!}
        for y in 1..<(height-1) { for x in 1..<(width-1) {
            let p=y*width+x
            guard ownership[p] != 0, rgba[p*4+3] >= 250 else {continue}
            let c=rgb(p)
            guard dist(c,guide)<=72, c.max()!-c.min()! >= max(28,(guide.max()!-guide.min()!)*0.8) else {continue}
            let stable=[p-1,p+1,p-width,p+width].filter {ownership[$0] != 0 && dist(rgb($0),c)<=12}.count
            guard stable>=2 else {continue}
            let key=(Int(c[0])/16)*256+(Int(c[1])/16)*16+Int(c[2])/16
            counts[key,default:0]+=1
            var sum=sums[key] ?? [0,0,0]
            for k in 0..<3 {sum[k]+=c[k]}; sums[key]=sum
            tiles[key,default:[]].insert((y*6/height)*6+x*6/width)
        }}
        let supported=counts.keys.filter {counts[$0]!>=12 && tiles[$0]!.count>=4}
        guard let key=supported.sorted(by:{counts[$0]! == counts[$1]! ? $0<$1 : counts[$0]!>counts[$1]!}).first else {return nil}
        return ["rgb":sums[key]!.map {($0/Double(counts[key]!)).rounded()},
            "pixels":counts[key]!,"tiles":tiles[key]!.count,
            "authority":"owned repeated stable chromatic native pixels near independent coarse endpoint; not gold"]
    }

    /// Exact bright-neutral/chromatic topology arithmetic from the tested parent pilot.
    static func topology(rgba:[UInt8],width:Int,height:Int,ownership:[UInt8],fill:[Double],stroke:[Double]?) -> [String:Any] {
        guard width >= 3, height >= 3, width <= 4_194_304 / height, rgba.count == width * height * 4,
              ownership.count == width * height, fill.count == 3,
              fill.allSatisfy({ $0.isFinite && (0...255).contains($0) }),
              stroke == nil || (stroke!.count == 3 && stroke!.allSatisfy({ $0.isFinite && (0...255).contains($0) })) else {
            return ["technicalError": "invalid source topology dimensions, buffers or endpoints"]
        }
        func distance(_ p:Int,_ rgb:[Double]) -> Double {
            max(abs(Double(rgba[p*4])-rgb[0]), max(abs(Double(rgba[p*4+1])-rgb[1]), abs(Double(rgba[p*4+2])-rgb[2])))
        }
        let assess = stroke.map { $0.max()!-$0.min()! < 28 && NativeSourceColorSampler.luminance($0)>0.7
            && fill.max()!-fill.min()! >= 28 } ?? false
        var counts=[0,0],shaped=[0,0],enclosed=[0,0],tiles=[Set<Int>(),Set<Int>()]
        for y in 1..<max(1,height-1) { for x in 1..<max(1,width-1) {
            let p=y*width+x
            guard rgba[p*4+3]>=250,ownership[p] != 0 else { continue }
            let df=distance(p,fill),ds=stroke.map{distance(p,$0)} ?? .infinity
            guard min(df,ds)<=24 else { continue }
            let role=df<=ds ? 0:1;counts[role]+=1
            let reach=max(3,min(18,min(width,height)/10))
            func reaches(_ dx:Int,_ dy:Int)->Bool {
                guard let other=role==0 ? stroke:fill else{return false}
                for d in 1...reach {
                    let xx=x+dx*d,yy=y+dy*d
                    guard xx>=0,yy>=0,xx<width,yy<height else{return false}
                    let q=yy*width+xx
                    guard rgba[q*4+3]>=250,ownership[q] != 0 else{return false}
                    let same=distance(q,role==0 ? fill:stroke!),opposite=distance(q,other)
                    if opposite<=28 && opposite<same{return true}
                    if min(same,opposite)>70{return false}
                }
                return false
            }
            if assess && ((reaches(-1,0)&&reaches(1,0)) || (reaches(0,-1)&&reaches(0,1))) {enclosed[role]+=1}
            let endpoint=role==0 ? fill:stroke!,r=max(2,min(12,min(width,height)/12))
            let probes=[(max(0,x-r),y),(min(width-1,x+r),y),(x,max(0,y-r)),(x,min(height-1,y+r))]
            if probes.contains(where:{distance($0.1*width+$0.0,endpoint)>36}) {
                shaped[role]+=1;tiles[role].insert((y*6/height)*6+x*6/width)
            }
        }}
        return ["fillPixels":counts[0],"strokePixels":counts[1],"fillShapePixels":shaped[0],
            "strokeShapePixels":shaped[1],"fillRepeatedTiles":tiles[0].count,"strokeRepeatedTiles":tiles[1].count,
            "fillEnclosedPixels":enclosed[0],"strokeEnclosedPixels":enclosed[1],
            "authority":"owned endpoint topology/chroma proxy; not gold"]
    }
}
