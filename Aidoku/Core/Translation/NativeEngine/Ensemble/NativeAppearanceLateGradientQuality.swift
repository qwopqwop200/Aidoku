import Foundation

extension NativeAppearanceLateGradient.Engine {
    typealias D = NativeAppearanceLateGradient.D
    struct NativeOption { var rgb:[Double]?;var evidence:D }

    func medoid(_ positions:[Int]) throws -> ([Double],D) {
        var counts=[Int:Int]()
        for p in positions {let c=rgb(p);let key=Int(c[0])*65536+Int(c[1])*256+Int(c[2]);counts[key,default:0]+=1}
        let keys=counts.keys.sorted(),colors=keys.map { [Double($0/65536),Double(($0/256)%256),Double($0%256)] }
        guard !keys.isEmpty else {throw NativeOpenCV.Failure.native("Empty native medoid")}
        if keys.count==1 {return(colors[0],["uniqueRGB":1,"candidatesExactlyScored":1,"prunedByConvexLowerBound":0])}
        let ll=try labs(colors),mass=Double(positions.count)
        var center=(0..<3).map {c in ll.indices.reduce(0.0) {$0+ll[$1][c]*Double(counts[keys[$1]]!)}/mass}
        for _ in 0..<40 {
            let weights=ll.indices.map { Double(counts[keys[$0]]!)/max(NativeAppearanceLateGradient.d64(ll[$0],center),1e-9) }
            let total=weights.reduce(0,+),next=(0..<3).map {c in ll.indices.reduce(0.0) {$0+ll[$1][c]*weights[$1]}/total}
            if NativeAppearanceLateGradient.d64(next,center)<1e-8 {break};center=next
        }
        func cost(_ index:Int)->Double {ll.indices.reduce(0.0) {$0+NativeAppearanceLateGradient.d64(ll[index],ll[$1])*Double(counts[keys[$1]]!)}}
        var best=ll.indices.min {NativeAppearanceLateGradient.d64(ll[$0],center)<NativeAppearanceLateGradient.d64(ll[$1],center)}!
        var objective=cost(best)
        // Admissible Jensen bounds prune only candidates that cannot beat the
        // incumbent. Every survivor retains its exact weighted native RGB cost.
        var pending=Array(ll.indices)
        if keys.count>512 {
            for width in [32,16,8,4] {
                var groups=[[Int]:[Int]]()
                for index in ll.indices {groups[colors[index].map {Int($0)/width},default:[]].append(index)}
                let ids=groups.keys.sorted(by:{$0.lexicographicallyPrecedes($1)})
                var centers:[[Double]]=[],weights:[Double]=[]
                for id in ids {
                    let members=groups[id]!,total=members.reduce(0.0) {$0+Double(counts[keys[$1]]!)}
                    centers.append((0..<3).map {c in members.reduce(0.0) {$0+ll[$1][c]*Double(counts[keys[$1]]!)}/total});weights.append(total)
                }
                pending=pending.filter {index in centers.indices.reduce(0.0) {$0+NativeAppearanceLateGradient.d64(ll[index],centers[$1])*weights[$1]}<=objective+1e-7*mass}
                if pending.count<=512 || centers.count>keys.count/2 {break}
            }
        }
        for index in pending {let candidate=cost(index);if candidate<objective || (candidate==objective && index<best) {best=index;objective=candidate}}
        return(colors[best],["uniqueRGB":keys.count,"candidatesExactlyScored":pending.count,"prunedByConvexLowerBound":keys.count-pending.count,"weightedObjective":objective])
    }

    func nativeOptions(_ prediction:D) throws -> [NativeOption] {
        let fill=NativeAppearanceLateGradient.part(prediction,"fill"),outline=NativeAppearanceLateGradient.part(prediction,"outline")
        let bg=NativeAppearanceLateGradient.part(prediction,"background")
        var other=NativeAppearanceLateGradient.colors(bg["colors"])
        if other.isEmpty {other=[NativeAppearanceLateGradient.vector(bg["rgb"])]}
        if outline["present"] as? Bool == true {other.append(NativeAppearanceLateGradient.vector(outline["rgb"]))}
        let current=try labs([NativeAppearanceLateGradient.vector(fill["rgb"])])[0],alternates=try labs(other)
        let foreground=(0..<n).map {p -> UInt8 in
            let color=lab(p),dist=NativeAppearanceLateGradient.d(color,current)
            let alternate=alternates.map {NativeAppearanceLateGradient.d(color,$0)}.min()!
            return roi[p] != 0 && input.ownMask[p] != 0 && dist<alternate ? 1:0
        }
        let components=try component(foreground),eligible=(1..<components.areas.count).filter {components.areas[$0]>=3}
        guard let largest=eligible.max(by:{components.areas[$0]<components.areas[$1] || (components.areas[$0]==components.areas[$1] && $0>$1)}) else {
            return [NativeOption(rgb:nil,evidence:["eligible":false,"reason":"No finite owned foreground component"]),
                NativeOption(rgb:nil,evidence:["eligible":false,"reason":"No foreground component"]),NativeOption(rgb:nil,evidence:["eligible":false,"reason":"No foreground component"])]
        }
        let positions=(0..<n).filter {components.labels[$0]==Int32(largest)},body=mask(positions),distances=try depth(body)
        let rect=components.bounds[largest]
        let (color,med)=try medoid(positions)
        var options=[NativeOption(rgb:color,evidence:["version":"largest-source-foreground-exact-native-medoid-v1","eligible":true,
            "component":largest,"componentPixels":positions.count,"components":eligible.count,"nativeRGB":color,
            "nativeXY":point(positions.first {rgb($0)==color}!),"bounds":[Int(rect.minX),Int(rect.minY),Int(rect.width),Int(rect.height)],"medoid":med,"GTAtInference":false])]
        for margin in [1.0,1.5] {
            let selected=positions.filter {Double(distances[$0])>margin}
            guard selected.count>=3 else {
                options.append(.init(rgb:nil,evidence:["eligible":false,"reason":"No native geometric core","componentPixels":positions.count,"corePixels":selected.count,"coreMarginPx":margin]));continue
            }
            let (core,report)=try medoid(selected)
            options.append(.init(rgb:core,evidence:["version":"largest-native-foreground-eroded-core-primary-v1","eligible":true,
                "component":largest,"componentPixels":positions.count,"corePixels":selected.count,"coreMarginPx":margin,
                "maximumNativeDepthPx":Double(distances.max()!),"nativeRGB":core,"nativeXY":point(selected.first {rgb($0)==core}!),"medoid":report,"GTAtInference":false]))
        }
        return options
    }

    func primaryFeatures(_ prediction:D,options:[NativeOption],index:Int) throws -> [String:Double] {
        typealias L=NativeAppearanceLateGradient
        var row=[String:Double]()
        func put(_ key:String,_ value:Any?) {row[key]=L.number(value)}
        func count(_ key:String,_ value:Any?) {row[key]=L.log(value)}
        let current=try labs([L.vector(L.part(prediction,"fill")["rgb"])])[0]
        let candidate=try labs([options[index].rgb ?? L.vector(L.part(prediction,"fill")["rgb"])])[0]
        let bg=try labs([L.vector(L.part(prediction,"background")["rgb"])])[0]
        let ol=try labs([L.vector(L.part(prediction,"outline")["rgb"])])[0]
        for (name,a,b) in [("candidate_current",candidate,current),("candidate_bg",candidate,bg),("current_bg",current,bg),
                            ("candidate_outline",candidate,ol),("current_outline",current,ol),("outline_bg",ol,bg)] {
            // The frozen Python number() rejects numpy.float32 scalars. These
            // direct Lab differences/norms are therefore NaN in training/runtime;
            // retain that feature missingness rather than silently repairing it.
            for c in ["L","a","b"] {row[name+"_"+c] = .nan}
            row[name+"_norm"] = .nan
            _ = a; _ = b
        }
        for role in ["fill","outline","background"] {
            let field=L.part(prediction,role)
            for key in ["confidence","probability"] {put(role+"_"+key,field[key])}
            row[role+"_max_candidate_score"]=L.vector(field["candidateScores"]).filter(\.isFinite).max() ?? .nan
        }
        put("outline_present",L.part(prediction,"outline")["present"])
        let evidence=L.part(prediction,"pixelRoleEvidence"),samples=L.number(evidence["samples"])
        count("role_samples_log",samples)
        for role in ["fill","outline","background"] {
            let ev=L.part(L.part(evidence,"roles"),role),prefix="role_"+role+"_"
            put(prefix+"mean_probability",ev["meanProbability"]);count(prefix+"confident_log",ev["confidentSamples"])
            row[prefix+"confident_fraction"]=samples>0 ? L.number(ev["confidentSamples"])/samples:.nan
            let colors=L.rows(ev["observedColours"])
            count(prefix+"colour_count_log",colors.count)
            row[prefix+"max_mass"]=colors.map {L.number($0["observedMass"])}.filter(\.isFinite).max() ?? .nan
            let ll=try labs(colors.map {L.vector($0["rgb"])})
            row[prefix+"current_min_distance"]=ll.map {L.d($0,current)}.min() ?? .nan
            row[prefix+"candidate_min_distance"]=ll.map {L.d($0,candidate)}.min() ?? .nan
        }
        let native=options[0].evidence,own=options[index].evidence,component=L.number(native["componentPixels"])
        count("native_components_log",native["components"]);count("native_component_pixels_log",component)
        let bounds=L.vector(native["bounds"])
        row["native_component_bbox_fraction"]=bounds.count==4 && bounds[2]*bounds[3]>0 ? component/(bounds[2]*bounds[3]):.nan
        for (name,e) in [("chosen",own),("native",native),("core1",options[1].evidence),("core1_5",options[2].evidence)] {
            let pixels=L.number(e["corePixels"] ?? e["componentPixels"]),unique=L.number(L.part(e,"medoid")["uniqueRGB"])
            count(name+"_pixels_log",pixels);row[name+"_component_fraction"]=component>0 ? pixels/component:.nan
            count(name+"_unique_log",unique);row[name+"_unique_fraction"]=pixels>0 ? unique/pixels:.nan
        }
        put("chosen_margin",own["coreMarginPx"] ?? 0)
        put("native_max_depth",options[1].evidence["maximumNativeDepthPx"] ?? options[2].evidence["maximumNativeDepthPx"])
        let names=["native","core1shift0","core1.5shift0"]
        for j in 0..<3 {
            put("type_"+names[j],j==index);put("available_"+names[j],options[j].rgb != nil)
            row["agreement_distance_"+names[j]] = .nan
        }
        put("agreement_exact_count",options.compactMap(\.rgb).filter {$0==options[index].rgb}.count)
        put("available_count",options.compactMap(\.rgb).count)
        guard row.count==88 else {throw NativeOpenCV.Failure.native("Native primary feature count !=88")};return row
    }

    func nativePrimary(_ prediction:D) throws -> D {
        typealias L=NativeAppearanceLateGradient
        var out=prediction
        let options=try nativeOptions(out),config=try heads.configuration("appearance/native-primary-quality-model")
        guard let names=config["featureNames"] as? [String],names.count==88,config["candidateOrder"] as? [String]==["native","core1shift0","core1.5shift0"] else {throw NativeAppearanceModelHeads.Failure.invalidMetadata("native primary88")}
        let rows=try (0..<3).map {index -> [Double] in let record=try primaryFeatures(out,options:options,index:index);return names.map {record[$0] ?? .nan}}
        let model=try heads.model("appearance/native-primary-quality-model/model")
        let scores=try rows.map {try model.predict($0)[0]},gate=try NativeAppearanceModelHeads.number(config,"gate")
        var best:Int?
        for i in 0..<3 where options[i].rgb != nil {if best==nil || scores[i]>scores[best!] {best=i}}
        guard let chosen=best,scores[chosen]>=gate,let color=options[chosen].rgb else {return out}
        var fill=L.part(out,"fill");let previous=L.vector(fill["rgb"]),palette=L.colors(fill["colors"])
        if color==previous {return out}
        if let first=palette.first,first != previous {throw NativeOpenCV.Failure.native("Native primary palette slot mismatch")}
        let emitted=[color]+Array(palette.dropFirst())
        let allRows=rows.flatMap {$0}
        let featureHash=allRows.withUnsafeBytes {L.hash(Data($0))}
        let source:D=["candidateIndex":chosen+1,"predictedImprovement":scores[chosen],"nativeXY":options[chosen].evidence["nativeXY"]!,
            "nativeRGBSHA256":L.hash(Data(input.rgb)),"predictedMaskSHA256":L.hash(Data(input.ownMask.map {$0==0 ? 0:1})),"featureVectorSHA256":featureHash]
        fill["rgb"]=color;fill["colors"]=emitted
        fill["nativePrimaryQualityCorrection"]=["version":L.qualityVersion,"modelSHA256":L.qualitySHA,"gate":gate,
            "previousRGB":previous,"previousColorsPresent":L.part(out,"fill")["colors"] != nil,"previousColors":palette,
            "newRGB":color,"emittedColors":emitted,"sourceEvidence":source] as D
        out["fill"]=fill;return out
    }
}
