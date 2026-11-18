import CoreGraphics
import Foundation

// Standalone CPU harness: only the RF data carrier is substituted. The actual
// production completion helper is compiled unchanged, with no neural models.
#if MASK_FRINGE_STANDALONE
struct Ensemble100RFRegion {
    let queryID: Int
    let classID: Int
    let confidence: Double
    let bounds: CGRect
}
#endif

@main enum NativeOriginalMaskFringeCompletionTests {
    typealias Helper = NativeOriginalMaskFringeCompletion
    struct Fixture {
        let width=64, height=64
        var rgb=[UInt8](repeating:220,count:64*64*3)
        var base=[UInt8](repeating:0,count:64*64)
        var protection=[UInt8](repeating:0,count:64*64)
        var opaque=true
        var regions=[Ensemble100RFRegion(queryID:1,classID:0,confidence:0.9,
            bounds:CGRect(x:0.2,y:0.2,width:0.6,height:0.6))]
        var polygon=[CGPoint(x:16,y:16),CGPoint(x:40,y:16),CGPoint(x:40,y:40),CGPoint(x:16,y:40)]
        mutating func color(_ x:Int,_ y:Int,_ color:[UInt8]) {
            for c in 0..<3 {rgb[(y*width+x)*3+c]=color[c]}
        }
        init() {
            for y in 20..<32 {for x in 20..<24 {
                color(x,y,[220,20,20]);if y<30 {base[y*width+x]=255}
            }}
            // Same pigment AA, an unrelated green fringe and an entirely
            // absent red component distinguish evidence from generic dilation.
            for x in 20..<24 {color(x,32,[220,190,190])}
            color(24,31,[185,220,185])
            for y in 20..<24 {for x in 30..<33 {color(x,y,[220,20,20])}}
        }
        func run(chromatic:Bool=false) throws -> Helper.Result {
            try Helper.apply(rgb:rgb,width:width,height:height,base:base,protection:protection,
                owners:[.init(id:"owner",polygon:polygon,font:16,background:[220,220,220])],
                regions:regions,reach:3,includeChromatic:chromatic,verifyOpacity:{_ in opaque})
        }
    }
    static func main() throws {
        var checks=0
        func check(_ condition:Bool,_ message:String) {precondition(condition,message);checks += 1}
        let flag="AIDOKU_MASK_CHROMATIC_FRINGE", previous=getenv("AIDOKU_MASK_CHROMATIC_FRINGE").map{String(cString:$0)}
        defer {
            if let previous {setenv(flag,previous,1)} else {unsetenv(flag)}
        }
        unsetenv(flag)
        check(Helper.activePolicy==nil && Helper.cacheProjection.isEmpty,"absent flag preserves default identity")
        setenv(flag,"0",1)
        check(Helper.activePolicy==nil && Helper.cacheProjection.isEmpty,"disabled flag preserves default identity")
        setenv(flag,"1",1)
        check(Helper.cacheProjection==["originalMaskChromaticFringePolicy":"source-color-connected-component-fringe-v1"],
            "enabled final-mask policy has explicit independent identity")
        unsetenv(flag)
        let f=Fixture(), tip=31*64+21, aa=32*64+21
        let baseline=try f.run(), candidate=try f.run(chromatic:true)
        check(baseline.additions.isEmpty,"OFF must preserve neutral-only baseline")
        check(candidate.additions.contains(tip),"ON completes a mostly seeded red component")
        check(candidate.additions.contains(aa),"AA must follow measured source pigment")
        check(!candidate.additions.contains(31*64+24),"unrelated green neighbor is not red AA")
        check(!candidate.additions.contains(21*64+31),"absent component cannot borrow nearby seed")
        check(candidate.additions.allSatisfy{f.base[$0]==0},"receipt contains additions only")
        var multicolor=f;multicolor.color(24,31,[20,20,220])
        check(try multicolor.run(chromatic:true).additions.isEmpty,"touching distinct pigments are ambiguous")
        var protected=f;protected.protection[tip]=1
        check(try protected.run(chromatic:true).additions.isEmpty,"hard protection vetoes whole component")
        var unknown=f;unknown.opaque=false
        check(try unknown.run(chromatic:true).additions.isEmpty,"unverified opacity abstains")
        var ambiguous=f;ambiguous.regions.append(.init(queryID:2,classID:0,confidence:0.9,
            bounds:CGRect(x:0.2,y:0.2,width:0.6,height:0.6)))
        check(try ambiguous.run(chromatic:true).additions.isEmpty,"ambiguous RF support abstains")
        var sparse=f
        for y in 24..<30 {for x in 20..<24 {sparse.base[y*64+x]=0}}
        check(try sparse.run(chromatic:true).additions.isEmpty,"minority seed cannot nominate entire glyph")
        var foreign=f
        foreign.polygon=[CGPoint(x:16,y:16),CGPoint(x:40,y:16),CGPoint(x:40,y:30),CGPoint(x:16,y:30)]
        check(try foreign.run(chromatic:true).additions.isEmpty,"complete component must belong to actual owner")
        var noRF=f;noRF.regions=[]
        check(try noRF.run(chromatic:true).additions.isEmpty,"owner bbox alone cannot erase")
        var neutral=f
        for y in 20..<32 {for x in 20..<24 {neutral.color(x,y,[20,20,20])}}
        check(try neutral.run().additions==neutral.run(chromatic:true).additions,
            "chromatic option preserves existing neutral completion")
        print("ORIGINAL_MASK_FRINGE_PASS checks=\(checks) models=0 images=0")
    }
}
