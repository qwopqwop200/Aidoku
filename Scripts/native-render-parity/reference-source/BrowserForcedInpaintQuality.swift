// Edge-aware donors for the final source-ink inpainting pass.
// This helper returns full RGBA pixels; only mask-owned pixels are changed.
enum BrowserForcedInpaintQuality {
    static let script = """
        // A whole OCR box has no recoverable texture evidence inside it. Only
        // a measured plane supported around every side may replace that area.
        function aidokuCertifiedSurfaceFill(rgba,w,h,mask,blocked,options={}) {
          const n=w*h;
          if(rgba?.length!==n*4||mask?.length!==n||blocked?.length!==n||
              typeof aidokuSourceSurfaceQuality!=='function')return null;
          const surface=aidokuSourceSurfaceQuality(rgba,w,h,mask,blocked,true);
          if(!surface.safe||surface.reason!=='smooth'||surface.rmse>3||
              surface.outliers!==0||surface.samples<64)return null;
          let l=w,t=h,r=-1,b=-1,erased=0;
          for(let i=0;i<n;i++)if(mask[i]){const x=i%w,y=i/w|0;
            l=Math.min(l,x);r=Math.max(r,x);t=Math.min(t,y);b=Math.max(b,y);erased++;}
          if(!erased)return null;
          const sides=[0,0,0,0];
          for(let y=Math.max(0,t-4);y<=Math.min(h-1,b+4);y++)
            for(let x=Math.max(0,l-4);x<=Math.min(w-1,r+4);x++){
              const i=y*w+x;if(mask[i]||blocked[i]||rgba[i*4+3]<250)continue;
              if(x<l)sides[0]++;if(x>r)sides[1]++;if(y<t)sides[2]++;if(y>b)sides[3]++;
            }
          if(sides.some(v=>v<8))return null;
          const out=Uint8ClampedArray.from(rgba),fg=options.sourceForeground;
          let residualSourceInk=0;
          for(let i=0;i<n;i++)if(mask[i]){
            const x=i%w,y=i/w|0;
            for(let c=0;c<3;c++){
              const a=surface.coefficients[c],v=a[0]+a[1]*x/w+a[2]*y/h;
              if(!Number.isFinite(v)||v<0||v>255)return null;
              out[i*4+c]=v;
            }
            out[i*4+3]=255;
            if(fg&&Math.max(...fg.map((v,c)=>Math.abs(rgba[i*4+c]-v)))<=28&&
                Math.max(...fg.map((v,c)=>Math.abs(out[i*4+c]-v)))<=28)residualSourceInk++;
          }
          if(residualSourceInk)return null;
          return {rgba:out,method:'certified-surface-plane',quality:{safe:true,erased,
            residualSourceInk,surface,supportSides:sides}};
        }
        // Texture is recovered from matching intact patches, never from a
        // donor ray stretched through a character. Bound work per component.
        function aidokuComponentExemplarFill(rgba,w,h,mask,blocked,options={}) {
          const n=w*h,fg=options.sourceForeground;
          if(n>750000||!fg||typeof aidokuSourceExemplarFill!=='function'||
              typeof aidokuSourceSurfaceQuality!=='function')return null;
          const seen=new Uint8Array(n),groups=[];
          for(let start=0;start<n;start++)if(mask[start]&&!seen[start]){
            const points=[start];seen[start]=1;let l=w,t=h,r=0,b=0;
            for(let head=0;head<points.length;head++){
              const i=points[head],x=i%w,y=i/w|0;
              l=Math.min(l,x);r=Math.max(r,x);t=Math.min(t,y);b=Math.max(b,y);
              for(const j of [x?i-1:-1,x<w-1?i+1:-1,y?i-w:-1,y<h-1?i+w:-1])
                if(j>=0&&mask[j]&&!seen[j]){seen[j]=1;points.push(j);}
            }
            if(points.length>32000||groups.length>=32)return null;
            groups.push({points,l,t,r,b});
          }
          if(!groups.length)return null;
          const fallback=aidokuForcedDonorFill(rgba,w,h,mask,{...options,excludedMask:blocked});
          const output=fallback?.rgba?.slice()||Uint8ClampedArray.from(rgba);
          let patches=0,maxError=0,erased=0,patchedPixels=0,rayPixels=0;
          for(const g of groups){
            const l=Math.max(0,g.l-32),t=Math.max(0,g.t-32),r=Math.min(w-1,g.r+32),b=Math.min(h-1,g.b+32);
            const cw=r-l+1,ch=b-t+1,cn=cw*ch;
            if(cn>131072||g.points.length<32){
              if(!fallback)return null;rayPixels+=g.points.length;continue;
            }
            const crop=new Uint8ClampedArray(cn*4),target=new Uint8Array(cn),forbidden=new Uint8Array(cn);
            for(let y=0;y<ch;y++)for(let x=0;x<cw;x++){
              const i=(y+t)*w+x+l,j=y*cw+x;
              crop.set(rgba.subarray(i*4,i*4+4),j*4);forbidden[j]=blocked[i]||mask[i]?1:0;
            }
            for(const i of g.points){const j=((i/w|0)-t)*cw+i%w-l;target[j]=1;forbidden[j]=0;}
            const surface=aidokuSourceSurfaceQuality(crop,cw,ch,target,forbidden);
            if(!surface.coefficients||surface.coefficients.some(a=>a.some(v=>!Number.isFinite(v)))){
              if(!fallback)return null;rayPixels+=g.points.length;continue;
            }
            const filled=aidokuSourceExemplarFill(crop,cw,ch,target,{foreground:fg},surface,forbidden,[]);
            if(!filled||filled.maxError>18||filled.textureRatio<.65||filled.textureRatio>1.5){
              if(!fallback)return null;rayPixels+=g.points.length;continue;
            }
            patches+=filled.patches;maxError=Math.max(maxError,filled.maxError);
            for(const i of g.points){const j=((i/w|0)-t)*cw+i%w-l;
              output.set(filled.rgba.subarray(j*4,j*4+4),i*4);erased++;patchedPixels++;}
          }
          if(!patchedPixels)return null;
          erased+=rayPixels;
          return {rgba:output,method:'component-matched-patches',quality:{safe:true,erased,
            components:groups.length,patches,maxError,patchedPixels,rayPixels,donorQuality:fallback?.quality||null}};
        }
        function aidokuForcedDonorFill(rgba,w,h,mask,options={}) {
          aidokuForcedDonorFill.lastFailure='';
          aidokuForcedDonorFill.lastResidualMask=null;
          aidokuForcedDonorFill.lastQuality=null;
          const n=w*h;
          if(!Number.isInteger(w)||!Number.isInteger(h)||w<8||h<8||n>1000000||
              rgba?.length!==n*4||mask?.length!==n)return null;
          const original=new Uint8ClampedArray(rgba),out=original.slice();
          const excluded=options.excludedMask,protectedPixels=options.protected;
          const donor=i=>!mask[i]&&!excluded?.[i]&&!protectedPixels?.[i]&&original[i*4+3]>=250;
          const left=new Int32Array(n),right=new Int32Array(n),up=new Int32Array(n),down=new Int32Array(n);
          left.fill(-1);right.fill(-1);up.fill(-1);down.fill(-1);
          for(let y=0;y<h;y++){
            let last=-1;
            for(let x=0;x<w;x++){const i=y*w+x;if(donor(i))last=i;left[i]=last;}
            last=-1;
            for(let x=w-1;x>=0;x--){const i=y*w+x;if(donor(i))last=i;right[i]=last;}
          }
          for(let x=0;x<w;x++){
            let last=-1;
            for(let y=0;y<h;y++){const i=y*w+x;if(donor(i))last=i;up[i]=last;}
            last=-1;
            for(let y=h-1;y>=0;y--){const i=y*w+x;if(donor(i))last=i;down[i]=last;}
          }
          const maxReach=Math.max(36,Math.min(64,(Number(options.glyphSize)||0)*.45));
          const difference=(a,b)=>Math.max(Math.abs(original[a*4]-original[b*4]),
            Math.abs(original[a*4+1]-original[b*4+1]),Math.abs(original[a*4+2]-original[b*4+2]));
          let erased=0,noDonor=0,continuous=0,seams=0,wide=0,wideDiscordant=0,maxSpan=0;
          // Opposing donors on the same material interpolate a real local
          // gradient. When a hair/art edge crosses text, select its coherent
          // side instead of averaging cyan paper with dark artwork.
          for(let i=0;i<n;i++)if(mask[i]){
            erased++;
            const x=i%w,y=i/w|0;
            const candidates=[];
            if(left[i]>=0&&right[i]>=0){
              const a=left[i],b=right[i],da=x-a%w,db=b%w-x;
              candidates.push({a,b,da,db,gap:difference(a,b),span:da+db});
            }
            if(up[i]>=0&&down[i]>=0){
              const a=up[i],b=down[i],da=y-(a/w|0),db=(b/w|0)-y;
              candidates.push({a,b,da,db,gap:difference(a,b),span:da+db});
            }
            // A distant matching color must not outrank nearby edge evidence.
            const local=candidates.filter(v=>v.da<=maxReach&&v.db<=maxReach);
            local.sort((a,b)=>(a.gap+Math.min(48,a.span*.45))-(b.gap+Math.min(48,b.span*.45)));
            let color=null;
            const best=local[0];
            if(best&&best.gap<=36){
              maxSpan=Math.max(maxSpan,best.span);
              const blend=best.da/Math.max(1,best.span);
              color=[0,1,2].map(c=>original[best.a*4+c]*(1-blend)+original[best.b*4+c]*blend);
              continuous++;
            }else{
              const singles=[left[i],right[i],up[i],down[i]].filter(v=>v>=0);
              if(singles.length){
                // The nearest side owns the hidden edge when no opposite
                // donors agree. A distant opposite color must not wash it out.
                let closest=singles[0],distance=Infinity;
                for(const j of singles){
                  const d=Math.abs(j%w-x)+Math.abs((j/w|0)-y);
                  if(d<distance){distance=d;closest=j;}
                }
                maxSpan=Math.max(maxSpan,distance);if(distance>maxReach){wide++;wideDiscordant++;}
                color=[original[closest*4],original[closest*4+1],original[closest*4+2]];
                seams++;
              }else{noDonor++;continue;}
            }
            const k=i*4;out[k]=color[0];out[k+1]=color[1];out[k+2]=color[2];out[k+3]=255;
          }
          // Long donor rays cross unrelated subjects and create hard bands.
          // A whole-box mask must use the caller's bounded broad fallback,
          // never be certified on the strength of this narrow-glyph method.
          const safe=erased>0&&!noDonor&&wide<=erased*.05&&erased<=n*.45;
          const quality={erased,noDonor,continuous,seams,wide,wideDiscordant,maxSpan,
            continuityRatio:continuous/Math.max(1,erased),safe};
          aidokuForcedDonorFill.lastQuality=quality;
          // The fill mask can be perfectly smooth yet omit an adjacent source
          // stroke. Report only source-colored original pixels reached from
          // the mask; the caller owns any retry that enlarges the paint mask.
          const foreground=options.sourceForeground;
          if(safe&&Array.isArray(foreground)&&foreground.length===3&&foreground.every(Number.isFinite)){
            const distance=new Uint8Array(n);distance.fill(255);
            const queue=new Int32Array(n);let head=0,tail=0;
            for(let i=0;i<n;i++)if(mask[i]){distance[i]=0;queue[tail++]=i;}
            while(head<tail){
              const i=queue[head++],d=distance[i];if(d>=16)continue;
              const x=i%w,y=i/w|0;
              for(const j of [x?i-1:-1,x<w-1?i+1:-1,y?i-w:-1,y<h-1?i+w:-1]){
                if(j<0||distance[j]<=d+1)continue;
                distance[j]=d+1;queue[tail++]=j;
              }
            }
            const residual=new Uint8Array(n);let residue=0;
            for(let i=0;i<n;i++)if(distance[i]>0&&distance[i]<=16&&
                !excluded?.[i]&&!protectedPixels?.[i]){
              const k=i*4;
              if(Math.max(Math.abs(original[k]-foreground[0]),
                  Math.abs(original[k+1]-foreground[1]),
                  Math.abs(original[k+2]-foreground[2]))<=24){residual[i]=1;residue++;}
            }
            quality.residualSourceInk=residue;
            const darkDetected=residue>=Math.max(8,Math.ceil(erased*.0025));
            const darkSparse=residue<=Math.max(64,erased*.15);
            // On colored art the dark glyph can be gone while its thick white
            // outline remains. Uniform white paper is not evidence: require a
            // sharp falloff in the fraction of white pixels away from the mask.
            const rings=new Int32Array(13),whiteRings=new Int32Array(13);
            for(let i=0;i<n;i++){
              const d=distance[i];if(d<1||d>12||excluded?.[i]||protectedPixels?.[i])continue;
              rings[d]++;
              const k=i*4;
              if(Math.min(original[k],original[k+1],original[k+2])>=246)whiteRings[d]++;
            }
            const fraction=(a,b)=>{
              let white=0,total=0;
              for(let d=a;d<=b;d++){white+=whiteRings[d];total+=rings[d];}
              return total?white/total:0;
            };
            const inner=fraction(1,3),outer=fraction(9,12);
            quality.whiteHaloFractionInner=inner;
            quality.whiteHaloFractionOuter=outer;
            if(inner>=.82&&inner-outer>=.28&&
                whiteRings[1]+whiteRings[2]+whiteRings[3]>=Math.max(12,erased*.05)){
              const midpoint=(inner+outer)/2;
              let radius=8;
              for(let d=4;d<=8;d++)if(rings[d]&&whiteRings[d]/rings[d]<midpoint){radius=Math.max(3,d-1);break;}
              const outline=new Uint8Array(n);let outlinePixels=0;
              for(let i=0;i<n;i++)if(distance[i]>0&&distance[i]<=radius&&
                  !excluded?.[i]&&!protectedPixels?.[i]){
                const k=i*4;
                if(Math.min(original[k],original[k+1],original[k+2])>=246){outline[i]=1;outlinePixels++;}
              }
              if(outlinePixels>=Math.max(12,erased*.05)){
                if(darkDetected&&darkSparse)for(let i=0;i<n;i++)if(residual[i]&&!outline[i]){
                  outline[i]=1;outlinePixels++;
                }
                quality.whiteHaloPixels=outlinePixels;
                quality.whiteHaloRadius=radius;
                quality.safe=false;
                aidokuForcedDonorFill.lastFailure='residual-white-outline';
                aidokuForcedDonorFill.lastResidualMask=outline;
                return options.diagnostic?{method:'rejected-edge-aware-donors',quality}:null;
              }
            }
            if(darkDetected){
              // A large matching area may be dark illustration rather than
              // lettering. Refuse this donor result, but offer a pixel retry
              // only for sparse evidence that cannot repaint broad artwork.
              aidokuForcedDonorFill.lastFailure=darkSparse?'residual-source-ink':'ambiguous-residual-source-ink';
              aidokuForcedDonorFill.lastResidualMask=darkSparse?residual:null;
              quality.safe=false;
              return options.diagnostic?{method:'rejected-edge-aware-donors',quality}:null;
            }
          }
          if(!safe){aidokuForcedDonorFill.lastFailure=noDonor?'no-clean-donor':wide>erased*.05?'distant-donors':'oversized-mask';
            return options.diagnostic?{method:'rejected-edge-aware-donors',quality}:null;}
          // Relax only the certified glyph mask. Fixed guidance from the clean
          // donor result blocks diffusion across real material boundaries while
          // removing row/column streaks from independent nearest-side choices.
          const points=[],index=new Int32Array(n);index.fill(-1);
          for(let i=0;i<n;i++)if(mask[i]){index[i]=points.length;points.push(i);}
          let values=new Float32Array(erased*3),next=new Float32Array(erased*3);
          const weights=new Float32Array(erased*4),adjacent=new Int32Array(erased*4);
          adjacent.fill(-1);
          for(let k=0;k<erased;k++){
            const i=points[k],x=i%w,y=i/w|0;
            for(let c=0;c<3;c++)values[k*3+c]=out[i*4+c];
            const neighbours=[x?i-1:-1,x<w-1?i+1:-1,y?i-w:-1,y<h-1?i+w:-1];
            for(let d=0;d<4;d++){
              const j=neighbours[d];if(j<0||!mask[j]&&!donor(j))continue;
              const delta=Math.max(...[0,1,2].map(c=>Math.abs(out[i*4+c]-out[j*4+c])));
              adjacent[k*4+d]=j;weights[k*4+d]=delta>32?0:1/(1+(delta/12)**4);
            }
          }
          for(let iteration=0;iteration<24;iteration++){
            for(let k=0;k<erased;k++){
              let total=0,red=0,green=0,blue=0;
              for(let d=0;d<4;d++){
                const weight=weights[k*4+d];if(!weight)continue;
                const j=adjacent[k*4+d],at=index[j];total+=weight;
                if(at>=0){red+=weight*values[at*3];green+=weight*values[at*3+1];blue+=weight*values[at*3+2];}
                else {red+=weight*out[j*4];green+=weight*out[j*4+1];blue+=weight*out[j*4+2];}
              }
              next[k*3]=total?red/total:values[k*3];
              next[k*3+1]=total?green/total:values[k*3+1];
              next[k*3+2]=total?blue/total:values[k*3+2];
            }
            [values,next]=[next,values];
          }
          for(let k=0;k<erased;k++)for(let c=0;c<3;c++)out[points[k]*4+c]=values[k*3+c];
          quality.edgeRelaxationIterations=24;
          return {rgba:out,method:'edge-aware-donors',quality};
        }
    """
}
