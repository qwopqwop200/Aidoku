import CoreGraphics
import Foundation

/// Original final display-lettering trial. Geometry is only adopted after
/// actual shaped range, longest-word and collision measurements all accept.
enum NativeDisplayLetteringTrial {
    struct Input {
        var text: String
        var source: CGRect
        var frame: CGRect?
        var glyph: Double
        var current: Double
        var ratio: Double
        var priorInk: CGRect
        var others: [CGRect]
    }
    struct Probe { var rect: CGRect; var size: Double; var strokeWidth: Double; var inset: Double; var lineHeight: Double }
    struct Measurement { var ink: CGRect; var longestWord: Double; var contentFits: Bool }
    struct Accepted { var probe: Probe; var measured: Measurement }
    static func prepare(_ input: Input,measure: (Probe)->Measurement?) -> Accepted? {
        guard input.glyph.isFinite, input.glyph > 0, input.current.isFinite, input.current > 0,
              [input.source.minX,input.source.minY,input.source.width,input.source.height].allSatisfy(\.isFinite) else { return nil }
        var l = Double(input.source.minX)-input.glyph*0.15, t = Double(input.source.minY)-input.glyph*0.15
        var width = Double(input.source.width)+input.glyph*0.3, height = Double(input.source.height)+input.glyph*0.3
        if let frame = input.frame {
            width = min(l+width,Double(frame.maxX))-max(l,Double(frame.minX)); height = min(t+height,Double(frame.maxY))-max(t,Double(frame.minY))
            l = max(l,Double(frame.minX)); t = max(t,Double(frame.minY))
        }
        let rect = CGRect(x:l,y:t,width:width,height:height), ratio = input.ratio == 0 || !input.ratio.isFinite ? 1.2 : input.ratio
        let target = max(input.current,min(input.glyph*0.9,72))
        func lines(_ height: Double,_ type: Double)->Int { max(1,Int(floor(height/(type*ratio)+0.5))) }
        for step in 0..<10 {
            let size = floor((target-(target-input.current)*Double(step)/9)*4)/4, stroke = min(8,max(2,size*0.16)), inset = stroke/2+1
            let probe = Probe(rect:rect,size:size,strokeWidth:stroke,inset:inset,lineHeight:size*ratio)
            guard let m = measure(probe), m.longestWord <= width-inset*2, m.contentFits else { continue }
            let ink = m.ink
            if Double(ink.minX) < l+inset-0.5 || Double(ink.maxX) > l+width-inset+0.5 || Double(ink.minY) < t+inset-0.5 || Double(ink.maxY) > t+height-inset+0.5 { continue }
            let before = lines(Double(input.priorInk.height),input.current), after = lines(Double(ink.height),size)
            let chars = String(String.UnicodeScalarView(input.text.unicodeScalars.filter { !$0.properties.isWhitespace })).utf16.count
            if !(chars > 0 && (after < 3 || chars < 8 || Double(chars)/Double(after) >= 2.5 || Double(chars)/Double(after) >= Double(chars)/Double(max(1,before)))) { continue }
            if input.others.contains(where: { Double(ink.minX)-inset < Double($0.maxX) && Double(ink.maxX)+inset > Double($0.minX) && Double(ink.minY)-inset < Double($0.maxY) && Double(ink.maxY)+inset > Double($0.minY) }) { continue }
            if size < input.glyph*0.4 { return nil }
            return .init(probe:probe,measured:m)
        }
        return nil
    }
}
