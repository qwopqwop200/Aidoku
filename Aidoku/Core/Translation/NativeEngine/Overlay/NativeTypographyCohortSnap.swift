import CoreGraphics
import Foundation

/// Frozen late cohortSnap; source rows and line estimates are captured before
/// trials while live font and clearance queries follow every accepted member.
enum NativeTypographyCohortSnap {
    struct Member {
        let id: String
        let source: CGRect
        let vertical: Bool
        let glyph: CGFloat
        let line: CGFloat
        let font: CGFloat
        let base: CGFloat
        let readablePeer: CGFloat
        let readableHeld: CGFloat
        let condensedFrom: CGFloat?
        let key: String
        var captured = true
    }
    struct Input {
        let id: String
        let text: String
        let bounds: [CGFloat]?
        let frame: [CGFloat]?
        let glyph: CGFloat
        let font: CGFloat
        let vertical: Bool
        let rotation: Bool
        let nearRotation: Bool
        let sourceRotation: Bool
        let hidden: Bool
        let automatic: Bool
        let displayGrowth: Bool
        let rotatingPanel: Bool
        let sampledInk: [Double]?
        let sampledBackground: [Double]?
        let appliedBackground: [Double]?
        let outlined: Bool
        let growthFonts: [CGFloat]
        let readablePeer: CGFloat?
        let condensedFrom: CGFloat?
    }
    static func capture(_ input: Input) -> Member? {
        guard !input.rotation,!input.nearRotation,!input.sourceRotation,!input.hidden,input.automatic,
              !input.displayGrowth,!input.rotatingPanel,
              let b=input.bounds,b.count==4,b.allSatisfy(\.isFinite),
              let f=input.frame,f.count==4,input.glyph>0,input.glyph<40,input.font>0,
              input.text.unicodeScalars.contains(where: { scalar in
                  switch scalar.properties.generalCategory {
                  case .uppercaseLetter,.lowercaseLetter,.titlecaseLetter,.modifierLetter,.otherLetter,
                       .decimalNumber,.letterNumber,.otherNumber: return true
                  default: return false
                  }
              }) else { return nil }
        let source=CGRect(x:f[0]+b[0]*f[2],y:f[1]+b[1]*f[3],width:b[2]*f[2],height:b[3]*f[3])
        let thickness=input.vertical ? b[2]*f[2]:b[3]*f[3]
        let line=thickness>0 && thickness<=1.7*input.glyph ? thickness:input.glyph
        let plate=input.appliedBackground
        let label=plate?.count==3 && plate!.allSatisfy(\.isFinite) && (plate!.max()!-plate!.min()!)>40 ? "label":""
        func colorClass(_ rgb:[Double]?) -> String {
            guard let rgb,rgb.count>=3,rgb.prefix(3).allSatisfy({$0.isFinite && $0>=0 && $0<=255}) else{return "?"}
            let r=rgb[0]/255,g=rgb[1]/255,b=rgb[2]/255,high=max(r,g,b),low=min(r,g,b)
            if (high-low)*255>60 {
                let h=high==r ? ((g-b)/(high-low)+6).truncatingRemainder(dividingBy:6):high==g ? (b-r)/(high-low)+2:(r-g)/(high-low)+4
                return "h"+String(Int(floor((h*60+30).truncatingRemainder(dividingBy:360)/60)))
            }
            let light=0.299*r+0.587*g+0.114*b
            return light<0.3 ? "dark":light>0.72 ? "light":"mid"
        }
        let key=[input.vertical ? "v":"h",colorClass(input.sampledInk),input.outlined ? "outline":"",colorClass(input.sampledBackground),label].joined(separator:"|")
        return .init(id:input.id,source:source,vertical:input.vertical,glyph:input.glyph,line:line,font:input.font,
            base:input.growthFonts.filter {$0.isFinite && $0>0}.min() ?? .infinity,
            readablePeer:input.readablePeer.flatMap {$0>0 ? $0:nil} ?? .infinity,
            readableHeld:input.readablePeer != nil ? 1:0,condensedFrom:input.condensedFrom,key:key)
    }
    struct Result {
        var changed: [Int: [CGFloat]] = [:]
        var held: [Int: [CGFloat]] = [:]
        var sourceRows: [[Int]] = []
    }
    static func snap<Snapshot>(members: [Member], rowGroups: [[Int]], font: (Int)->CGFloat,
        clearance:(Int)->CGFloat, inconsistent:()->Int, snapshot:(Int)->Snapshot,
        restore:(Int,Snapshot)->Void, scale:(Int,CGFloat)->Bool) -> Result {
        var result=Result()
        func spread(_ values:[CGFloat])->CGFloat {
            guard let low=values.min(),let high=values.max(),low>0 else{return .infinity}
            return high/low
        }
        func gap(_ a:Member,_ b:Member)->CGFloat {
            max(a.source.minX-b.source.maxX,b.source.minX-a.source.maxX,
                a.source.minY-b.source.maxY,b.source.minY-a.source.maxY)
        }
        let captureIndices=members.indices.filter {members[$0].captured}
        var cohorts:[[Int]]=[]
        if captureIndices.count<=256 {
            let sorted=captureIndices.sorted {a,b in
                if members[a].key != members[b].key{return members[a].key.compare(members[b].key,locale:Locale(identifier:"en_US")) == .orderedAscending}
                if members[a].line != members[b].line{return members[a].line<members[b].line}
                return members[a].id.compare(members[b].id,locale:Locale(identifier:"en_US")) == .orderedAscending
            }
            for i in sorted {
                if let n=cohorts.firstIndex(where:{g in g.allSatisfy {j in members[i].key==members[j].key &&
                    max(members[i].line,members[j].line)/min(members[i].line,members[j].line)<=1.25}}) {cohorts[n].append(i)}
                else{cohorts.append([i])}
            }
            cohorts=cohorts.filter{$0.count>=2}
        }
        for i in captureIndices {
            for j in captureIndices where j>i {
                let a=members[i],b=members[j]
                guard a.vertical==b.vertical,max(a.line,b.line)/min(a.line,b.line)<=1.2 else{continue}
                let cross=a.vertical ? min(a.source.maxX,b.source.maxX)-max(a.source.minX,b.source.minX) :
                    min(a.source.maxY,b.source.maxY)-max(a.source.minY,b.source.minY)
                let side=a.vertical ? max(a.source.minY,b.source.minY)-min(a.source.maxY,b.source.maxY) :
                    max(a.source.minX,b.source.minX)-min(a.source.maxX,b.source.maxX)
                let ta=a.vertical ? a.source.width:a.source.height,tb=b.vertical ? b.source.width:b.source.height
                if cross>0.6*min(ta,tb),side<3*max(ta,tb){result.sourceRows.append([i,j])}
            }
        }
        func mismatch(_ groups:[[Int]])->Int {
            groups.reduce(0){total,g in
                var count=total
                for a in g.indices {for b in g.indices where b>a {if spread([font(g[a]),font(g[b])])>1.15{count+=1}}}
                return count
            }
        }
        func attempt(_ i:Int,_ size:CGFloat,_ shrink:Bool)->Bool {
            let rows=(rowGroups+result.sourceRows).filter{$0.contains(i)}
            let pb=inconsistent(),rb=mismatch(rows),spreads=rows.map{spread($0.map(font))}
            let mates=shrink ? captureIndices.filter {j in
                j != i && members[j].key==members[i].key && max(members[j].line,members[i].line)/min(members[j].line,members[i].line)<=1.25 &&
                gap(members[i],members[j])<=1.5*max(members[i].line,members[j].line,members[i].glyph,members[j].glyph) && font(j)>=font(i)-0.01
            }:[]
            let previousClearance=clearance(i),saved=snapshot(i),oldFont=font(i)
            guard scale(i,size),abs(font(i)-oldFont)>=0.01 else {restore(i,saved);return false}
            let pa=inconsistent(),ra=mismatch(rows)
            let okay=pa<=pb && ra<=rb && rows.enumerated().allSatisfy {k,g in spread(g.map(font))<=max(spreads[k],1.15)+0.001} &&
                (font(i)>=8.5-0.01 || font(i)>=oldFont) && (!shrink || pa<pb || ra<rb) &&
                mates.allSatisfy{spread([font($0),font(i)])<=1.1+0.001} &&
                (shrink || clearance(i)>=min(previousClearance,max(2,0.2*font(i))))
            if !okay{restore(i,saved)}
            return okay
        }
        func condensedFloor(_ i:Int,_ size:CGFloat)->CGFloat {
            guard let from=members[i].condensedFrom,from>0 else{return size}
            let floor=ceil(from*1.06*4)/4
            if size<floor-0.01 {result.held[i]=[size,floor];return floor}
            return size
        }
        func giveBack(_ i:Int,_ size:CGFloat)->CGFloat {max(size,ceil(0.93*font(i)*4)/4)}
        for cohort in cohorts {
            guard spread(cohort.map(font))>1.2 else{continue}
            let before=inconsistent(),saved=cohort.map{($0,snapshot($0))}
            let sorted=cohort.map(font).sorted()
            let target=floor((sorted[sorted.count/2]+sorted[(sorted.count-1)/2])/2*4+0.5)/4
            let ascending=cohort.enumerated().sorted {a,b in font(a.element)==font(b.element) ? a.offset<b.offset:font(a.element)<font(b.element)}.map(\.element)
            for i in ascending {
                let f=font(i),from=min(f,members[i].readablePeer)
                guard from*1.1<target,target>=f+0.25 else{continue}
                for step:CGFloat in [1,0.75,0.5] {
                    let size=floor((f+(target-f)*step)*4)/4
                    if size<max(from*1.08,f+0.25){break}
                    if attempt(i,size,false){break}
                }
            }
            let ratios=cohort.map{font($0)/members[$0].line}.sorted()
            let ratio=(ratios[ratios.count/2]+ratios[(ratios.count-1)/2])/2
            let descending=cohort.enumerated().sorted{a,b in font(a.element)==font(b.element) ? a.offset<b.offset:font(a.element)>font(b.element)}.map(\.element)
            for i in descending {
                let f=font(i),m=members[i]
                guard f>target*1.1,cohort.contains(where:{j in j != i && gap(m,members[j])<=3*max(m.line,members[j].line) && font(j)*1.2<f}) else{continue}
                let size=min(f,giveBack(i,condensedFloor(i,max(target,floor(ratio*m.line*4)/4,min(m.base,m.font),8.5,(m.readableHeld>0 ? min(font(i),8.5):0),
                    ceil(0.7*max(m.line,m.glyph)*4)/4,ceil(0.8*f*4)/4))))
                if size<f-0.01{_ = attempt(i,size,true)}
            }
            guard cohort.contains(where:{abs(font($0)-members[$0].font)>0.01}) else{continue}
            if inconsistent()>before {for (i,old) in saved{restore(i,old)}}
        }
        let pairs=result.sourceRows.enumerated().sorted {a,b in
            let sa=spread(a.element.map(font)),sb=spread(b.element.map(font))
            return sa==sb ? a.offset<b.offset:sa>sb
        }.map(\.element)
        for pair in pairs {
            guard spread(pair.map(font))>1.15+0.001 else{continue}
            let small=font(pair[0])<=font(pair[1]) ? pair[0]:pair[1],large=small==pair[0] ? pair[1]:pair[0]
            let f=font(small),goal=floor(font(large)*4)/4
            for step:CGFloat in [1,0.5] {
                let size=floor((f+(goal-f)*step)*4)/4
                if size<f*1.05{break}
                if attempt(small,size,false){break}
            }
            if spread(pair.map(font))<=1.15+0.001{continue}
            let big=font(large),low=font(small),m=members[large]
            let size=min(big,giveBack(large,condensedFloor(large,max(floor(low*1.15*4)/4,8.5,(m.readableHeld>0 ? min(font(large),8.5):0),
                ceil(0.7*max(m.line,m.glyph)*4)/4,ceil(0.85*big*4)/4))))
            if size<big-0.01{_ = attempt(large,size,true)}
        }
        for i in captureIndices where abs(font(i)-members[i].font)>0.01 {result.changed[i]=[members[i].font,font(i)]}
        return result
    }
}
