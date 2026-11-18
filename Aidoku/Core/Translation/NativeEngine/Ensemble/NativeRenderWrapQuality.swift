import Foundation
import CoreText

/// Original UTF16 ownership, no insertion or deletion of translation characters.
enum NativeRenderWrapQuality {
    /// Optional semantic divisions matter only for an already multiline block.
    /// A complete one-line utterance never acquires a forced extra row.
    static func semanticCrossings(_ text: String, ranges: [NSRange]) -> Int {
        guard ranges.count > 1 else { return 0 }
        let starts = Set(ranges.map(\.location))
        return NativeLineBreakPolicy.preferredOffsets(text: text).filter {
            !starts.contains($0) && (ranges.count <= 2 || !NativeLineBreakPolicy.isExpressiveTailBoundary(text: text, offset: $0))
        }.count
    }

    /// A soft alphanumeric boundary inside an original word. Necessary CJK
    /// breaks remain legal; this is a readability cost, never a text filter.
    static func wordCutOffsets(_ text:String,ranges:[NSRange])->Set<Int> {
        var before:[Int:Character]=[:],after:[Int:Character]=[:],offset=0
        for c in text {
            after[offset]=c;offset+=String(c).utf16.count;before[offset]=c
        }
        return Set(ranges.compactMap {range in
            let end=NSMaxRange(range)
            guard range.location>=0,range.length>0,end<offset,
                  let a=before[end],let b=after[end],(a.isLetter || a.isNumber),(b.isLetter || b.isNumber)else{return nil}
            return end
        })
    }
    /// Resolve wrap constraints before joint geometry, so a later owner-local
    /// repair cannot unexpectedly widen a packed caption. Preserve input order.
    static func preferredCandidateIndices(defects:[Int],tails:[Int],wordCuts:[Int]?=nil)->[Int] {
        guard defects.count==tails.count,defects.allSatisfy({$0>=0}),tails.allSatisfy({$0>=0})else{return []}
        var indices=Array(defects.indices)
        let legal=indices.filter {defects[$0]==0}
        if !legal.isEmpty {indices=legal}
        let balanced=indices.filter {tails[$0]==0}
        if !balanced.isEmpty {indices=balanced}
        if let wordCuts,wordCuts.count==defects.count,wordCuts.allSatisfy({$0>=0}),let best=indices.map({wordCuts[$0]}).min() {
            indices=indices.filter {wordCuts[$0]==best}
        }
        return indices
    }
    /// Actual shaped advance and ink, including overhangs. This is the inner
    /// line width; callers add their own stroke/shadow/inset reservation.
    static func joinedLineWidth(_ text:NSAttributedString)->CGFloat {
        let line=CTLineCreateWithAttributedString(text)
        return joinedLineWidth(line)
    }
    static func joinedLineWidth(_ line:CTLine)->CGFloat {
        let ink=CTLineGetBoundsWithOptions(line,[.useGlyphPathBounds])
        let advance=CGFloat(CTLineGetTypographicBounds(line,nil,nil,nil))
        let valid = !ink.isNull && !ink.isEmpty && !ink.isInfinite
        return max(advance,valid ? ink.maxX:0)-min(0,valid ? ink.minX:0)+0.02
    }
    static func tailJoinWidths(_ text:NSAttributedString,ranges:[NSRange])->[CGFloat] {
        let offsets=shortTailOffsets(text.string,ranges:ranges)
        return ranges.indices.dropFirst().compactMap {i in
            guard offsets.contains(ranges[i].location)else{return nil}
            let begin=ranges[i-1].location,end=NSMaxRange(ranges[i])
            guard begin>=0,end<=text.length,end>begin else{return nil}
            let width=joinedLineWidth(text.attributedSubstring(from:NSRange(location:begin,length:end-begin)))
            return width.isFinite && width>0 ? width:nil
        }
    }
    /// Measure only lexical runs that cross a current soft row boundary. Width
    /// proposals come from the actual face and fallback shaping, not a glyph
    /// count or a page-specific expansion factor.
    static func wordJoinWidths(_ text:NSAttributedString,ranges:[NSRange],includeAttachedPunctuation:Bool=false)->[CGFloat] {
        let cuts=wordCutOffsets(text.string,ranges:ranges)
        guard !cuts.isEmpty else{return []}
        // Optional expressive-row styling must not make ordinary word-width
        // recovery forget its attached closing punctuation and undershoot.
        let legal=NativeLineBreakPolicy.legalOffsets(text:text.string,allowExpressiveTail:false)
        var spans:[Int:(NSRange,Character)]=[:],ends:[Int:(NSRange,Character)]=[:],position=0
        for character in text.string {
            let range=NSRange(location:position,length:String(character).utf16.count)
            spans[position]=(range,character);ends[NSMaxRange(range)]=(range,character);position=NSMaxRange(range)
        }
        var widths=Set<CGFloat>(),offset=0,start:Int?
        func finish(_ end:Int) {
            guard let begin=start,cuts.contains(where:{$0>begin && $0<end})else{return}
            var lower=begin,upper=end
            // A fitting lexical word is still overwide if its required closing
            // punctuation was omitted from the measured proposal. Include only
            // attached graphemes that the shared break policy cannot separate.
            while includeAttachedPunctuation,!legal.contains(lower),let (range,c)=ends[lower],!c.isWhitespace {
                lower=range.location
            }
            while includeAttachedPunctuation,!legal.contains(upper),let (range,c)=spans[upper],!c.isWhitespace {
                upper=NSMaxRange(range)
            }
            let width=joinedLineWidth(text.attributedSubstring(from:NSRange(location:lower,length:upper-lower)))
            if width.isFinite,width>0 {widths.insert(width)}
        }
        for character in text.string {
            if character.isLetter || character.isNumber {
                if start==nil {start=offset}
            } else {finish(offset);start=nil}
            offset+=String(character).utf16.count
        }
        finish(offset)
        return widths.sorted()
    }
    /// Measured intermediate widths for a coarse capacity lattice. Whitespace
    /// delimits original lexical spans; hard paragraphs are never joined. The
    /// bounded palette covers short and long joins without page/GT identities.
    static func lexicalLineWidths(_ text:NSAttributedString,minimumWidth:CGFloat,maximumWidth:CGFloat,
                                  limit:Int=12,lineFactory:((NSAttributedString)->CTLine)?=nil)->[CGFloat] {
        guard minimumWidth.isFinite,maximumWidth.isFinite,minimumWidth>=0,maximumWidth>minimumWidth,
              limit>0,limit<=32 else{return []}
        var tokens:[(NSRange,Int)]=[],offset=0,start:Int?,paragraph=0
        for character in text.string {
            let length=String(character).utf16.count
            if character.isWhitespace {
                if let begin=start {tokens.append((NSRange(location:begin,length:offset-begin),paragraph));start=nil}
                if character.isNewline {paragraph+=1}
            } else if start==nil {start=offset}
            offset+=length
        }
        if let begin=start {tokens.append((NSRange(location:begin,length:offset-begin),paragraph))}
        guard !tokens.isEmpty else{return []}
        let indices=tokens.count<=128 ? Array(tokens.indices):
            (0..<128).map {Int((Double($0)*Double(tokens.count-1)/127).rounded())}
        var measured=Set<CGFloat>()
        for index in indices {
            for count in 1...3 where index+count<=tokens.count && tokens[index].1==tokens[index+count-1].1 {
                let begin=tokens[index].0.location,end=NSMaxRange(tokens[index+count-1].0)
                let fragment=text.attributedSubstring(from:NSRange(location:begin,length:end-begin))
                let width=lineFactory.map {joinedLineWidth($0(fragment))} ?? joinedLineWidth(fragment)
                if width>minimumWidth+0.01,width<=maximumWidth {measured.insert(width)}
            }
        }
        let ordered=measured.sorted()
        if ordered.count<=limit {return ordered}
        if limit==1 {return [ordered[ordered.count/2]]}
        return (0..<limit).map {ordered[Int((Double($0)*Double(ordered.count-1)/Double(limit-1)).rounded())]}
    }
    static func compactLineWidth(_ text:NSAttributedString,ranges:[NSRange],fontSize:CGFloat)->CGFloat? {
        guard ranges.count>1,ranges.count<=3,fontSize.isFinite,fontSize>0,
              !text.string.contains(where:{$0.isNewline})else{return nil}
        let width=joinedLineWidth(text)
        return width.isFinite && width>0 && width<=fontSize*10 ? width:nil
    }
    /// A clean paragraph can still be unnecessarily tall. Measure adjacent soft
    /// rows as real width alternatives, preserving explicit hard paragraphs.
    /// Three representative joins bound shaping work independently of row count.
    static func compactParagraphWidths(_ text:NSAttributedString,ranges:[NSRange],
                                       currentWidth:CGFloat,maximumWidth:CGFloat)->[CGFloat] {
        guard ranges.count>=4,currentWidth.isFinite,currentWidth>0,
              maximumWidth.isFinite,maximumWidth>currentWidth else{return []}
        let ns=text.string as NSString
        var widths=Set<CGFloat>()
        for index in ranges.indices.dropFirst() {
            let a=ranges[index-1],b=ranges[index]
            guard a.location>=0,a.length>0,b.length>0,NSMaxRange(a)==b.location,NSMaxRange(b)<=ns.length,
                  !ns.substring(with:a).contains(where:NativeLineBreakPolicy.isBreak),
                  ns.paragraphRange(for:NSRange(location:a.location,length:0)).location ==
                    ns.paragraphRange(for:NSRange(location:b.location,length:0)).location else{continue}
            let joined=NSRange(location:a.location,length:NSMaxRange(b)-a.location)
            let width=joinedLineWidth(text.attributedSubstring(from:joined))
            if width>currentWidth+0.01,width<=maximumWidth {widths.insert(width)}
        }
        let ordered=widths.sorted()
        return ordered.count<=3 ? ordered:[ordered[0],ordered[ordered.count/2],ordered.last!]
    }
    static func singleCharacterRows(_ text:String,ranges:[NSRange])->Int {
        let original=text as NSString
        return ranges.filter {range in
            guard range.location>=0,range.length>0,NSMaxRange(range)<=original.length else{return false}
            let value=original.substring(with:range).trimmingCharacters(in:.whitespacesAndNewlines)
            return value.count==1 && value.rangeOfCharacter(from:.alphanumerics) != nil
        }.count
    }
    /// Subset of singleCharacterRows whose sole alphanumeric grapheme is a
    /// fragment of an original word. Standalone one-letter words are intentional.
    static func singleCharacterFragmentRows(_ text:String,ranges:[NSRange])->Int {
        let original=text as NSString
        var graphemes:[NSRange]=[],offset=0
        for character in text {
            let length=String(character).utf16.count
            graphemes.append(NSRange(location:offset,length:length));offset+=length
        }
        let internalBoundaries=wordCutOffsets(text,ranges:graphemes)
        return ranges.filter {range in
            guard range.location>=0,range.length>0,NSMaxRange(range)<=original.length else{return false}
            let value=original.substring(with:range).trimmingCharacters(in:.whitespacesAndNewlines)
            return value.count==1 && value.rangeOfCharacter(from:.alphanumerics) != nil &&
                (internalBoundaries.contains(range.location) || internalBoundaries.contains(NSMaxRange(range)))
        }.count
    }
    /// Only soft paragraph tails count. Explicit one-letter paragraphs such as
    /// a short reply or a deliberately isolated numeral remain intentional.
    static func shortTailOffsets(_ text:String,ranges:[NSRange])->Set<Int> {
        let ns=text as NSString
        var result=Set<Int>()
        for i in ranges.indices where i>0 {
            let row=ranges[i],previous=ranges[i-1]
            guard row.location>=0,row.length>0,NSMaxRange(row)<=ns.length,
                  previous.location>=0,previous.length>0,NSMaxRange(previous)<=row.location else {continue}
            let line=ns.substring(with:row).trimmingCharacters(in:.whitespacesAndNewlines)
            guard line.count==1,line.rangeOfCharacter(from:.alphanumerics) != nil else {continue}
            let preceding=ns.substring(with:previous).filter { String($0).rangeOfCharacter(from:.alphanumerics) != nil }.count
            guard preceding>=2 else {continue} // A whole one-character-wide column is not an isolated tail.
            let paragraph=ns.paragraphRange(for:NSRange(location:row.location,length:0))
            guard previous.location>=paragraph.location,
                  i==ranges.count-1 || ranges[i+1].location>=NSMaxRange(paragraph) else {continue}
            let content=ns.substring(with:paragraph)
            let letters=content.filter { String($0).rangeOfCharacter(from:.alphanumerics) != nil }.count
            if letters>=4 {result.insert(row.location)}
        }
        return result
    }
    static func evaluate(_ text: String, ranges: [NSRange], legal: Set<Int>? = nil) -> (illegal: Int, orphans: Int) {
        let ns=text as NSString, allowed=legal ?? NativeLineBreakPolicy.legalOffsets(text:text)
        var illegal=0,orphans=0
        for range in ranges {
            guard range.location>=0,range.length>=0,NSMaxRange(range)<=ns.length else { continue }
            let end=NSMaxRange(range)
            if end>0 && end<ns.length && !allowed.contains(end) { illegal+=1 }
            let line=ns.substring(with:range).trimmingCharacters(in:.whitespacesAndNewlines)
            if !line.isEmpty && line.rangeOfCharacter(from:.alphanumerics)==nil &&
                !NativeLineBreakPolicy.isExpressiveTailRow(text:text,range:range) {
                let paragraph=ns.substring(with:ns.paragraphRange(for:range))
                if paragraph.rangeOfCharacter(from:.alphanumerics) != nil { orphans+=1 }
            }
        }
        return(illegal,orphans)
    }
}
