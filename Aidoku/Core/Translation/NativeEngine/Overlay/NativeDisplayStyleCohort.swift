import Foundation
import CoreGraphics

/// Frozen final display-style majority pass (BrowserOverlayView13874–14103).
/// Collection is immutable: every decision observes the pre-pass styles.
enum NativeDisplayStyleCohort {
    struct Member: Codable {
        var id: String
        var sampled: [Double]
        var fill: [Double]
        var stroke: [Double]? = nil
        var sampledStroke: [Double]? = nil
        var sampledBack: [Double]? = nil
        var strokeSource = ""
        var glyph: Double? = nil
        var font = 10.0
        var outlined = false
        var locked = false
        var strokeLocked = false
        var fillLocked = false
        var ringKind: String? = nil
        var ringCore: [Double]? = nil
        var ringSurface: [Double]? = nil
        var ringPlateTo = false
        var plate: [Double]? = nil
        var backing: [Double]? = nil
        var ink: CGRect
        var ownerRect: CGRect? = nil
        var ownerIsNode = false
        var ownerAlone = true
    }
    struct Decision: Codable {
        let id: String
        var fill: [Double]? = nil
        var plate: [Double]? = nil
        var dropStroke = false
        var minimumContrast: Double
    }
    struct Panel {
        var rect: CGRect
        var color: [Double]?
    }
    struct BackingInput {
        var ink: CGRect
        var frame: CGRect
        var imageWidth: Double
        var imageHeight: Double
        var originX: Double
        var originY: Double
        var scaleX: Double
        var scaleY: Double
        var width: Int
        var height: Int
        var luminance: [UInt8]?
        /// Non-Uint8 original luminance arrays are supported without quantizing.
        var fractionalLuminance: [Double]? = nil
        var connected = true
        var fallback: [Double]? = nil
    }
    final class BackingBudget {
        var samples: Int
        init(_ samples: Int = 600_000) { self.samples = samples }
    }
    static func valid(_ rgb: [Double]?) -> Bool {
        guard let rgb else { return false }
        return rgb.count == 3 && rgb.allSatisfy { $0.isFinite && $0 >= 0 && $0 <= 255 }
    }
    static func luminance(_ rgb: [Double]) -> Double {
        let channels=rgb.map {v -> Double in let s=v/255;return s<=0.04045 ? s/12.92:pow((s+0.055)/1.055,2.4)}
        return 0.2126*channels[0]+0.7152*channels[1]+0.0722*channels[2]
    }
    static func lab(_ rgb:[Double]) -> [Double] {
        let c=rgb.map {v -> Double in let s=v/255;return s<=0.04045 ? s/12.92:pow((s+0.055)/1.055,2.4)}
        func f(_ x:Double)->Double {x>0.008856 ? cbrt(x):7.787*x+16.0/116}
        let x=f((0.4124*c[0]+0.3576*c[1]+0.1805*c[2])/0.95047)
        let y=f(0.2126*c[0]+0.7152*c[1]+0.0722*c[2])
        let z=f((0.0193*c[0]+0.1192*c[1]+0.9505*c[2])/1.08883)
        return [116*y-16,500*(x-y),200*(y-z)]
    }
    static func delta(_ a:[Double],_ b:[Double])->Double {
        let p=lab(a),q=lab(b)
        return hypot(hypot(p[0]-q[0],p[1]-q[1]),p[2]-q[2])
    }
    static func ratio(_ a:Double,_ b:Double)->Double {(max(a,b)+0.05)/(min(a,b)+0.05)}
    static func worst(_ rgb:[Double],_ range:[Double])->Double {
        let l=luminance(rgb);return min(ratio(l,range[0]),ratio(l,range[1]))
    }
    static func best(_ rgb:[Double],_ range:[Double])->Double {
        let l=luminance(rgb);return max(ratio(l,range[0]),ratio(l,range[1]))
    }
    static func gap(_ a:[Double],_ b:[Double])->Double {max(abs(a[0]-b[0]),abs(a[1]-b[1]),abs(a[2]-b[2]))}
    static func spread(_ c:[Double])->Double {c.max()!-c.min()!}
    static func hueGap(_ a:[Double],_ b:[Double])->Double {
        let p=lab(a),q=lab(b),d=abs(atan2(p[2],p[1])-atan2(q[2],q[1]))*180/Double.pi
        return min(d,360-d)
    }
    static func meets(_ a:CGRect,_ b:CGRect)->Bool {a.minX<b.maxX && b.minX<a.maxX && a.minY<b.maxY && b.minY<a.maxY}
    static func backing(_ input:BackingInput,panels:[Panel],budget:BackingBudget)->[Double]? {
        let values=[input.originX,input.originY,Double(input.width),Double(input.height),input.scaleX,input.scaleY,
                    input.imageWidth,input.imageHeight,Double(input.frame.minX),Double(input.frame.minY),
                    Double(input.frame.width),Double(input.frame.height)]
        var count=0,counts=[Int](repeating:0,count:256),fractions:[Double]=[]
        if budget.samples>0,input.connected,(input.luminance != nil || input.fractionalLuminance != nil),
           values.allSatisfy(\.isFinite),input.ink.width>0,input.ink.height>0,input.frame.width != 0,input.frame.height != 0 {
            func px(_ x:CGFloat)->Double {((Double(x-input.frame.minX))*input.imageWidth/Double(input.frame.width)-input.originX)*input.scaleX}
            func py(_ y:CGFloat)->Double {((Double(y-input.frame.minY))*input.imageHeight/Double(input.frame.height)-input.originY)*input.scaleY}
            let l=max(0,Int(floor(px(input.ink.minX)))),t=max(0,Int(floor(py(input.ink.minY))))
            let r=min(input.width,Int(ceil(px(input.ink.maxX)))),b=min(input.height,Int(ceil(py(input.ink.maxY))))
            let full=(px(input.ink.maxX)-px(input.ink.minX))*(py(input.ink.maxY)-py(input.ink.minY))
            if r>l,b>t,Double((r-l)*(b-t))>=full*0.8 {
                let step=max(1,Int(floor(sqrt(Double((r-l)*(b-t))/20_000))))
                if let luminance=input.luminance,luminance.count>=input.width*input.height {
                    for y in stride(from:t,to:b,by:step) {for x in stride(from:l,to:r,by:step) {counts[Int(luminance[y*input.width+x])]+=1;count+=1}}
                } else if let luminance=input.fractionalLuminance,luminance.count>=input.width*input.height {
                    for y in stride(from:t,to:b,by:step) {for x in stride(from:l,to:r,by:step) {fractions.append(luminance[y*input.width+x]/255)}}
                    count=fractions.count
                }
                budget.samples-=count
            }
        }
        var range:[Double]?
        if count>=16 {
            let low=Int(floor(Double(count-1)*0.02)),high=Int(ceil(Double(count-1)*0.98))
            if fractions.isEmpty {
                func rank(_ k:Int)->Double {var seen=0;for v in 0..<255 {seen+=counts[v];if seen>k {return Double(v)/255}};return 1}
                range=[rank(low),rank(high)]
            } else {fractions.sort();range=[fractions[low],fractions[high]]}
        } else if let fallback=input.fallback,fallback.count==2,fallback.allSatisfy(\.isFinite) {range=[min(fallback[0],fallback[1]),max(fallback[0],fallback[1])]}
        guard var result=range else{return nil}
        for panel in panels where meets(input.ink,panel.rect) {
            if let color=panel.color,valid(color) {let l=luminance(color);result=[min(result[0],l),max(result[1],l)]}
        }
        return result
    }
    static func consensus(_ colors:[[Double]])->[Double]? {
        var chosen:[Double]?,support=0,cost=Double.infinity
        for a in colors {
            var n=0,d=0.0
            for b in colors {let x=delta(a,b);if x<=10 {n+=1;d+=x}}
            if n>support || n==support && d<cost {chosen=a;support=n;cost=d}
        }
        return support>=2 && support*2>colors.count ? chosen:nil
    }
    static func decisions(_ members:[Member])->[Decision] {
        var result:[Decision]=[]
        for (index,m) in members.enumerated() {
            guard !m.locked,let backing=m.backing,backing.count==2 else{continue}
            let partners=members.enumerated().filter {i,o in
                i != index && m.outlined==o.outlined && delta(m.sampled,o.sampled)<10 &&
                !(m.glyph.map {$0>0} == true && o.glyph.map {$0>0} == true && max(m.glyph!,o.glyph!)>1.8*min(m.glyph!,o.glyph!))
            }.map(\.element)
            guard !partners.isEmpty else{continue}
            let required=m.font>=18 ? 3.0:4.5
            let fill=partners.count>=2 ? consensus(partners.map(\.fill)):
                (delta(partners[0].fill,partners[0].sampled)<=10 && delta(m.fill,m.sampled)>10 ? partners[0].fill:nil)
            var newFill:[Double]?,newPlate:[Double]?
            if let fill,!m.fillLocked,delta(fill,m.fill)>10,delta(fill,m.sampled)<delta(m.fill,m.sampled),
               !(valid(m.ringCore) && gap(m.ringCore!,fill)>48),!(spread(m.fill)>=40 && spread(fill)<24),
               !(spread(m.fill)>=60 && hueGap(m.fill,fill)>45) {
                let keptStroke=m.stroke != nil && m.strokeLocked
                if worst(fill,backing)>=required && (!keptStroke || ratio(luminance(fill),luminance(m.stroke!))>=3) {newFill=fill}
                else if let currentPlate=m.plate,!m.ownerIsNode,!m.ringPlateTo {
                    let plated=partners.filter {$0.plate != nil && !$0.ownerIsNode && delta($0.fill,fill)<=10}
                    let plate=plated.count>=2 ? consensus(plated.map {$0.plate!}):nil
                    let surface=m.ringSurface.flatMap {$0.count>=4 && $0[3]==1 ? Array($0.prefix(3)):nil}
                    let clear=plate != nil && members.enumerated().allSatisfy {i,o in
                        i==index || m.ownerRect.map {!meets(o.ink,$0)} == true || ratio(luminance(o.fill),luminance(plate!))>=3
                    }
                    let range=plate.map {[luminance($0),luminance($0)]}
                    let flips=plate.map {(luminance(m.fill)>luminance(currentPlate)) != (luminance(fill)>luminance($0))} ?? false
                    if let plate,let range,m.ownerAlone,clear,(!flips || m.ringKind=="outline"),delta(plate,currentPlate)>12,
                       worst(fill,range)>=required,!(surface.map {gap($0,currentPlate)<=24} ?? false),
                       (!keptStroke || best(m.stroke!,range)<=1.5 || ratio(luminance(fill),luminance(m.stroke!))>=3) {
                        newFill=fill;newPlate=plate
                    }
                }
            }
            let effectiveBacking=newPlate.map {[luminance($0),luminance($0)]} ?? backing,ownFill=newFill ?? m.fill
            var drop=false
            if let stroke=m.stroke,!m.strokeLocked,worst(ownFill,effectiveBacking)>=required {
                let bare=partners.filter {$0.stroke==nil},majority=bare.count>=2*(partners.count-bare.count)
                let plateNow=newPlate ?? m.plate
                let faint=plateNow.map {gap(stroke,$0)<=24} ?? (best(stroke,effectiveBacking)<=1.1)
                let shared=m.sampledStroke != nil && m.ringKind != "outline" &&
                    bare.filter {$0.sampledStroke.map {gap($0,m.sampledStroke!)<=40} ?? false}.count*3>=bare.count*2
                let backL=m.sampledBack.flatMap {valid($0) ? luminance($0):nil} ?? .nan
                let paper=m.ringKind=="paper" || m.strokeSource=="preserved" && m.ringKind != "outline" &&
                    valid(m.sampledBack) && gap(stroke,m.sampledBack!)<=48 && backL>=effectiveBacking[0]-0.08 && backL<=effectiveBacking[1]+0.08
                if majority,bare.count>=1,(faint || bare.count>=2 && (m.strokeSource=="readability-outline" || paper || shared)) {drop=true}
            }
            if drop || newFill != nil {result.append(.init(id:m.id,fill:newFill,plate:newPlate,dropStroke:drop,minimumContrast:worst(ownFill,effectiveBacking)))}
        }
        return result
    }
}
