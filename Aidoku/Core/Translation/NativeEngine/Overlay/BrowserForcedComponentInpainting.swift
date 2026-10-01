// An isolated component-owned fallback. The broad legacy fallback remains available
// for crops where source glyph components cannot be identified.
enum BrowserForcedComponentInpainting {
    static let script = """
        function aidokuForceInpaintSourceComponent(rgba,w,h,box,palette,options={}) {
          aidokuForceInpaintSourceComponent.lastFailure='';
          const fail=reason=>{aidokuForceInpaintSourceComponent.lastFailure=reason;return null;};
          const n=w*h;
          if(!rgba||rgba.length!==n*4||w<5||h<5||!Array.isArray(box)||box.length!==4||
              !box.every(Number.isFinite)||box[2]<=0||box[3]<=0)return fail('invalid-crop');
          if(typeof aidokuForcedTextMask!=='function')return fail('missing-component-segmentation');
          let candidates;
          try {candidates=aidokuForcedTextMask(rgba,w,h,box,palette,options);}catch(_error){return fail('segmentation-error');}
          // Some cached crops exceed the segmentation helper's bounded pixel
          // budget. Re-run only those at a glyph-preserving scale, then lift the
          // component candidates back to native pixels before the donor fill.
          let segmentedScale=1;
          if(!candidates&&n>262144){
            const scale=Math.sqrt(245000/n),sw=Math.max(5,Math.floor(w*scale)),sh=Math.max(5,Math.floor(h*scale));
            const small=new Uint8ClampedArray(sw*sh*4);
            for(let y=0;y<sh;y++)for(let x=0;x<sw;x++){
              const sx=Math.min(w-1,Math.floor((x+.5)*w/sw)),sy=Math.min(h-1,Math.floor((y+.5)*h/sh));
              const from=(sy*w+sx)*4,to=(y*sw+x)*4;
              small[to]=rgba[from];small[to+1]=rgba[from+1];small[to+2]=rgba[from+2];small[to+3]=rgba[from+3];
            }
            const sb=[box[0]*sw/w,box[1]*sh/h,box[2]*sw/w,box[3]*sh/h];
            let reduced=null;
            try {reduced=aidokuForcedTextMask(small,sw,sh,sb,palette,{...options,
              polygons:options.polygons?.map(p=>p.map(v=>[v[0]*sw/w,v[1]*sh/h])),
              excludedPolygons:options.excludedPolygons?.map(p=>p.map(v=>[v[0]*sw/w,v[1]*sh/h])),
              glyphSize:(Number(options.glyphSize)||0)*Math.min(sw/w,sh/h),
              trailing:(Number(options.trailing)||0)*sh/h});}catch(_error){}
            if(reduced?.length===sw*sh&&reduced.sourceCoreCandidateMask?.length===sw*sh&&
                reduced.sourceOutlineCandidateMask?.length===sw*sh){
              const lifted=new Uint8Array(n),coreMap=new Uint8Array(n),outlineMap=new Uint8Array(n);
              for(let y=0;y<h;y++)for(let x=0;x<w;x++){
                const j=Math.min(sh-1,Math.floor(y*sh/h))*sw+Math.min(sw-1,Math.floor(x*sw/w)),i=y*w+x;
                lifted[i]=reduced[j];coreMap[i]=reduced.sourceCoreCandidateMask[j];
                outlineMap[i]=reduced.sourceOutlineCandidateMask[j];
              }
              lifted.sourceCoreCandidateMask=coreMap;lifted.sourceOutlineCandidateMask=outlineMap;
              lifted.sourceCoreCandidateCount=reduced.sourceCoreCandidateCount;
              lifted.sourceCoreCandidateCovered=reduced.sourceCoreCandidateCovered;
              lifted.sourceOutlineCandidateCount=reduced.sourceOutlineCandidateCount;
              lifted.sourceOutlineCandidateCovered=reduced.sourceOutlineCandidateCovered;
              candidates=lifted;segmentedScale=Math.min(sw/w,sh/h);
            }
          }
          if(candidates?.length!==n||candidates.sourceCoreCandidateMask?.length!==n||
              candidates.sourceOutlineCandidateMask?.length!==n)return fail('no-component-candidates');
          const foreground=palette?.sourceInk?.foreground||palette?.foreground;
          const stroke=palette?.sourceInk?.stroke||((palette?.confidence?.stroke||0)>=.55&&
            palette?.foreground&&foreground&&Math.max(...palette.foreground.map((v,k)=>Math.abs(v-foreground[k])))<=24?palette.stroke:null);
          const distance=(i,color)=>color&&color.length>=3?
            Math.max(Math.abs(rgba[i*4]-color[0]),Math.abs(rgba[i*4+1]-color[1]),
              Math.abs(rgba[i*4+2]-color[2])):256;
          const owned=new Uint8Array(n),main=new Uint8Array(n),protectedPixels=new Uint8Array(n);
          const geometry=typeof aidokuOCRGeometryMask==='function'
            ?aidokuOCRGeometryMask(w,h,options.polygons,options.excludedPolygons,7):null;
          const auxiliary=Array.isArray(options.auxiliary)?options.auxiliary:[];
          const trailing=Math.max(0,Math.min(96,Number(options.trailing)||0));
          const margin=Math.max(8,Math.min(24,Math.round(Math.min(box[2],box[3])*.1)));
          for(const r of [box,...auxiliary]){
            if(!Array.isArray(r)||r.length!==4||!r.every(Number.isFinite)||r[2]<=0||r[3]<=0)continue;
            const x0=Math.max(1,Math.floor(r[0]-margin)),y0=Math.max(1,Math.floor(r[1]-margin));
            const x1=Math.min(w-2,Math.ceil(r[0]+r[2]+margin+(options.vertical?0:trailing)));
            const y1=Math.min(h-2,Math.ceil(r[1]+r[3]+margin+(options.vertical?trailing:0)));
            for(let y=y0;y<=y1;y++)owned.fill(1,y*w+x0,y*w+x1+1);
            const cx0=Math.max(1,Math.floor(r[0]-3)),cy0=Math.max(1,Math.floor(r[1]-3));
            const cx1=Math.min(w-2,Math.ceil(r[0]+r[2]+3)),cy1=Math.min(h-2,Math.ceil(r[1]+r[3]+3));
            for(let y=cy0;y<=cy1;y++)main.fill(1,y*w+cx0,y*w+cx1+1);
          }
          for(const r of Array.isArray(options.excluded)?options.excluded:[]){
            if(!Array.isArray(r)||r.length!==4||!r.every(Number.isFinite))continue;
            const x0=Math.max(1,Math.floor(r[0]-2)),y0=Math.max(1,Math.floor(r[1]-2));
            const x1=Math.min(w-2,Math.ceil(r[0]+r[2]+2)),y1=Math.min(h-2,Math.ceil(r[1]+r[3]+2));
            for(let y=y0;y<=y1;y++)protectedPixels.fill(1,y*w+x0,y*w+x1+1);
          }
          const mask=Uint8Array.from(candidates);
          if(geometry)for(let i=0;i<n;i++)if(!geometry[i]){owned[i]=0;main[i]=0;}
          const core=candidates.sourceCoreCandidateMask,outline=candidates.sourceOutlineCandidateMask;
          // Color is evidence inside accepted components, never permission
          // to erase matching illustration or white paper across the OCR box.
          for(let i=0;i<n;i++){
            if(!owned[i]||protectedPixels[i]&&!main[i]){mask[i]=0;continue;}
            if(core[i]||outline[i])mask[i]=1;
          }
          const seeds=mask.slice();
          for(let y=1;y<h-1;y++)for(let x=1;x<w-1;x++){
            const i=y*w+x;if(!seeds[i])continue;
            for(let yy=Math.max(1,y-1);yy<=Math.min(h-2,y+1);yy++)
              for(let xx=Math.max(1,x-1);xx<=Math.min(w-2,x+1);xx++){
                if(Math.abs(xx-x)+Math.abs(yy-y)>1)continue;
                const j=yy*w+xx;if(owned[j]&&(!protectedPixels[j]||main[j]))mask[j]=1;
              }
          }
          const queue=new Int32Array(n),painted=mask.slice();let tail=0,coreTotal=0,coreMasked=0,outlineTotal=0,outlineMasked=0;
          for(let i=0;i<n;i++){
            if(mask[i])queue[tail++]=i;
            if(!owned[i]||protectedPixels[i]&&!main[i])continue;
            if(core[i]){coreTotal++;if(mask[i])coreMasked++;}
            if(outline[i]){outlineTotal++;if(mask[i])outlineMasked++;}
          }
          if(!tail||coreTotal<3||coreMasked<coreTotal||outlineMasked<outlineTotal)
            return fail('uncertified-component-mask');
          const p=Uint8ClampedArray.from(rgba),blocked=new Uint8Array(n);
          const background=palette?.sourceInk?.background||palette?.background;
          // White paper may have the same RGB as a white glyph outline. It is
          // a valid donor away from the accepted outline component.
          const separateStroke=stroke&&background&&
            Math.max(...stroke.map((v,c)=>Math.abs(v-background[c])))>=48;
          for(let i=0;i<n;i++)if(!painted[i]&&(protectedPixels[i]||options.excludedMask?.[i]||
              options.protected?.[i]||owned[i]&&(distance(i,foreground)<=40||separateStroke&&distance(i,stroke)<=45)))blocked[i]=1;
          for(const r of Array.isArray(options.donorExcluded)?options.donorExcluded:[]){
            if(!Array.isArray(r)||r.length!==4||!r.every(Number.isFinite)||r[2]<=0||r[3]<=0)continue;
            const x0=Math.max(0,Math.floor(r[0]-2)),y0=Math.max(0,Math.floor(r[1]-2));
            const x1=Math.min(w-1,Math.ceil(r[0]+r[2]+2)),y1=Math.min(h-1,Math.ceil(r[1]+r[3]+2));
            for(let y=y0;y<=y1;y++)for(let x=x0;x<=x1;x++){
              const i=y*w+x;if(!painted[i])blocked[i]=1;
            }
          }
          let method='component-donor-front',quality=null,residualExpansionPixels=0,residualRetryCount=0;
          const donorOptions={...options,excludedMask:blocked,sourceForeground:foreground,
            sourceStroke:stroke,sourceBackground:palette?.sourceInk?.background||palette?.background};
          if(typeof aidokuForcedDonorFill==='function')try {
            let filled=typeof aidokuComponentExemplarFill==='function'
              ?aidokuComponentExemplarFill(p,w,h,painted,blocked,donorOptions):null;
            if(!filled)filled=aidokuForcedDonorFill(p,w,h,painted,donorOptions);
            // The quality gate can return a sparse bitmap of source-colored
            // strokes just outside the component mask. Expand only those local
            // strokes, then retry once; never turn the entire OCR box into a
            // diffuse rectangle because of a handful of missing antialiases.
            const residualReason=aidokuForcedDonorFill.lastFailure;
            if(!filled&&(residualReason==='residual-source-ink'||residualReason==='residual-white-outline')&&
                aidokuForcedDonorFill.lastResidualMask?.length===n){
              const residual=aidokuForcedDonorFill.lastResidualMask;
              const radius=1;
              for(let y=1;y<h-1;y++)for(let x=1;x<w-1;x++){
                const i=y*w+x;if(!residual[i]||!owned[i]||protectedPixels[i]&&!main[i])continue;
                for(let yy=Math.max(1,y-radius);yy<=Math.min(h-2,y+radius);yy++)
                  for(let xx=Math.max(1,x-radius);xx<=Math.min(w-2,x+radius);xx++){
                    if(Math.abs(xx-x)+Math.abs(yy-y)>radius)continue;
                    const j=yy*w+xx;if(!owned[j]||protectedPixels[j]&&!main[j]||painted[j])continue;
                    painted[j]=1;mask[j]=1;blocked[j]=0;queue[tail++]=j;residualExpansionPixels++;
                  }
              }
              if(residualExpansionPixels){
                residualRetryCount=1;
                filled=aidokuForcedDonorFill(p,w,h,painted,donorOptions);
              }
            }
            if(filled?.rgba?.length===n*4){p.set(filled.rgba);method=filled.method||'component-edge-aware';quality=filled.quality||null;}
          }catch(_error){}
          // An uncertified fill can smear large title strokes across artwork.
          if(options.requireSafeDonors&&(!quality?.safe||method==='component-donor-front'))
            return fail('display-donors-unverified');
          if(method==='component-donor-front'){
            const filled=typeof aidokuCertifiedSurfaceFill==='function'
              ?aidokuCertifiedSurfaceFill(rgba,w,h,painted,blocked,donorOptions):null;
            if(!filled)return fail('uncertified-background-surface');
            p.set(filled.rgba);method=filled.method;quality=filled.quality;
          }
          const output=new Uint8ClampedArray(n*4),layoutSafe=new Uint8Array(n);
          let edgeInk=0,postFillPaletteInkPixels=0;
          for(let k=0;k<tail;k++){
            const i=queue[k],at=i*4,x=i%w,y=i/w|0;
            output[at]=p[at];output[at+1]=p[at+1];output[at+2]=p[at+2];output[at+3]=255;layoutSafe[i]=1;
            if((x<=3||x>=w-4||y<=3||y>=h-4)&&distance(i,foreground)<=40)edgeInk++;
            if(foreground&&Math.max(Math.abs(output[at]-foreground[0]),Math.abs(output[at+1]-foreground[1]),
                Math.abs(output[at+2]-foreground[2]))<=28)postFillPaletteInkPixels++;
          }
          let remainingCore=0;
          for(let i=0;i<n;i++)if(core[i]&&painted[i]&&foreground&&
              Math.max(...foreground.map((v,c)=>Math.abs(output[i*4+c]-v)))<=28)remainingCore++;
          if(remainingCore>Math.max(4,coreTotal*.01))return fail('source-ink-in-reconstruction');
          return {rgba:output,layoutSafe,erased:tail,method,quality,sourceGlyphsVerified:true,
            sourceErasureVerified:true,sourceRemainingInk:remainingCore,sourceCorePixels:coreTotal,
            sourceOutlinePixels:outlineTotal,sourceRemainingOutline:0,preservedPixels:0,preservedCore:0,
            forcedCoverage:1,forcedOutlineCoverage:1,forcedMaskMode:'component',
            sourceCoreCandidateCoverage:candidates.sourceCoreCandidateCount?
              candidates.sourceCoreCandidateCovered/candidates.sourceCoreCandidateCount:null,
            sourceOutlineCandidateCoverage:candidates.sourceOutlineCandidateCount?
              candidates.sourceOutlineCandidateCovered/candidates.sourceOutlineCandidateCount:null,
            sourceTouchesCropEdge:edgeInk,postFillPaletteInkPixels,
            residualExpansionPixels,residualRetryCount,segmentedScale};
        }
    """
}
