import Foundation

/// Correct only the historical chromatic caller's missing foreign layout mask.
/// Its original OCR exclusions remain the authority; native output is never input.
/// This opt-in reference cannot paint, erase, or upgrade any source certificate.
enum FrozenForeignLayoutExclusionReference {
    static let contract = "frozen-web-with-foreign-layout-exclusions-v1"
    enum TransformError: Error { case missingOrAmbiguousMarker }
    static let marker = "// A joined unit erases only its members' boxes and its balloon's interior: its union rectangle may"

    static let correction = #"""
    if(!detached&&restored?.method==='chromatic-balloon-glyphs'&&
        restored.sourceErasureVerified===true&&restored.sourceGlyphsVerified===true){
      if(!Number.isInteger(w)||!Number.isInteger(h)||w<=0||h<=0||w*h>262144||
          restored.rgba?.length!==w*h*4||restored.layoutSafe?.length!==w*h||
          !Array.isArray(rubyExclusions)||rubyExclusions.length>256)
        throw new Error('Invalid foreign layout exclusion reference input');
      const referenceForeignSafe=restored.layoutSafe.slice(),referenceForeignMask=new Uint8Array(w*h);
      const referenceForeignRGBA=restored.rgba.slice(),referenceSourceRGBA=original.slice();
      const referenceProof=()=>JSON.stringify(Object.fromEntries(Object.entries(restored)
        .filter(([key])=>key!=='rgba'&&key!=='layoutSafe')));
      const referenceProofBefore=referenceProof();
      let referenceExcludedPixels=0,referenceAddedUnsafe=0,referenceForeignInk=0;
      for(const r of rubyExclusions){
        if(!Array.isArray(r)||r.length!==4||!r.every(Number.isFinite)||r[2]<=0||r[3]<=0)
          throw new Error('Invalid original foreign OCR rectangle');
        const local=[(r[0]*iw-x)*sx,(r[1]*ih-y)*sy,r[2]*iw*sx,r[3]*ih*sy];
        const left=Math.max(0,Math.min(w,Math.floor(local[0])));
        const top=Math.max(0,Math.min(h,Math.floor(local[1])));
        const right=Math.max(0,Math.min(w,Math.ceil(local[0]+local[2])));
        const bottom=Math.max(0,Math.min(h,Math.ceil(local[1]+local[3])));
        for(let yy=top;yy<bottom;yy++)for(let xx=left;xx<right;xx++){
          const index=yy*w+xx;
          if(referenceForeignMask[index])continue;
          referenceForeignMask[index]=1;referenceExcludedPixels++;
          // This repair covers only an omitted placement restriction. Foreign
          // source-paint overlap needs a different proof and must fail loudly.
          if(restored.rgba[index*4+3]!==0)
            throw new Error('Foreign painted source cannot receive a layout-only reference repair');
          if(referenceForeignSafe[index])referenceAddedUnsafe++;
          referenceForeignSafe[index]=0;
          const bg=palette?.background;
          if(original[index*4+3]===255&&bg?.length===3&&
              Math.max(...bg.map((v,c)=>Math.abs(original[index*4+c]-v)))>=24)referenceForeignInk++;
        }
      }
      if(referenceAddedUnsafe>0){
        restored.layoutSafe=referenceForeignSafe;
        const rgbaUnchanged=restored.rgba.every((v,i)=>v===referenceForeignRGBA[i]);
        const sourceUnchanged=original.every((v,i)=>v===referenceSourceRGBA[i]);
        const proofUnchanged=referenceProof()===referenceProofBefore;
        if(!rgbaUnchanged||!sourceUnchanged||!proofUnchanged)
          throw new Error('Foreign layout reference changed source paint or restoration proof');
        (globalThis.__aidokuReferenceForeignLayoutTrace ||= []).push({id:String(item.id),
          excludedPixels:referenceExcludedPixels,addedUnsafePixels:referenceAddedUnsafe,
          foreignInkPixels:referenceForeignInk,rgbaUnchanged,sourceUnchanged,proofUnchanged});
      }
    }
    """#

    static func correcting(_ script: String) throws -> String {
        guard script.components(separatedBy: marker).count == 2 else {
            throw TransformError.missingOrAmbiguousMarker
        }
        return script.replacingOccurrences(of: marker, with: correction + "\n" + marker)
    }
}
