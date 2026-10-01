import Foundation
import CoreGraphics

/// Source-preserving LTR pre-line/normal keep-all flow. It retains original UTF16 ownership;
/// paragraph whitespace normalization is independent of overflow-wrap mode.
enum NativePreLineTextFlow {
    struct Normalized {
        let text: String
        let sourceUTF16: [NSRange]
    }
    struct Row {
        let text: String
        let sourceUTF16: [NSRange]
    }
    static func normalize(_ text: String, preservesLineBreaks: Bool = true) -> Normalized {
        let input=Array(text.utf16)
        var output:[UInt16]=[], origins:[NSRange]=[], pending:NSRange?
        func discardSpace(){pending=nil}
        func writeSpace(){
            if let pending, output.last != nil, output.last != 10 {
                output.append(32);origins.append(pending)
            }
            pending=nil
        }
        for (index,unit) in input.enumerated() {
            switch unit {
            case 13: break // Existing DOM CR has no inline advance; CRLF keeps its LF.
            case 32,9:
                if let old=pending {pending=NSRange(location:old.location,length:index-old.location+1)}
                else {pending=NSRange(location:index,length:1)}
            case 10:
                if preservesLineBreaks {
                    discardSpace();output.append(unit);origins.append(NSRange(location:index,length:1))
                } else if let old=pending {
                    pending=NSRange(location:old.location,length:index-old.location+1)
                } else {pending=NSRange(location:index,length:1)}
            default:
                writeSpace();output.append(unit);origins.append(NSRange(location:index,length:1))
            }
        }
        discardSpace()
        return .init(text:String(decoding:output,as:UTF16.self),sourceUTF16:origins)
    }
    static func rows(_ source:String,width:CGFloat,overflowAnywhere:Bool,
        preservesLineBreaks:Bool=true,balances:Bool=false,
        measure:(String)->CGFloat)->[Row]? {
        let normalized=normalize(source,preservesLineBreaks:preservesLineBreaks),units=Array(normalized.text.utf16)
        guard width.isFinite,width>0,units.count<=8192 else {return nil}
        if units.isEmpty {return []}
        var rows:[Row]=[],begin=0
        var paragraphs:[NSRange]=[]
        for index in units.indices where units[index]==10 {
            paragraphs.append(NSRange(location:begin,length:index-begin));begin=index+1
        }
        if begin<units.count {paragraphs.append(NSRange(location:begin,length:units.count-begin))}
        for paragraph in paragraphs {
            if paragraph.length==0 {rows.append(.init(text:"",sourceUTF16:[]));continue}
            let string=String(decoding:units[paragraph.location..<NSMaxRange(paragraph)],as:UTF16.self)
            let ns=string as NSString
            guard let auto=NativeKeepAllAutoLines.greedy(text:string,maximumWidth:width,
                overflowAnywhere:overflowAnywhere,width:{measure(ns.substring(with:$0))},
                emergencyBreak:{ range,room in
                    var end=range.location,selected=0
                    while end<NSMaxRange(range) {
                        end=NSMaxRange(ns.rangeOfComposedCharacterSequence(at:end))
                        if measure(ns.substring(with:NSRange(location:range.location,length:end-range.location)))>room {break}
                        selected=end-range.location
                    }
                    return selected
                }) else {return nil}
            // Preserve paragraph-local auto count when the shared balance
            // solver declines. A forced LF never joins another paragraph.
            let balanced=balances ? NativeKeepAllTextBalance.solve(text:string,
                originalAutoRanges:auto,maximumWidth:width,
                itemWidth:{Float(measure(ns.substring(with:$0)))}) : nil
            let ranges=balanced?.flowRanges ?? auto
            for range in ranges {
                var start=paragraph.location+range.location,end=start+range.length
                while start<end && units[start]==32 {start+=1}
                while end>start && units[end-1]==32 {end-=1}
                rows.append(.init(text:String(decoding:units[start..<end],as:UTF16.self),
                    sourceUTF16:Array(normalized.sourceUTF16[start..<end])))
            }
        }
        return rows
    }
}
