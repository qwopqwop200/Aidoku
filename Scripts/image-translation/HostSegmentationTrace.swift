import Foundation

/// Wraps host-only renderer copies. The original return values and exceptions are preserved.
enum HostSegmentationTrace {
    static let script = #"""
    globalThis.__aidokuHostSegmentationTrace={captures:[],dropped:0,pixels:0,forcedPixels:0,forcedCaptures:0};
    function aidokuHostCapture(name,original,args,result,polygonOnly) {
      const trace=globalThis.__aidokuHostSegmentationTrace;
      const w=Number(args[polygonOnly?0:1]),h=Number(args[polygonOnly?1:2]);
      if(!Number.isInteger(w)||!Number.isInteger(h)||w<=0||h<=0)return;
      const forced=name==='aidokuForceInpaintSource'||name==='aidokuForceInpaintSourceComponent';
      if(forced){if(trace.forcedCaptures>=20||trace.forcedPixels+w*h>12000000){trace.dropped++;return;}
        trace.forcedCaptures++;trace.forcedPixels+=w*h;
      }else{if(trace.captures.length-trace.forcedCaptures>=64||trace.pixels+w*h>8000000){trace.dropped++;return;}
        trace.pixels+=w*h;}
      const rgba=polygonOnly?null:args[0],box=args[polygonOnly?2:3];
      const entry={function:name,kind:polygonOnly?'polygon-ownership':'glyph-mask',width:w,height:h,box:box,status:result?'returned':'null',selectedPixels:0};
      if(!polygonOnly){
        const palette=args[4],options=args[5];
        if(palette)entry.palette={foreground:palette.foreground,background:palette.background,stroke:palette.stroke,
          confidence:palette.confidence,sourceInk:palette.sourceInk};
        if(options&&typeof options==='object')entry.options={vertical:options.vertical,glyphSize:options.glyphSize,sampleScale:options.sampleScale,
          polygons:options.polygons,excludedPolygons:options.excludedPolygons,auxiliary:options.auxiliary,excluded:options.excluded,
          donorExcluded:options.donorExcluded,trailing:options.trailing,requireSafeDonors:options.requireSafeDonors};
      }
      const mask=result&&result.length===w*h?result:(result&&result.mask&&result.mask.length===w*h?result.mask:
        result&&result.layoutSafe&&result.layoutSafe.length===w*h?result.layoutSafe:null);
      const repaired=result&&result.rgba&&result.rgba.length===w*h*4?result.rgba:null;
      if(repaired&&!mask)entry.kind='repair-delta';
      if(forced&&!result)entry.failure=name==='aidokuForceInpaintSourceComponent'
        ?aidokuForceInpaintSourceComponent.lastFailure:aidokuForceInpaintSource.lastFailure;
      if(result&&result.method)entry.method=result.method;
      if(result&&Number.isFinite(result.erased))entry.erased=result.erased;
      if(result&&result.quality)entry.quality=result.quality;
      if(result&&result.forcedMaskMode)entry.maskMode=result.forcedMaskMode;
      entry.evidence={};
      for(const field of ['sourceCorePixels','sourceComponents','sourceCoreCandidateCount','sourceCoreCandidateCovered','sourceOutlineCandidateCount','sourceOutlineCandidateCovered'])if(result&&Number.isFinite(result[field]))entry.evidence[field]=result[field];
      function canvas(){const c=document.createElement('canvas');c.width=w;c.height=h;return c;}
      let source=null;
      if(rgba&&rgba.length===w*h*4){source=canvas();source.getContext('2d').putImageData(new ImageData(new Uint8ClampedArray(rgba),w,h),0,0);entry.source=source.toDataURL('image/png');}
      if(repaired&&source){
        const c=canvas(),ctx=c.getContext('2d');ctx.drawImage(source,0,0);
        const layer=canvas();layer.getContext('2d').putImageData(new ImageData(new Uint8ClampedArray(repaired),w,h),0,0);
        ctx.drawImage(layer,0,0);entry.repaired=c.toDataURL('image/png');
      }
      if(mask||repaired){
        const c=canvas(),ctx=c.getContext('2d'),im=ctx.createImageData(w,h);
        const o=canvas(),ox=o.getContext('2d');if(source)ox.drawImage(source,0,0);
        const overlay=ox.createImageData(w,h);
        for(let i=0;i<w*h;i++){
          const p=i*4,selected=mask?!!mask[i]:(rgba&&[0,1,2].some(k=>rgba[p+k]!==repaired[p+k]));
          im.data[p]=im.data[p+1]=im.data[p+2]=selected?255:0;im.data[p+3]=255;
          if(selected){entry.selectedPixels++;overlay.data[p]=255;overlay.data[p+1]=40;overlay.data[p+2]=110;overlay.data[p+3]=150;}
        }
        ctx.putImageData(im,0,0);entry.mask=c.toDataURL('image/png');
        const layer=canvas();layer.getContext('2d').putImageData(overlay,0,0);ox.drawImage(layer,0,0);entry.overlay=o.toDataURL('image/png');
      }
      trace.captures.push(entry);
    }
    if(typeof aidokuReadablePolygonMask==='function'){
      const aidokuHostReadableOriginal=aidokuReadablePolygonMask;
      aidokuReadablePolygonMask=function(...args){const result=aidokuHostReadableOriginal.apply(this,args);try{aidokuHostCapture('aidokuReadablePolygonMask',aidokuHostReadableOriginal,args,result,false);}catch(_){}return result;};
    }
    const aidokuHostForcedOriginal=aidokuForcedTextMask;
    aidokuForcedTextMask=function(...args){const result=aidokuHostForcedOriginal.apply(this,args);try{aidokuHostCapture('aidokuForcedTextMask',aidokuHostForcedOriginal,args,result,false);}catch(_){}return result;};
    if(typeof aidokuSourcePolygonMask==='function'){
      const aidokuHostPolygonOriginal=aidokuSourcePolygonMask;
      aidokuSourcePolygonMask=function(...args){const result=aidokuHostPolygonOriginal.apply(this,args);try{aidokuHostCapture('aidokuSourcePolygonMask',aidokuHostPolygonOriginal,args,result,true);}catch(_){}return result;};
    }
    if(typeof aidokuRestoreSourcePanel==='function'){const original=aidokuRestoreSourcePanel;aidokuRestoreSourcePanel=function(...args){const result=original.apply(this,args);try{aidokuHostCapture('aidokuRestoreSourcePanel',original,args,result,false);}catch(_){}return result;};}
    if(typeof aidokuEnclosedPaperRestore==='function'){const original=aidokuEnclosedPaperRestore;aidokuEnclosedPaperRestore=function(...args){const result=original.apply(this,args);try{aidokuHostCapture('aidokuEnclosedPaperRestore',original,args,result,false);}catch(_){}return result;};}
    if(typeof aidokuLocalComponentRestore==='function'){const original=aidokuLocalComponentRestore;aidokuLocalComponentRestore=function(...args){const result=original.apply(this,args);try{aidokuHostCapture('aidokuLocalComponentRestore',original,args,result,false);}catch(_){}return result;};}
    if(typeof aidokuRuledGridRestore==='function'){const original=aidokuRuledGridRestore;aidokuRuledGridRestore=function(...args){const result=original.apply(this,args);try{aidokuHostCapture('aidokuRuledGridRestore',original,args,result,false);}catch(_){}return result;};}
    if(typeof aidokuRestoreChromaticBalloonGlyphs==='function'){const original=aidokuRestoreChromaticBalloonGlyphs;aidokuRestoreChromaticBalloonGlyphs=function(...args){const result=original.apply(this,args);try{aidokuHostCapture('aidokuRestoreChromaticBalloonGlyphs',original,args,result,false);}catch(_){}return result;};}
    if(typeof aidokuRestoreSlantedSource==='function'){const original=aidokuRestoreSlantedSource;aidokuRestoreSlantedSource=function(...args){const result=original.apply(this,args);try{aidokuHostCapture('aidokuRestoreSlantedSource',original,args,result,false);}catch(_){}return result;};}
    if(typeof aidokuSourceInkMask==='function'){const original=aidokuSourceInkMask;aidokuSourceInkMask=function(...args){const result=original.apply(this,args);try{aidokuHostCapture('aidokuSourceInkMask',original,args,result,false);}catch(_){}return result;};}
    if(typeof aidokuForceInpaintSourceComponent==='function'){const original=aidokuForceInpaintSourceComponent;aidokuForceInpaintSourceComponent=function(...args){const result=original.apply(this,args);try{aidokuHostCapture('aidokuForceInpaintSourceComponent',original,args,result,false);}catch(_){}return result;};}
    if(typeof aidokuForceInpaintSource==='function'){const original=aidokuForceInpaintSource;aidokuForceInpaintSource=function(...args){const result=original.apply(this,args);try{aidokuHostCapture('aidokuForceInpaintSource',original,args,result,false);}catch(_){}return result;};}
    """#
    static func save(_ value: Any?, directory: URL) throws {
        guard var trace = value as? [String: Any] else { return }
        let relativeFolder = "analysis/segmentation/" + UUID().uuidString
        let folder = directory.appendingPathComponent(relativeFolder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var records = trace["captures"] as? [[String: Any]] ?? []
        for index in records.indices {
            for field in ["source", "mask", "overlay", "repaired"] {
                guard let encoded = records[index][field] as? String, encoded.hasPrefix("data:image/png;base64,"),
                      let data = Data(base64Encoded: String(encoded.dropFirst("data:image/png;base64,".count))) else { continue }
                let name = String(format: "%03d-", index + 1) + field + ".png"
                try data.write(to: folder.appendingPathComponent(name), options: .atomic)
                records[index][field] = relativeFolder + "/" + name
            }
        }
        trace["captures"] = records
        HostDump.capture("segmentation-trace", trace)
    }
}
