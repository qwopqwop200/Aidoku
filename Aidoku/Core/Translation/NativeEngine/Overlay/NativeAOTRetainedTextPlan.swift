import Foundation
import CoreText
import CoreGraphics

/// Immutable source-bound actual row transport. Not a line-box estimator.
@available(iOS 16.0, macOS 13.0, *)
enum NativeAOTRetainedTextPlan {
    struct Run: Codable, Equatable, Sendable {
        let fontName: String, fontSize: Double, tracking: Double
        let range: [Int], glyphs: [Int], indices: [Int], positions: [[Double]]
    }
    struct Row: Codable, Equatable, Sendable {
        let ownedRange: [Int], paintedRange: [Int], text: String, baseline: [Double], runs: [Run]
    }
    /// Upstream source predictions and display choice remain distinct; neither is GT.
    struct Style: Codable, Equatable, Sendable {
        let sourceFillRGB: [Double]?, sourceStrokeRGB: [Double]?
        let displayFillRGB: [Double], displayStrokeWhite: Bool
        let evidenceSHA256: String, policyRevision: String
    }
    struct Plan: Codable, Equatable, Sendable {
        let sourceRGBA256: String, sourceWidth: Int, sourceHeight: Int, plannerRevision: String, style: Style
        let schema: Int, text: String, fontSize: Double, fontName: String
        let origin: [Double], scale: Double, body: [Double], ownershipComplete: Bool, unresolved: Int, rows: [Row]
    }
    enum Failure: Error {case invalid(String),canonical(String),glyph(String),clipped(String),overlap(String),allocation}
    static func checkedRange(_ values:[Int],limit:Int,owner:String) throws -> NSRange {
        guard values.count==2,values[0]>=0,values[1]>=0,values[0]<=limit,values[1]<=limit else{throw Failure.invalid(owner+"-range-bounds")}
        let (end,overflow)=values[0].addingReportingOverflow(values[1])
        guard !overflow,end<=limit else{throw Failure.invalid(owner+"-range-overflow")}
        return NSRange(location:values[0],length:values[1])
    }
    static func render(_ owners: [NativeAdmittedAOTPageRoute.Owner],width:Int,height:Int,sourceRGBA256:String) throws -> (CGImage,[[String:Any]]) {
        guard width>0,height>0,width<=16384,height<=16384,width<=12000000/height,owners.count<=256,Set(owners.map(\.id)).count==owners.count else{throw Failure.invalid("inventory")}
        var canonicalBudget=0
        for owner in owners {
            let count=owner.text.utf16.count
            guard count<=16384,count<=65536-canonicalBudget else{throw Failure.invalid("inventory-budget")}
            canonicalBudget+=count
        }
        var paths:[(CGPath,CGFloat,NativeAdmittedAOTPageRoute.Owner)]=[],bounds:[CGRect]=[],audits:[[String:Any]]=[]
        let page=CGRect(x:0,y:0,width:width,height:height)
        for o in owners {
            try Task.checkCancellation()
            guard let p=o.retainedPlan,p.sourceRGBA256==sourceRGBA256,p.sourceWidth==width,p.sourceHeight==height,
                !p.plannerRevision.isEmpty,!o.id.isEmpty,o.rect.count==4,o.rect.allSatisfy(\.isFinite),o.rect[2]>0,o.rect[3]>0,
                o.fontName==p.fontName,abs(o.fontSize-p.fontSize*p.scale)<1e-7,
                o.fillRGB==p.style.displayFillRGB,o.strokeWhite==p.style.displayStrokeWhite,
                p.style.evidenceSHA256.count==64,!p.style.policyRevision.isEmpty,
                o.fillRGB.count==3,o.fillRGB.allSatisfy({$0.isFinite && (0...1).contains($0)}),
                !o.fillRGB.allSatisfy({$0 == (o.strokeWhite ? 1:0)}) else{throw Failure.invalid(o.id+"-binding-style")}
            for rgb in [p.style.sourceFillRGB,p.style.sourceStrokeRGB].compactMap({$0}) {
                guard rgb.count==3,rgb.allSatisfy({$0.isFinite && (0...1).contains($0)})else{throw Failure.invalid(o.id+"-source-style")}
            }
            let ns=o.text as NSString
            guard p.text.utf16.elementsEqual(o.text.utf16) else{throw Failure.canonical(o.id+"-canonical-UTF16")}
            guard ns.length<=16384,p.schema==1,p.ownershipComplete,p.unresolved==0,p.origin.count==2,p.origin.allSatisfy(\.isFinite),
                  p.scale.isFinite,p.scale>0,p.fontSize.isFinite,p.fontSize*p.scale>=4,p.fontSize*p.scale<=512,!p.rows.isEmpty else{throw Failure.invalid(o.id)}
            guard p.rows.count<=ns.length+1 else{throw Failure.invalid(o.id+"-row-budget")}
            let path=CGMutablePath();var cursor=0,glyphCount=0,rowAudits:[[String:Any]]=[]
            for row in p.rows {
                guard row.ownedRange.count==2,row.paintedRange.count==2,row.baseline.count==2,row.baseline.allSatisfy(\.isFinite) else{throw Failure.invalid(o.id+"-row")}
                let owned=try checkedRange(row.ownedRange,limit:ns.length,owner:o.id),paint=try checkedRange(row.paintedRange,limit:ns.length,owner:o.id)
                guard owned.location==cursor,owned.length>=0,NSMaxRange(owned)<=ns.length,paint.location>=owned.location,paint.length>=0,
                      NSMaxRange(paint)<=NSMaxRange(owned),ns.substring(with:paint).utf16.elementsEqual(row.text.utf16) else{throw Failure.canonical(o.id+"-ranges")}
                let prefix=ns.substring(with:NSRange(location:owned.location,length:paint.location-owned.location))
                let suffix=ns.substring(with:NSRange(location:NSMaxRange(paint),length:NSMaxRange(owned)-NSMaxRange(paint)))
                guard prefix.unicodeScalars.allSatisfy({CharacterSet.whitespacesAndNewlines.contains($0)}),
                      suffix.unicodeScalars.allSatisfy({CharacterSet.whitespacesAndNewlines.contains($0)}) else{throw Failure.canonical(o.id+"-nonwhitespace-not-painted")}
                cursor=NSMaxRange(owned)
                let attributed=NSMutableAttributedString(string:row.text)
                var runCursor=0
                for r in row.runs {
                    let runRange=try checkedRange(r.range,limit:attributed.length,owner:o.id)
                    guard runRange.location==runCursor,runRange.length>0,r.glyphs.count<=runRange.length*8,
                          r.fontSize.isFinite,r.fontSize>0,(r.fontSize*p.scale).isFinite,r.fontSize*p.scale<=512,r.tracking.isFinite else{throw Failure.invalid(o.id+"-run")}
                    let font=CTFontCreateWithName(r.fontName as CFString,r.fontSize,nil)
                    guard CTFontCopyPostScriptName(font) as String == r.fontName else{throw Failure.glyph(o.id+"-font")}
                    attributed.addAttributes([.init(kCTFontAttributeName as String):font,.init(kCTKernAttributeName as String):r.tracking],range:runRange)
                    runCursor=NSMaxRange(runRange)
                }
                guard runCursor==attributed.length else{throw Failure.canonical(o.id+"-run-coverage")}
                // A CTLine verifies the stored glyph inventory; NEVER a fresh CTFrame.
                let line=CTLineCreateWithAttributedString(attributed),runs=CTLineGetGlyphRuns(line) as! [CTRun]
                guard runs.count==row.runs.count else{throw Failure.glyph(o.id+"-run-count")}
                for (run,expected) in zip(runs,row.runs) {
                    let n=CTRunGetGlyphCount(run)
                    var glyphs=[CGGlyph](repeating:0,count:n),positions=[CGPoint](repeating:.zero,count:n),indices=[CFIndex](repeating:0,count:n)
                    CTRunGetGlyphs(run,CFRange(location:0,length:0),&glyphs);CTRunGetPositions(run,CFRange(location:0,length:0),&positions)
                    CTRunGetStringIndices(run,CFRange(location:0,length:0),&indices)
                    guard glyphs.map(Int.init)==expected.glyphs,indices==expected.indices,positions.count==expected.positions.count,
                          expected.positions.allSatisfy({$0.count==2 && $0.allSatisfy(\.isFinite)}) else{throw Failure.glyph(o.id+"-inventory")}
                    let font=(CTRunGetAttributes(run) as NSDictionary)[kCTFontAttributeName] as! CTFont
                    let actualRange=CTRunGetStringRange(run)
                    guard CTFontCopyPostScriptName(font) as String==expected.fontName,abs(CTFontGetSize(font)-expected.fontSize)<1e-7,
                        actualRange.location==expected.range[0],actualRange.length==expected.range[1] else{throw Failure.glyph(o.id+"-run-identity")}
                    for j in 0..<n {
                        guard glyphs[j] != 0,abs(positions[j].x-expected.positions[j][0])<1e-7,abs(positions[j].y-expected.positions[j][1])<1e-7 else{throw Failure.glyph(o.id+"-position")}
                        if let glyph=CTFontCreatePathForGlyph(font,glyphs[j],nil) {
                            let tx=(p.origin[0]+row.baseline[0]+positions[j].x)*p.scale
                            let ty=Double(height)-(p.origin[1]+row.baseline[1]-positions[j].y)*p.scale
                            guard tx.isFinite,ty.isFinite,abs(tx)<=Double(width)+512,abs(ty)<=Double(height)+512 else{throw Failure.clipped(o.id)}
                            path.addPath(glyph,transform:CGAffineTransform(a:p.scale,b:0,c:0,d:p.scale,tx:tx,ty:ty));glyphCount+=1
                        } else {
                            let index=indices[j]
                            guard index>=0,index<(row.text as NSString).length,
                                  (row.text as NSString).substring(with:NSRange(location:index,length:1)).trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else{throw Failure.glyph(o.id+"-pathless")}
                        }
                    }
                }
                rowAudits.append(["text":row.text,"ownedRange":row.ownedRange,"paintedRange":row.paintedRange,
                    "baselineSourceTopLeft":[(p.origin[0]+row.baseline[0])*p.scale,(p.origin[1]+row.baseline[1])*p.scale],"glyphInventoryExact":true])
            }
            guard cursor==ns.length,!path.isEmpty else{throw Failure.canonical(o.id+"-whole-coverage")}
            let radius=max(2,0.20*p.fontSize*p.scale),paint=path.boundingBoxOfPath.insetBy(dx:-radius-1,dy:-radius-1)
            guard page.contains(paint)else{throw Failure.clipped(o.id)}
            guard !bounds.contains(where:{$0.intersects(paint)})else{throw Failure.overlap(o.id)}
            bounds.append(paint);paths.append((path,radius,o))
            audits.append(["id":o.id,"text":o.text,"visibleUTF16":cursor,"glyphOutlines":glyphCount,"strokeRadius":radius,
                "displayFillRGB":o.fillRGB,"displayStrokeWhite":o.strokeWhite,"sourceStyleEvidenceSHA256":p.style.evidenceSHA256,
                "transport":"retained-CTLine-runs-no-CTFrame","fontOutputPixels":p.fontSize*p.scale,"rows":rowAudits,"rowOriginsAndGlyphPositionsExact":true,
                "paintBoundsBottomLeft":[paint.minX,paint.minY,paint.width,paint.height]])
        }
        guard let c=CGContext(data:nil,width:width,height:height,bitsPerComponent:8,bytesPerRow:width*4,space:CGColorSpace(name:CGColorSpace.sRGB)!,
            bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue|CGBitmapInfo.byteOrder32Big.rawValue)else{throw Failure.allocation}
        c.setLineJoin(.round)
        for (path,radius,o) in paths {c.addPath(path);c.setLineWidth(2*radius);c.setStrokeColor(CGColor(gray:o.strokeWhite ? 1:0,alpha:1));c.strokePath()}
        for (path,_,o) in paths {c.addPath(path);c.setFillColor(CGColor(srgbRed:o.fillRGB[0],green:o.fillRGB[1],blue:o.fillRGB[2],alpha:1));c.fillPath()}
        guard let image=c.makeImage()else{throw Failure.allocation}
        let raster=try NativeAdmittedAOTPageRoute.rgba(image)
        for j in paths.indices {
            let box=bounds[j],o=paths[j].2,endpoint:UInt8=o.strokeWhite ? 255:0
            let fill=o.fillRGB.map{UInt8(($0*255).rounded())}
            var endpointPixels=0,fillPixels=0
            for y in max(0,height-Int(ceil(box.maxY)))..<min(height,height-Int(floor(box.minY))) {
                for x in max(0,Int(floor(box.minX)))..<min(width,Int(ceil(box.maxX))) {
                    let i=(y*width+x)*4
                    guard raster[i+3]==255 else{continue}
                    if raster[i]==endpoint && raster[i+1]==endpoint && raster[i+2]==endpoint {endpointPixels+=1}
                    if raster[i]==fill[0] && raster[i+1]==fill[1] && raster[i+2]==fill[2] {fillPixels+=1}
                }
            }
            guard endpointPixels>0,fillPixels>0 else{throw Failure.canonical(o.id+"-retained-style-core")}
            audits[j]["retainedOpaqueBWStrokePixels"]=endpointPixels
            audits[j]["retainedOpaqueExactFillPixels"]=fillPixels
            audits[j]["pureBWStroke"]=true
            audits[j]["allHalosBeforeAllFills"]=true
        }
        return(image,audits)
    }
}
