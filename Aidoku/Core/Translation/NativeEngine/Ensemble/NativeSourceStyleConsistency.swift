import Foundation
import CoreFoundation

/// Display normalization of close, source-bound observations. Source heads/bindings stay immutable.
enum NativeSourceStyleConsistency {
    /// Source observations, not the scalar primary alone, choose the display
    /// fill. Retained-corpus replay preserves geometry and original predictions.
    static var observedFillDominanceEnabled: Bool {
        ProcessInfo.processInfo.environment["AIDOKU_OBSERVED_FILL_DOMINANCE"] != "0"
    }
    private struct Observation {
        let index: Int
        let font: Double
        let fill: [Double]
        let outline: [Double]?
        let width: Double
        let weight: String
        let shadow: Bool
    }
    private static func rgb(_ value: Any?) -> [Double]? {
        guard let c=value as? [Double],c.count==3,c.allSatisfy({ $0.isFinite && (0...255).contains($0) }) else { return nil }
        return c
    }
    private static func luminance(_ c:[Double])->Double {
        let v=c.map {x -> Double in let a=x/255;return a<=0.04045 ? a/12.92:pow((a+0.055)/1.055,2.4)}
        return v[0]*0.2126+v[1]*0.7152+v[2]*0.0722
    }
    private static func lab(_ c:[Double])->[Double] {
        let v=c.map { x -> Double in let a=x/255;return a<=0.04045 ? a/12.92 : pow((a+0.055)/1.055,2.4) }
        let x=(0.4124564*v[0]+0.3575761*v[1]+0.1804375*v[2])/0.95047
        let y=0.2126729*v[0]+0.7151522*v[1]+0.072175*v[2]
        let z=(0.0193339*v[0]+0.119192*v[1]+0.9503041*v[2])/1.08883
        let f=[x,y,z].map { $0>pow(6.0/29,3) ? pow($0,1.0/3) : $0/(3*pow(6.0/29,2))+4.0/29 }
        return [116*f[1]-16,500*(f[0]-f[1]),200*(f[1]-f[2])]
    }
    private static func delta(_ a:[Double],_ b:[Double])->Double {
        sqrt(zip(lab(a),lab(b)).reduce(0) { $0+pow($1.0-$1.1,2) })
    }
    /// Display-only selection from authenticated source pixel-role hypotheses.
    /// The source primary is never rewritten; a palette list is not a spatial map.
    static func observedFillDominance(_ prediction: [String: Any])
        -> (selectedRGB: [Double], audit: [String: Any])? {
        func number(_ value: Any?) -> Double? {
            guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(),
                  n.doubleValue.isFinite else { return nil }
            return n.doubleValue
        }
        func flag(_ value: Any?, _ expected: Bool) -> Bool {
            guard let n = value as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() else { return false }
            return n.boolValue == expected
        }
        func colour(_ value: Any?) -> [Double]? {
            guard let values = value as? [Any], values.count == 3 else { return nil }
            let c = values.compactMap { number($0) }
            return c.count == 3 && c.allSatisfy({ (0...255).contains($0) }) ? c : nil
        }
        func records(_ value: Any?) -> [(rgb: [Double], mass: Double)]? {
            guard let rows = value as? [[String: Any]], rows.count <= 256 else { return nil }
            var result: [(rgb: [Double], mass: Double)] = []
            for row in rows {
                guard let c = colour(row["rgb"]), let m = number(row["observedMass"]),
                      (0...1).contains(m) else { return nil }
                result.append((c, m))
            }
            guard result.map(\.mass).sorted().reduce(0, +) <= 1 else { return nil }
            return result
        }
        guard flag(prediction["sourceOnly"], true), flag(prediction["inferenceUsesGT"], false),
              let primary = colour((prediction["fill"] as? [String: Any])?["rgb"]),
              let pixels = prediction["pixelRoleEvidence"] as? [String: Any], flag(pixels["GTAtInference"], false),
              let roles = pixels["roles"] as? [String: Any], let fill = roles["fill"] as? [String: Any],
              let samples = number(fill["confidentSamples"]), samples >= 32, samples.rounded() == samples,
              let modes = records(fill["observedColours"]), !modes.isEmpty,
              let background = roles["background"] as? [String: Any],
              let backgrounds = records(background["observedColours"]) else { return nil }
        let primarySupport = modes.filter { delta($0.rgb, primary) <= 6 }.reduce(0.0) { $0 + $1.mass }
        guard primarySupport < 0.25 else { return nil }
        // Canonical ordering and complete-link agglomeration avoid input-order
        // dependence and transitive chains joining perceptually distinct inks.
        let ordered = modes.sorted {
            if $0.rgb != $1.rgb { return $0.rgb.lexicographicallyPrecedes($1.rgb) }
            return $0.mass > $1.mass
        }
        var distances = [Double](repeating: 0, count: ordered.count * ordered.count)
        for a in ordered.indices {
            for b in ordered.indices where b > a {
                let value = delta(ordered[a].rgb, ordered[b].rgb)
                distances[a * ordered.count + b] = value
                distances[b * ordered.count + a] = value
            }
        }
        var clusters = ordered.indices.map { [$0] }
        while clusters.count > 1 {
            var pair: (Int, Int)?, best = Double.infinity
            for a in clusters.indices {
                for b in clusters.indices where b > a {
                    let distance = clusters[a].reduce(0.0) { value, x in
                        max(value, clusters[b].reduce(0.0) { max($0, distances[x * ordered.count + $1]) })
                    }
                    if distance <= 6 && distance < best { best = distance; pair = (a, b) }
                }
            }
            guard let (a, b) = pair else { break }
            clusters[a].append(contentsOf: clusters[b]); clusters.remove(at: b)
        }
        func clusterMass(_ indices: [Int]) -> Double { indices.map { ordered[$0].mass }.sorted().reduce(0, +) }
        clusters.sort { clusterMass($0) > clusterMass($1) }
        let winner = clusters[0].map { ordered[$0] }, mass = clusterMass(clusters[0])
        let nextClusterMass = clusters.dropFirst().map { clusterMass($0) }.max() ?? 0
        // Only the leading quantized modes are reported. All unreported mass
        // could belong to one competitor; never assign it a fabricated colour.
        let observedMass = modes.map(\.mass).sorted().reduce(0, +)
        let unreportedMass = max(0, 1 - observedMass)
        let runner = max(nextClusterMass, unreportedMass)
        guard mass >= 0.55, mass > runner, mass >= 2 * runner,
              let mode = winner.max(by: { $0.mass < $1.mass }),
              !winner.contains(where: { $0.mass == mode.mass && $0.rgb != mode.rgb }),
              !winner.contains(where: { c in backgrounds.contains { $0.mass >= 0.05 && delta(c.rgb, $0.rgb) <= 6 } }),
              delta(mode.rgb, primary) > 6 else { return nil }
        return (mode.rgb, ["policy": "observed-fill-complete-link-dominance-v1", "sourcePrimaryRGB": primary,
            "selectedDisplayRGB": mode.rgb, "dominantMass": mass, "runnerMass": runner,
            "nextClusterMass": nextClusterMass, "sumObservedMass": observedMass, "unreportedMass": unreportedMass,
            "runnerMassPolicy": "max(next-observed-cluster,all-unreported-mass)",
            "primarySupport": primarySupport, "confidentFillSamples": samples, "clusterDeltaE": 6,
            "backgroundSignificantMass": 0.05, "sourcePredictionUnchanged": true,
            "selectedActualObservedMode": true, "spatialMappingPerformed": false])
    }
    /// Recover an observed chromatic core when a weak pale fill head measures
    /// the blend into a strongly observed outline. Never invent or average ink,
    /// override a strongly supported fill, or resolve a multicolour ambiguity.
    static func sourceUnblendedFill(_ prediction:[String:Any],fill:[Double])->[Double]? {
        sourceRimUnblendedFill(prediction,fill:fill) ?? sourceObservedChromaticFill(prediction,fill:fill)
    }
    private static func sourceRimUnblendedFill(_ prediction:[String:Any],fill:[Double])->[Double]? {
        guard prediction["inferenceUsesGT"]as?Bool == false,prediction["sourceOnly"]as?Bool == true,
              let fill=rgb(fill),let outline=prediction["outline"]as?[String:Any],outline["present"]as?Bool == true,
              (outline["measurementEvidence"]as?[String:Any])?["reliable"]as?Bool == false,
              let border=rgb(outline["rgb"]),
              let roles=(prediction["pixelRoleEvidence"]as?[String:Any])?["roles"]as?[String:Any],
              let ink=roles["fill"]as?[String:Any],(ink["confidentSamples"]as?Int ?? 0)>=32,
              let ring=roles["outline"]as?[String:Any],(ring["confidentSamples"]as?Int ?? 0)>=32,
              let colours=ink["observedColours"]as?[[String:Any]],
              let edges=ring["observedColours"]as?[[String:Any]]else{return nil}
        func contrast(_ a:[Double],_ b:[Double])->Double {
            let x=luminance(a),y=luminance(b);return (max(x,y)+0.05)/(min(x,y)+0.05)
        }
        guard contrast(fill,border)<1.5,edges.contains(where:{c in
            guard (c["observedMass"]as?Double ?? 0)>=0.8,let observed=rgb(c["rgb"])else{return false}
            return delta(observed,border)<=3
        })else{return nil}
        let support=colours.reduce(0.0) {sum,c in
            guard let observed=rgb(c["rgb"]),delta(observed,fill)<=5,
                  let mass=c["observedMass"]as?Double,mass.isFinite,(0...1).contains(mass)else{return sum}
            return sum+mass
        }
        guard support<0.5 else{return nil}
        let background=(roles["background"]as?[String:Any])?["observedColours"]as?[[String:Any]] ?? []
        var candidates:[([Double],Double)]=[]
        for c in colours {
            guard let colour=rgb(c["rgb"]),let mass=c["observedMass"]as?Double,mass.isFinite,(0.05...1).contains(mass),
                  colour.max()!-colour.min()!>=64,contrast(colour,border)>=2,delta(colour,fill)>=15,
                  !background.contains(where:{b in
                    guard (b["observedMass"]as?Double ?? 0)>=0.05,let observed=rgb(b["rgb"])else{return false}
                    return delta(colour,observed)<12
                  })else{continue}
            let vector=zip(colour,border).map(-),mass2=vector.reduce(0){$0+$1*$1}
            guard mass2>0 else{continue}
            let t=zip(zip(fill,border),vector).reduce(0.0){$0+($1.0.0-$1.0.1)*$1.1}/mass2
            let error=sqrt(fill.indices.reduce(0.0){$0+pow(fill[$1]-border[$1]-t*vector[$1],2)})
            if (0.03...0.35).contains(t),error<=18 {candidates.append((colour,mass))}
        }
        guard !candidates.isEmpty,candidates.allSatisfy({a in candidates.allSatisfy {delta(a.0,$0.0)<=5}})else{return nil}
        return candidates.max(by:{$0.1<$1.1})!.0
    }
    /// Recover a coherent chromatic fill from source pixel roles and a pale
    /// observed context, independently of an unreliable outline/background head.
    /// Select an actual maximum-mass mode; never average or extrapolate colours.
    static func sourceObservedChromaticFill(_ prediction:[String:Any],fill:[Double])->[Double]? {
        func number(_ value:Any?)->Double? {
            guard let n=value as? NSNumber,CFGetTypeID(n) != CFBooleanGetTypeID(),n.doubleValue.isFinite else{return nil}
            return n.doubleValue
        }
        func colour(_ value:Any?)->[Double]? {
            guard let values=value as?[Any],values.count==3 else{return nil}
            let c=values.compactMap {number($0)}
            guard c.count==3,c.allSatisfy({(0...255).contains($0)})else{return nil}
            return c
        }
        func records(_ value:Any?)->[([Double],Double)]? {
            guard let rows=value as?[[String:Any]]else{return nil}
            var result:[([Double],Double)]=[]
            for row in rows {
                guard let c=colour(row["rgb"]),let mass=number(row["observedMass"]),(0...1).contains(mass)else{return nil}
                result.append((c,mass))
            }
            return result
        }
        func contrast(_ a:[Double],_ b:[Double])->Double {
            let x=luminance(a),y=luminance(b);return (max(x,y)+0.05)/(min(x,y)+0.05)
        }
        guard prediction["sourceOnly"]as?Bool == true,prediction["inferenceUsesGT"]as?Bool == false,
              let fill=colour(fill),fill.min()!>=180,
              let outline=prediction["outline"]as?[String:Any],
              (outline["measurementEvidence"]as?[String:Any])?["reliable"]as?Bool == false,
              let background=prediction["background"]as?[String:Any],let bg=colour(background["rgb"]),contrast(fill,bg)<1.5,
              let palette=background["colors"]as?[Any],let rawWeights=background["observedContextWeights"]as?[Any],
              palette.count==rawWeights.count else{return nil}
        var paleMass=0.0
        for (value,rawWeight)in zip(palette,rawWeights) {
            guard let c=colour(value),let w=number(rawWeight),(0...1).contains(w)else{return nil}
            if c.min()!>=200,c.max()!-c.min()!<=24 {paleMass+=w}
        }
        guard paleMass>=0.8,
              let roles=(prediction["pixelRoleEvidence"]as?[String:Any])?["roles"]as?[String:Any],
              let ink=roles["fill"]as?[String:Any],let samples=number(ink["confidentSamples"]),samples>=32,
              let observations=records(ink["observedColours"]),let body=roles["background"]as?[String:Any],
              let bodyColours=records(body["observedColours"])else{return nil}
        let support=observations.filter {delta($0.0,fill)<=5}.reduce(0.0){$0+$1.1}
        guard support<0.5 else{return nil}
        let modes=observations.filter {c,mass in
            mass>=0.05 && c.max()!-c.min()!>=48 && contrast(c,bg)>=2 && delta(c,fill)>=15
        }
        guard modes.reduce(0.0,{$0+$1.1})>=0.2,
              !modes.contains(where:{c in bodyColours.contains { $0.1>=0.05 && delta(c.0,$0.0)<12 }})else{return nil}
        // Complete pairwise agreement admits AA brightness, not distinct inks.
        for a in modes {
            for b in modes {
                let meanA=a.0.reduce(0,+)/3,meanB=b.0.reduce(0,+)/3
                let x=a.0.map {$0-meanA},y=b.0.map {$0-meanB}
                let dot=zip(x,y).reduce(0.0){$0+$1.0*$1.1}
                let norm=sqrt(x.reduce(0.0){$0+$1*$1}*y.reduce(0.0){$0+$1*$1})
                guard dot/norm>=0.96,delta(a.0,b.0)<=24 else{return nil}
            }
        }
        // Strict comparison preserves the first observed mode on equal mass.
        return modes.reduce(nil as ([Double],Double)?) {best,c in
            guard let best=best else{return c}
            return c.1>best.1 ? c:best
        }?.0
    }
    static func sourceBackgroundEndpoint(_ prediction:[String:Any],fill:[Double])->[Double]? {
        func number(_ value:Any?)->Double? {
            guard let n=value as?NSNumber,CFGetTypeID(n) != CFBooleanGetTypeID(),n.doubleValue.isFinite else{return nil}
            return n.doubleValue
        }
        func checkedRGB(_ value:Any?)->[Double]? {
            guard let values=value as?[Any],values.count==3 else{return nil}
            let c=values.compactMap {number($0)}
            guard c.count==3,c.allSatisfy({(0...255).contains($0)})else{return nil}
            return c
        }
        guard prediction["sourceOnly"]as?Bool == true,prediction["inferenceUsesGT"]as?Bool == false,
              let outline=prediction["outline"]as?[String:Any],outline["present"]as?Bool == false,
              let fill=checkedRGB(fill),fill.max()!-fill.min()!>24,
              let background=prediction["background"]as?[String:Any],let colour=checkedRGB(background["rgb"]),
              let rawWeights=background["observedContextWeights"]as?[Any],!rawWeights.isEmpty,
              colour.max()!-colour.min()!<=24,colour.min()!>=232 || colour.max()!<=24 else{return nil}
        let weights=rawWeights.compactMap {number($0)}
        guard weights.count==rawWeights.count,weights.allSatisfy({(0...1).contains($0)})else{return nil}
        let support:Double
        if let value=background["colors"] {
            guard let palette=value as?[Any],palette.count==weights.count else{return nil}
            var matchingMass=0.0
            for (entry,weight)in zip(palette,weights) {
                guard let observed=checkedRGB(entry)else{return nil}
                if delta(observed,colour)<=3 {matchingMass+=weight}
            }
            support=matchingMass
        }else{
            // Legacy packets/intentional fixtures bind the first weight to rgb
            // when no palette exists. A present malformed palette never falls back.
            support=weights[0]
        }
        guard support>=0.8 else{return nil}
        let a=luminance(fill),b=luminance(colour)
        guard (max(a,b)+0.05)/(min(a,b)+0.05)>=2 else{return nil}
        return [Double](repeating:colour.min()!>=232 ? 255:0,count:3)
    }
    /// Warm near-white ink can have a blue channel below the neutral RGB gate.
    /// Perceptual lightness/chroma keep that source fill in the light family.
    private static func lightNeutral(_ fill:[Double])->Bool {
        let value=lab(fill)
        return fill.min()!>=232 || value[0]>=94 && hypot(value[1],value[2])<=16
    }
    static func sourceOutlineEndpoint(_ prediction:[String:Any],fill:[Double])->[Double]? {
        guard prediction["inferenceUsesGT"]as?Bool == false,prediction["sourceOnly"]as?Bool == true,
              let outline=prediction["outline"]as?[String:Any],outline["present"]as?Bool == true,
              (outline["probability"]as?Double ?? 0)>=0.9,
              (outline["observedLayers"]as?[[String:Any]] ?? []).count<=1,
              let evidence=outline["measurementEvidence"]as?[String:Any],evidence["reliable"]as?Bool == true,
              (evidence["usableRays"]as?Int ?? 0)>=32,let colour=rgb(outline["rgb"]),
              colour.max()!-colour.min()!>24,let fill=rgb(fill),lightNeutral(fill) || fill.max()!<=24,
              let pixels=prediction["pixelRoleEvidence"]as?[String:Any],let roles=pixels["roles"]as?[String:Any],
              let role=roles["outline"]as?[String:Any],(role["confidentSamples"]as?Int ?? 0)>=32,
              let colours=role["observedColours"]as?[[String:Any]],colours.contains(where:{ c in
                  guard (c["observedMass"]as?Double ?? 0)>=0.8,let observed=rgb(c["rgb"])else{return false}
                  return delta(observed,colour)<=3
              })else{return nil}
        let a=luminance(fill),b=luminance(colour)
        guard (max(a,b)+0.05)/(min(a,b)+0.05)>=3 else{return nil}
        return [Double](repeating:lightNeutral(fill) ? 255:0,count:3)
    }
    /// An unreliable same-tone border is not authority to thicken neutral
    /// glyphs into solid silhouettes. Preserve observed fill, and contrast only
    /// the mandatory display guard; trusted contrasting source bands stay intact.
    static func sourceNeutralContrastEndpoint(_ prediction:[String:Any],fill:[Double])->[Double]? {
        guard prediction["inferenceUsesGT"]as?Bool == false,prediction["sourceOnly"]as?Bool == true,
              let fill=rgb(fill),fill.max()!-fill.min()!<=24,fill.min()!>=232 || fill.max()!<=24,
              let outline=prediction["outline"]as?[String:Any],outline["present"]as?Bool == true,
              let evidence=outline["measurementEvidence"]as?[String:Any],evidence["reliable"]as?Bool == false,
              let colour=rgb(outline["rgb"]),
              let roles=(prediction["pixelRoleEvidence"]as?[String:Any])?["roles"]as?[String:Any],
              let role=roles["fill"]as?[String:Any],(role["confidentSamples"]as?Int ?? 0)>=32,
              let observations=role["observedColours"]as?[[String:Any]]else{return nil}
        let a=luminance(fill),b=luminance(colour)
        guard (max(a,b)+0.05)/(min(a,b)+0.05)<=1.5 else{return nil}
        let light=fill.min()!>=232
        let support=observations.reduce(0.0) {sum,c in
            guard let observed=rgb(c["rgb"]),let mass=c["observedMass"]as?Double,mass.isFinite,(0...1).contains(mass),
                  light ? observed.min()!>=224:observed.max()!<=32 else{return sum}
            return sum+mass
        }
        guard support>=0.8 else{return nil}
        return [Double](repeating:light ? 0:255,count:3)
    }
    private static func compatible(_ a:Observation,_ b:Observation)->Bool {
        guard a.weight==b.weight,a.shadow==b.shadow,!a.shadow,
              max(a.font,b.font)<=min(a.font,b.font)*1.08,delta(a.fill,b.fill)<=3,
              abs(a.width/a.font-b.width/b.font)<=0.025 else { return false }
        switch (a.outline,b.outline) {
        case (nil,nil):return true
        case let (x?,y?):return delta(x,y)<=3
        default:return false
        }
    }
    static func harmonized(_ input:[[String:Any]])->[[String:Any]] {
        var groups:[[Observation]]=[],result=input
        for (i,item) in input.enumerated() {
            // Only already authenticated live-estimator outputs may normalize the live route.
            guard let binding=item["sourceAppearanceBinding"] as? [String:String],Set(binding.keys)==NativeOperationalAppearance.bindingKeys,
                  binding.values.allSatisfy({ $0.count==64 && $0.allSatisfy(\.isHexDigit) }),
                  let p=item["sourceAppearance"] as? [String:Any],let fill=p["fill"] as? [String:Any],
                  let colour=rgb(fill["rgb"]),let outline=p["outline"] as? [String:Any],
                  let font=(item["sourceFontSize"] as? NSNumber)?.doubleValue,font.isFinite,font>0 else { continue }
            let dominant = observedFillDominanceEnabled ? observedFillDominance(p) : nil
            if let dominant {
                result[i]["renderSourceFillRGB"] = dominant.selectedRGB
                result[i]["ensembleDisplayFill"] = dominant.selectedRGB
                result[i]["observedFillDisplaySelection"] = dominant.audit
            }
            if let bands=outline["observedLayers"] as? [[String:Any]],bands.count>1 { continue }
            let present=outline["present"] as? Bool == true
            let width=present ? ((outline["widthPx"] as? NSNumber)?.doubleValue ?? 0) : 0
            guard width.isFinite,width>=0,width<=256,!present || rgb(outline["rgb"]) != nil else { continue }
            let weight=(item["sourceFontWeight"] as? String ?? "unknown")+"|"+String(item["renderBold"] as? Bool ?? false)
            let recovered=dominant?.selectedRGB ?? sourceUnblendedFill(p,fill:colour)
            let o=Observation(index:i,font:font,fill:recovered ?? colour,outline:present ? rgb(outline["rgb"]) : nil,width:width,
                weight:weight,shadow:(p["shadow"] as? [String:Any])?["present"] as? Bool == true)
            if let g=groups.firstIndex(where: { $0.allSatisfy { compatible($0,o) } }) { groups[g].append(o) }
            else { groups.append([o]) }
        }
        for (g,members) in groups.enumerated() {
            let exemplar=members.min { a,b in
                members.reduce(0) { $0+delta(a.fill,$1.fill) } < members.reduce(0) { $0+delta(b.fill,$1.fill) }
            }!
            let widths=members.map { $0.width/$0.font }.sorted(),n=members.count
            let ratio=n%2==1 ? widths[n/2] : (widths[n/2-1]+widths[n/2])/2
            for o in members {
                result[o.index]["renderSourceFillRGB"]=exemplar.fill
                result[o.index]["renderSourceOutlineWidthPx"]=ratio*o.font
                result[o.index]["sourceStyleGroupID"]="native-source-style-\(g)"
                if let colour=exemplar.outline,
                   colour.max()!-colour.min()!>12 || colour.min()!>24 && colour.max()!<232 {
                    result[o.index]["renderSourceOutlineRGB"]=colour
                }
            }
        }
        var colours:[[Observation]]=[]
        for o in groups.flatMap({$0}) {
            if let g=colours.firstIndex(where:{$0.allSatisfy {delta($0.fill,o.fill)<=3}}) {colours[g].append(o)}
            else {colours.append([o])}
        }
        for (g,members)in colours.enumerated() {
            let exemplar=members.min {a,b in
                members.reduce(0) {$0+delta(a.fill,$1.fill)} < members.reduce(0) {$0+delta(b.fill,$1.fill)}
            }!
            for o in members {
                result[o.index]["renderSourceFillRGB"]=exemplar.fill
                result[o.index]["sourceColourGroupID"]="native-source-colour-\(g)"
                if let p=input[o.index]["sourceAppearance"]as?[String:Any],
                   let endpoint=sourceBackgroundEndpoint(p,fill:exemplar.fill) {
                    result[o.index]["renderSourceDisplayStrokeRGB"]=endpoint
                } else if let p=input[o.index]["sourceAppearance"]as?[String:Any],
                          let endpoint=sourceOutlineEndpoint(p,fill:exemplar.fill) {
                    result[o.index]["renderSourceDisplayStrokeRGB"]=endpoint
                } else if let p=input[o.index]["sourceAppearance"]as?[String:Any],
                          let endpoint=sourceNeutralContrastEndpoint(p,fill:exemplar.fill) {
                    result[o.index]["renderSourceDisplayStrokeRGB"]=endpoint
                }
            }
        }
        // Close-colour group exemplars may normalize other owners, but cannot
        // overwrite an independently selected actual observed winning mode.
        for i in result.indices where observedFillDominanceEnabled && result[i]["observedFillDisplaySelection"] != nil {
            if let p = input[i]["sourceAppearance"] as? [String: Any], let selected = observedFillDominance(p) {
                result[i]["renderSourceFillRGB"] = selected.selectedRGB
                result[i]["ensembleDisplayFill"] = selected.selectedRGB
                result[i]["observedFillDisplaySelection"] = selected.audit
            }
        }
        return result
    }
}
