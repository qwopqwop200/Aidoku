import CoreGraphics
import Foundation

/// The late source-line pass reads bounded original pixels, then preserves the
/// committed footprint when aligning text or opening a verified label line.
enum NativeTranslationSourceAlignment {
    enum Children { case plain, blockSpans, unsupported }
    struct Plate { var rect: CGRect; var coverage: [CGRect]?; var parent = false; let ownerID: String }
    struct Entry {
        let id: String
        let text: String
        var renderedText: String
        let source: CGRect
        var font: Double
        let sourceFont: Double?
        var lines: [CGRect]
        var ink: CGRect
        var nodeRect: CGRect
        var visible = true
        var sourceRotation = false
        var horizontalWriting = true
        var rtl = false
        var transformNone = true
        var hasScale = false
        var sourceVertical = false
        var rotation: Double = 0
        var automaticRecovery = true
        var children: Children = .plain
        var wrap = "balance"
        var backgroundKind = "inpainted"
        var sampledForeground: [Double]?
        var sampledBackground: [Double]?
        var paintsBackground = false
        var hasBackgroundImage = false
        var isRoot = true
        var sourcePanelCoverage: [CGRect]?
        var heading: String?
        var alignment: String?
        var edgeShift: String?
        var shift = CGPoint.zero
        var lineOffsets: [CGFloat]?
        var wrapperWidth: CGFloat?
        var headingShape: Measurement?
    }
    enum Mode { case heading, flushPlain }
    struct Request { let mode: Mode; let text: String; let wrap: String; let width: CGFloat?; let headUTF16Length: Int }
    struct Measurement { let lines: [CGRect]; let ink: CGRect; let nodeRect: CGRect; let scrollSize: CGSize; let clientSize: CGSize; let labelRows: Int }
    struct SourceLine { let left: Int; let right: Int; let top: Int; let bottom: Int }
    struct SourceRead { let bands: Int; let lines: [SourceLine]; let lineHeight: Double; let scale: Double }
    struct Result { let entries: [Entry]; let headings: Int; let aligned: Int; let edgeMoves: Int; let remainingPixels: Int }
    typealias Reader = (CGRect, _ width: Int, _ height: Int) -> [UInt8]?
    typealias Shape = (Entry, Request) -> Measurement?

    static func rows(_ input: [CGRect]) -> [CGRect] {
        var out: [CGRect] = []
        for r in input where r.size.width > 0 && r.size.height > 0 {
            if let index = out.firstIndex(where: { abs($0.minY-r.minY) < r.height*0.5 }) {
                let old=out[index];out[index]=CGRect(x:min(old.minX,r.minX),y:old.minY,width:max(old.maxX,r.maxX)-min(old.minX,r.minX),height:old.height)
            } else {out.append(r)}
        }
        return out.sorted {$0.minY < $1.minY}
    }
    static func readSourceLines(_ e: Entry, frame: CGRect, sourcePixelWidth: Int, budget: inout Int, reader: Reader) -> SourceRead? {
        let s=e.source,pad:CGFloat=4
        let crop=CGRect(x:max(frame.minX,s.minX-pad),y:max(frame.minY,s.minY-pad),width:0,height:0)
        let right=min(frame.maxX,s.maxX+pad),bottom=min(frame.maxY,s.maxY+pad)
        let box=CGRect(x:crop.minX,y:crop.minY,width:right-crop.minX,height:bottom-crop.minY)
        guard box.size.width>0,box.size.height>0 else {return nil}
        let k=min(max(1,min(2,Double(sourcePixelWidth)/Double(frame.width))),sqrt(160_000/Double(box.width*box.height)))
        let w=max(1,Int(floor(Double(box.width)*k+0.5))),h=max(1,Int(floor(Double(box.height)*k+0.5)))
        guard w>=12,h>=12,w*h<=budget else {return nil};budget-=w*h
        guard let rgba=reader(box,w,h),rgba.count==w*h*4 else {return nil}
        func lum(_ i:Int)->Double {0.2126*Double(rgba[i*4])+0.7152*Double(rgba[i*4+1])+0.0722*Double(rgba[i*4+2])}
        var border:[Double]=[]
        for x in stride(from:0,to:w,by:2) {border += [lum(x),lum((h-1)*w+x)]}
        for y in stride(from:0,to:h,by:2) {border += [lum(y*w),lum(y*w+w-1)]}
        border.sort();let paper=border[border.count>>1]
        let fg=e.sampledForeground.flatMap {validRGB($0) ? $0:nil},bg=e.sampledBackground.flatMap {validRGB($0) ? $0:nil}
        let usable=fg != nil && bg != nil && zip(fg!,bg!).reduce(0) {$0+abs($1.0-$1.1)}>=90
        var all=[UInt8](repeating:0,count:w*h)
        for i in all.indices {
            if usable {
                var toFG:Double=0,toBG:Double=0
                for c in 0..<3 {toFG+=abs(Double(rgba[i*4+c])-fg![c]);toBG+=abs(Double(rgba[i*4+c])-bg![c])}
                if toFG<toBG && toBG>60 {all[i]=1}
            } else if abs(lum(i)-paper)>70 {all[i]=1}
        }
        var queue:[Int]=[],head=0
        func seed(_ i:Int) {if all[i]==1 {all[i]=2;queue.append(i)}}
        for x in 0..<w {seed(x);seed((h-1)*w+x)}
        for y in 0..<h {seed(y*w);seed(y*w+w-1)}
        while head<queue.count {
            let i=queue[head],x=i%w;head+=1
            if x>0 {seed(i-1)};if x<w-1 {seed(i+1)};if i>=w {seed(i-w)};if i<w*(h-1) {seed(i+w)}
        }
        let ox=Int(floor(Double(s.minX-box.minX)*k+0.5)),oy=Int(floor(Double(s.minY-box.minY)*k+0.5))
        let iw=min(w-ox,max(1,Int(floor(Double(s.width)*k+0.5)))),ih=min(h-oy,max(1,Int(floor(Double(s.height)*k+0.5))))
        guard ox>=0,oy>=0,iw>=12,ih>=12 else {return nil}
        var ink=[UInt8](repeating:0,count:iw*ih),rowInk=[Int](repeating:0,count:ih)
        for y in 0..<ih {for x in 0..<iw where all[(y+oy)*w+x+ox]==1 {ink[y*iw+x]=1;rowInk[y]+=1}}
        let sorted=rowInk.sorted(),minimum=max(2,Double(sorted[Int(floor(Double(ih)*0.9))])*0.1)
        var bands:[[Int]]=[],start = -1
        for y in 0...ih {
            if y<ih && Double(rowInk[y])>=minimum {if start<0 {start=y};continue}
            if start>=0 {bands.append([start,y-1]);start = -1}
        }
        guard bands.count>=2 else {return nil}
        let heights=bands.map {$0[1]-$0[0]+1}.sorted(),lh=Double(heights[heights.count>>1])
        var lines:[SourceLine]=[]
        for band in bands where Double(band[1]-band[0]+1)>=lh*0.6 {
            var cols=[Int](repeating:0,count:iw),total=0
            for y in band[0]...band[1] {for x in 0..<iw where ink[y*iw+x] != 0 {cols[x]+=1;total+=1}}
            let trim=max(3,Double(total)*0.03);var left=0,right=iw-1,sum=0
            while left<iw {sum+=cols[left];if Double(sum)>=trim {break};left+=1};sum=0
            while right>=0 {sum+=cols[right];if Double(sum)>=trim {break};right-=1}
            if right>left {lines.append(.init(left:left,right:right,top:band[0],bottom:band[1]))}
        }
        return .init(bands:bands.count,lines:lines,lineHeight:lh,scale:k)
    }
    static func isFlushLeft(_ read: SourceRead?) -> Bool {
        guard let read,read.bands>=3,read.lines.count>=3 else {return false}
        let lines=read.lines,lh=read.lineHeight,widths=lines.map {$0.right-$0.left}.sorted()
        guard Double(widths[widths.count>>1])>=3*lh else {return false}
        let tol=max(2*read.scale,lh*0.5),lefts=lines.map {Double($0.left)}.sorted()
        var edge=lefts[0],best=0
        for l in lefts {let count=lefts.filter {$0>=l && $0<=l+tol}.count;if count>best {best=count;edge=l}}
        let flush=lines.filter {Double($0.left)>=edge && Double($0.left)<=edge+tol}
        guard flush.count>=max(3,Int(ceil(Double(lines.count)*0.7))),!lines.contains(where:{Double($0.left)<edge-0.5 || Double($0.left)>edge+lh*1.5}) else {return false}
        let rights=flush.map {Double($0.right)},fl=flush.map {Double($0.left)},centres=flush.map {Double($0.left+$0.right)/2}
        let rs=rights.max()!-rights.min()!,ls=fl.max()!-fl.min()!,cs=centres.max()!-centres.min()!
        return rs>lh && rs>3*ls && cs>max(lh*0.5,1.5*ls)
    }
    private static func validRGB(_ v:[Double])->Bool {v.count==3 && v.allSatisfy(\.isFinite)}
    private static func union(_ rows:[CGRect])->CGRect {rows.reduce(CGRect.null) {$0.union($1)}}
    private static func touching(_ a:CGRect,_ b:CGRect)->Bool {a.minX<b.maxX-1 && a.maxX>b.minX+1 && a.minY<b.maxY-1 && a.maxY>b.minY+1}
    private static func strip(_ text:String)->String {text.replacingOccurrences(of:"[\\s\\uFEFF]+",with:"",options:.regularExpression)}
    private static func eligible(_ e:Entry,rtl:Bool=true)->Bool {e.visible && !e.sourceRotation && e.horizontalWriting && (!rtl || !e.rtl) && e.transformNone && !e.hasScale && !e.sourceVertical && abs(e.rotation)<=0.02}
    static func apply(_ input:[Entry], frame:CGRect, sourcePixelWidth:Int, plates:[Plate],
                      pixelBudget:Int=1_000_000,reader:Reader,shape:Shape,
                      holdsSurface:((Entry)->Bool)?=nil)->Result {
        guard input.count<=256,sourcePixelWidth>0,frame.size.width>0,frame.size.height>0,
              [frame.minX,frame.minY,frame.width,frame.height].allSatisfy(\.isFinite) else {
            return .init(entries:input,headings:0,aligned:0,edgeMoves:0,remainingPixels:pixelBudget)
        }
        var entries=input,budget=pixelBudget,headings=0,aligned=0,moves=0,cache:[String:SourceRead]=[:],readIDs=Set<String>()
        for i in entries.indices {entries[i].lines=rows(entries[i].lines)}
        func read(_ e:Entry)->SourceRead? {
            if readIDs.insert(e.id).inserted {cache[e.id]=readSourceLines(e,frame:frame,sourcePixelWidth:sourcePixelWidth,budget:&budget,reader:reader)}
            return cache[e.id]
        }
        func plateFor(_ e:Entry,parentOnly:Bool=false)->Plate? {plates.first {$0.ownerID==e.id && (!parentOnly || $0.parent)}}
        func moved(_ m:Measurement,_ dy:CGFloat)->Measurement {
            .init(lines:m.lines.map {$0.offsetBy(dx:0,dy:dy)},ink:m.ink.offsetBy(dx:0,dy:dy),nodeRect:m.nodeRect.offsetBy(dx:0,dy:dy),scrollSize:m.scrollSize,clientSize:m.clientSize,labelRows:m.labelRows)
        }
        let label="^\\s*(?:([○●◎◇◆□■☆★◯◉♦♢▽△♥♡])[^○●◎◇◆□■☆★◯◉♦♢▽△♥♡\\n]{1,16}?\\1|【[^】\\n]{1,16}】|〔[^〕\\n]{1,16}〕|《[^》\\n]{1,16}》|〈[^〉\\n]{1,16}〉|［[^］\\n]{1,16}］|\\[[^\\]\\n]{1,16}\\]|＜[^＞\\n]{1,16}＞)"
        let sentence="^\\s*[^.!?。！？\\n]{2,20}[.!?。！？]+(?=\\s)"
        let labelRegex=try? NSRegularExpression(pattern:label),sentenceRegex=try? NSRegularExpression(pattern:sentence)
        for i in entries.indices {
            let e=entries[i],s=e.source
            guard eligible(e),e.automaticRecovery,!e.text.contains("\r"),!e.text.contains("\n"),e.children != .unsupported,
                  strip(e.renderedText)==strip(e.text),s.width>=12,s.height>=12,e.lines.count>=2 else {continue}
            let text=e.text as NSString,range=NSRange(location:0,length:text.length)
            let delimited=labelRegex?.firstMatch(in:e.text,range:range),match=delimited ?? sentenceRegex?.firstMatch(in:e.text,range:range)
            guard let match else {continue}
            let head=text.substring(with:match.range).trimmingCharacters(in:.whitespacesAndNewlines),body=text.substring(from:NSMaxRange(match.range)).trimmingCharacters(in:.whitespacesAndNewlines)
            guard strip(body).unicodeScalars.count>=4,let observation=read(e),observation.lines.count>=2 else {continue}
            let first=observation.lines[0],rest=Array(observation.lines.dropFirst()),widest=rest.map {$0.right-$0.left}.max()!,heights=rest.map {$0.bottom-$0.top+1}.sorted(),bodyHeight=Double(heights[rest.count>>1])
            guard Double(first.right-first.left)<=(delimited != nil ? 1.1:0.8)*Double(widest),Double(rest[0].top-first.bottom)<=1.5*bodyHeight else {continue}
            if delimited==nil && (observation.lines.count<3 || Double(first.bottom-first.top+1)<1.25*bodyHeight) {continue}
            let before=e.ink,own=plates.filter {$0.ownerID==e.id},foreign=plates.filter {$0.ownerID != e.id}.map(\.rect),others=entries.filter {$0.id != e.id && $0.visible}.map(\.ink).filter {$0.width>0}
            func safe(_ m:Measurement)->Bool {
                let after=m.ink
                if after.minX<frame.minX-0.5 || after.minY<frame.minY-0.5 || after.maxX>frame.maxX+0.5 || after.maxY>frame.maxY+0.5 {return false}
                let air=max(2,e.font*0.25),grown=after.insetBy(dx:-air,dy:-air),old=before.insetBy(dx:-air,dy:-air)
                if others.contains(where:{touching(grown,$0) && !touching(old,$0)}) || foreign.contains(where:{touching(after,$0) && !touching(before,$0)}) {return false}
                if after.minX>=before.minX-0.5 && after.maxX<=before.maxX+0.5 && after.minY>=before.minY-0.5 && after.maxY<=before.maxY+0.5 {return true}
                if !own.isEmpty {
                    let covers=own.flatMap {$0.coverage ?? [$0.rect]}
                    guard own.contains(where:{after.minX>=$0.rect.minX-0.5 && after.maxX<=$0.rect.maxX+0.5 && after.minY>=$0.rect.minY-0.5 && after.maxY<=$0.rect.maxY+0.5}) else {return false}
                    return rows(m.lines).allSatisfy {r in covers.contains {r.midY>=$0.minY-0.5 && r.midY<=$0.maxY+0.5 && r.minX>=$0.minX+0.5 && r.maxX<=$0.maxX-0.5}}
                }
                guard e.isRoot,e.backgroundKind=="inpainted",let paper=e.sampledBackground,validRGB(paper) else {return false}
                let fresh=rows(m.lines).map {$0.insetBy(dx:-1,dy:-0.5)}.filter {r in !(r.minX>=min(before.minX,s.minX-2) && r.maxX<=max(before.maxX,s.maxX+2) && r.minY>=min(before.minY,s.minY-2) && r.maxY<=max(before.maxY,s.maxY+2))}
                if fresh.contains(where:{r in entries.contains {$0.id != e.id && touching(r,$0.source)}}) {return false}
                for r in fresh {
                    let w=max(1,Int(floor(r.width+0.5))),h=max(1,Int(floor(r.height+0.5)))
                    guard w*h<=budget else {return false};budget-=w*h
                    guard let rgba=reader(r,w,h),rgba.count==w*h*4 else {return false}
                    var marked=0
                    for px in 0..<(w*h) {
                        let x=r.minX+CGFloat(px%w)+0.5,y=r.minY+CGFloat(px/w)+0.5
                        if x>=s.minX-2 && x<=s.maxX+2 && y>=s.minY-2 && y<=s.maxY+2 {continue}
                        if (0..<3).reduce(0.0,{$0+abs(Double(rgba[px*4+$1])-paper[$1])})>60 {marked+=1}
                    }
                    if marked>0 {return false}
                };return true
            }
            var accepted:Measurement?,chosenWrap=e.wrap
            for wrap in e.wrap=="wrap" ? [e.wrap]:[e.wrap,"wrap"] {
                guard let m=shape(e,.init(mode:.heading,text:head+"\n"+body,wrap:wrap,width:nil,headUTF16Length:head.utf16.count)) else {continue}
                let after=rows(m.lines)
                guard m.labelRows==1,after.count<=e.lines.count+1,m.scrollSize.width<=m.clientSize.width+1 else {continue}
                let shifts:[CGFloat]=after.count>e.lines.count ? [0,before.minY-m.ink.minY,before.maxY-m.ink.maxY]:[0]
                for dy in shifts {let proposal=moved(m,dy);if safe(proposal) {accepted=proposal;chosenWrap=wrap;break}}
                if accepted != nil {break}
            }
            guard let m=accepted else {entries[i].heading="unfitted";continue}
            let settled=rows(m.lines)
            if settled.count==e.lines.count && zip(settled,e.lines).allSatisfy({a,b in abs(a.minX-b.minX)<=0.5 && abs(a.maxX-b.maxX)<=0.5 && abs(a.minY-b.minY)<=0.5 && abs(a.maxY-b.maxY)<=0.5}) {continue}
            entries[i].renderedText=head+"\n"+body;entries[i].wrap=chosenWrap;entries[i].lines=settled;entries[i].ink=m.ink;entries[i].nodeRect=m.nodeRect
            entries[i].shift.y+=m.nodeRect.minY-e.nodeRect.minY
            entries[i].nodeRect.size.height+=max(0,m.scrollSize.height-m.clientSize.height)
            if e.isRoot {entries[i].nodeRect.size.width+=max(0,m.scrollSize.width-m.clientSize.width)}
            entries[i].heading=delimited != nil ? "label":"sentence";entries[i].headingShape=m;entries[i].children = .plain;headings+=1
        }
        func flush(_ index:Int)->Bool {
            let e=entries[index],before=e.ink,oldRows=e.lines,plate=plateFor(e,parentOnly:true)
            func holds(_ rows:[CGRect],_ ink:CGRect)->Bool {
                if rows.count != oldRows.count || ink.height>before.height+0.5 || ink.minX<before.minX-0.5 || ink.maxX>before.maxX+0.5 || ink.minX<frame.minX-0.5 || ink.maxX>frame.maxX+0.5 {return false}
                guard let plate else {return true}
                return rows.indices.allSatisfy {i in
                    let r=rows[i],y=r.midY,coverage=e.sourcePanelCoverage
                    var left=plate.rect.minX
                    if let coverage,!coverage.isEmpty {let hits=coverage.filter {y>=$0.minY-0.5 && y<=$0.maxY+0.5};left=hits.isEmpty ? .infinity:max(left,hits.map(\.minX).min()!)}
                    return r.minX>=min(oldRows[i].minX,left)-0.5
                }
            }
            if e.children == .blockSpans,e.lines.count>=2 {
                let left=e.lines.map(\.minX).min()!,offsets=e.lines.map {left-$0.minX},lines=zip(e.lines,offsets).map {$0.offsetBy(dx:$1,dy:0)},ink=union(lines)
                guard holds(lines,ink) else {return false}
                entries[index].lines=lines;entries[index].ink=ink;entries[index].lineOffsets=offsets;return true
            }
            if e.children != .blockSpans {
                let width=ceil(before.width*4)/4+0.5
                for wrap in ["wrap",e.wrap] {
                    guard let m=shape(e,.init(mode:.flushPlain,text:e.renderedText,wrap:wrap,width:width,headUTF16Length:0)) else {continue}
                    let dx=before.minX-m.ink.minX,shift=abs(dx)>0.25 ? dx:0,lines=rows(m.lines).map {$0.offsetBy(dx:shift,dy:0)},ink=m.ink.offsetBy(dx:shift,dy:0)
                    guard holds(lines,ink) else {continue}
                    entries[index].lines=lines;entries[index].ink=ink;entries[index].wrapperWidth=width;entries[index].wrap=wrap
                    entries[index].lineOffsets=lines.map {before.minX-$0.minX};return true
                }
            };return false
        }
        var candidates:[Int]=[],flushed=Set<Int>()
        for i in entries.indices {
            let e=entries[i]
            guard eligible(e),e.lines.count>=2,e.source.width>=12,e.source.height>=12 else {continue}
            candidates.append(i)
            guard isFlushLeft(read(e)) else {continue};flushed.insert(i)
            if flush(i) {entries[i].alignment="left";aligned+=1}else {entries[i].alignment="left-unfitted"}
        }
        for i in candidates where !flushed.contains(i) {
            let e=entries[i]
            let leader=candidates.first {j in let o=entries[j];return o.alignment=="left" && abs(o.source.minX-e.source.minX)<=max(2,o.font*0.5) && max(o.font,e.font)<=1.3*min(o.font,e.font) && max(o.source.minY,e.source.minY)-min(o.source.maxY,e.source.maxY)<=3*max(o.font,e.font)}
            if leader != nil,flush(i) {entries[i].alignment="left-column";aligned+=1}
        }
        applyEdges(entries:&entries,frame:frame,plates:plates,holdsSurface:holdsSurface,moves:&moves)
        return .init(entries:entries,headings:headings,aligned:aligned,edgeMoves:moves,remainingPixels:budget)
    }
    private static func applyEdges(entries:inout [Entry],frame:CGRect,plates:[Plate],holdsSurface:((Entry)->Bool)?,moves:inout Int) {
        let members=entries.indices.filter {i in let e=entries[i];return eligible(e,rtl:false) && e.automaticRecovery && (e.sourceFont ?? 0)>0 && !e.paintsBackground && !e.hasBackgroundImage && e.ink.width>0}
        func shifts(_ index:Int,_ dx:CGFloat,_ before:CGRect,_ others:[CGRect])->Bool {
            let e=entries[index],after=e.ink.offsetBy(dx:dx,dy:0),lines=e.lines.map {$0.offsetBy(dx:dx,dy:0)}
            var ok=after.minX>=frame.minX-0.5 && after.maxX<=frame.maxX+0.5
            let plate=ok ? (plates.first {$0.ownerID==e.id && $0.parent} ?? plates.first {$0.ownerID==e.id}):nil
            let own=after.minX>=min(before.minX,e.source.minX)-0.5 && after.maxX<=max(before.maxX,e.source.maxX)+0.5
            if ok && plate==nil && !own {
                var proposed=e;proposed.ink=after;proposed.lines=lines;proposed.nodeRect=proposed.nodeRect.offsetBy(dx:dx,dy:0)
                ok=e.backgroundKind=="inpainted" && (holdsSurface?(proposed) ?? false)
            }
            if let plate {
                let cover=plate.coverage ?? [plate.rect]
                ok = !lines.isEmpty && lines.allSatisfy {r in cover.contains {r.midY>=$0.minY-0.5 && r.midY<=$0.maxY+0.5 && r.minX>=$0.minX+0.5 && r.maxX<=$0.maxX-0.5}}
            }
            if ok {ok = !others.contains(where:{touching(after,$0) && !touching(before,$0)}) && !plates.contains(where:{$0.ownerID != e.id && touching(after,$0.rect) && !touching(before,$0.rect)})}
            if ok {entries[index].ink=after;entries[index].lines=lines;entries[index].nodeRect=entries[index].nodeRect.offsetBy(dx:dx,dy:0);entries[index].shift.x+=dx}
            return ok
        }
        for edge in 0...1 {
            var parent=Array(members.indices)
            func find(_ i:Int)->Int {if parent[i] != i {parent[i]=find(parent[i])};return parent[i]}
            for i in members.indices {for j in members.indices where j>i {
                let a=entries[members[i]],b=entries[members[j]],small=min(a.sourceFont!,b.sourceFont!),large=max(a.sourceFont!,b.sourceFont!)
                if large/small>1.25 {continue}
                let overlap=min(a.source.maxX,b.source.maxX)-max(a.source.minX,b.source.minX),gap=max(a.source.minY,b.source.minY)-min(a.source.maxY,b.source.maxY),tol=max(2,small*0.25)
                let ae=edge==0 ? a.source.minX:a.source.maxX,be=edge==0 ? b.source.minX:b.source.maxX,ao=edge==0 ? a.source.maxX:a.source.minX,bo=edge==0 ? b.source.maxX:b.source.minX
                if overlap<0.5*min(a.source.width,b.source.width) || gap < -0.2*small || gap>3*large || abs(ae-be)>tol || abs(a.source.midX-b.source.midX)<=tol && abs(ao-bo)<=tol {continue}
                parent[find(j)]=find(i)
            }}
            var groups:[[Int]]=[],roots:[Int]=[]
            for i in members.indices {let root=find(i);if let at=roots.firstIndex(of:root) {groups[at].append(members[i])}else {roots.append(root);groups.append([members[i]])}}
            for group in groups {
                if group.count<2 || group.count<3 && !group.contains(where:{entries[$0].alignment?.hasPrefix("left") == true}) {continue}
                let inks=group.map {entries[$0].ink},offsets=group.map {edge==0 ? entries[$0].ink.minX-entries[$0].source.minX:entries[$0].ink.maxX-entries[$0].source.maxX},font=group.map {entries[$0].font}.max()!
                if offsets.max()!-offsets.min()!<=max(2,font*0.25) {continue}
                func cost(_ target:CGFloat)->CGFloat {offsets.reduce(0) {$0+abs($1-target)}}
                let sorted=offsets.sorted();var targets:[CGFloat]=[]
                for t in [CGFloat(0),sorted[(sorted.count-1)/2]]+offsets where !targets.contains(where:{abs($0-t)<0.5}) {targets.append(t)}
                targets=targets.enumerated().sorted {a,b in let ac=cost(a.element),bc=cost(b.element);return ac==bc ? a.offset<b.offset:ac<bc}.map(\.element)
                func attempt(_ target:CGFloat)->(at:Int,moved:[(Int,CGFloat)]) {
                    var at=0,moved:[(Int,CGFloat)]=[],rects=members.map {entries[$0].ink}
                    for k in group.indices {
                        let index=group[k],dx=target-offsets[k]
                        if abs(dx)<=0.5 {at+=1;continue}
                        let others=members.indices.filter {members[$0] != index}.map {rects[$0]}
                        if shifts(index,dx,inks[k],others) {moved.append((index,dx));at+=1;rects[members.firstIndex(of:index)!]=entries[index].ink}
                    };return (at,moved)
                }
                let already=offsets.map {o in offsets.filter {abs($0-o)<=0.5}.count}.max()!
                var best:(target:CGFloat,at:Int)?
                for target in targets.prefix(4) {
                    let saved=entries,result=attempt(target);entries=saved
                    if result.at>already && (best==nil || result.at>best!.at) {best=(target,result.at)}
                }
                if let best {
                    let result=attempt(best.target)
                    for (index,dx) in result.moved {entries[index].edgeShift=(edge==0 ? "left:":"right:")+String(format:"%.1f",Double(dx))}
                    moves+=result.moved.count
                }
            }
        }
    }
}
