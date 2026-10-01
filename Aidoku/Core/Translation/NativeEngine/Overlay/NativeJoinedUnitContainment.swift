import CoreGraphics
import Foundation

/// Frozen joined-unit final containment: evaluate full parent-plate footprints,
/// keep words intact, and mutate nothing until the committed layout passes again.
enum NativeJoinedUnitContainment {
    struct Shape { let lines:[CGRect]; let widthFits:Bool; let splitsWord:Bool }
    struct Candidate { let rect:CGRect; let font:Double; let pitch:Double }
    struct Input {
        let font:Double
        let pitch:Double
        let lines:[CGRect]
        let parentPlate:CGRect?
        let span:Double
        let centres:[CGPoint]
        let canGrow:Bool
        let sourceFont:Double?
        let obstacles:[CGRect]
    }
    struct Result {
        let candidate:Candidate?
        let shape:Shape?
        let before:Double
        let after:Double?
        let partial:Bool
        let searched:Bool
    }
    static func contain(_ input:Input,outside:(CGRect)->Double,measure:(Candidate)->Shape?)->Result {
        let size=input.font,ratio=input.pitch/size
        guard size>0,size.isFinite,ratio.isFinite,input.span>0,!input.centres.isEmpty else {
            return .init(candidate:nil,shape:nil,before:.infinity,after:nil,partial:false,searched:false)
        }
        func out(_ lines:[CGRect],_ dx:Double,_ dy:Double,_ fs:Double)->Double {
            if input.parentPlate != nil {
                guard !lines.isEmpty else{return .infinity}
                let u=lines.reduce(CGRect.null){$0.union($1)},pad=max(3,min(6,fs*0.3))
                return outside(CGRect(x:Double(u.minX)+dx-pad,y:Double(u.minY)+dy-pad,width:Double(u.width)+pad*2,height:Double(u.height)+pad*2))
            }
            let m=max(1.5,fs*0.2)
            return lines.reduce(0) {sum,r in sum+outside(CGRect(x:Double(r.minX)+dx-m,y:Double(r.minY)+dy-m,width:Double(r.width)+m*2,height:Double(r.height)+m*2))}
        }
        let before=out(input.lines,0,0,size)
        let ceiling=input.canGrow ? max(size,floor(min(24,size*1.25,input.sourceFont ?? size)*2)/2):size
        if before<=2 && ceiling<size+0.5 {return .init(candidate:nil,shape:nil,before:before,after:nil,partial:false,searched:false)}
        struct Trial {let out:Double;let score:Double;let candidate:Candidate}
        var best:Trial?,nearest:Trial?,fs=ceiling
        let originalCenter=input.centres[0]
        while fs>=min(size,8.5)-1e-6 {
            for scale in [1.0,0.95,0.85,0.75,0.65,0.55,0.45] {
                let width=floor(input.span*scale),tall=fs*ratio*14
                if width<fs*2 {break}
                let probe=Candidate(rect:CGRect(x:Double(originalCenter.x)-width/2,y:Double(originalCenter.y)-tall/2,width:width,height:tall),font:fs,pitch:fs*ratio)
                guard let shape=measure(probe),shape.widthFits,!shape.lines.isEmpty,!shape.splitsWord else{continue}
                let ink=shape.lines.reduce(CGRect.null){$0.union($1)}
                let step=max(1,fs*0.25),reach=fs*3,pad=input.parentPlate == nil ? 1:max(3,min(6,fs*0.3))
                for center in input.centres {
                    var dy = -reach
                    while dy<=reach+0.01 {
                        var dx = -reach
                        while dx<=reach+0.01 {
                            let ox=Double(center.x-originalCenter.x)+dx,oy=Double(center.y-originalCenter.y)+dy
                            let shifted=ink.offsetBy(dx:ox,dy:oy)
                            if !input.obstacles.contains(where:{Double(shifted.minX)-pad<Double($0.maxX) && Double(shifted.maxX)+pad>Double($0.minX) && Double(shifted.minY)-pad<Double($0.maxY) && Double(shifted.maxY)+pad>Double($0.minY)}) {
                                let count=out(shape.lines,ox,oy,fs),score=hypot(dx,dy)/fs+(size-fs)*4
                                let candidate=Candidate(rect:probe.rect.offsetBy(dx:ox,dy:oy),font:fs,pitch:fs*ratio)
                                let trial=Trial(out:count,score:score,candidate:candidate)
                                if nearest == nil || count<nearest!.out || count==nearest!.out && score<nearest!.score {nearest=trial}
                                if count<=2 && (best == nil || score<best!.score) {best=trial}
                            }
                            dx+=step
                        }
                        dy+=step
                    }
                }
            }
            if best != nil {break};fs-=0.5
        }
        let partial=input.parentPlate == nil && best == nil && nearest != nil && nearest!.out*2<=before
        if partial {best=nearest}
        guard let best,let final=measure(best.candidate),!final.lines.isEmpty else {
            return .init(candidate:nil,shape:nil,before:before,after:nil,partial:partial,searched:true)
        }
        let settled=out(final.lines,0,0,best.candidate.font)
        guard settled<=(partial ? best.out:2)+(input.parentPlate == nil ? 16:0),!final.splitsWord else {
            return .init(candidate:nil,shape:nil,before:before,after:settled,partial:partial,searched:true)
        }
        return .init(candidate:best.candidate,shape:final,before:before,after:settled,partial:partial,searched:true)
    }
}
