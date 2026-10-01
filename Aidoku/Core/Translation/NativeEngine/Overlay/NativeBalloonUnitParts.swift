import CoreGraphics
import Foundation

/// A contained joined two-member unit may grow by assigning one whole-word
/// translated part to each original member, in the source's reading order.
enum NativeBalloonUnitParts {
    struct Entry {
        let id:String
        let text:String
        let members:[CGRect]
        let font:Double
        let ratio:Double
        let interiorSpan:Double
        let isRoot:Bool
        let obstacles:[CGRect]
        let panel:CGRect?
        let coverage:[CGRect]
    }
    struct Measurement {let lines:[CGRect];let scrollWidth:Double;let clientWidth:Double;let splits:Bool}
    struct Part {let text:String;let frame:CGRect;let ink:CGRect;let lines:[CGRect]}
    struct Result {let font:Double;let originalFont:Double;let firstUTF16Length:Int;let parts:[Part];let panel:CGRect?;let coverage:[CGRect]}
    typealias Measure = (String,CGRect,Double,Double)->Measurement?
    static func place(_ entry:Entry,measure:Measure,outside:(CGRect)->Double)->Result? {
        guard entry.members.count==2,entry.font>0,!entry.text.isEmpty,
              !entry.text.contains("\n"),!entry.text.contains("\r") else {return nil}
        let a=entry.members[0],b=entry.members[1]
        let overlap=min(a.maxY,b.maxY)-max(a.minY,b.minY)
        guard overlap<=min(a.height,b.height)*0.2,a.minY<=b.minY else {return nil}
        let text=entry.text.trimmingCharacters(in:.whitespacesAndNewlines),source=text as NSString
        let share=Double(a.width*a.height/(a.width*a.height+b.width*b.height))
        let regex=try! NSRegularExpression(pattern:" +")
        struct Break {let index:Int;let first:String;let second:String;let score:Double}
        func visibleCount(_ part:String)->Int {part.unicodeScalars.filter {
            (0xAC00...0xD7A3).contains($0.value)||(65...90).contains($0.value)||(97...122).contains($0.value)||(48...57).contains($0.value)
        }.count}
        let breaks=regex.matches(in:text,range:NSRange(location:0,length:source.length)).enumerated().compactMap {index,match -> Break? in
            let first=source.substring(to:match.range.location),second=source.substring(from:NSMaxRange(match.range))
            guard visibleCount(first)>=2,visibleCount(second)>=2 else {return nil}
            let punctuation=first.last.map {".!?…~,".contains($0)} ?? false
            return .init(index:index,first:first,second:second,score:abs(Double(first.utf16.count)/Double(first.utf16.count+second.utf16.count)-share)-(punctuation ? 0.15:0))
        }.sorted {$0.score==$1.score ? $0.index<$1.index:$0.score<$1.score}.prefix(2)
        guard !breaks.isEmpty else {return nil}
        func meets(_ p:CGRect,_ q:CGRect,_ gap:Double)->Bool {
            p.minX-gap<q.maxX && p.maxX+gap>q.minX && p.minY-gap<q.maxY && p.maxY+gap>q.minY
        }
        func part(_ text:String,_ member:CGRect,_ font:Double,_ prior:[CGRect])->Part? {
            let tall=font*entry.ratio*8
            for scale in [0.9,0.75,0.6,0.5,0.4,0.3,0.25,0.2] {
                let width=floor(entry.interiorSpan*scale)
                if width<font*2 {break}
                let frame=CGRect(x:Double(member.midX)-width/2,y:Double(member.midY)-tall/2,width:width,height:tall)
                let shown=text+(prior.isEmpty ? " ":"")
                guard let m=measure(shown,frame,font,font*entry.ratio),!m.lines.isEmpty,
                      m.scrollWidth<=m.clientWidth+1,!m.splits else {continue}
                let ink=m.lines.reduce(CGRect.null) {$0.union($1)}
                let margin=entry.isRoot ? max(1.5,font*0.2):max(3,min(6,font*0.3))
                let out=entry.isRoot ? m.lines.reduce(0.0) {$0+outside($1.insetBy(dx:-margin,dy:-margin))}
                    :outside(ink.insetBy(dx:-margin,dy:-margin))
                if out<=2 && !entry.obstacles.contains(where:{meets(ink,$0,entry.isRoot ? 1:margin)}) &&
                    !prior.contains(where:{meets(ink,$0,font*0.4)}) {
                    return .init(text:shown,frame:frame,ink:ink,lines:m.lines)
                }
            }
            return nil
        }
        var font=floor(min(entry.font*1.5,24)*2)/2
        while font>=entry.font+0.5 {
            for candidate in breaks {
                guard let first=part(candidate.first,a,font,[]),let second=part(candidate.second,b,font,[first.ink]) else {continue}
                var panel=entry.panel,coverage=entry.coverage
                if !entry.isRoot,let existing=panel {
                    if coverage.isEmpty {coverage=[existing]}
                    let pad=max(3,min(6,font*0.3)),regions=[first.ink,second.ink].map {$0.insetBy(dx:-pad,dy:-pad)}
                    coverage+=regions;panel=regions.reduce(existing) {$0.union($1)}
                }
                return .init(font:font,originalFont:entry.font,firstUTF16Length:candidate.first.utf16.count,parts:[first,second],panel:panel,coverage:coverage)
            }
            font-=0.5
        }
        return nil
    }
}
