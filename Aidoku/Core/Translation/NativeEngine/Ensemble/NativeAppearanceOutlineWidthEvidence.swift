import Foundation

/// Exact cardinal source fill→outline→background run descriptor (8 values).
/// Original source pixels only; translated/display widths never enter it.
enum NativeAppearanceOutlineWidthEvidence {
    struct Result {
        let vector:[Double]
        let runs:[Double]
        let gaps:[Double]
        let reliable:Bool
    }
    static func measure(rgb:[UInt8],mask:[UInt8],width w:Int,height h:Int,fill:[Double],outline:[Double]) throws -> Result {
        guard w>0,h>0,w<=1_500_000/h,rgb.count==w*h*3,mask.count==w*h,
              fill.count==3,outline.count==3,fill.allSatisfy(\.isFinite),outline.allSatisfy(\.isFinite) else {
            throw SourceNativeInput.Failure.invalidSource
        }
        let empty=Result(vector:[Double](repeating:0,count:8),runs:[],gaps:[],reliable:false)
        guard zip(fill,outline).map({abs($0-$1)}).max()!>=60 else {return empty}
        let fillTolerance=fill.max()!<45 || fill.min()!>215 ? 20.0:35.0
        let outlineTolerance=outline.max()!<45 ? 20.0:35.0
        func close(_ p:Int,_ color:[Double],_ tolerance:Double)->Bool {
            (0..<3).allSatisfy {abs(Double(rgb[p*3+$0])-color[$0])<=tolerance}
        }
        let allFill=(0..<w*h).map {close($0,fill,fillTolerance)}
        let owned=(0..<w*h).map {allFill[$0] && mask[$0] != 0}
        let stroke=(0..<w*h).map {close($0,outline,outlineTolerance)}
        var runs:[Double]=[],gaps:[Double]=[]
        for (dx,dy) in [(1,0),(-1,0),(0,1),(0,-1)] {
            for p in owned.indices where owned[p] {
                var x=p%w+dx,y=p/w+dy
                let valid=x>=0 && x<w && y>=0 && y<h
                guard valid,!owned[y*w+x] else {continue}
                var active=true,gap=0
                for _ in 0..<3 {
                    let inside=x>=0 && x<w && y>=0 && y<h
                    let index=min(h-1,max(0,y))*w+min(w-1,max(0,x))
                    let advance=active && inside && !stroke[index] && !allFill[index]
                    if advance {x+=dx;y+=dy;gap+=1}
                    active=active && inside && !allFill[index]
                }
                guard active,gap<3,x>=0,x<w,y>=0,y<h,stroke[y*w+x] else {continue}
                var length=0
                for _ in 0..<20 {
                    let inside=x>=0 && x<w && y>=0 && y<h
                    let index=min(h-1,max(0,y))*w+min(w-1,max(0,x))
                    let advance=active && inside && stroke[index]
                    if advance {length+=1;x+=dx;y+=dy}
                    active=advance
                }
                guard x>=0,x<w,y>=0,y<h,length>=1,length<15,!allFill[y*w+x] else {continue}
                let contrast=(0..<3).map {abs(Double(rgb[(y*w+x)*3+$0])-outline[$0])}.max()!
                if contrast>=45 {runs.append(Double(length));gaps.append(Double(gap))}
            }
        }
        guard runs.count>=40 else {
            var values=[Double](repeating:0,count:8);values[7]=log1p(Double(runs.count))
            return .init(vector:values,runs:runs,gaps:gaps,reliable:false)
        }
        let quantiles=[0.1,0.25,0.5,0.75].map {NativeAppearanceNumeric.quantile(runs,$0)}
        let transition=NativeAppearanceNumeric.quantile(gaps,0.5)
        let vector=[1,quantiles[1]+transition*0.5]+quantiles+[transition,log1p(Double(runs.count))]
        return .init(vector:vector,runs:runs,gaps:gaps,reliable:true)
    }
}
