import CoreGraphics
import CoreText
import Foundation

/// Native measured row-effect evidence; no certificate is minted from a Double.
enum NativeEffectSafePitch {
    enum Failure:Error {case budget,invalidOwner,ownership,unboundRows,unsafeRows,clipped}
    struct Config {
        let owner:String,text:String,font:CGFloat,face:String,family:String,minimum:CGFloat
        let raw:[String:Any],style:NativeSourceStylePaint.Style?,sourceOnly:Bool
    }
    struct Span {let top:CGFloat,bottom:CGFloat}
    final class Certificate {
        let pitch:CGFloat,owner:String
        fileprivate let lines:[CTLine],ranges:[NSRange],text:String
        fileprivate init(owner:String,pitch:CGFloat,wrapped:NativeWholeWordWrap.Result) {
            self.owner=owner;self.pitch=pitch;lines=wrapped.rows.map(\.line)
            ranges=wrapped.rows.map(\.ownedRange);text=wrapped.text
        }
        func position(_ wrapped:NativeWholeWordWrap.Result,width:CGFloat)throws->NativeWholeWordGlyphPainter.PositionedRows {
            guard wrapped.text==text,wrapped.rows.map(\.ownedRange)==ranges,
                zip(wrapped.rows.map(\.line),lines).allSatisfy({$0 === $1}) else {throw Failure.unboundRows}
            let top=ceil(wrapped.rows.map {max(0,$0.inkBounds.maxY)}.max() ?? 0)+1
            let bottom=ceil(wrapped.rows.map {max(0,-$0.inkBounds.minY)}.max() ?? 0)+1
            let positions=wrapped.rows.enumerated().map {index,row in CGPoint(x:row.centeredBaselineX(width:width),y:top+CGFloat(index)*pitch)}
            var bounds=CGRect.null
            for (row,p) in zip(wrapped.rows,positions) where !row.inkBounds.isEmpty {
                bounds=bounds.union(CGRect(x:p.x+row.inkBounds.minX,y:p.y-row.inkBounds.maxY,width:row.inkBounds.width,height:row.inkBounds.height))
            }
            return .init(wrapped:wrapped,baselines:positions,fillBounds:bounds,
                size:CGSize(width:width,height:top+CGFloat(max(0,positions.count-1))*pitch+bottom))
        }
    }
    final class Context: @unchecked Sendable {
        let configs:[String:Config]
        private var floors:[String:CGFloat]=[:],certificates:[ObjectIdentifier:Certificate]=[:]
        private(set) var owner:String?
        private var pixels=0,measurements=0
        private var shapeRecords:[[String:Any]]=[]
        private(set) var finalChecks=0
        private var generations:[String:Int]=[:],admissions=0
        func recordShape(_ owner:String)throws {guard generations[owner,default:0]<8 else {throw Failure.budget};generations[owner,default:0]+=1}
        func recordAdmission()throws {guard admissions<64 else {throw Failure.budget};admissions+=1}
        func validateFamilies(_ rows:[[String:Any]])throws {
            var values:[String:CGFloat]=[:]
            for row in rows {
                guard let owner=row["id"] as? String,let c=configs[owner],let p=row["retainedLinePitchOutputPixels"] as? Double else {throw Failure.unboundRows}
                guard CGFloat(p)>=(floors[c.family] ?? 0)-1e-7 else {throw Failure.unsafeRows}
                if let prior=values[c.family],abs(prior-CGFloat(p))>1e-7 {throw Failure.unsafeRows}
                values[c.family]=CGFloat(p)
            }
        }
        init(_ values:[Config],page:CGRect)throws {
            guard !values.isEmpty,values.count<=256,Set(values.map(\.owner)).count==values.count,
                !page.isEmpty,page==page.integral,[page.width,page.height].allSatisfy(\.isFinite),
                values.allSatisfy({!$0.owner.isEmpty && !$0.text.isEmpty && $0.text.utf16.count<=8192 &&
                    $0.font.isFinite && $0.font>0 && $0.font<=2048 && $0.minimum.isFinite && $0.minimum>0}) else {throw Failure.invalidOwner}
            configs=Dictionary(uniqueKeysWithValues:values.map {($0.owner,$0)})
            for c in values {
                let font=CTFontCreateWithName(c.face as CFString,c.font,nil)
                guard CTFontCopyPostScriptName(font) as String == c.face else {throw Failure.invalidOwner}
                let line=CTLineCreateWithAttributedString(NSAttributedString(string:c.text,attributes:[
                    .init(kCTFontAttributeName as String):font,.init(kCTForegroundColorAttributeName as String):CGColor(gray:0,alpha:1)]))
                let span=try measure(line,c:c,xPhase:0,yPhase:0)
                floors[c.family]=max(floors[c.family] ?? 0,rounded(max(c.minimum,c.font*1.2,span.top+span.bottom+c.font*NativeTextSpacing.rowBreathingEm+4),font:c.font))
            }
        }
        private func rounded(_ value:CGFloat,font:CGFloat)->CGFloat {ceil(ceil(value/(font*0.1)-1e-9)*(font*0.1))}
        func activate(_ owner:String)throws {guard configs[owner] != nil else {throw Failure.invalidOwner};self.owner=owner}
        func pitchFloor()throws->CGFloat {guard let owner,let c=configs[owner],let p=floors[c.family] else {throw Failure.invalidOwner};return p}
        func certify(_ wrapped:NativeWholeWordWrap.Result)throws->Certificate {
            guard let owner,let c=configs[owner],wrapped.text==c.text,
                abs(wrapped.requestedFontSize-c.font)<1e-7,wrapped.requestedFontName==c.face,wrapped.completeOwnership,
                wrapped.unresolvedGlyphRanges.isEmpty,!wrapped.rows.isEmpty,wrapped.rows.count<=128 else {throw Failure.ownership}
            var end=0,top:CGFloat = -1e9,bottom:CGFloat = -1e9
            for row in wrapped.rows {
                guard row.ownedRange.location==end,row.ownedRange.length>0 else {throw Failure.ownership};end=NSMaxRange(row.ownedRange)
                let s=try measure(row.line,c:c,xPhase:0,yPhase:0);top=max(top,s.top);bottom=max(bottom,s.bottom)
            }
            guard end==wrapped.text.utf16.count else {throw Failure.ownership}
            let p=max(try pitchFloor(),rounded(max(c.minimum,c.font*1.2,top+bottom+c.font*NativeTextSpacing.rowBreathingEm+4),font:c.font))
            floors[c.family]=p
            let cert=Certificate(owner:owner,pitch:p,wrapped:wrapped)
            for line in cert.lines {certificates[ObjectIdentifier(line)]=cert}
            return cert
        }
        func certificate(lines:[CTLine])->Certificate? {lines.first.flatMap {certificates[ObjectIdentifier($0)]}}
        /// Uses the exact candidate CTLines and final global draw phases. No
        /// phase0 approximation or bbox assumption replaces this gate.
        func verify(lines:[CTLine],ranges:[NSRange],origins:[CGPoint],box:CGRect,font:CGFloat)throws {
            guard let cert=certificate(lines:lines),let c=configs[cert.owner],lines.count==cert.lines.count,
                ranges==cert.ranges,origins.count==lines.count,abs(font-c.font)<1e-7,
                zip(lines,cert.lines).allSatisfy({$0 === $1}),cert.pitch>=(floors[c.family] ?? .infinity) else {throw Failure.unboundRows}
            var spans:[Span]=[]
            for (line,origin) in zip(lines,origins) {
                let x=box.minX+origin.x,y=box.minY+origin.y
                spans.append(try measure(line,c:c,xPhase:x-floor(x),yPhase:y-floor(y)))
            }
            for index in lines.indices.dropFirst() {
                let step=origins[index].y-origins[index-1].y
                guard abs(step-cert.pitch)<1e-7,
                    step-spans[index-1].bottom-spans[index].top>=c.font*NativeTextSpacing.rowBreathingEm-1e-7 else {throw Failure.unsafeRows}
            }
            finalChecks+=1
            if shapeRecords.count<128 {
                let font=CTFontCreateWithName(c.face as CFString,c.font,nil)
                let native=NativeTextSpacing.pitch(text:c.text,font:font,fontSize:c.font,
                    outwardExtent:NativeTextSpacing.outwardExtent(raw:c.raw,fontSize:c.font))
                let gaps=lines.indices.dropFirst().map {origins[$0].y-origins[$0-1].y-spans[$0-1].bottom-spans[$0].top}
                let row:[String:Any]=["owner":cert.owner,"font":c.font,"rows":ranges.count,"pitch":cert.pitch,
                    "nativeDefaultPitch":native,"minimumActualGap":gaps.min() as Any? ?? NSNull(),
                    "requiredBreathing":c.font*NativeTextSpacing.rowBreathingEm,"ranges":ranges.map {[$0.location,$0.length]}]
                shapeRecords.append(row)
            }
        }
        var audit:[String:Any] {["familyPitchPixels":floors,"measurements":measurements,"measurementPixels":pixels,
            "finalActualPhaseChecks":finalChecks,"verifiedShapes":shapeRecords,"shapeGenerations":generations,"nativeAdmissions":admissions,"maxMeasurementPixels":64_000_000,"maxMeasurements":1024,
            "rowGapPolicy":"actual-row-effect-envelope plus .12em breathing; requested min + family max",
            "actualGuardAndSourceBandsUnchanged":true,"typedRowOwnershipRequired":true]}
        private func measure(_ line:CTLine,c:Config,xPhase:CGFloat,yPhase:CGFloat)throws->Span {
            try Task.checkCancellation()
            let ink=CTLineGetBoundsWithOptions(line,[.useGlyphPathBounds])
            if ink.isEmpty || ink.isNull {return .init(top:0,bottom:0)}
            let outward=NativeTextSpacing.outwardExtent(raw:c.raw,fontSize:c.font)
            let scale=c.style.map {Double(c.font)/$0.sourceFontPixels} ?? 1
            let shadow=c.style?.shadow.map {max(abs($0.offset[0]),abs($0.offset[1]))*scale} ?? 0
            let pad=Int(ceil(outward+c.font+CGFloat(shadow)))+16
            let width=Int(ceil(ink.width))+pad*2+8,height=Int(ceil(c.font*2+ink.height))+pad*2+8
            guard width>0,height>0,width<=16384,height<=16384,width<=8_000_000/height,
                pixels<=64_000_000-width*height,measurements<1024 else {throw Failure.budget}
            pixels+=width*height;measurements+=1
            func canvas(_ white:Bool=false)throws->CGContext {
                guard let ctx=CGContext(data:nil,width:width,height:height,bitsPerComponent:8,bytesPerRow:width*4,
                    space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else {throw Failure.budget}
                if white {ctx.setFillColor(CGColor(gray:1,alpha:1));ctx.fill(CGRect(x:0,y:0,width:width,height:height))};return ctx
            }
            let baselineTop=CGFloat(pad)+ceil(max(0,ink.maxY))+yPhase
            let ctx=try canvas();ctx.textMatrix = .identity
            ctx.textPosition=CGPoint(x:CGFloat(pad)-floor(ink.minX)+xPhase,y:CGFloat(height)-baselineTop);CTLineDraw(line,ctx)
            guard let fill=ctx.makeImage(),let background=try canvas(true).makeImage() else {throw Failure.budget}
            let endpoint=(c.raw["ensembleDisplayStroke"] as? [Double])?.first ?? 0
            let layer=try NativeMandatoryDisplayStroke.prepare(fill:fill,restored:background,fontOutputPixels:c.font,
                outwardEm:CGFloat((c.raw["ensembleStrokeRatio"] as? Double) ?? 0.2),
                forcedEndpoint:endpoint>127 ? 255:0,sourceAppearance:c.raw["sourceAppearance"] as? [String:Any],sourceContourOnly:c.sourceOnly)
            let painted=try canvas()
            if let style=c.style {_ = try NativeSourceStylePaint.paint(style,fill:layer.fill,frame:layer.frame,fontPixels:c.font,
                mandatoryOutward:layer.outwardPixels,pageHeight:height,context:painted)}
            NativeMandatoryDisplayStroke.paint([layer],in:painted)
            guard let image=painted.makeImage() else {throw Failure.budget}
            let bytes=try NativeMandatoryDisplayStroke.rgba(image);var top=height,bottom=0,left=width,right=0
            for y in 0..<height {for x in 0..<width where bytes[(y*width+x)*4+3]>0 {top=min(top,y);bottom=max(bottom,y+1);left=min(left,x);right=max(right,x+1)}}
            guard top>0,left>0,bottom<height,right<width,bottom>top else {throw Failure.clipped}
            return .init(top:baselineTop-CGFloat(top),bottom:CGFloat(bottom)-baselineTop)
        }
    }
    /// Enabled only after an unchanged complete legacy page attempt fails.
    @TaskLocal static var fallbackEnabled=false
    @TaskLocal static var current:Context?
}
