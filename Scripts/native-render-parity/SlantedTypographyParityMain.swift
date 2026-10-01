import Foundation
import CoreGraphics
let fs = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))) as! [[String: Any]]
func n(_ f: [String: Any], _ k: String, _ d: Double = 0) -> Double { (f[k] as? NSNumber)?.doubleValue ?? d }
func rect(_ a: [Double]) -> CGRect { CGRect(x: a[0], y: a[1], width: a[2], height: a[3]) }
func array(_ r: CGRect) -> [Double] { [r.minX,r.minY,r.width,r.height] }
var outputs: [[String: Any]] = []
for f in fs {
    let name = f["name"] as! String, text = f["text"] as? String ?? "HELLO WORLD", quad = rect(f["quad"] as? [Double] ?? [50, 60, 90, 45])
    let font = n(f,"font",12), padding = f["padding"] as? [Double] ?? [2,2,2,2], ratio = n(f,"ratio",1.2)
    let c = NativeSlantedTypographyTrial.Candidate(rect:quad,font:font,pitch:font*ratio,padding:padding,angle:n(f,"angle",0.2))
    let foreground = f["foreground"] as? [Double] ?? [0,0,0]
    var surface = NativeSlantedTypographyTrial.Surface(id:"original",method:f["method"] as? String ?? "rectified",width:12,height:12,
        safe:[UInt8](repeating:1,count:144),luminance:[UInt8](repeating:245,count:144))
    if f["paper"] as? Bool == true { surface.safe = (0..<144).map { i in let x=i%12,y=i/12; return x>=2 && x<10 && y>=2 && y<10 ? 1 : 0 } }
    let peers = (f["peers"] as? [[String:Any]] ?? []).map { p -> NativeSlantedTypographyTrial.Peer in
        let r = rect(p["rect"] as! [Double]); return .init(text:p["text"] as? String ?? "",plannedFont:n(p,"font",12),source:r,sourceFont:n(p,"glyph",20),
            card:NativeSlantedGeometry.rotatedCard(cx:r.midX,cy:r.midY,width:r.width,height:r.height,angle:0))
    }
    let obstacles = peers.flatMap { p -> [[[Double]]] in [p.card, p.source.map { NativeSlantedGeometry.rotatedCard(cx:$0.midX,cy:$0.midY,width:$0.width,height:$0.height,angle:0) } ?? []] }
    var entry = NativeSlantedTypographyTrial.Entry(quad:quad,initial:c,plannedFont:f["planned"] as? Double,minimumFont:n(f,"minimum",5),text:text,sourceText:f["sourceText"] as? String ?? "",
        sourceFont:n(f,"glyph",20),sourceBounds:quad,sourceVertical:f["sourceVertical"] as? Bool ?? false,
        vertical:f["vertical"] as? Bool ?? false,wrappingKorean:f["korean"] as? Bool ?? false,
        sourceForeground:foreground,observedForeground:f["observed"] as? [Double],frame:rect([0,0,500,500]),uprightQuad:f["upright"] as? Bool ?? false,peers:peers,bodyObstacles:obstacles)
    entry.wideObstacles = peers.compactMap { p in p.source.map { NativeSlantedGeometry.rotatedCard(cx:$0.midX,cy:$0.midY,width:$0.width,height:$0.height,angle:0,margin:6) } }
    var trace: [[Double]] = [], proofCalls = 0
    func measure(_ c: NativeSlantedTypographyTrial.Candidate) -> NativeSlantedTypographyTrial.Measurement {
        let advance = c.font * 0.5, avail = max(0.01,Double(c.rect.width)-c.padding[1]-c.padding[3]), columns = max(1,Int(floor(avail/advance)))
        let chars = Array(text), rows = max(1,Int(ceil(Double(chars.count)/Double(columns))))
        let top = c.padding[0]+(Double(c.rect.height)-c.padding[0]-c.padding[2]-Double(rows)*c.pitch)/2+(c.pitch-c.font)/2
        var glyphs:[[Double]] = [], words:[[Int]] = [[]], lines:[CGRect] = [], ranges:[CGRect] = []
        for (i,ch) in chars.enumerated() {
            let row=i/columns,col=i%columns,x=c.padding[3]+Double(col)*advance,y=top+Double(row)*c.pitch
            if ch.isWhitespace { if !words[words.count-1].isEmpty { words.append([]) } }
            else { ranges.append(CGRect(x:x,y:y,width:advance,height:c.font));glyphs.append([x*c.condense,y,(x+advance)*c.condense,y+c.font]);words[words.count-1].append(row) }
        }
        for row in 0..<rows { let count=min(columns,chars.count-row*columns);lines.append(CGRect(x:c.padding[3],y:top+Double(row)*c.pitch,width:Double(max(0,count))*advance,height:c.font)) }
        let broken=words.contains { Set($0).count>1 } || rows>=3 && glyphs.count>=8 && Double(glyphs.count)/Double(rows)<2.5
        let fits=Double(rows)*c.pitch+c.padding[0]+c.padding[2]<=Double(c.rect.height)+0.5 && advance<=avail+0.5
        return .init(glyphs:glyphs,lines:lines,lineCount:rows,contentFits:fits,wordBroken:broken,rangeRects:ranges)
    }
    let hooks = NativeSlantedTypographyTrial.Hooks(measure:{ c in trace.append([c.font,c.rect.width,c.rect.height,c.pitch,c.condense,c.fraction,c.angle]); return measure(c) },
        longestWord:{ size in Double(text.split(whereSeparator:\.isWhitespace).map(\.count).max() ?? 0)*size*0.5 },
        fits:{ s,c,rs,color,audit in
            proofCalls += 1
            let fraction = 1-(c.padding[1]+c.padding[3]-padding[1]-padding[3])/Double(quad.width)
            let lifted = c.padding[0] == 0 && c.font >= 8.5 && f["allowLift"] as? Bool == true
            let safeFont = s.expandedPaper ? n(f,"paperSafeFont",n(f,"safeFont",100)) : s.id == "wide" ? n(f,"wideSafeFont",n(f,"safeFont",100)) : n(f,"safeFont",100)
            let geometry=c.font<=safeFont && (lifted || fraction<=n(f,"safeFraction",1)+1e-8) &&
                Double(c.rect.width)>=n(f,"safeWidth",0) && (!((f["rotatedOnly"] as? Bool) ?? false) || c.angle != 0) && !rs.isEmpty
            let unsafeCount=geometry ? Int(n(f,"unsafe",0)) : 20, dim=Int(n(f,"dim",0))
            let surfaceByte=n(f,"surfaceByte",245), l=NativeTranslationSourceStylePostPolish.luminance(color), q=surfaceByte/255
            let contrast=(max(l,q)+0.05)/(min(l,q)+0.05), samples=1000
            audit.minimumContrast=contrast;audit.unsafeCount=unsafeCount;audit.unsafeDim=0;audit.dim=contrast>=4.5 ? dim : 1000
            audit.samples=samples;audit.range=[surfaceByte,surfaceByte]
            if audit.histogram != nil { audit.histogram![Int(surfaceByte)]=samples }
            return unsafeCount==0 && audit.dim==0 && contrast>=4.5
        },prepareWide:{ _ in (f["wide"] as? Bool ?? false) ? .init(id:"wide",method:"rectified",width:12,height:12,safe:surface.safe,luminance:surface.luminance) : nil },
        leftover:{ _ in (144,Int(n(f,"leftover",10))) })
    var clipPolygon: [[Double]]?
    var result=NativeSlantedTypographyTrial.run(entry,surface:(f["noSurface"] as? Bool ?? false) ? nil : surface,hooks:hooks),budget=Int(n(f,"budget",600))
    if f["mode"] as? String == "baseline" { result = .init(candidate:NativeSlantedTypographyTrial.baseline(entry,measure:measure),surface:surface,foreground:foreground) }
    if f["mode"] as? String == "clip" {
        entry.uprightQuad = true; var cc=c;cc.angle=0
        let clipped=NativeSlantedTypographyTrial.finalClip(entry,result:.init(candidate:cc,surface:surface,foreground:foreground),measure:measure)
        result=clipped.result;clipPolygon=clipped.polygon
    }
    if f["mode"] as? String == "upright" {
        let a=rect(f["alternative"] as? [Double] ?? array(quad)),ap=f["alternativePadding"] as? [Double] ?? padding
        let u=NativeSlantedTypographyTrial.Upright(rect:a,content:CGRect(x:a.minX+ap[3],y:a.minY+ap[0],width:a.width-ap[1]-ap[3],height:a.height-ap[0]-ap[2]),font:n(f,"alternativeFont",font),pitch:n(f,"alternativeFont",font)*ratio)
        result=NativeSlantedTypographyTrial.upright(entry,alternative:u,surface:surface,obstacles:peers.compactMap { $0.source?.insetBy(dx:-8,dy:-8) },hooks:hooks) ?? .init(candidate:c,surface:surface,foreground:foreground,metadata:["uprightFromSlant":"rejected","sourceBackgroundColor":"rotated-panel"])
    }
    if f["lift"] as? Bool == true {result=NativeSlantedTypographyTrial.lift(entry,result:result,obstacles:obstacles,budget:&budget,hooks:hooks)}
    let out=result.candidate
    var output: [String:Any] = ["name":name,"accepted":result.accepted,"candidate":[out.rect.minX,out.rect.minY,out.rect.width,out.rect.height,out.font,out.pitch,out.condense,out.angle],
        "padding":out.padding,"foreground":result.foreground,"fraction":out.fraction,"surface":result.surface?.id ?? NSNull(),"pending":result.pendingReadableLift,
        "metadata":result.metadata.filter { !["narrowPaperFit","slantedSurfaceLuminance"].contains($0.key) },"budget":budget,"proofCalls":proofCalls]
    if f["mode"] as? String == "clip" {output["clip"] = clipPolygon ?? []}
    outputs.append(output)
}
try JSONSerialization.data(withJSONObject:outputs,options:[.sortedKeys]).write(to:URL(fileURLWithPath:CommandLine.arguments[2]))
