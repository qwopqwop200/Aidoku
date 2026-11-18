import CoreGraphics
import Foundation

/// Bounded complete integer-alpha proposals. This is geometry evidence, not
/// source/background certification. The native caller remains the authority.
enum NativeExactAlphaOrigins {
    @TaskLocal static var enabled=false
    final class Budget {
        private(set) var remaining=1_000_000
        func charge(_ amount:Int)->Bool {
            guard amount>=0,amount<=remaining else {return false}
            remaining-=amount;return true
        }
    }
    enum Status:String {case complete,unknown}
    struct Result {
        let status:Status,shifts:[CGPoint],reason:String
        static func unknown(_ reason:String)->Self {.init(status:.unknown,shifts:[],reason:reason)}
    }
    private static func intersection(_ a:[(Int,Int)],_ b:[(Int,Int)])->[(Int,Int)] {
        var output:[(Int,Int)]=[]
        for x in a {for y in b {
            let lo=max(x.0,y.0),hi=min(x.1,y.1)
            if lo<=hi {output.append((lo,hi))}
        }}
        output.sort {$0.0 == $1.0 ? $0.1<$1.1:$0.0<$1.0}
        var merged:[(Int,Int)]=[]
        for p in output {
            if let last=merged.last,p.0<=last.1+1 {merged[merged.count-1]=(last.0,max(last.1,p.1))}
            else {merged.append(p)}
        }
        return merged
    }
    /// Unknown returns no proposals. Complete includes every native-valid integer
    /// translation in this necessary mask/body envelope, or a proven empty set.
    /// More than 256 possible mask origins is unknown, never silently truncated.
    static func make(_ footprint:NativeFinalTextPaintAdmission.Footprint,page:CGRect,margin:CGFloat,
        policy:NativeTextExpansionPolicy?,body:CGRect?,fixedOrigin:CGPoint?,
        cluster:(NativeSourceClusterAlignment.Axis,CGFloat)?,budget:Budget,
        validate:(NativeFinalTextPaintAdmission.Footprint)->Bool)throws->Result {
        try Task.checkCancellation()
        guard let policy,policy.valid,policy.insideBalloon,let normalized=policy.maskRectNormalized,
              let spans=policy.maskSpansNormalized,!spans.isEmpty,spans.count%2==0,spans.count<=8192,
              page==page.integral,page.minX==0,page.minY==0,page.width>0,page.height>0,page.width<=16384,page.height<=16384,
              footprint.runs.count<=32_000,!footprint.runs.isEmpty,
              footprint.bounds==footprint.bounds.integral else {return .unknown("unsupported-input")}
        guard normalized.count==4,policy.allowedRectNormalized.count==4,
              normalized.allSatisfy(\.isFinite),policy.allowedRectNormalized.allSatisfy(\.isFinite),
              margin.isFinite,margin>=0,margin<=256,
              [footprint.bounds.minX,footprint.bounds.minY,footprint.bounds.width,footprint.bounds.height].allSatisfy(\.isFinite),
              footprint.bounds.width>0,footprint.bounds.height>0,footprint.bounds.width<=16384,footprint.bounds.height<=16384,
              abs(footprint.bounds.minX)<=65536,abs(footprint.bounds.minY)<=65536,
              footprint.runs.allSatisfy({$0.right>$0.left && (-65536...65536).contains($0.y) && (-65536...65536).contains($0.left) && (-65536...65536).contains($0.right)}) else {return .unknown("malformed-input")}
        let region=NativeTextExpansionPolicy.rect(normalized,page:page)
        let allowed=NativeTextExpansionPolicy.rect(policy.allowedRectNormalized,page:page)
            .insetBy(dx:0.01,dy:0.01).insetBy(dx:-0.02,dy:-0.02)
        var box=page.insetBy(dx:margin,dy:margin).intersection(region).intersection(allowed)
        if let body {box=box.intersection(body)}
        guard !box.isNull,!box.isEmpty else {return .init(status:.complete,shifts:[],reason:"empty-envelope")}
        guard [box.minX,box.minY,box.maxX,box.maxY].allSatisfy(\.isFinite) else {return .unknown("nonfinite-envelope")}
        var x0=Int(ceil(box.minX-footprint.bounds.minX)),x1=Int(floor(box.maxX-footprint.bounds.maxX))
        var y0=Int(ceil(box.minY-footprint.bounds.minY)),y1=Int(floor(box.maxY-footprint.bounds.maxY))
        if let fixedOrigin {
            let x=fixedOrigin.x-footprint.bounds.minX,y=fixedOrigin.y-footprint.bounds.minY
            guard x.isFinite,y.isFinite,x==x.rounded(),y==y.rounded(),abs(x)<=32768,abs(y)<=32768 else {return .unknown("fractional-fixed-origin")}
            x0=max(x0,Int(x));x1=min(x1,Int(x));y0=max(y0,Int(y));y1=min(y1,Int(y))
        }
        if let cluster {
            let d=cluster.0 == .top ? cluster.1-footprint.bounds.minY:cluster.1-footprint.bounds.minX
            guard d.isFinite,d==d.rounded(),abs(d)<=32768 else {return .unknown("fractional-cluster")}
            if cluster.0 == .top {y0=max(y0,Int(d));y1=min(y1,Int(d))}
            else {x0=max(x0,Int(d));x1=min(x1,Int(d))}
        }
        guard x0<=x1,y0<=y1 else {return .init(status:.complete,shifts:[],reason:"empty-envelope")}
        guard y1-y0<4096 else {return .unknown("row-budget")}
        let count=spans.count/2,step=region.height/CGFloat(count)
        guard step.isFinite,step>0 else {return .unknown("invalid-mask")}
        var candidates:[CGPoint]=[]
        for dy in y0...y1 {
            try Task.checkCancellation()
            var possible=[(x0,x1)]
            for run in footprint.runs {
                guard budget.charge(1) else {return .unknown("work-budget")}
                let y=CGFloat(run.y+dy)
                let a=max(0,Int(floor((y-region.minY)/step)))
                let b=min(count-1,Int(ceil((y+1-region.minY)/step))-1)
                if a>b {possible=[];break}
                for row in a...b {
                    let values=policy.maskIntervals(row:row)
                    guard values.count%2==0,values.count<=256,values.allSatisfy(\.isFinite),
                          budget.charge(max(1,possible.count*values.count/2)) else {return .unknown("interval-budget")}
                    var intervals:[(Int,Int)]=[]
                    for k in stride(from:0,to:values.count,by:2) {
                        let left=CGFloat(values[k])*page.width-CGFloat(run.left)
                        let right=CGFloat(values[k+1])*page.width-CGFloat(run.right)
                        guard left.isFinite,right.isFinite,abs(left)<=65536,abs(right)<=65536 else {return .unknown("invalid-interval")}
                        let lo=Int(ceil(left)),hi=Int(floor(right))
                        if lo<=hi {intervals.append((lo,hi))}
                    }
                    possible=intersection(possible,intervals)
                    if possible.isEmpty {break}
                }
                if possible.isEmpty {break}
            }
            for interval in possible {
                let n=interval.1-interval.0+1
                guard n<=256-candidates.count else {return .unknown("origin-budget")}
                for dx in interval.0...interval.1 {candidates.append(CGPoint(x:dx,y:dy))}
            }
        }
        var accepted:[CGPoint]=[]
        for point in candidates {
            try Task.checkCancellation()
            guard budget.charge(footprint.runs.count) else {return .unknown("validation-budget")}
            if validate(footprint.translated(point)) {accepted.append(point)}
        }
        return .init(status:.complete,shifts:accepted,reason:"native-validated")
    }
}
