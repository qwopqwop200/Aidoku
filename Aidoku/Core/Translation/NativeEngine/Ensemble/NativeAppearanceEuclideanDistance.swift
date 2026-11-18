import Foundation

/// Exact source-grid Euclidean distance/nearest native seed, matching scipy EDT
/// tie priority (lowest X, then lowest Y). Used by categorical shadow ownership;
/// OpenCV chamfer distances remain separate where the accepted graph uses them.
enum NativeAppearanceEuclideanDistance {
    struct Result {let values:[Double];let nearest:[Int]}
    enum Failure:Error {case invalidInput,noSeeds}
    static func transform(seed:[UInt8],width w:Int,height h:Int) throws -> Result {
        guard w>0,h>0,w<=1_500_000/h,seed.count==w*h else {throw Failure.invalidInput}
        guard seed.contains(where:{$0 != 0}) else {throw Failure.noSeeds}
        var vertical=[Double](repeating:.infinity,count:w*h),nativeY=[Int](repeating:0,count:w*h)
        for x in 0..<w {
            let input=(0..<h).map {seed[$0*w+x] != 0 ? 0.0:Double.infinity}
            let (values,nearest)=axis(input)
            for y in 0..<h {vertical[y*w+x]=values[y];nativeY[y*w+x]=nearest[y]}
        }
        var distances=[Double](repeating:0,count:w*h),owners=[Int](repeating:0,count:w*h)
        for y in 0..<h {
            let (values,nearest)=axis(Array(vertical[y*w..<y*w+w]))
            for x in 0..<w {
                let xx=nearest[x];distances[y*w+x]=sqrt(values[x]);owners[y*w+x]=nativeY[y*w+xx]*w+xx
            }
        }
        return .init(values:distances,nearest:owners)
    }
    private static func axis(_ input:[Double])->([Double],[Int]) {
        let count=input.count,sites=input.indices.filter {input[$0].isFinite}
        guard let first=sites.first else {return([Double](repeating:.infinity,count:count),[Int](repeating:0,count:count))}
        var envelope=[Int](repeating:0,count:sites.count),boundaries=[Double](repeating:.infinity,count:sites.count+1)
        envelope[0]=first;boundaries[0] = -.infinity;var k=0
        for q in sites.dropFirst() {
            func crossing(_ p:Int)->Double {(input[q]+Double(q*q)-input[p]-Double(p*p))/Double(2*(q-p))}
            var intersection=crossing(envelope[k])
            while k>0,intersection<=boundaries[k] {k-=1;intersection=crossing(envelope[k])}
            k+=1;envelope[k]=q;boundaries[k]=intersection;boundaries[k+1] = .infinity
        }
        var result=[Double](repeating:0,count:count),nearest=[Int](repeating:0,count:count);k=0
        for q in 0..<count {
            while boundaries[k+1]<Double(q) {k+=1}
            let site=envelope[k];result[q]=Double((q-site)*(q-site))+input[site];nearest[q]=site
        }
        return(result,nearest)
    }
}
