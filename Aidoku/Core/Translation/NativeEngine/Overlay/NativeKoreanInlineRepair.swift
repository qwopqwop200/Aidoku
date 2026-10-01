import CoreGraphics
import Foundation

/// Two bounded font probes and one punctuation-only padding proposal. Original
/// translation text and card geometry are immutable throughout this policy.
enum NativeKoreanInlineRepair {
    struct Profile { let lines: Int; let breaks: [Int]; let badStarts: [Int]; let badEnds: [Int]; let ink: [CGRect] }
    struct Entry {
        let text: String
        let card: CGRect
        let exclusions: [CGRect]
        let font: Double
        let padding: [Double]
        var vertical = false
        var wrappingScript = "korean"
    }
    struct Candidate { let font: Double; let padding: [Double]; let strictPunctuation: Bool }
    struct Measurement { let profile: Profile?; let fits: Bool }
    struct Result { let candidate: Candidate; let wrapAccepted: Bool; let punctuationAccepted: Bool; let probes: Int }
    typealias Measure = (Candidate) -> Measurement?
    static func repair(_ e:Entry,characterBudget:inout Int,minimumFont:Double=5,
                       widestWord:(String,Double)->Double,measure:Measure)->Result {
        var font=e.font,padding=e.padding,wrapAccepted=false,punctuationAccepted=false,probes=0
        guard !e.vertical,e.wrappingScript=="korean",e.padding.count==4 else {
            return .init(candidate:.init(font:font,padding:padding,strictPunctuation:false),wrapAccepted:false,punctuationAccepted:false,probes:0)
        }
        let count=e.text.utf16.count
        func profile(_ f:Double,_ p:[Double],strict:Bool=false)->Measurement? {
            probes+=1;return measure(.init(font:f,padding:p,strictPunctuation:strict))
        }
        func penalty(_ p:Profile)->Int {p.badStarts.count*4+p.badEnds.count*4+p.breaks.count}
        func obstacle(_ r:CGRect)->Bool {e.exclusions.contains {min(r.maxX,$0.maxX)-max(r.minX,$0.minX)>0.5 && min(r.maxY,$0.maxY)-max(r.minY,$0.minY)>0.5}}
        func violations(_ p:Profile)->Int {p.ink.filter {$0.minX<e.card.minX-0.5 || $0.minY<e.card.minY-0.5 || $0.maxX>e.card.maxX+0.5 || $0.maxY>e.card.maxY+0.5 || obstacle($0)}.count}
        let available=Double(e.card.width)-padding[1]-padding[3]
        if count<=180,widestWord(e.text,font)>available,count<=characterBudget {
            characterBudget-=count
            if let original=profile(font,padding)?.profile,penalty(original)>0 {
                var chosen=original,chosenFont=font
                let originalViolations=violations(original)
                for ratio in [0.94,0.88] {
                    let size=max(ceil(font*0.88*4)/4,floor(font*ratio*4)/4)
                    if size<minimumFont {continue}
                    guard let measured=profile(size,padding),measured.fits,let candidate=measured.profile else {continue}
                    if candidate.lines<=original.lines,candidate.badStarts.count<=original.badStarts.count,
                       candidate.badEnds.count<=original.badEnds.count,candidate.breaks.allSatisfy(original.breaks.contains),
                       violations(candidate)<=originalViolations,penalty(candidate)<penalty(chosen) {
                        chosen=candidate;chosenFont=size
                        if penalty(chosen)==0 {break}
                    }
                }
                wrapAccepted=chosenFont<font;font=chosenFont
            }
        }
        if count<=8,!e.text.contains(where:{$0.isWhitespace}),let original=profile(font,padding)?.profile,!original.badStarts.isEmpty {
            var proposal=padding;proposal[1]=min(1,padding[1]);proposal[3]=min(1,padding[3])
            if let measured=profile(font,proposal,strict:true),measured.fits,let candidate=measured.profile,
               candidate.lines<=original.lines,candidate.badStarts.count<original.badStarts.count,
               candidate.badEnds.count<=original.badEnds.count,candidate.breaks.allSatisfy(original.breaks.contains),
               !candidate.ink.contains(where:{$0.minX<e.card.minX+0.9 || $0.minY<e.card.minY-0.5 || $0.maxX>e.card.maxX-0.9 || $0.maxY>e.card.maxY+0.5 || obstacle($0)}) {
                padding=proposal;punctuationAccepted=true
            }
        }
        return .init(candidate:.init(font:font,padding:padding,strictPunctuation:punctuationAccepted),wrapAccepted:wrapAccepted,punctuationAccepted:punctuationAccepted,probes:probes)
    }
}
