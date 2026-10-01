import CoreGraphics
import Foundation

/// A final background rectangle may admit a wider transparent text flow without
/// changing that rectangle, its erasure, the chosen font, or the wording.
enum NativeCaptionFixedBoxReflow {
    struct Profile {
        let lines:Int;let breaks:[Int];let badStarts:[Int];let badEnds:[Int]
        let hangulIsolated:Int;let punctuationOnly:Int;let ink:[CGRect]
    }
    struct Glyph {let character:Unicode.Scalar;let offset:Int;let rect:CGRect}
    struct Entry {
        let text:String;let x:Double;let width:Double;let paddingLeft:Double;let paddingRight:Double
        let panel:CGRect;let padding:Double;let obstacles:[CGRect]
        var preserveBackground=true;var opacity=1.0;var automaticRecovery=true;var vertical=false;var script="korean"
    }
    struct Measurement {let profile:Profile;let fits:Bool}
    struct Result {let x:Double;let width:Double;let originalWidth:Double;let originalLines:Int;let finalLines:Int;let scale:Double}
    final class Session {var characters:Int;init(characters:Int=8192){self.characters=characters}}
    static func profile(glyphs:[Glyph],pitch:Double)->Profile? {
        guard !glyphs.isEmpty else {return nil}
        let closing=Set("、。，．,.！？!?…‥）)]」』】》〉:;".unicodeScalars),opening=Set("（([「『【《〈".unicodeScalars)
        var rows:[Double]=[],members:[[Glyph]]=[],breaks:[Int]=[],ink:[CGRect]=[]
        var previousRow = -1,previousLeft = -Double.infinity,joined=false
        for glyph in glyphs {
            if CharacterSet.whitespacesAndNewlines.contains(glyph.character)||glyph.character.value==0xFEFF {joined=false;continue}
            let axis=Double(glyph.rect.minY)
            let row=rows.firstIndex(where:{abs($0-axis)<=pitch*0.4}) ?? rows.count
            if row==rows.count {rows.append(axis);members.append([])}
            members[row].append(glyph);ink.append(glyph.rect)
            if joined && (row != previousRow || Double(glyph.rect.minX)<previousLeft-0.5) {breaks.append(glyph.offset)}
            previousRow=row;previousLeft=Double(glyph.rect.minX);joined=true
        }
        guard !rows.isEmpty else {return nil}
        let badStarts=members.compactMap {row in row.first.flatMap {closing.contains($0.character) ? $0.offset:nil}},badEnds=members.compactMap {row in row.last.flatMap {opening.contains($0.character) ? $0.offset:nil}}
        func textOf(_ row:[Glyph])->String {
            guard let first=row.first,let last=row.last else {return ""}
            return String(String.UnicodeScalarView(glyphs.filter {$0.offset>=first.offset && $0.offset<=last.offset}.map(\.character)))
        }
        let isolated=members.filter {row in
            let normalized=textOf(row).precomposedStringWithCanonicalMapping.unicodeScalars.filter {
                !CharacterSet.punctuationCharacters.contains($0) && !CharacterSet.whitespacesAndNewlines.contains($0) && $0.value != 0xFEFF
            }
            return normalized.count==1 && normalized.first.map {String($0).range(of:"^\\p{script=Hangul}$",options:.regularExpression) != nil} == true
        }.count
        let punctuation=members.filter {row in textOf(row).unicodeScalars.allSatisfy {CharacterSet.punctuationCharacters.contains($0) || CharacterSet.whitespacesAndNewlines.contains($0) || $0.value==0xFEFF}}.count
        return .init(lines:rows.count,breaks:breaks,badStarts:badStarts,badEnds:badEnds,hangulIsolated:isolated,punctuationOnly:punctuation,ink:ink)
    }
    static func reflow(_ e:Entry,session:Session,baseline:()->Profile?,measure:(Double,Double)->Measurement?)->Result? {
        guard e.preserveBackground,e.opacity>0,e.automaticRecovery,!e.vertical,e.script=="korean",e.text.utf16.count<=180,
              !e.text.contains("\r"),!e.text.contains("\n"),e.text.utf16.count*4<=session.characters else {return nil}
        session.characters-=e.text.utf16.count*4
        guard let original=baseline(),original.lines>=2 else {return nil}
        let usable=e.width-e.paddingLeft-e.paddingRight,available=Double(e.panel.width)-e.padding*2
        guard available>usable+0.5 else {return nil}
        for scale in [1.0,0.67,0.33] {
            let width=usable+(available-usable)*scale,x=Double(e.panel.midX)-width/2
            guard let measured=measure(x,width) else {continue}
            let p=measured.profile
            let safe=p.ink.allSatisfy {r in
                r.minX>=e.panel.minX+e.padding-0.5 && r.maxX<=e.panel.maxX-e.padding+0.5 && r.minY>=e.panel.minY-0.5 && r.maxY<=e.panel.maxY+0.5 &&
                !e.obstacles.contains {o in min(r.maxX,o.maxX)-max(r.minX,o.minX)>0.5 && min(r.maxY,o.maxY)-max(r.minY,o.minY)>0.5}
            }
            if measured.fits,p.lines<=original.lines,p.breaks.allSatisfy(original.breaks.contains),p.badStarts.count<=original.badStarts.count,p.badEnds.count<=original.badEnds.count,
               p.hangulIsolated<=original.hangulIsolated,p.punctuationOnly<=original.punctuationOnly,safe,
               p.lines<original.lines || p.breaks.count<original.breaks.count || p.hangulIsolated<original.hangulIsolated {
                return .init(x:x,width:width,originalWidth:e.width,originalLines:original.lines,finalLines:p.lines,scale:scale)
            }
        }
        return nil
    }
}
