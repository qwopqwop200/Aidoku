import Foundation

/// Closed grammatical classes, never page/owner-specific translated phrases.
/// This is a deliberately limited dependency proxy, not a Korean parser.
enum NativePhraseRowCoupling {
    static func boundaries(_ text:String)->Set<Int> {
        let ns=text as NSString
        let regex=try! NSRegularExpression(pattern:"\\S+")
        let tokens=regex.matches(in:text,range:NSRange(location:0,length:ns.length)).map(\.range)
        let determiners:Set<String>=["몇","한","두","세","각","모든","어떤","무슨","이런","그런","저런"]
        let dependents:Set<String>=["수","것","거","게","줄","데","뿐","때"]
        let auxiliaries:Set<String>=["못","안"]
        var result=Set<Int>()
        for i in tokens.indices.dropLast() {
            let left=ns.substring(with:tokens[i]),right=ns.substring(with:tokens[i+1])
            if determiners.contains(left) || dependents.contains(right) || auxiliaries.contains(left) {
                result.insert(tokens[i+1].location)
            }
        }
        return result
    }
    /// Lexicographic hard tiers: word preservation precedes phrase adjacency.
    /// The multiplier exceeds all possible phrase edges in this exact string;
    /// it is an integer encoding of a pair, not an adjustable score weight.
    static func rank(text:String,rows:[NativeWholeWordWrap.Row])->Int {
        let ns=text as NSString,required=boundaries(text)
        var cuts=0,broken=0
        for row in rows.dropLast() {
            let e=NSMaxRange(row.ownedRange)
            guard e>0,e<ns.length else{continue}
            func ws(_ i:Int)->Bool {
                guard let s=UnicodeScalar(ns.character(at:i)) else{return false}
                return CharacterSet.whitespacesAndNewlines.contains(s)
            }
            if !ws(e-1) && !ws(e) {cuts+=1}
            var next=e
            while next<ns.length && ws(next) {next+=1}
            if required.contains(next) {broken+=1}
        }
        return cuts*(required.count+1)+broken
    }
}
