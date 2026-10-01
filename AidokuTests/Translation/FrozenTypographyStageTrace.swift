import Foundation

/// Read-only probes inserted into a disposable runtime copy of the frozen script.
/// The baseline file and the ordinary oracle render are never modified.
enum FrozenTypographyStageTrace {
    enum TraceError: Error { case missingOrAmbiguousMarker(String) }

    static func instrument(_ script: String, regionIDs: [String]) throws -> String {
        let selectedData = try JSONEncoder().encode(regionIDs)
        let selected = String(decoding: selectedData, as: UTF8.self)
        let checkpoints: [(String, String)] = [
            ("const growPlate=(node,cap=Infinity,strict=false,styleGlyph=0,condensedOnly=false)=>{", "before-growth"),
            ("// Whole words for captions set in place on their restorations.", "after-growth"),
            ("const harmonyStarted=performance.now();", "after-word-repair"),
            ("// After the rows: same-style captions anywhere on the page", "after-row-size"),
            ("// Interface rows (game or visual-novel button bars, menus, credit\n", "after-page-style"),
            ("// Vertical-source rows: side-by-side source columns of one lettering", "after-interface"),
            ("// Axis: along each shared line/column, the aligned edge of every", "after-column-size"),
            ("// Condensed width (장평) for word-bound captions, after every size", "after-axis"),
            ("// Final cohort snap: the growth passes above size each caption on its", "after-condensed"),
            ("// Late whole-word repair: after every size harmony pass, a caption", "after-cohort")
        ]
        var instrumented = script
        for (marker, stage) in checkpoints {
            guard instrumented.components(separatedBy: marker).count == 2 else {
                throw TraceError.missingOrAmbiguousMarker(marker)
            }
            let probe = """
            (globalThis.__aidokuTypographyStageTrace ||= []).push({stage:'\(stage)',
              cards:Array.from(root.querySelectorAll('[data-aidoku-image-ocr-overlay="item"]'))
                .filter(n=>\(selected).includes(n.dataset.aidokuRegion)).map(n=>{
                  const range=document.createRange();range.selectNodeContents(n);
                  const rect=r=>[r.x,r.y,r.width,r.height];
                  return {id:n.dataset.aidokuRegion,css:n.style.cssText,text:n.textContent,dataset:{...n.dataset},
                    rect:rect(n.getBoundingClientRect()),ink:rect(range.getBoundingClientRect()),
                    lineRects:Array.from(range.getClientRects(),rect)};} )});
            """
            instrumented = instrumented.replacingOccurrences(of: marker, with: probe + "\n" + marker)
        }
        let inputMarker = "// Handwriting on ruled or grid paper keeps its rules; see aidokuRuledGridRestore."
        let resultMarker = "if(prepared.unitResidue)unitResidueRisk.add(item);"
        guard instrumented.components(separatedBy: inputMarker).count == 2,
              instrumented.components(separatedBy: resultMarker).count == 2 else {
            throw TraceError.missingOrAmbiguousMarker("initial restoration input/result")
        }
        let inputProbe = """
        if(\(selected).includes(String(item.id))){
          let bytes='';for(let start=0;start<original.length;start+=8192)
            bytes+=String.fromCharCode(...original.subarray(start,Math.min(original.length,start+8192)));
          const transform=r=>[(r[0]*iw-x)*sx,(r[1]*ih-y)*sy,r[2]*iw*sx,r[3]*ih*sy];
          (globalThis.__aidokuRestorationInputTrace ||= []).push(JSON.parse(JSON.stringify({
            id:String(item.id),detached,b,frame,sourceSize:[iw,ih],crop:[x,y,sourceWidth,sourceHeight],
            raster:[w,h],scale:[sx,sy],palette,rgbaBase64:btoa(bytes),
            options:{readabilityGate:true,chromaticBalloon:Boolean(item.balloonInterior?.contourVerified),
              sampleScale:Math.min(sx,sy),auxiliary:auxiliary.map(transform),
              inferredRubyExclusions:rubyExclusions.map(transform),leadingRule,vertical:Boolean(item.sourceVertical),
              ...(rowEndMarks.length?{rowEndMarks:rowEndMarks.map(transform)}:{})}})));
        }
        """
        instrumented = instrumented.replacingOccurrences(of: inputMarker, with: inputProbe + "\n" + inputMarker)
        let resultProbe = """
        if(\(selected).includes(String(item.id)))
          (globalThis.__aidokuRestorationResultTrace ||= []).push(JSON.parse(JSON.stringify({
            id:String(item.id),detached,b,frame,sourceSize:[iw,ih],crop:[x,y,sourceWidth,sourceHeight],
            raster:[w,h],palette,result:result?{method:result.method,erased:result.erased,
              sourceErasureVerified:result.sourceErasureVerified,sourceGlyphsVerified:result.sourceGlyphsVerified,
              surfaceQuality:result.surfaceQuality,localProposal:result.localProposal}:null})));
        if(prepared.unitResidue)unitResidueRisk.add(item);
        """
        instrumented = instrumented.replacingOccurrences(of: resultMarker, with: resultProbe)
        let growthMarker = "const candidate=layout(widths[index]);last=candidate?widths[index]:null;"
        let exceptionMarker = "if(error===unsupportedSurfaceGrowth)return null;"
        guard instrumented.components(separatedBy: growthMarker).count == 2,
              instrumented.components(separatedBy: exceptionMarker).count == 2 else {
            throw TraceError.missingOrAmbiguousMarker("restored growth width/exception")
        }
        let growthProbe = """
        const candidate=layout(widths[index]);last=candidate?widths[index]:null;
        if(\(selected).includes(String(item.id))&&(globalThis.__aidokuTypographyStageTrace?.length||0)<256)
          (globalThis.__aidokuTypographyStageTrace ||= []).push({stage:'restored-growth-width',id:String(item.id),
            size,widths,index,wordWidth,advance,font,anchor:[anchorX,anchorY],original,box,
            candidate,css:node.style.cssText,dataset:{...node.dataset}});
        """
        let exceptionProbe = """
        if(error===unsupportedSurfaceGrowth){
          if(\(selected).includes(String(item.id)))
            (globalThis.__aidokuTypographyStageTrace ||= []).push({stage:'unsupported-surface-growth',id:String(item.id),
              accepted,growStateFont:growState.font,css:node.style.cssText,dataset:{...node.dataset}});
          return null;
        }
        """
        instrumented = instrumented.replacingOccurrences(of: growthMarker, with: growthProbe)
        instrumented = instrumented.replacingOccurrences(of: exceptionMarker, with: exceptionProbe)
        let profileMarker = "const original=lineProfile(),box=aidokuCaptionInkFrame(original?.ink,font);"
        let growthStart = "growBalloon: (cap=Infinity, extraBreaks=1, styleGlyph=0, condensedOnly=false) => {"
        let growthEnd = "// A caption set in place on its restoration can inherit the narrow"
        guard instrumented.components(separatedBy: growthStart).count == 2,
              instrumented.components(separatedBy: growthEnd).count == 2,
              let begin = instrumented.range(of: growthStart), let end = instrumented.range(of: growthEnd),
              begin.upperBound < end.lowerBound else {
            throw TraceError.missingOrAmbiguousMarker("restored growth body")
        }
        let growthRange = begin.upperBound..<end.lowerBound
        guard String(instrumented[growthRange]).components(separatedBy: profileMarker).count == 2,
              let profileRange = instrumented.range(of: profileMarker, range: growthRange) else {
            throw TraceError.missingOrAmbiguousMarker("restored growth measurement profile")
        }
        let profileProbe = """
        const original=lineProfile(),box=aidokuCaptionInkFrame(original?.ink,font);
        if(\(selected).includes(String(item.id))){
          const inspect=n=>{
            const cs=getComputedStyle(n),r=n.getBoundingClientRect(),walker=document.createTreeWalker(n,NodeFilter.SHOW_TEXT);
            const keys=['fontFamily','fontWeight','fontSize','fontStyle','fontStretch','fontVariant','fontFeatureSettings',
              'fontKerning','fontSynthesis','textRendering','letterSpacing','wordSpacing','lineHeight','direction','writingMode',
              'whiteSpace','wordBreak','overflowWrap','textWrap','textIndent','textTransform','zoom','transform','scale'];
            const scalarRects=[];let child;
            while(child=walker.nextNode()){let offset=0;for(const scalar of child.data){
              const next=offset+scalar.length;
              if(!/\\s/u.test(scalar)){
                const range=document.createRange();range.setStart(child,offset);range.setEnd(child,next);
                const parts=Array.from(range.getClientRects()).filter(q=>q.width>0&&q.height>0);
                const q=parts.length?parts[parts.length-1]:range.getBoundingClientRect();
                scalarRects.push({scalar,local:[q.left-r.left,q.top-r.top,q.width,q.height]});
              }offset=next;
            }}
            return {css:n.style.cssText,computed:Object.fromEntries(keys.map(k=>[k,cs[k]])),
              rect:[r.x,r.y,r.width,r.height],scalarRects,parentCSS:n.parentElement?.style.cssText};
          };
          (globalThis.__aidokuTypographyStageTrace ||= []).push({stage:'restored-growth-profile',id:String(item.id),
            original,box,live:inspect(node),measurement:inspect(measurementNode)});
        }
        """
        instrumented.replaceSubrange(profileRange, with: profileProbe)
        let candidateMarker = "if(condensed&&(candidate.hangulIsolated>original.hangulIsolated||candidate.lines>original.lines+1))return null;"
        let shiftMarker = "return best?[best.dx/kx,best.dy/ky]:null;"
        for marker in [candidateMarker, shiftMarker] {
            guard instrumented.components(separatedBy: marker).count == 2 else {
                throw TraceError.missingOrAmbiguousMarker("restored growth placement: " + marker)
            }
        }
        let candidateProbe = """
        if(\(selected).includes(String(item.id))&&(globalThis.__aidokuTypographyCandidateCount||0)<256){
          globalThis.__aidokuTypographyCandidateCount=(globalThis.__aidokuTypographyCandidateCount||0)+1;
          (globalThis.__aidokuTypographyStageTrace ||= []).push({stage:'restored-growth-candidate',id:String(item.id),
            size,candidateWidth,anchor:[anchorX,anchorY],candidate,css:node.style.cssText});
        }
        """
        instrumented = instrumented.replacingOccurrences(of: candidateMarker, with: candidateMarker + candidateProbe)
        let shiftProbe = """
        if(\(selected).includes(String(item.id))&&(globalThis.__aidokuTypographyShiftCount||0)<64){
          globalThis.__aidokuTypographyShiftCount=(globalThis.__aidokuTypographyShiftCount||0)+1;
          (globalThis.__aidokuTypographyStageTrace ||= []).push({stage:'restored-growth-shift',id:String(item.id),size,
            frame:[frameBox.left,frameBox.top,frameBox.right-frameBox.left,frameBox.bottom-frameBox.top],
            crop:[cx0,cy0,w/kx,h/ky],raster:[w,h],scale:[kx,ky],origin:[ox,oy],block:[bw,bh],
            bounds:[bl,bt,br,bb],reach,blockedPixels:sat[sat.length-1],best:best?[best.dx,best.dy,best.d]:null,
            obstacles:[...otherBackgrounds,...otherInks].map(r=>[r.left,r.top,r.width,r.height])});
        }
        return best?[best.dx/kx,best.dy/ky]:null;
        """
        instrumented = instrumented.replacingOccurrences(of: shiftMarker, with: shiftProbe)
        return instrumented
    }
}
