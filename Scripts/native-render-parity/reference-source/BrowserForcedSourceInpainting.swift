// Last-resort erasure for source lettering that the art-preserving restorer cannot certify.
// The caller uses this only for remaining source-readability cards. Unlike the primary
// restorer, this path may reconstruct illustrated pixels to leave no opaque cards.
enum BrowserForcedSourceInpainting {
    static let script = """
        function aidokuForceInpaintSource(rgba,w,h,box,palette,options={}) {
          aidokuForceInpaintSource.lastFailure='';
          const fail=reason=>{aidokuForceInpaintSource.lastFailure=reason;return null;};
          const n=w*h;
          if(!rgba||rgba.length!==n*4||w<5||h<5||!Array.isArray(box)||box.length!==4||
              !box.every(Number.isFinite)||box[2]<=0||box[3]<=0)return fail('invalid-crop');
          const auxiliary=Array.isArray(options.auxiliary)?options.auxiliary:[];
          const geometry=typeof aidokuOCRGeometryMask==='function'
            ?aidokuOCRGeometryMask(w,h,options.polygons,options.excludedPolygons,7):null;
          const boxes=[box,...auxiliary].filter(r=>Array.isArray(r)&&r.length===4&&r.every(Number.isFinite)&&r[2]>0&&r[3]>0);
          const bounds=new Uint8Array(n),ownedCore=new Uint8Array(n),protectedPixels=new Uint8Array(n);
          // The OCR rectangle is occasionally a few glyph pixels short. Expand only
          // its source-owned neighborhood; keep neighbouring captions as donors.
          const margin=Math.max(8,Math.min(24,Math.round(Math.min(box[2],box[3])*.1)));
          const trailing=Math.max(0,Math.min(96,Number(options.trailing)||0));
          for(const r of boxes){
            const x0=Math.max(1,Math.floor(r[0]-margin)),y0=Math.max(1,Math.floor(r[1]-margin));
            const x1=Math.min(w-2,Math.ceil(r[0]+r[2]+margin+(options.vertical?0:trailing)));
            const y1=Math.min(h-2,Math.ceil(r[1]+r[3]+margin+(options.vertical?trailing:0)));
            for(let y=y0;y<=y1;y++)bounds.fill(1,y*w+x0,y*w+x1+1);
            const cx0=Math.max(1,Math.floor(r[0]-3)),cy0=Math.max(1,Math.floor(r[1]-3));
            const cx1=Math.min(w-2,Math.ceil(r[0]+r[2]+3)),cy1=Math.min(h-2,Math.ceil(r[1]+r[3]+3));
            for(let y=cy0;y<=cy1;y++)ownedCore.fill(1,y*w+cx0,y*w+cx1+1);
          }
          if(geometry)for(let i=0;i<n;i++)if(!geometry[i]){bounds[i]=0;ownedCore[i]=0;}
          for(const r of Array.isArray(options.excluded)?options.excluded:[]){
            if(!Array.isArray(r)||r.length!==4||!r.every(Number.isFinite))continue;
            const x0=Math.max(1,Math.floor(r[0]-2)),y0=Math.max(1,Math.floor(r[1]-2));
            const x1=Math.min(w-2,Math.ceil(r[0]+r[2]+2)),y1=Math.min(h-2,Math.ceil(r[1]+r[3]+2));
            for(let y=y0;y<=y1;y++)protectedPixels.fill(1,y*w+x0,y*w+x1+1);
          }
          let mask=null,segmented=false;
          if(typeof aidokuForcedTextMask==='function')try {
            const candidate=aidokuForcedTextMask(rgba,w,h,box,palette,options);
            if(candidate?.length===n){mask=Uint8Array.from(candidate);segmented=true;}
            else if(candidate?.mask?.length===n){mask=Uint8Array.from(candidate.mask);segmented=true;}
          }catch(_error){}
          if(!mask)mask=new Uint8Array(n);
          // An overlapping OCR neighbour never vetoes this item's own source
          // rectangle. Each neighbour receives its own erasure patch as well.
          for(let i=0;i<n;i++)if(!bounds[i]||protectedPixels[i]&&!ownedCore[i])mask[i]=0;
          const foreground=palette?.sourceInk?.foreground||palette?.foreground;
          const stroke=palette?.sourceInk?.stroke||((palette?.confidence?.stroke||0)>=.55&&
            palette?.foreground&&foreground&&Math.max(...palette.foreground.map((v,k)=>Math.abs(v-foreground[k])))<=24?palette.stroke:null);
          const colorAt=(i,color)=>color&&color.length>=3?
            Math.max(Math.abs(rgba[i*4]-color[0]),Math.abs(rgba[i*4+1]-color[1]),Math.abs(rgba[i*4+2]-color[2])):256;
          // Independent source-core census catches a segmentation miss before it
          // can expose dark centers under the translated lettering.
          let coreTotal=0,coreMasked=0;
          for(let i=0;i<n;i++)if(ownedCore[i]&&colorAt(i,foreground)<=28){
            coreTotal++;if(mask[i])coreMasked++;
          }
          let coverage=coreTotal?coreMasked/coreTotal:0;
          // The white outline belongs to dark source letters too. Build an
          // independent seven-pixel neighborhood of observed dark centers;
          // a pure RGB-core census would miss unpainted white glyph edges.
          const nearCore=new Uint8Array(n);
          if(stroke&&foreground){
            for(let y=1;y<h-1;y++)for(let x=1;x<w-1;x++){
              const i=y*w+x;if(!ownedCore[i]||colorAt(i,foreground)>28)continue;
              for(let yy=Math.max(1,y-7);yy<=Math.min(h-2,y+7);yy++)
                nearCore.fill(1,yy*w+Math.max(1,x-7),yy*w+Math.min(w-2,x+7)+1);
            }
          }
          let outlineTotal=0,outlineMasked=0;
          for(let i=0;i<n;i++)if(ownedCore[i]&&nearCore[i]&&colorAt(i,stroke)<=32){
            outlineTotal++;if(mask[i])outlineMasked++;
          }
          let outlineCoverage=outlineTotal?outlineMasked/outlineTotal:1;
          const narrowMask=segmented&&coreTotal>=3&&coverage>=.995&&outlineCoverage>=.995;
          // Display lettering keeps its panel when ownership cannot be isolated.
          if(options.requireSafeDonors&&!narrowMask)return fail('display-mask-unverified');
          if(!narrowMask){
            // A bounded guarantee for boxes whose source colors merge into art:
            // erase the precise OCR/auxiliary rectangles, not the whole crop.
            for(const r of boxes){
              const x0=Math.max(1,Math.floor(r[0]-3)),y0=Math.max(1,Math.floor(r[1]-3));
              const x1=Math.min(w-2,Math.ceil(r[0]+r[2]+3)),y1=Math.min(h-2,Math.ceil(r[1]+r[3]+3));
              for(let y=y0;y<=y1;y++)for(let x=x0;x<=x1;x++){
                const i=y*w+x;if(!geometry||geometry[i])mask[i]=1;
              }
            }
          }
          // A 1-pixel fringe avoids retaining the antialiased source outline at
          // a rectangle edge while preserving the outer crop for interpolation.
          const painted=mask.slice(),queue=new Int32Array(n);let tail=0;
          for(let i=0;i<n;i++)if(mask[i])queue[tail++]=i;
          if(!tail)return fail('empty-erasure-mask');
          const p=Uint8ClampedArray.from(rgba),blocked=new Uint8Array(n);
          // Neighbouring lettering remains visible but is never a background
          // donor. Carry rectangle exclusions into both reconstruction solvers.
          for(let i=0;i<n;i++)if(!painted[i]&&(protectedPixels[i]||
              options.excludedMask?.[i]||options.protected?.[i]))blocked[i]=1;
          // Donor-only exclusions do not veto erasure of overlapping source text.
          // They prevent other captions from becoming reconstruction colors.
          for(const r of Array.isArray(options.donorExcluded)?options.donorExcluded:[]){
            if(!Array.isArray(r)||r.length!==4||!r.every(Number.isFinite)||r[2]<=0||r[3]<=0)continue;
            const x0=Math.max(0,Math.floor(r[0]-2)),y0=Math.max(0,Math.floor(r[1]-2));
            const x1=Math.min(w-1,Math.ceil(r[0]+r[2]+2)),y1=Math.min(h-1,Math.ceil(r[1]+r[3]+2));
            for(let y=y0;y<=y1;y++)for(let x=x0;x<=x1;x++){
              const i=y*w+x;if(!painted[i])blocked[i]=1;
            }
          }
          let method='forced-donor-front',quality=null;
          if(narrowMask&&typeof aidokuForcedDonorFill==='function')try {
            const filled=aidokuForcedDonorFill(p,w,h,painted,{...options,excludedMask:blocked,sourceForeground:foreground,sourceStroke:stroke,
              sourceBackground:palette?.sourceInk?.background||palette?.background});
            if(filled?.length===n*4){p.set(filled);method='forced-structured-donor';}
            else if(filled?.rgba?.length===n*4){p.set(filled.rgba);method=filled.method||'forced-structured-donor';quality=filled.quality||null;}
            else throw Error('no donor result');
          }catch(_error){method='forced-donor-front';}
          if(options.requireSafeDonors&&(!quality?.safe||method==='forced-donor-front'))
            return fail('display-donors-unverified');
          if(method==='forced-donor-front'){
            const filled=typeof aidokuCertifiedSurfaceFill==='function'
              ?aidokuCertifiedSurfaceFill(rgba,w,h,painted,blocked,{...options,sourceForeground:foreground}):null;
            if(!filled)return fail('uncertified-background-surface');
            p.set(filled.rgba);method=filled.method;quality=filled.quality;
          }
          const output=new Uint8ClampedArray(n*4),layoutSafe=new Uint8Array(n);
          for(let k=0;k<tail;k++){
            const i=queue[k],at=i*4;
            output[at]=p[at];output[at+1]=p[at+1];output[at+2]=p[at+2];output[at+3]=255;
            layoutSafe[i]=1;
          }
          coreMasked=0;
          for(let i=0;i<n;i++)if(ownedCore[i]&&colorAt(i,foreground)<=28&&painted[i])coreMasked++;
          coverage=coreTotal?coreMasked/coreTotal:1;
          outlineMasked=0;
          for(let i=0;i<n;i++)if(ownedCore[i]&&nearCore[i]&&colorAt(i,stroke)<=32&&painted[i])outlineMasked++;
          outlineCoverage=outlineTotal?outlineMasked/outlineTotal:1;
          // The caller's final pass accepts only a fully painted source-core
          // region. Keep an honest rejection when another caption's exclusion
          // overlaps and leaves source ink owned by this one.
          if(coverage<.995||outlineCoverage<.995)return fail('source-ink-outside-mask');
          let sourceTouchesCropEdge=0,postFillPaletteInkPixels=0;
          for(let k=0;k<tail;k++){
            const i=queue[k],x=i%w,y=i/w|0;
            if((x<=3||x>=w-4||y<=3||y>=h-4)&&colorAt(i,foreground)<=40)sourceTouchesCropEdge++;
            if(foreground&&Math.max(Math.abs(output[i*4]-foreground[0]),Math.abs(output[i*4+1]-foreground[1]),
                Math.abs(output[i*4+2]-foreground[2]))<=28)postFillPaletteInkPixels++;
          }
          let remainingCore=0;
          for(let i=0;i<n;i++)if(ownedCore[i]&&painted[i]&&colorAt(i,foreground)<=28&&
              Math.max(...foreground.map((v,c)=>Math.abs(output[i*4+c]-v)))<=28)remainingCore++;
          if(remainingCore>Math.max(4,coreTotal*.01))return fail('source-ink-in-reconstruction');
          return {rgba:output,layoutSafe,erased:tail,method,quality,sourceTouchesCropEdge,postFillPaletteInkPixels,sourceGlyphsVerified:true,
            sourceErasureVerified:true,sourceRemainingInk:remainingCore,sourceCorePixels:coreTotal,
            sourceOutlinePixels:outlineTotal,sourceRemainingOutline:outlineTotal-outlineMasked,
            preservedPixels:0,preservedCore:0,forcedCoverage:coverage,
            forcedOutlineCoverage:outlineCoverage,forcedMaskMode:narrowMask?'glyph':'rect'};
        }
    """
}
