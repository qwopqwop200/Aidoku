import Foundation

/// Native perceptual clusters. Cube bins nominate actual source seeds only;
/// membership is bounded LAB distance and the emitted RGB is a native witness.
enum NativeAppearanceColorNeighborhoods {
    static func clusters(rgb:[[Double]],weights:[Double],limit:Int=3,radius:Float=8,
                         ops:any NativeAppearanceImageOperations) throws -> [[String:Any]] {
        guard rgb.count==weights.count,weights.allSatisfy({$0.isFinite && $0>=0}) else {
            throw NativeAppearanceModelHeads.Failure.invalidOutput("native colour weights")
        }
        let total=weights.reduce(0,+)
        guard rgb.count>=8,total>0 else {return []}
        let lab=try ops.lab(colors:rgb)
        var masses=[Double](repeating:0,count:4096),bins=[Int:[Int]]()
        for p in rgb.indices {
            let code=Int(rgb[p][0])/16*256+Int(rgb[p][1])/16*16+Int(rgb[p][2])/16
            masses[code]+=weights[p];bins[code,default:[]].append(p)
        }
        var seeds:[Int]=[]
        for code in NativeAppearanceNumeric.numpyArgSort(masses.map(-)).prefix(64) {
            guard let indices=bins[code],!indices.isEmpty else {continue}
            let median=(0..<3).map {c in Float(NativeAppearanceNumeric.quantile(indices.map {Double(lab[$0][c])},0.5))}
            var chosen=indices[0],best=Float.infinity
            for p in indices {
                let delta=zip(lab[p],median).map {$0-$1},distance=delta.reduce(Float(0)) {$0+$1*$1}
                if distance<best {chosen=p;best=distance}
            }
            seeds.append(chosen)
        }
        var available=[Bool](repeating:true,count:rgb.count),result:[[String:Any]]=[]
        for _ in 0..<limit {
            var selected:[Int]?,mass = -Double.infinity
            for seed in seeds {
                let members=rgb.indices.filter {available[$0] && NativeAppearancePhysicalImage.distance(lab[$0],lab[seed])<=radius}
                let value=members.reduce(0) {$0+weights[$1]}
                if members.count>=8,value>=max(1,0.05*total),selected==nil || value>mass {selected=members;mass=value}
            }
            guard let selected else {break}
            let center=(0..<3).map {channel in selected.reduce(0) {$0+Double(lab[$1][channel])*weights[$1]}/mass}
            var chosen=selected[0],best=Double.infinity
            for p in selected {
                let distance=(0..<3).reduce(0) {sum,c in let d=Double(lab[p][c])-center[c];return sum+d*d}
                if distance<best {chosen=p;best=distance}
            }
            result.append(["rgb":rgb[chosen],"samples":selected.count,"observedMass":mass/total,
                "nativeActualSample":true,"perceptualRadius":Double(radius)])
            for p in selected {available[p]=false}
        }
        return result
    }
    static func dominant(_ colors:[[String:Any]],ratio:Double=2)->[String:Any]? {
        guard let first=colors.first else {return nil}
        if colors.count==1 {return first}
        guard let a=(first["observedMass"] as? NSNumber)?.doubleValue,
              let b=(colors[1]["observedMass"] as? NSNumber)?.doubleValue,a>=ratio*b else {return nil}
        return first
    }
}
