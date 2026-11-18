import CryptoKit
import Foundation

/// Final source-only contour, native palette/primary, and finite secondary shell.
/// Original RGB and predicted ownership only; no row identity or saved features.
enum NativeAppearanceLateGradient {
    typealias D = [String: Any]
    static let contourVersion = "source-confirmed-primary-contour-v2"
    static let paletteVersion = "source-confirmed-contour-owned-palette-v6"
    static let qualityVersion = "source-native-relative-primary-quality-v2-slot-only"
    static let qualitySHA = "c1269096e10da34c1104d0b88eec2b63780a159ec1e74f0d64b81fb69120429a"
    static let brightPrimaryVersion = "repeated-certified-bright-interior-primary-medoid-v1"
    static let pruningVersion = "native-certified-contour-component-palette-pruning-v7"
    static let shellVersion = "source-owned-finite-secondary-layer-v1"

    static func refine(input: SourceNativeInput, packet: NativeAppearanceSourceFeatures209.Packet,
                       prediction: D, heads: NativeAppearanceModelHeads,
                       ops: any NativeAppearanceImageOperations) throws -> D {
        let engine = try Engine(input, packet: packet, heads: heads, ops: ops)
        let policy = try heads.configuration("appearance/policies")
        let contourPolicy = part(policy, "NATIVE-GRADIENT-CONTOUR-POLICY.json")
        let shellPolicy = part(policy, "NATIVE-OUTER-SHELL-POLICY.json")
        guard contourPolicy["enabled"] as? Bool == true, shellPolicy["enabled"] as? Bool == true,
              contourPolicy["sourceContourVersion"] as? String == contourVersion,
              contourPolicy["nativePrimaryQualityModelSHA256"] as? String == qualitySHA else {
            throw NativeAppearanceModelHeads.Failure.invalidMetadata("late source contour policy")
        }
        let baseline = try engine.restore(prediction)
        let (contoured, diagnostic) = try engine.contour(baseline)
        var result = contoured
        if part(baseline, "fill")["representation"] != nil {
            result = try engine.extendPalette(result, baseline: baseline, diagnostic: diagnostic)
            result = try engine.certifiedPrimary(result, diagnostic: diagnostic)
            result = try engine.prunePalette(result, diagnostic: diagnostic)
        }
        result = try engine.nativePrimary(result)
        result = try engine.outerShell(result, diagnostic: diagnostic,
            threshold: NativeAppearanceModelHeads.number(shellPolicy, "minimumExcessCoherence"))
        return result
    }

    static func part(_ value: D, _ key: String) -> D { value[key] as? D ?? [:] }
    static func rows(_ value: Any?) -> [D] { value as? [D] ?? [] }
    static func vector(_ value: Any?) -> [Double] { (value as? [NSNumber])?.map(\.doubleValue) ?? [] }
    static func colors(_ value: Any?) -> [[Double]] { (value as? [Any])?.map { vector($0) } ?? [] }
    static func number(_ value: Any?) -> Double { (value as? NSNumber)?.doubleValue ?? .nan }
    static func d(_ a: [Double], _ b: [Double]) -> Double {
        let x = Float(a[0]) - Float(b[0]), y = Float(a[1]) - Float(b[1]), z = Float(a[2]) - Float(b[2])
        return Double(sqrt((x*x + y*y) + z*z))
    }
    static func d64(_ a: [Double], _ b: [Double]) -> Double {
        sqrt(zip(a,b).reduce(0) { $0 + ($1.0-$1.1)*($1.0-$1.1) })
    }
    static func q(_ values: [Double], _ p: Double = 0.5) -> Double { NativeAppearanceNumeric.quantile(values,p) }
    static func median(_ vectors: [[Double]]) -> [Double] { (0..<3).map { c in q(vectors.map { $0[c] }) } }
    static func log(_ value: Any?) -> Double { let x = number(value); return x.isFinite ? log1p(max(0,x)) : .nan }
    static func hash(_ data: Data) -> String { SHA256.hash(data:data).map { String(format:"%02x",$0) }.joined() }

    final class Engine {
        let input: SourceNativeInput
        let packet: NativeAppearanceSourceFeatures209.Packet
        let heads: NativeAppearanceModelHeads
        let ops: any NativeAppearanceImageOperations
        let w: Int, h: Int, n: Int, font: Double
        let image: [Float]
        let roi: [UInt8]
        init(_ input: SourceNativeInput, packet: NativeAppearanceSourceFeatures209.Packet,
             heads: NativeAppearanceModelHeads, ops: any NativeAppearanceImageOperations) throws {
            try input.validate()
            self.input=input;self.packet=packet;self.heads=heads;self.ops=ops
            w=input.width;h=input.height;n=w*h;font=input.fontPriorSourcePixels
            image=try ops.lab(rgb:input.rgb,width:w,height:h)
            roi=try ops.raster(polygons:input.memberPolygons,width:w,height:h)
        }
        func rgb(_ p: Int) -> [Double] { (0..<3).map { Double(input.rgb[p*3+$0]) } }
        func lab(_ p: Int) -> [Double] { (0..<3).map { Double(image[p*3+$0]) } }
        func labs(_ colors: [[Double]]) throws -> [[Double]] {
            try ops.lab(colors:colors).map { $0.map(Double.init) }
        }
        func point(_ p: Int) -> [Int] { [p%w,p/w] }
        func mask(_ positions: [Int]) -> [UInt8] {
            var result=[UInt8](repeating:0,count:n);for p in positions { result[p]=1 };return result
        }
        func supported(_ p: Int, detector: Bool = true) -> Bool {
            let rf=input.rf
            let owner=max(Double(rf[p*27+15])*Double(rf[p*27+16]),Double(rf[p*27+17])*Double(rf[p*27+18]))
            let o=input.ocr
            return owner>=0.001 && max(input.primary[p],input.boundary[p])>=0.5 && o[p*8]>0
                && (!detector || ((o[p*8+1]==0 || o[p*8+2]>=0.2) && (o[p*8+3]==0 || o[p*8+4]>=0.2)))
        }
        func component(_ mask:[UInt8]) throws -> NativeAppearancePhysicalImage.Components {
            try NativeAppearancePhysicalImage.components(mask,width:w,height:h)
        }
        func depth(_ mask:[UInt8]) throws -> [Float] { try ops.distance(mask,width:w,height:h,maskSize:5) }
        func exactDepth(_ mask:[UInt8]) throws -> [Double] {
            try NativeAppearanceEuclideanDistance.transform(seed:mask.map { $0==0 ? 1:0 },width:w,height:h).values
        }
        func family(_ color:[Double]) throws -> [UInt8] {
            let c=try labs([color])[0],chroma=hypot(c[1],c[2])
            return (0..<n).map { p in
                let l=lab(p),pc=hypot(l[1],l[2]);let hit:Bool
                if chroma>=8 { hit=(l[1]*c[1]+l[2]*c[2])/max(pc*chroma,1e-6)>=0.9 && pc>=max(5,chroma*0.2) && abs(l[0]-c[0])<=20 }
                else { hit=hypot(l[1]-c[1],l[2]-c[2])<=8 && abs(l[0]-c[0])<=15 }
                return hit ? 1:0
            }
        }
        func flood(_ seed:Int) -> [UInt8]? {
            var seen=[UInt8](repeating:0,count:n),queue=[seed];seen[seed]=1;var cursor=0,touches=false
            while cursor<queue.count {
                let p=queue[cursor];cursor+=1;let x=p%w,y=p/w
                if x==0 || y==0 || x==w-1 || y==h-1 { touches=true }
                for dy in -1...1 { for dx in -1...1 where dx != 0 || dy != 0 {
                    let xx=x+dx,yy=y+dy
                    if xx<0 || yy<0 || xx>=w || yy>=h { continue }
                    let next=yy*w+xx
                    if seen[next]==0 && (0..<3).allSatisfy({ abs(image[p*3+$0]-image[next*3+$0])<=4 }) {
                        seen[next]=1;queue.append(next)
                    }
                }}
            }
            return touches ? nil:seen
        }
        func restore(_ prediction:D) throws -> D {
            var out=prediction,fill=part(out,"fill"),outline=part(out,"outline")
            if let tag=fill["nativePrimaryQualityCorrection"] as? D {
                guard tag["version"] as? String==qualityVersion,tag["modelSHA256"] as? String==qualitySHA,
                      vector(fill["rgb"])==vector(tag["newRGB"]),colors(fill["colors"])==colors(tag["emittedColors"]) else { throw NativeOpenCV.Failure.native("Invalid warm native primary provenance") }
                fill["rgb"]=tag["previousRGB"]
                if tag["previousColorsPresent"] as? Bool == true {fill["colors"]=tag["previousColors"]} else {fill.removeValue(forKey:"colors")}
                fill.removeValue(forKey:"nativePrimaryQualityCorrection")
            }
            if let tag=fill["interiorPalettePruning"] as? D {
                guard tag["version"] as? String==pruningVersion,vector(fill["rgb"])==vector(tag["primaryRGB"]),colors(fill["colors"])==colors(tag["retainedColors"]) else {throw NativeOpenCV.Failure.native("Invalid warm palette pruning")}
                fill["colors"]=tag["previousColors"];fill.removeValue(forKey:"interiorPalettePruning")
            }
            if let tag=fill["brightPrimaryCorrection"] as? D {
                let new=vector(tag["newRGB"]),previous=colors(tag["previousColors"])
                guard tag["version"] as? String==brightPrimaryVersion,vector(fill["rgb"])==new,colors(fill["colors"])==[new]+previous.filter({$0 != new}) else {throw NativeOpenCV.Failure.native("Invalid warm bright primary")}
                fill["rgb"]=tag["previousRGB"];fill["colors"]=previous;fill.removeValue(forKey:"brightPrimaryCorrection")
            }
            if let tag=outline["gradientContourCorrection"] as? D {
                guard [contourVersion,"source-confirmed-gradient-primary-contour-v1"].contains(tag["version"] as? String ?? ""),vector(tag["previousRGB"]).count==3 else {throw NativeOpenCV.Failure.native("Invalid warm gradient contour")}
                outline["rgb"]=tag["previousRGB"];outline.removeValue(forKey:"gradientContourCorrection")
            }
            if let tag=fill["gradientPaletteCorrection"] as? D {
                guard [paletteVersion,"source-confirmed-contour-owned-palette-v5","source-confirmed-contour-owned-palette-v4","source-confirmed-contour-owned-palette-v3"].contains(tag["version"] as? String ?? ""),vector(fill["rgb"])==vector(tag["primaryRGB"]),colors(fill["colors"])==colors(tag["previousColors"])+colors(tag["addedRGB"]) else {throw NativeOpenCV.Failure.native("Invalid warm gradient palette")}
                fill["colors"]=tag["previousColors"];fill.removeValue(forKey:"gradientPaletteCorrection")
            }
            out["fill"]=fill;out["outline"]=outline;return out
        }
    }
}
