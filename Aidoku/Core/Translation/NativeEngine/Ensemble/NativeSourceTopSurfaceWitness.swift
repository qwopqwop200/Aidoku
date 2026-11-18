import CoreGraphics
import Foundation

/// Conservative local background connectivity, not a balloon detector. A
/// closed source surface must not become top-aligned solely because RF missed.
enum NativeSourceTopSurfaceWitness {
    /// Placement evidence only: discover local background candidates directly
    /// from the original pixels, independently of the ink/palette confidence.
    static func measureLocal(original: CGImage, source: CGRect, fontPixels: CGFloat) -> [String: Any] {
        guard let part = original.cropping(to: source.integral), part.width > 0, part.height > 0 else {
            return ["accepted": false, "reason": "local-source-crop-unavailable", "originalPixelsMeasured": false]
        }
        let ratio = min(1, min(96 / CGFloat(part.width), 256 / CGFloat(part.height)))
        let w = max(1, Int(CGFloat(part.width) * ratio)), h = max(1, Int(CGFloat(part.height) * ratio))
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        let decoded = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let c = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8,
                bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            c.interpolationQuality = .none
            c.draw(part, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard decoded else { return ["accepted": false, "reason": "local-source-decode-failed"] }
        var bins: [Int: (count: Int, r: Int, g: Int, b: Int)] = [:]
        for i in 0..<(w * h) where bytes[i * 4 + 3] >= 245 {
            let r = Int(bytes[i * 4]), g = Int(bytes[i * 4 + 1]), b = Int(bytes[i * 4 + 2])
            let key = (r / 16) * 256 + (g / 16) * 16 + b / 16
            let old = bins[key] ?? (0, 0, 0, 0)
            bins[key] = (old.count + 1, old.r + r, old.g + g, old.b + b)
        }
        var checks: [[String: Any]] = []
        for entry in bins.sorted(by: { a, b in a.value.count == b.value.count ? a.key < b.key : a.value.count > b.value.count }).prefix(12) {
            let bin = entry.value, n = Double(bin.count)
            var measured = measure(original: original, source: source, fontPixels: fontPixels,
                background: [Double(bin.r) / n, Double(bin.g) / n, Double(bin.b) / n])
            // Joint source-top geometry is a second independent constraint.
            // Gradients and artwork may split an otherwise open background;
            // require an actual component escaping at least two context sides,
            // rather than insisting on one colour filling three sides.
            if measured["originalPixelsMeasured"] as? Bool == true,
               (measured["openContextSides"] as? Int ?? 0) >= 2,
               (measured["sourceComponentDominance"] as? Double ?? 0) >= 0.45,
               (measured["matchingSourcePixels"] as? Int ?? 0) >= 12 {
                measured["accepted"] = true
                measured["reason"] = "local-component-escapes-two-context-sides; joint-source-top-geometry-required"
            }
            checks.append(measured)
            if measured["accepted"] as? Bool == true {
                var result = measured
                result["candidateAuthority"] = "local original background hypotheses verified by connectivity; not source fill/stroke colour"
                return result
            }
        }
        return ["accepted": false, "originalPixelsMeasured": true, "reason": "no-locally-open-background-candidate",
            "candidateChecks": checks]
    }

    static func measure(original: CGImage, source: CGRect, fontPixels: CGFloat, background: [Double],
                        reachEm: Double = 3, tolerance: Double = 36,closedCapacityMask:CGImage? = nil) -> [String: Any] {
        func rejected(_ reason: String) -> [String: Any] {
            ["accepted":false,"reason":reason,"originalPixelsMeasured":false]
        }
        guard background.count==3,background.allSatisfy({$0.isFinite && (0...255).contains($0)}),
              fontPixels.isFinite,fontPixels>0,reachEm.isFinite,tolerance.isFinite,
              [source.minX,source.minY,source.width,source.height].allSatisfy(\.isFinite),source.width>0,source.height>0 else {
            return rejected("invalid-surface-witness-input")
        }
        let page=CGRect(x:0,y:0,width:original.width,height:original.height)
        guard page.contains(source) else{return rejected("source-outside-original")}
        let margin=max(8,fontPixels*CGFloat(min(6,max(1,reachEm))))
        let crop=source.insetBy(dx:-margin,dy:-margin).integral.intersection(page)
        guard crop.width*crop.height<=1_048_576,let part=original.cropping(to:crop) else {
            return rejected("optional-context-buffer-unavailable-or-over-1Mi-pixels; not a source-colour sampling limit")
        }
        let w=part.width,h=part.height
        var rgba=[UInt8](repeating:0,count:w*h*4)
        let decoded=rgba.withUnsafeMutableBytes { buffer->Bool in
            guard let c=CGContext(data:buffer.baseAddress,width:w,height:h,bitsPerComponent:8,bytesPerRow:w*4,
                space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else{return false}
            c.draw(part,in:CGRect(x:0,y:0,width:w,height:h));return true
        }
        guard decoded else{return rejected("original-context-decode-failed")}
        var matches=[Bool](repeating:false,count:w*h),visited=[Bool](repeating:false,count:w*h)
        let bound=min(64,max(8,tolerance))
        for i in matches.indices where rgba[i*4+3]>=245 {
            matches[i]=(0..<3).allSatisfy { abs(Double(rgba[i*4+$0])*255/Double(rgba[i*4+3])-background[$0])<=bound }
        }
        let local=source.offsetBy(dx:-crop.minX,dy:-crop.minY)
        let left=max(0,Int(floor(local.minX))),right=min(w,Int(ceil(local.maxX)))
        let top=max(0,Int(floor(local.minY))),bottom=min(h,Int(ceil(local.maxY)))
        var totalSeeds=0,bestSeeds=0,bestEdges=[0,0,0,0],components=0
        var bestComponent=[Int]()
        for y in top..<bottom {for x in left..<right {
            let seed=y*w+x
            if matches[seed] {totalSeeds += 1}
            guard matches[seed],!visited[seed] else{continue}
            components += 1
            var queue=[seed],cursor=0,hits=0,edges=[0,0,0,0]
            visited[seed]=true
            while cursor<queue.count {
                let i=queue[cursor];cursor += 1
                let xx=i%w,yy=i/w
                if xx>=left,xx<right,yy>=top,yy<bottom {hits += 1}
                if xx==0 {edges[0] += 1};if xx==w-1 {edges[1] += 1}
                if yy==0 {edges[2] += 1};if yy==h-1 {edges[3] += 1}
                func append(_ j:Int) {
                    if matches[j],!visited[j] {visited[j]=true;queue.append(j)}
                }
                if xx>0 {append(i-1)};if xx+1<w {append(i+1)}
                if yy>0 {append(i-w)};if yy+1<h {append(i+w)}
            }
            if hits>bestSeeds {
                bestSeeds=hits;bestEdges=edges
                if closedCapacityMask != nil {bestComponent=edges.allSatisfy{$0==0} ? queue : []}
            }
        }}
        let thresholds=[max(4,h/10),max(4,h/10),max(4,w/10),max(4,w/10)]
        let exits=zip(bestEdges,thresholds).filter{$0.0>=$0.1}.count
        let dominance:Double?=totalSeeds>0 ? Double(bestSeeds)/Double(totalSeeds) : nil
        let accepted=totalSeeds>=12 && (dominance ?? 0)>=0.6 && exits>=3
        var result:[String:Any]=["accepted":accepted,"originalPixelsMeasured":true,
            "reason":accepted ? "dominant-source-background-connects-three-context-sides" : totalSeeds<12
                ? "insufficient-opaque-source-background-seed-evidence" : "enclosed-or-insufficiently-open-local-source-surface",
            "cropOutputPixels":[crop.minX,crop.minY,crop.width,crop.height],"backgroundRGB":background,
            "tolerance":bound,"reachEm":min(6,max(1,reachEm)),"matchingSourcePixels":totalSeeds,
            "dominantSourcePixels":bestSeeds,"sourceComponentDominance":dominance.map{$0 as Any} ?? NSNull(),"seededComponents":components,
            "edgeContactsLRUD":bestSeeds>0 ? bestEdges as Any : NSNull(),"edgeContactThresholdsLRUD":thresholds,
            "openContextSides":bestSeeds>0 ? exits as Any : NSNull(),
            "authority":"original background connectivity supporting placement; not proof of absent balloon or semantic owner"]
        if let closedCapacityMask {
            if closedCapacityMask.width != original.width || closedCapacityMask.height != original.height {
                result["closedSurfaceCapacity"]=["accepted":false,"reason":"mask-source-dimension-mismatch","sourceMaskValidated":false]
            } else if totalSeeds>=12,(dominance ?? 0)>=0.6,!bestComponent.isEmpty {
                result["closedSurfaceCapacity"]=NativeClosedSourceRectangle.inspect(rgba:rgba,component:bestComponent,
                    width:w,height:h,crop:crop,source:source,background:background,removalMask:closedCapacityMask)
            } else {result["closedSurfaceCapacity"]=["accepted":false,"reason":"not-a-complete-original-enclosure"]}
        }
        return result
    }
}
