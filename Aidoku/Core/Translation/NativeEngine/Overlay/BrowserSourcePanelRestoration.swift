// Bounded, model-free reconstruction of observed lettering on spatial backgrounds.
// Original pixels outside the glyph/outline mask are never painted over.
enum BrowserSourcePanelRestoration {
    static let script = """
        // Fit an RGB plane to unmasked donor pixels. Smooth gradients are safe;
        // texture and illustration edges are not recoverable by diffusion. Sampling
        // is bounded by the crop budget and never reads the page a second time.
        function aidokuSourceSurfaceQuality(rgba,w,h,mask,blocked) {
          const matrix=[[0,0,0],[0,0,0],[0,0,0]],rhs=[[0,0,0],[0,0,0],[0,0,0]];
          let count=0;
          const stride=Math.max(1,Math.ceil(Math.sqrt(w*h/4096)));
          const isDonor=(x,y)=>{
            const i=y*w+x;if(mask[i]||blocked[i])return false;
            for(let yy=Math.max(0,y-4);yy<=Math.min(h-1,y+4);yy++)
              for(let xx=Math.max(0,x-4);xx<=Math.min(w-1,x+4);xx++)if(mask[yy*w+xx])return true;
            return false;
          };
          for(let y=1;y<h-1;y+=stride)for(let x=1;x<w-1;x+=stride){
            const i=y*w+x;if(!isDonor(x,y))continue;
            const a=[1,x/w,y/h];count++;
            for(let j=0;j<3;j++){
              for(let k=0;k<3;k++)matrix[j][k]+=a[j]*a[k];
              for(let c=0;c<3;c++)rhs[c][j]+=a[j]*rgba[i*4+c];
            }
          }
          if(count<24)return {safe:false,reason:'insufficient-donors',samples:count};
          const coefficients=rhs.map(values=>{
            const m=matrix.map((row,i)=>[...row,values[i]]);
            for(let k=0;k<3;k++){
              let pivot=k;for(let j=k+1;j<3;j++)if(Math.abs(m[j][k])>Math.abs(m[pivot][k]))pivot=j;
              [m[k],m[pivot]]=[m[pivot],m[k]];
              if(Math.abs(m[k][k])<1e-6)return null;
              const d=m[k][k];for(let c=k;c<4;c++)m[k][c]/=d;
              for(let j=0;j<3;j++)if(j!==k){const f=m[j][k];for(let c=k;c<4;c++)m[j][c]-=f*m[k][c];}
            }
            return m.map(row=>row[3]);
          });
          if(coefficients.some(c=>!c))return {safe:false,reason:'insufficient-geometry',samples:count};
          let squared=0,outliers=0;
          for(let y=1;y<h-1;y+=stride)for(let x=1;x<w-1;x+=stride){
            const i=y*w+x;if(!isDonor(x,y))continue;
            let error=0;
            for(let c=0;c<3;c++)error=Math.max(error,Math.abs(rgba[i*4+c]-(coefficients[c][0]+coefficients[c][1]*x/w+coefficients[c][2]*y/h)));
            squared+=error*error;if(error>22)outliers++;
          }
          const rmse=Math.sqrt(squared/count),fraction=outliers/count;
          if(rmse<=14&&fraction<=.08)return {safe:true,reason:'smooth',samples:count,rmse,outliers:fraction,coefficients};
          // Colored lighting and curved gradients need not fit a single plane.
          // Validate local donor continuity before using the existing diffusion;
          // high-frequency texture and hard illustration edges still fail.
          let localCount=0,localSquared=0,localOutliers=0,edges=0;
          for(let y=2;y<h-2;y+=stride)for(let x=2;x<w-2;x+=stride){
            const i=y*w+x;if(!isDonor(x,y))continue;
            const neighbors=[i-1,i+1,i-w,i+w];
            if(neighbors.some(j=>mask[j]||blocked[j]))continue;
            let residual=0,edge=0;
            for(let c=0;c<3;c++){
              const center=rgba[i*4+c];
              const average=neighbors.reduce((sum,j)=>sum+rgba[j*4+c],0)/4;
              residual=Math.max(residual,Math.abs(center-average));
              for(const j of neighbors)edge=Math.max(edge,Math.abs(center-rgba[j*4+c]));
            }
            localCount++;localSquared+=residual*residual;
            if(residual>12)localOutliers++;if(edge>28)edges++;
          }
          const localRMSE=Math.sqrt(localSquared/Math.max(1,localCount));
          const safe=localCount>=24&&localCount>=count*.25&&localRMSE<=5&&
            localOutliers/localCount<=.04&&edges/localCount<=.04;
          return {safe,reason:safe?'locally-smooth':'textured',samples:count,rmse,outliers:fraction,
            localSamples:localCount,localRMSE,edgeFraction:edges/Math.max(1,localCount),coefficients};
        }
        // Restoration may recover a palette even when display-color role
        // inference is ambiguous. Require a dominant interior surface and the
        // same observed color on opposing exterior sides of the OCR rectangle.
        // This evidence is used only for erasure, never to recolor translation.
        function aidokuFlatInpaintingPalette(rgba,w,h,b) {
          const n=w*h;
          if(!Number.isInteger(w)||!Number.isInteger(h)||w<8||h<8||n>262144||!rgba||rgba.length!==n*4||
              !Array.isArray(b)||b.length!==4||!b.every(Number.isFinite)||b[0]<2||b[1]<2||
              b[2]<=0||b[3]<=0||b[0]+b[2]>w-2||b[1]+b[3]>h-2)return null;
          const bins=new Map(),distance=(a,c)=>Math.max(...a.map((v,k)=>Math.abs(v-c[k])));
          const x0=Math.floor(b[0]),y0=Math.floor(b[1]),x1=Math.ceil(b[0]+b[2]),y1=Math.ceil(b[1]+b[3]);
          let count=0;
          for(let y=y0;y<y1;y++)for(let x=x0;x<x1;x++){
            const i=(y*w+x)*4,rgb=[rgba[i],rgba[i+1],rgba[i+2]],key=rgb.map(v=>v>>4).join(',');
            let bin=bins.get(key);if(!bin){bin={count:0,sum:[0,0,0]};bins.set(key,bin);}
            bin.count++;count++;for(let c=0;c<3;c++)bin.sum[c]+=rgb[c];
          }
          const peaks=[...bins.values()].sort((a,b)=>b.count-a.count);
          if(!peaks.length)return null;
          // A smooth colored backing can straddle quantization boundaries.
          // Corroborate a compact cluster instead of requiring a single RGB bin.
          const mean=bin=>bin.sum.map(v=>v/bin.count),seed=mean(peaks[0]);
          const surface=peaks.filter(bin=>distance(mean(bin),seed)<=20);
          const support=surface.reduce((sum,bin)=>sum+bin.count,0);
          if(support<count*.4)return null;
          const background=[0,1,2].map(c=>surface.reduce((sum,bin)=>sum+bin.sum[c],0)/support),sides=[];
          for(let side=0;side<4;side++){
            let support=0,samples=0;
            const length=side<2?y1-y0:x1-x0;
            for(let t=0;t<length;t++)for(let step=1;step<=3;step++){
              const x=side===0?x0-step:side===1?x1-1+step:x0+t;
              const y=side===2?y0-step:side===3?y1-1+step:y0+t;
              if(x<0||x>=w||y<0||y>=h)continue;
              const i=(y*w+x)*4;samples++;
              if(distance([rgba[i],rgba[i+1],rgba[i+2]],background)<=20)support++;
            }
            sides.push(support/Math.max(1,samples));
          }
          if(!((sides[0]>=.65&&sides[1]>=.65)||(sides[2]>=.65&&sides[3]>=.65)))return null;
          const ink=peaks.find(bin=>bin.count>=Math.max(4,count*.015)&&
            distance(bin.sum.map(v=>v/bin.count),background)>=40);
          if(!ink)return null;
          const foreground=ink.sum.map(v=>v/ink.count);
          return {foreground,background,confidence:{foreground:.75,background:.8},inpaintingOnly:true};
        }
        // The page sampler may keep a second ink only in sourceInk.stroke.
        // Revalidate it at restoration resolution: repeated compact components
        // must lie inside OCR, across several text bands, with little exterior
        // support. A palette entry by itself never authorizes another pass.
        function aidokuSecondarySourceInk(rgba,w,h,b,palette,usedPalette) {
          const ink=palette?.sourceInk?.stroke,fg=usedPalette?.foreground,bg=usedPalette?.background;
          const distance=(a,c)=>Math.max(...a.map((v,k)=>Math.abs(v-c[k])));
          if(!ink||!fg||!bg||Math.max(...ink)-Math.min(...ink)<40||
              (palette.sourceInk.confidence?.stroke||0)<.6||distance(ink,fg)<48||distance(ink,bg)<48)return null;
          const n=w*h,seen=new Uint8Array(n),queue=new Int32Array(n),bands=new Set();
          const vertical=b[3]>=b[2],inside=(x,y)=>x>=b[0]&&x<b[0]+b[2]&&y>=b[1]&&y<b[1]+b[3];
          const matches=i=>rgba[i*4+3]>=250&&Math.max(...ink.map((v,c)=>Math.abs(v-rgba[i*4+c])))<=28;
          let interior=0,exterior=0,owned=0,components=0;
          for(let i=0;i<n;i++){
            if(seen[i]||!matches(i))continue;
            seen[i]=1;queue[0]=i;let head=0,tail=1,x0=w,y0=h,x1=0,y1=0,local=0;
            while(head<tail){
              const j=queue[head++],x=j%w,y=j/w|0;
              x0=Math.min(x0,x);x1=Math.max(x1,x);y0=Math.min(y0,y);y1=Math.max(y1,y);
              if(inside(x,y)){interior++;local++;}else exterior++;
              for(let yy=Math.max(0,y-1);yy<=Math.min(h-1,y+1);yy++)
                for(let xx=Math.max(0,x-1);xx<=Math.min(w-1,x+1);xx++){
                  const k=yy*w+xx;if(!seen[k]&&matches(k)){seen[k]=1;queue[tail++]=k;}
                }
            }
            if(tail<4||local<tail*.97||x0<1||y0<1||x1>=w-1||y1>=h-1||
                (vertical?y1-y0+1:x1-x0+1)>Math.max(b[2],b[3])*.3||
                (vertical?x1-x0+1:y1-y0+1)>Math.min(b[2],b[3])*.8)continue;
            owned+=local;components++;
            const center=vertical?(y0+y1)/2:(x0+x1)/2,start=vertical?b[1]:b[0],length=vertical?b[3]:b[2];
            bands.add(Math.min(7,Math.max(0,Math.floor((center-start)*8/length))));
          }
          const support=interior/(b[2]*b[3]),outside=exterior/Math.max(1,n-b[2]*b[3]);
          if(components<3||bands.size<3||support<.015||support>.4||outside>.02||owned<interior*.8)return null;
          return {color:ink,components,bands:bands.size,support,exterior:outside};
        }
        // Missing OCR ruby can sit just beyond a tall Japanese body column.
        // Require two aligned small glyph rows on the same clear paper surface;
        // isolated marks, adjoining contours and textured artwork cannot qualify.
        function aidokuInferVerticalRuby(raw,rgba,w,h,b,background) {
          if(b[3]<b[2]*2.5||b[2]<12||Math.min(...background)<220)return [];
          const n=w*h,seen=new Uint8Array(n),queue=new Int32Array(n),candidates=[];
          const left=b[0]+b[2]-.15*b[2],right=Math.min(w-3,b[0]+b[2]+Math.min(96,b[2]*.8));
          const limit=b[2]*.6;
          for(let yy=Math.max(3,Math.floor(b[1]));yy<Math.min(h-3,b[1]+b[3]);yy++)
            for(let xx=Math.max(3,Math.floor(left));xx<right;xx++){
              const start=yy*w+xx;if(!raw[start]||seen[start])continue;
              let head=0,tail=1,l=w,t=h,r=0,d=0;queue[0]=start;seen[start]=1;
              while(head<tail){const i=queue[head++],x=i%w,y=i/w|0;l=Math.min(l,x);r=Math.max(r,x);t=Math.min(t,y);d=Math.max(d,y);
                for(let cy=Math.max(0,y-1);cy<=Math.min(h-1,y+1);cy++)for(let cx=Math.max(0,x-1);cx<=Math.min(w-1,x+1);cx++){
                  const j=cy*w+cx;if(raw[j]&&!seen[j]){seen[j]=1;queue[tail++]=j;}
                }
              }
              if(tail<3||l<left||r>right||t<b[1]||d>b[1]+b[3]||l<3||t<3||r>=w-3||d>=h-3||
                  r-l+1>limit||d-t+1>limit)continue;
              // Small solid dots belong to an established reading column too.
              // They cannot establish that ownership without actual glyphs.
              const solid=tail>(r-l+1)*(d-t+1)*.85;
              if(solid&&(Math.max(r-l+1,d-t+1)>b[2]*.25||
                  Math.max(r-l+1,d-t+1)>Math.min(r-l+1,d-t+1)*2))continue;
              candidates.push({l,t,r,d,solid});if(candidates.length>32)return [];
            }
          const result=[];
          for(const seed of candidates){
            const group=candidates.filter(c=>Math.abs((c.l+c.r-seed.l-seed.r)/2)<=b[2]*.22);
            const l=Math.min(...group.map(c=>c.l)),r=Math.max(...group.map(c=>c.r));
            if(r-l+1>limit||group.filter(c=>!c.solid).length<2)continue;
            const rows=[];
            for(const c of group.slice().sort((a,z)=>a.t-z.t)){
              const previous=rows.at(-1);
              if(previous&&c.t<=previous[1]+b[2]*.14)previous[1]=Math.max(previous[1],c.d);
              else rows.push([c.t,c.d]);
            }
            if(rows.length<2||rows.length>12||rows.some((row,i)=>i>0&&row[0]-rows[i-1][1]>b[2]*1.3))continue;
            const t=rows[0][0],d=rows.at(-1)[1];
            let clear=true;
            for(let y=t-3;y<=d+3&&clear;y++)for(let x=l-3;x<=r+3;x++){
              if(x>l-3&&x<r+3&&y>t-3&&y<d+3)continue;
              const i=(y*w+x)*4;
              if(Math.max(...background.map((v,c)=>Math.abs(rgba[i+c]-v)))>32){clear=false;break;}
            }
            // A balloon rule between the main text and the small column means
            // the two texts do not share a surface.
            for(let y=t;y<=d&&clear;y++)for(let x=Math.ceil(b[0]+b[2]+3);x<l-3;x++){
              const i=(y*w+x)*4;
              if(Math.max(...background.map((v,c)=>Math.abs(rgba[i+c]-v)))>32){clear=false;break;}
            }
            if(!clear)continue;
            const rect=[l-1,t-1,r-l+3,d-t+3];
            if(!result.some(q=>q.every((v,i)=>v===rect[i])))result.push(rect);
          }
          return result.slice(0,4);
        }
        function aidokuRestoreSourcePanel(rgba,w,h,b,palette,options={}) {
          // A merged OCR region can contain separately colored lettering. The
          // sampler or native repeated-component evidence establishes the second ink;
          // a spare palette color alone cannot authorize erasing illustration.
          const finish=(result,usedPalette,method)=>{
            const distance=(a,c)=>Math.max(...a.map((v,k)=>Math.abs(v-c[k])));
            let evidence=palette?.lettering;
            if(options.readabilityGate&&(!evidence?.color||!usedPalette?.foreground||
                distance(evidence.color,usedPalette.foreground)<48))
              evidence=aidokuSecondarySourceInk(rgba,w,h,b,palette,usedPalette);
            const ink=evidence?.color;
            if(options.readabilityGate&&ink&&usedPalette?.foreground&&usedPalette?.background&&
                evidence.bands>=3&&evidence.components>=3&&evidence.support>=.015&&evidence.exterior<=.02&&
                distance(ink,usedPalette.foreground)>=48&&distance(ink,usedPalette.background)>=48){
              // Mask both observed inks together. Sequential erasure would
              // treat the other ink's white halo as a background donor and
              // preserve a pale silhouette after both colored cores disappear.
              const joint=aidokuRestoreObservedSourcePanel(rgba,w,h,b,usedPalette,{...options,secondaryInk:ink});
              // A dark outline can connect separate pale glyphs into a large
              // protected component. Never trade already removed primary ink
              // for the second color, even if the new donor surface is smooth.
              let preservesPrimary=Boolean(joint);
              if(joint)for(let i=0;i<w*h;i++){
                if(!result.rgba[i*4+3]||joint.rgba[i*4+3])continue;
                const rgb=[rgba[i*4],rgba[i*4+1],rgba[i*4+2]];
                if(distance(rgb,usedPalette.foreground)<=48&&distance(rgb,usedPalette.background)>=32){preservesPrimary=false;break;}
              }
              if(preservesPrimary){joint.secondaryInkPixels=Math.max(0,joint.erased-result.erased);result=joint;}
            }
            // WebKit downsamples the transparent patch separately from the
            // page. Without a sampling guard its alpha edge exposes the old
            // white outline, even when every native glyph pixel was erased.
            // Copy only matching original background into a two-pixel guard;
            // source ink and artwork are never reconstructed by this step.
            if(options.readabilityGate&&usedPalette?.stroke&&usedPalette.background&&
                distance(usedPalette.stroke,usedPalette.background)>=32){
              const rgbaOut=result.rgba,guard=new Uint8Array(w*h);
              for(let pass=0;pass<2;pass++){
                const pending=[];
                for(let y=1;y<h-1;y++)for(let x=1;x<w-1;x++){
                  const i=y*w+x;if(rgbaOut[i*4+3]||!result.layoutSafe?.[i])continue;
                  let agrees=false;
                  for(let yy=y-1;yy<=y+1&&!agrees;yy++)for(let xx=x-1;xx<=x+1;xx++){
                    const j=yy*w+xx;if(!rgbaOut[j*4+3]||guard[j]>pass)continue;
                    let error=0;for(let c=0;c<3;c++)error=Math.max(error,Math.abs(rgba[i*4+c]-rgbaOut[j*4+c]));
                    if(error<=16){agrees=true;break;}
                  }
                  if(agrees)pending.push(i);
                }
                for(const i of pending){rgbaOut.set(rgba.subarray(i*4,i*4+4),i*4);guard[i]=pass+1;}
              }
            }
            return {...result,method,...(options.slantedOwnership?
              {sourceForeground:usedPalette.foreground,sourceBackground:usedPalette.background}: {})};
          };
          const original=aidokuRestoreObservedSourcePanel(rgba,w,h,b,palette,options);
          if(original)return finish(original,palette,original.surfaceQuality?.reason==='locally-smooth'?'local-diffusion':'observed-palette');
          if(!options.readabilityGate)return null;
          if(palette?.sourceInk){
            const observed=aidokuRestoreObservedSourcePanel(rgba,w,h,b,palette.sourceInk,options);
            if(observed)return finish(observed,palette.sourceInk,'observed-ink-evidence');
          }
          const flat=aidokuFlatInpaintingPalette(rgba,w,h,b);
          if(!flat)return null;
          const recovered=aidokuRestoreObservedSourcePanel(rgba,w,h,b,flat,{...options,compactMask:true,flatPalette:true});
          return recovered?finish(recovered,flat,'flat-surface-palette'):null;
        }
        // Small repeated marks on both sides of the OCR boundary are surface
        // texture, not disconnected punctuation. Require the same two-dimensional
        // periodicity inside and outside before refusing model-free reconstruction.
        // Reuse a repeated background only when independently exposed pixels
        // corroborate its phase in two directions. The search uses existing
        // crop pixels, bounded probes and original (never synthesized) donors.
        function aidokuSourcePeriodicFill(rgba,w,h,mask,blocked,halftone=false,texturePoints=[]) {
          const n=w*h,valid=new Uint8Array(n),samples=[],stride=Math.max(1,Math.ceil(Math.sqrt(n/768)));
          let total=0;const tone=halftone?texturePoints.reduce((sum,i)=>sum+rgba[i*4+1],0)/Math.max(1,texturePoints.length):0;const supported=halftone?new Uint8Array(n):null;
          if(supported)for(const i of texturePoints){const x=i%w,y=i/w|0;
            for(let yy=Math.max(3,y-3);yy<Math.min(h-3,y+4);yy++)for(let xx=Math.max(3,x-3);xx<Math.min(w-3,x+4);xx++)supported[yy*w+xx]=1;
          }
          for(let y=3;y<h-3;y++)for(let x=3;x<w-3;x++){
            const i=y*w+x;if(mask[i]||blocked[i]||supported&&!supported[i])continue;
            valid[i]=1;total++;
            if(x%stride===0&&y%stride===0)samples.push(i);
          }
          if(total<256||samples.length<96)return null;
          const probes=samples.filter((_,k)=>k%Math.max(1,Math.ceil(samples.length/192))===0);
          const evaluate=(dx,dy,list=probes,limit=Infinity)=>{
            let count=0,error=0,outliers=0,sum=0,squared=0;
            for(const i of list){
              const x=i%w+dx,y=(i/w|0)+dy;if(x<3||y<3||x>=w-3||y>=h-3)continue;
              const j=y*w+x;if(!valid[j])continue;
              let e=0;for(let c=0;c<3;c++)e=Math.max(e,Math.abs(rgba[i*4+c]-rgba[j*4+c]));
              count++;error+=Math.min(64,e);if(error>list.length*limit)return null;outliers+=e>12;sum+=rgba[i*4+1];squared+=rgba[i*4+1]**2;
            }
            if(count<Math.max(32,list.length*.12))return null;
            const deviation=Math.sqrt(Math.max(0,squared/count-(sum/count)**2));
            return {dx,dy,error:error/count,outliers:outliers/count,deviation,count};
          };
          const coarse=[];
          for(let dy=0;dy<=Math.min(64,h>>1);dy+=(halftone?1:2))for(let dx=-Math.min(128,w>>1);dx<=Math.min(128,w>>1);dx+=(halftone?1:2)){
            if(dy===0&&dx<=0||Math.max(Math.abs(dx),dy)<8)continue;
            const v=evaluate(dx,dy,probes,halftone?12:2.5);if(v&&v.error<=(halftone?12:2.5)&&v.deviation>=3&&v.outliers<=(halftone?.3:.02))coarse.push(v);
          }
          coarse.sort((a,b)=>a.error-b.error||(halftone?Math.hypot(a.dx,a.dy)-Math.hypot(b.dx,b.dy):0));
          const refined=[],visited=new Set();
          for(const v of coarse.slice(0,halftone?96:24))for(let dy=v.dy-1;dy<=v.dy+1;dy++)for(let dx=v.dx-1;dx<=v.dx+1;dx++){
            if(dy<0||dy===0&&dx<=0)continue;
            const key=dx+','+dy;if(visited.has(key))continue;visited.add(key);
            const q=evaluate(dx,dy,samples);
            if(!q||q.error>(halftone?9:1.5)||q.deviation<3||q.outliers>(halftone?.2:.01))continue;
            const nearby=[evaluate(dx+4,dy,samples),evaluate(dx,dy+4,samples)].filter(Boolean);
            if(nearby.length<2||nearby.some(p=>p.error<q.error*(halftone?1.25:1.5)+1))continue;
            refined.push(q);
          }
          refined.sort((a,b)=>a.error-b.error||(halftone?Math.hypot(a.dx,a.dy)-Math.hypot(b.dx,b.dy):0));
          const vectors=[];
          // Equal-error horizontal periods must not crowd out the independent
          // vertical/diagonal witness needed to continue a two-dimensional tone.
          if(halftone&&refined.length){const first=refined[0];
            const independent=refined.find(v=>Math.abs(v.dx*first.dy-v.dy*first.dx)>Math.hypot(v.dx,v.dy)*Math.hypot(first.dx,first.dy)*.2);
            if(independent)vectors.push(first,independent);
          }
          for(const v of refined){
            if(vectors.some(q=>Math.hypot(q.dx-v.dx,q.dy-v.dy)<6))continue;
            vectors.push(v);if(vectors.length===6)break;
          }
          if(vectors.length<2||!vectors.some(v=>Math.abs(v.dx*vectors[0].dy-v.dy*vectors[0].dx)>
              Math.hypot(v.dx,v.dy)*Math.hypot(vectors[0].dx,vectors[0].dy)*.2))return null;
          const shifts=[];
          for(const v of vectors)for(const scale of [1,-1,2,-2,3,-3,4,-4])shifts.push({dx:v.dx*scale,dy:v.dy*scale,error:v.error*Math.abs(scale)});
          // A diagonal period and a horizontal period together can reach an
          // exposed row even when a whole dialogue line hides its own row.
          for(const shift of shifts.slice())for(const scale of [-2,-1,1,2]){
            const dx=shift.dx+vectors[0].dx*scale,dy=shift.dy+vectors[0].dy*scale;
            if(Math.abs(dx)<w-6&&Math.abs(dy)<h-6&&!shifts.some(v=>v.dx===dx&&v.dy===dy))
              shifts.push({dx,dy,error:shift.error+vectors[0].error*Math.abs(scale)});
          }
          shifts.sort((a,b)=>a.error-b.error);
          const output=new Uint8ClampedArray(n*4);let painted=0;
          for(let i=0;i<n;i++){
            if(!mask[i])continue;
            const x=i%w,y=i/w|0,donors=[];
            for(const v of shifts){
              const xx=x+v.dx,yy=y+v.dy;if(xx<3||yy<3||xx>=w-3||yy>=h-3)continue;
              const j=yy*w+xx;if(!valid[j]||donors.includes(j))continue;
              donors.push(j);if(donors.length===(halftone?12:6))break;
            }
            let pair=null,pairShade=Infinity;
            for(let a=0;a<donors.length&&(halftone||!pair);a++)for(let b=a+1;b<donors.length;b++){
              if([0,1,2].every(c=>Math.abs(rgba[donors[a]*4+c]-rgba[donors[b]*4+c])<=(halftone?24:6))){const shade=Math.abs((rgba[donors[a]*4+1]+rgba[donors[b]*4+1])/2-tone);if(shade<pairShade){pair=[donors[a],donors[b]];pairShade=shade;}if(!halftone)break;}
            }
            // Missing or disagreeing donors invalidate the whole patch. There
            // is no diffusion fallback inside an otherwise patterned result.
            if(!pair)return null;
            for(let c=0;c<3;c++)output[i*4+c]=Math.round((rgba[pair[0]*4+c]+rgba[pair[1]*4+c])/2);
            output[i*4+3]=255;painted++;
          }
          return {rgba:output,erased:painted,vectors:vectors.map(v=>[v.dx,v.dy]),error:vectors[0].error};
        }
        // Bounded exemplar synthesis for stationary grain on a validated smooth
        // backing. Remove the fitted gradient before comparing 9x9 patches,
        // then restore it at the target. Only original pixels provide texture;
        // filled pixels guide seams but never become donor patches. Require
        // texture energy on both sides and abandon the whole proposal on
        // insufficient support, a bad seam, or the fixed work limit.
        function aidokuSourceExemplarFill(rgba,w,h,mask,palette,surface,protectedInk,textureComponents) {
          const n=w*h,r=4;
          let left=mask.reduce((a,v)=>a+v,0),erased=left,comparisons=0,operations=0;
          if(left<32||left>32000||n>131072)return null;
          const output=new Uint8ClampedArray(n*4),work=rgba.slice(),pending=mask.slice();
          const residual=new Float32Array(n*3);
          for(let i=0;i<n;i++)for(let c=0;c<3;c++){const a=surface.coefficients[c];residual[i*3+c]=rgba[i*4+c]-(a[0]+a[1]*(i%w)/w+a[2]*(i/w|0)/h);}
          const filled=residual.slice();
          const forbidden=protectedInk.slice();for(const points of textureComponents)for(const i of points)forbidden[i]=0;
          const integral=new Int32Array((w+1)*(h+1));
          for(let y=0;y<h;y++){let row=0;for(let x=0;x<w;x++){row+=Boolean(mask[y*w+x]||forbidden[y*w+x]);integral[(y+1)*(w+1)+x+1]=integral[y*(w+1)+x+1]+row;}}
          const box=(x,y)=>integral[(y+r+1)*(w+1)+x+r+1]-integral[(y-r)*(w+1)+x+r+1]-integral[(y+r+1)*(w+1)+x-r]+integral[(y-r)*(w+1)+x-r];
          const donors=[];let donorSquares=0,donorCount=0,activePatches=0;
          for(let y=r+1;y<h-r-1;y+=2)for(let x=r+1;x<w-r-1;x+=2){
            if(box(x,y))continue;let bad=0;
            for(let yy=y-r;yy<=y+r;yy++)for(let xx=x-r;xx<=x+r;xx++){
              const i=(yy*w+xx)*4;let d=0;for(let c=0;c<3;c++)d=Math.max(d,Math.abs(rgba[i+c]-palette.foreground[c]));if(d<48)bad++;
            }
            if(bad>5)continue;
            let sum=0,squared=0,high=0;
            for(let yy=y-r;yy<=y+r;yy++)for(let xx=x-r;xx<=x+r;xx++){
              const j=yy*w+xx,v=residual[j*3+1];sum+=v;squared+=v*v;
              if(Math.abs(rgba[j*4+1]-(rgba[(j-1)*4+1]+rgba[(j+1)*4+1]+rgba[(j-w)*4+1]+rgba[(j+w)*4+1])/4)>4)high++;
            }
            const variance=squared/81-(sum/81)**2;
            if(Math.abs(sum/81)>12||variance>625)continue;
            if(variance>=9&&high>=3)activePatches++;
            donorSquares+=squared;donorCount+=81;donors.push(y*w+x);
          }
          if(donors.length<24||activePatches<donors.length*.4||donorSquares/donorCount<9)return null;
          const sample=donors.filter((_,i)=>i%Math.max(1,Math.ceil(donors.length/192))===0);
          let patches=0,maxError=0;
          while(left){
            if(++patches>1200)return null;
            let at=-1,priority=-1,known=[];
            // High-confidence boundary patches first; gradients prefer continuous edges.
            for(let y=r+1;y<h-r-1;y+=2)for(let x=r+1;x<w-r-1;x+=2){
              const i=y*w+x;if(!pending[i]||pending[i-1]&&pending[i+1]&&pending[i-w]&&pending[i+w])continue;
              let count=0,lo=255,hi=0;
              for(let dy=-r;dy<=r;dy+=2)for(let dx=-r;dx<=r;dx+=2){
                if(++operations>24000000)return null;const j=i+dy*w+dx;if(pending[j])continue;count++;lo=Math.min(lo,work[j*4+1]);hi=Math.max(hi,work[j*4+1]);
              }
              const value=count*(1+Math.min(hi-lo,80)/80);
              if(value>priority){priority=value;at=i;}
            }
            if(at<0){at=pending.findIndex(v=>v);if(at<0)break;}
            const ax=at%w,ay=at/w|0;
            if(ax<r||ay<r||ax>=w-r||ay>=h-r)return null;
            for(let dy=-r;dy<=r;dy++)for(let dx=-r;dx<=r;dx++){
              const j=at+dy*w+dx;if(!pending[j])known.push([dy*w+dx,j*4]);
            }
            if(known.length<12)return null;
            let best=-1,error=Infinity;
            for(const donor of sample){
              let s=0;
              for(const [offset,j] of known){
                const q=(donor+offset)*4;
                for(let c=0;c<3;c++){const d=filled[(j/4)*3+c]-residual[(q/4)*3+c];s+=d*d;}
                comparisons++;if(++operations>24000000)return null;
                if(s>error)break;
              }
              if(s<error){error=s;best=donor;}
            }
            const rmse=Math.sqrt(error/(known.length*3));maxError=Math.max(maxError,rmse);
            if(best<0||rmse>24)return null;
            for(let dy=-r;dy<=r;dy++)for(let dx=-r;dx<=r;dx++){
              const j=at+dy*w+dx;if(!pending[j])continue;const q=(best+dy*w+dx)*4;
              for(let c=0;c<3;c++){
                const a=surface.coefficients[c],v=residual[(q/4)*3+c];filled[j*3+c]=v;
                output[j*4+c]=work[j*4+c]=v+a[0]+a[1]*(j%w)/w+a[2]*(j/w|0)/h;
              }output[j*4+3]=255;pending[j]=0;left--;
            }
          }
          let resultSquares=0;for(let i=0;i<n;i++)if(mask[i])resultSquares+=filled[i*3+1]**2;
          const textureRatio=Math.sqrt((resultSquares/erased)/(donorSquares/donorCount));
          if(textureRatio<.5||textureRatio>1.8)return null;
          return {rgba:output,erased,patches,maxError,comparisons,operations,donors:sample.length,textureRatio};
        }
        function aidokuSourceHasPeriodicInk(points,w,h,b) {
          if(points.length<64)return false;
          const map=new Uint8Array(w*h),inside=[],outside=[];
          for(const i of points){
            const x=i%w,y=i/w|0,inBox=x>=b[0]&&x<b[0]+b[2]&&y>=b[1]&&y<b[1]+b[3];
            map[i]=inBox?1:2;(inBox?inside:outside).push(i);
          }
          if(inside.length<32||outside.length<32||inside.length<b[2]*b[3]*.004)return false;
          const samples=list=>list.filter((_,i)=>i%Math.max(1,Math.ceil(list.length/256))===0);
          const groups=[samples(inside),samples(outside)],vectors=[];
          for(let dx=0;dx<=8;dx++)for(let dy=-8;dy<=8;dy++){
            const length=Math.hypot(dx,dy);if(length<3||length>9||dx===0&&dy<0)continue;
            const support=groups.map((group,k)=>{
              let matches=0,total=0;
              for(const i of group){
                const x=i%w+dx,y=(i/w|0)+dy;if(x<1||y<1||x>=w-1||y>=h-1)continue;
                total++;let found=false;
                for(let yy=y-1;yy<=y+1&&!found;yy++)for(let xx=x-1;xx<=x+1;xx++)if(map[yy*w+xx]===k+1){found=true;break;}
                if(found)matches++;
              }
              return matches/Math.max(1,total);
            });
            if(Math.min(...support)<.6)continue;
            if(vectors.some(v=>Math.abs(v[0]*dx+v[1]*dy)/(Math.hypot(...v)*length)<.75))return true;
            vectors.push([dx,dy]);
          }
          return false;
        }
        function aidokuRestoreObservedSourcePanel(rgba,w,h,b,palette,options={}) {
          const n=w*h;
          if(!Number.isInteger(w)||!Number.isInteger(h)||w<8||h<8||n>262144||
              !rgba||rgba.length!==n*4||!Array.isArray(b)||b.length!==4||!b.every(Number.isFinite)||
              b[0]<2||b[1]<2||b[2]<=0||b[3]<=0||b[0]+b[2]>w-2||b[1]+b[3]>h-2||
              !palette?.foreground||!palette?.background)return null;
          // WebKit crop resampling can round opaque alpha to 254. Accept that
          // one-byte error without flattening genuinely transparent source art.
          for(let q=3;q<rgba.length;q+=4)if(rgba[q]<254)return null;
          // Suppressed white readings on a dark caption retain the same verified
          // ownership. Reuse the bounded mask in opposite polarity; alpha and
          // protected illustration components are unchanged.
          if(Math.min(...palette.foreground)>=175&&Math.max(...palette.background)<=115&&options.auxiliary?.length){
            const inverted=rgba.slice();
            for(let i=0;i<n;i++)for(let c=0;c<3;c++)inverted[i*4+c]=255-inverted[i*4+c];
            const flip=c=>c?c.map(v=>255-v):null;
            const restored=aidokuRestoreObservedSourcePanel(inverted,w,h,b,{...palette,foreground:flip(palette.foreground),
              background:flip(palette.background),stroke:flip(palette.stroke)},
              options.secondaryInk?{...options,secondaryInk:flip(options.secondaryInk)}:options);
            if(!restored)return null;
            for(let i=0;i<n;i++)if(restored.rgba[i*4+3])for(let c=0;c<3;c++)restored.rgba[i*4+c]=255-restored.rgba[i*4+c];
            if(restored.surfaceQuality?.coefficients)restored.surfaceQuality={...restored.surfaceQuality,
              coefficients:restored.surfaceQuality.coefficients.map(a=>[255-a[0],-a[1],-a[2]])};
            return restored;
          }
          const foreground=palette.foreground;
          const colorDistance=(a,b)=>Math.max(...a.map((v,c)=>Math.abs(v-b[c])));
          const separation=colorDistance(foreground,palette.background);
          const onInkBlend=(rgb,end,start=foreground)=>{
            if(!end||!start)return false;
            const delta=end.map((v,c)=>v-start[c]);
            const length=delta.reduce((sum,v)=>sum+v*v,0);
            if(!length)return false;
            const t=Math.max(0,Math.min(1,delta.reduce((sum,v,c)=>sum+(rgb[c]-start[c])*v,0)/length));
            return colorDistance(rgb,start.map((v,c)=>v+t*delta[c]))<=24;
          };
          const legacyDark=Math.max(...foreground)<=80&&Math.min(...palette.background)>=140;
          // Match observed ink in RGB space, independent of hue or panel polarity.
          // Color is evidence for ownership, never a reason to replace the panel.
          const matchedInk=!legacyDark&&separation>=24&&(palette.confidence?.foreground||0)>=.55;
          if(!legacyDark&&!matchedInk)return null;
          const inkTolerance=Math.max(10,Math.min(48,separation*.4));
          // Use measured exterior halo thickness when available. Counter-area
          // estimates do not measure the outer halo and retain the bounded fallback.
          const evidence=palette.widthEvidence;
          const measuredHalo=options.readabilityGate&&evidence?.method?.startsWith('outer stroke boundary')&&
            (palette.confidence?.stroke||0)>=.6&&Number.isFinite(evidence.samplePixels)&&
            Number.isFinite(evidence.sampleScale)&&evidence.sampleScale>0;
          const measuredRadius=measuredHalo?Math.max(4,Math.min(12,Math.ceil(
            evidence.samplePixels/evidence.sampleScale*(options.sampleScale||1))+2)):null;
          // Retry with a tighter glyph margin when a wide default mask reaches
          // neighboring artwork. Observed outlines retain their measured width.
          const radius=measuredRadius??(options.compactMask?(palette.stroke?6:3):12);
          
     const p=rgba.slice(),raw=new Uint8Array(n),seen=new Uint8Array(n),mask=new Uint8Array(n),protectedInk=new Uint8Array(n),frameInk=new Uint8Array(n),queue=new Int32Array(n),seedRadius=new Uint8Array(n),accepted=[],isolatedBodyInk=[],readingCandidates=[],edgeFragments=[];
     const observedInk=matchedInk?new Uint8Array(n):null;
     for(let i=0;i<n;i++){
       const rgb=[p[4*i],p[4*i+1],p[4*i+2]];
       const inkDistance=colorDistance(rgb,foreground),backgroundDistance=colorDistance(rgb,palette.background);
       const secondaryDistance=options.secondaryInk?colorDistance(rgb,options.secondaryInk):Infinity;
       const secondaryMatch=secondaryDistance<=inkTolerance&&secondaryDistance+8<backgroundDistance;
       if(observedInk&&(inkDistance<=inkTolerance&&inkDistance+8<backgroundDistance||secondaryMatch))observedInk[i]=1;
       // Dark rules on a light surface still enter component protection. On a
       // dark surface the dark pixels are background, not an enormous ink component.
       if(secondaryMatch||observedInk?.[i]||(Math.min(...palette.background)>=140&&Math.max(...rgb)<110))raw[i]=1;
       // The outer antialias ramp runs from stroke to backing, independently
       // of the fill hue. Treating it as artwork strands valid colored halos.
       if(observedInk&&!raw[i]&&backgroundDistance>=Math.max(32,separation*.55)&&
           inkDistance>inkTolerance&&(!palette.stroke||colorDistance(rgb,palette.stroke)>inkTolerance)&&
           !onInkBlend(rgb,palette.stroke)&&!onInkBlend(rgb,palette.background)&&
           !onInkBlend(rgb,palette.background,palette.stroke))
         protectedInk[i]=1;
     }
     const auxiliary=(options.auxiliary||[]).slice(0,32).filter(r=>Array.isArray(r)&&r.length===4&&r.every(Number.isFinite)&&r[0]>=2&&r[1]>=2&&r[2]>0&&r[3]>0&&r[0]+r[2]<w-2&&r[1]+r[3]<h-2);
     if(options.readabilityGate&&options.vertical&&legacyDark&&auxiliary.length===0)
       auxiliary.push(...aidokuInferVerticalRuby(raw,p,w,h,b,palette.background).filter(r=>
         !(options.inferredRubyExclusions||[]).some(q=>r[0]<q[0]+q[2]&&r[0]+r[2]>q[0]&&r[1]<q[1]+q[3]&&r[1]+r[3]>q[1])));
     // Faded body letters, punctuation and fine ruby can have no dark core.
     // Require a clear surrounding ring before recruiting the ink-to-paper
     // blend. The body uses stricter support than an explicit ruby annotation;
     // texture or an intersecting illustration cannot establish ownership.
     const faintInk=new Uint8Array(n);
     let faintBodyAdded=false,extendedHalo=false;
     const faintRegions=[...auxiliary.map(rect=>({rect,ruby:true}))];
     if(options.readabilityGate&&options.faintBody!==false&&separation>=60)faintRegions.push({rect:b,ruby:false});
     for(const {rect:r,ruby} of faintRegions){
       const x0=Math.floor(r[0]),y0=Math.floor(r[1]),x1=Math.ceil(r[0]+r[2]),y1=Math.ceil(r[1]+r[3]);
       let samples=0,clear=0,rough=0;
       for(let y=y0-2;y<=y1+1;y++)for(let x=x0-2;x<=x1+1;x++){
         if(x!==x0-2&&x!==x1+1&&y!==y0-2&&y!==y1+1)continue;
         const i=(y*w+x)*4;samples++;
         if(colorDistance([p[i],p[i+1],p[i+2]],palette.background)<=20)clear++;
         // Grain near the OCR box cannot establish ownership of faint glyphs.
         // Otherwise isolated background noise recruits a much wider erase mask.
         if(!ruby&&x>0&&y>0&&x<w-1&&y<h-1&&[0,1,2].some(c=>Math.abs(p[i+c]-(p[i-4+c]+p[i+4+c]+p[i-w*4+c]+p[i+w*4+c])/4)>6))rough++;
       }
       if(samples<(ruby?8:16)||clear/samples<(ruby?.85:.95)||!ruby&&rough/samples>.2)continue;
       const soft=ruby?null:new Uint8Array(n);
       for(let y=y0;y<y1;y++)for(let x=x0;x<x1;x++){
         const i=y*w+x,rgb=[p[i*4],p[i*4+1],p[i*4+2]];
         if(colorDistance(rgb,palette.background)<Math.max(ruby?24:16,separation*.08)||!onInkBlend(rgb,palette.background))continue;
         if(soft)soft[i]=1;
         else {raw[i]=1;faintInk[i]=1;}
       }
       if(!soft)continue;
       // Grow only components with no existing strong seed. Adding the faint
       // antialias ramp to an already owned character can join adjacent Kanji
       // into an oversized component and reject previously recoverable text.
       for(let y=y0;y<y1;y++)for(let x=x0;x<x1;x++){
         const start=y*w+x;if(!soft[start])continue;
         let head=0,tail=1,strong=false,crosses=false,l=x,t=y,right=x,bottom=y;queue[0]=start;soft[start]=0;
         while(head<tail){
           const i=queue[head++],cx=i%w,cy=i/w|0;if(raw[i])strong=true;
           l=Math.min(l,cx);t=Math.min(t,cy);right=Math.max(right,cx);bottom=Math.max(bottom,cy);
           // A pale drawing line may cross an otherwise clear OCR boundary.
           // Check its continuation outside the box before claiming a clipped
           // piece as a faint letter; the darker component guard cannot see it.
           if(cx===x0||cx===x1-1||cy===y0||cy===y1-1)
             for(let yy=cy-1;yy<=cy+1;yy++)for(let xx=cx-1;xx<=cx+1;xx++){
               if(xx>=x0&&xx<x1&&yy>=y0&&yy<y1)continue;
               const j=(yy*w+xx)*4,rgb=[p[j],p[j+1],p[j+2]];
               if(colorDistance(rgb,palette.background)>=Math.max(16,separation*.08)&&onInkBlend(rgb,palette.background))crosses=true;
             }
           for(let yy=Math.max(y0,cy-1);yy<Math.min(y1,cy+2);yy++)
             for(let xx=Math.max(x0,cx-1);xx<Math.min(x1,cx+2);xx++){
               const j=yy*w+xx;if(!soft[j])continue;
               soft[j]=0;queue[tail++]=j;
             }
         }
         // Solid inset blocks are not faint lettering (e.g. a redaction or UI
         // swatch). Do not let them turn a clear ring into glyph ownership.
         const solid=right-l>=3&&bottom-t>=3&&tail>(right-l+1)*(bottom-t+1)*.9;
         // A lone low-contrast sample is paper/JPEG noise, not a new body
         // component. Promoting it to protected ink would unnecessarily block
         // translated glyphs; explicitly owned one-pixel ruby stays supported.
         if(tail>=2&&!strong&&!solid&&!crosses)for(let k=0;k<tail;k++){raw[queue[k]]=1;faintInk[queue[k]]=1;faintBodyAdded=true;}
       }
     }
     const retryPrevious=()=>faintBodyAdded||extendedHalo?
       aidokuRestoreObservedSourcePanel(rgba,w,h,b,palette,{...options,faintBody:false,outlineFringe:false}):null;
     let companions=0;const texturePoints=[],textureComponents=[];
     for(let start=0;start<n;start++){
     if(!raw[start]||seen[start])continue;let head=0,tail=1,x0=w,y0=h,x1=0,y1=0;queue[0]=start;seen[start]=1;
     while(head<tail){const i=queue[head++],x=i%w,y=i/w|0;x0=Math.min(x0,x);y0=Math.min(y0,y);x1=Math.max(x1,x);y1=Math.max(y1,y);
     for(let yy=Math.max(0,y-1);yy<=Math.min(h-1,y+1);yy++)for(let xx=Math.max(0,x-1);xx<=Math.min(w-1,x+1);xx++){const j=yy*w+xx;if(raw[j]&&!seen[j]){seen[j]=1;queue[tail++]=j;}}
     }
     const cx=(x0+x1)/2,cy=(y0+y1)/2;
     if(options.readabilityGate&&tail<=4&&texturePoints.length<8192){texturePoints.push((cy|0)*w+(cx|0));textureComponents.push(Array.from(queue.subarray(0,tail)));}
     // Touching the rectified ownership boundary alone is not a glyph seed.
     // Otherwise a tiny coordinate round-off can recruit a detached drawing
     // stroke exactly three pixels outside the OCR body.
     const boundaryInset=options.slantedOwnership?1e-6:0;
     const body=cx>=b[0]-3+boundaryInset&&cx<=b[0]+b[2]+3-boundaryInset&&
       cy>=b[1]-3+boundaryInset&&cy<=b[1]+b[3]+3-boundaryInset;
     const ruby=auxiliary.some(r=>cx>=r[0]-2&&cx<=r[0]+r[2]+2&&cy>=r[1]-2&&cy<=r[1]+r[3]+2);
     // A missed leading em dash is a narrow, isolated, white-outlined stroke
     // ending at the first glyph. Curved balloon rules, unoutlined drawing
     // strokes and detached punctuation cannot establish this ownership.
     let rule=false;
     if(options.leadingRule&&palette.stroke&&cy<b[1]&&x1-x0<=Math.max(3,b[2]*.12)&&
         y1-y0>=b[2]*.75&&y1-y0<=Math.min(120,b[2]*3)&&
         cx>=b[0]+b[2]*.25&&cx<=b[0]+b[2]*.75&&
         y0>=b[1]-Math.min(120,b[2]*3)&&y1>=b[1]-8&&y1<=b[1]+b[2]*.6){
       let outlined=0,samples=0;
       for(let y=y0+3;y<y1-2;y++)for(const x of [x0-3,x1+3]){
         if(x<1||x>=w-1)continue;const i=(y*w+x)*4;samples++;
         if(Math.min(p[i],p[i+1],p[i+2])>240)outlined++;
       }
       rule=samples>8&&outlined/samples>.9;
     }
     // Dark drawing components remain protected when the observed text is colored.
     let observedCount=0;
     if(observedInk)for(let k=0;k<tail;k++)observedCount+=Boolean(observedInk[queue[k]]||faintInk[queue[k]]);
     // OCR-owned ruby can include a one-pixel colored stroke. Its explicit
     // ownership has the same meaning for colored ink as for black ink.
     // Rectified words can contain connected cursive or large display glyphs.
     // Their complete component must stay inside the OCR axes; a sign border
     // or drawing crossing those axes remains protected, regardless of color.
     const slantedWord=options.slantedOwnership&&body&&x0>=b[0]&&y0>=b[1]&&
       x1<b[0]+b[2]&&y1<b[1]+b[3]&&x1-x0<b[2]*.96&&y1-y0<b[3]*.96&&
       tail<(x1-x0+1)*(y1-y0+1)*.8;
     const keep=(!observedInk||observedCount>=Math.max(ruby?1:2,tail*.1))&&(tail>=2||(ruby&&tail===1))&&x0>2&&y0>2&&x1<w-3&&y1<h-3&&(body||ruby||rule)&&
       (slantedWord||Math.max(x1-x0,y1-y0)<(rule?121:Math.min(100,Math.max(b[2],b[3])*.6)));
     if(keep&&!body)companions++;
     if(!keep&&body&&tail===1&&x0>2&&y0>2&&x1<w-3&&y1<h-3)isolatedBodyInk.push(start);
     for(let k=0;k<tail;k++){
       (keep?mask:protectedInk)[queue[k]]=1;
       if(keep)seedRadius[queue[k]]=ruby&&!body?Math.min(6,radius):radius;
       if(!keep&&(x0<=2||y0<=2||x1>=w-3||y1>=h-3))frameInk[queue[k]]=1;
     }
     if(keep)accepted.push([x0,y0,x1,y1,tail,observedInk?observedCount:tail]);
     // A tiny disconnected ruby stroke can sit just outside the body box,
     // while the rest of that same glyph is already owned inside the box.
     if(!keep&&options.vertical&&edgeFragments.length<64&&tail<=8&&
         x0>=b[0]+b[2]-3&&x1<=b[0]+b[2]+8&&y0>=b[1]&&y1<=b[1]+b[3]&&
         x1-x0<=3&&y1-y0<=7&&x1<w-3&&y0>2&&y1<h-3)
       edgeFragments.push(Array.from(queue.subarray(0,tail)));
     if(options.vertical&&tail>=2&&tail<=256&&readingCandidates.length<64&&
         x0>2&&y0>2&&x1<w-3&&y1<h-3&&auxiliary.some(r=>
           r[3]>=r[2]*2&&b[3]>=b[2]*2&&r[0]>=b[0]+b[2]*.5&&
           x0>=r[0]-2&&x1<=r[0]+r[2]+2&&y0>r[1]+r[3]+2&&
           y1<=Math.min(b[1]+b[3],r[1]+r[3]+Math.min(72,b[2]))&&
           x1-x0<=r[2]*.8&&y1-y0<=r[2]*.9))
       readingCandidates.push({x0,y0,x1,y1,owned:keep,pixels:Array.from(queue.subarray(0,tail))});
     }
     const hasPeriodicTexture=options.readabilityGate&&aidokuSourceHasPeriodicInk(texturePoints,w,h,b);
     const periodicInk=hasPeriodicTexture&&texturePoints.filter(i=>accepted.some(a=>a[4]>4&&i%w>=a[0]-12&&i%w<=a[2]+12&&(i/w|0)>=a[1]-12&&(i/w|0)<=a[3]+12)).length>=32;
     // Independent tiny-dot repetition establishes texture ownership. Keep
     // these components out of glyph seeds, including one-pixel body fragments;
     // only the bounded neighborhood of substantial glyphs is reconstructed.
     if(periodicInk){
       for(let k=accepted.length-1;k>=0;k--)if(accepted[k][4]<=4)accepted.splice(k,1);
       for(const points of textureComponents)for(const i of points){mask[i]=0;protectedInk[i]=0;seedRadius[i]=0;}
       for(let i=0;i<n;i++)if(mask[i])seedRadius[i]=8;
     }
     if(accepted.length<(options.flatPalette?2:3))return retryPrevious();
     // Recover at most one compact continuation glyph below an observed ruby
     // column. A clear, flat outer ring is required; connected rays, frame
     // strokes, distant marks and a second line never establish ownership.
     for(const r of auxiliary){
       const candidates=readingCandidates.filter(c=>c.x0>=r[0]-2&&c.x1<=r[0]+r[2]+2&&
         c.y0>r[1]+r[3]+2&&c.y1<=Math.min(b[1]+b[3],r[1]+r[3]+Math.min(72,b[2])));
       if(!candidates.some(c=>!c.owned))continue;
       const x0=Math.min(...candidates.map(c=>c.x0)),x1=Math.max(...candidates.map(c=>c.x1)),
         y0=Math.min(...candidates.map(c=>c.y0)),y1=Math.max(...candidates.map(c=>c.y1));
       const pixels=candidates.flatMap(c=>c.pixels);
       if(pixels.length<6||pixels.length>(x1-x0+1)*(y1-y0+1)*.75||
           x1-x0>r[2]*.8||y1-y0>r[2]*1.1)continue;
       let samples=0,clear=0;
       for(let y=y0-2;y<=y1+2;y++)for(let x=x0-2;x<=x1+2;x++){
         if(x!==x0-2&&x!==x1+2&&y!==y0-2&&y!==y1+2)continue;
         const i=(y*w+x)*4;samples++;
         if(Math.max(...palette.background.map((v,c)=>Math.abs(p[i+c]-v)))<=32)clear++;
       }
       if(clear!==samples)continue;
       for(const i of pixels){mask[i]=1;protectedInk[i]=0;seedRadius[i]=6;}
       companions+=candidates.filter(c=>!c.owned).length;
     }
     // Rasterized small glyphs can have a disconnected one-pixel stroke.
     // Only attach it to already validated ink nearby; isolated paper specks
     // cannot seed cleanup or recruit one another across the panel.
     const bodyFragments=[];
     for(const i of (periodicInk?[]:isolatedBodyInk)){
       const x=i%w,y=i/w|0;let nearby=false;
       for(let yy=Math.max(0,y-6);yy<=Math.min(h-1,y+6)&&!nearby;yy++)
         for(let xx=Math.max(0,x-6);xx<=Math.min(w-1,x+6);xx++)if(mask[yy*w+xx]){nearby=true;break;}
       if(nearby)bodyFragments.push(i);
     }
     for(const i of bodyFragments){mask[i]=1;protectedInk[i]=0;seedRadius[i]=6;}
     // Require an already accepted glyph within two native pixels. Evaluate
     // every candidate before applying any, so fragments cannot recruit a chain.
     const ownedEdgeFragments=edgeFragments.filter(pixels=>{
       if(!pixels.some(i=>protectedInk[i]))return false;
       let owned=false,unsafe=false;
       const own=new Set(pixels);
       for(const i of pixels){
         const x=i%w,y=i/w|0;
         for(let yy=Math.max(0,y-3);yy<=Math.min(h-1,y+3);yy++)
           for(let xx=Math.max(0,x-3);xx<=Math.min(w-1,x+3);xx++){
             const j=yy*w+xx;
             if(protectedInk[j]&&!own.has(j))unsafe=true;
             if(mask[j]&&Math.max(Math.abs(xx-x),Math.abs(yy-y))<=2)owned=true;
           }
       }
       return owned&&!unsafe;
     });
     for(const pixels of ownedEdgeFragments){
       for(const i of pixels){mask[i]=1;protectedInk[i]=0;seedRadius[i]=2;}
       companions++;
     }
     // Antialiased drawing strokes can split into apparently isolated dark
     // components inside a merged OCR rectangle. From the first gated attempt,
     // reconnect them to known frame artwork through darker-than-paper pixels
     // before deciding which components belong to lettering.
     let drawingSurface=null;
     if(options.protectArtMargin||options.readabilityGate){
       const support=drawingSurface=new Uint8Array(n),threshold=Math.min(210,Math.min(...palette.background)-40);
       let end=0;
       for(let i=0;i<n;i++)if(frameInk[i]){support[i]=1;queue[end++]=i;}
       for(let head=0;head<end;head++){
         const i=queue[head],x=i%w,y=i/w|0;
         for(let yy=Math.max(0,y-1);yy<=Math.min(h-1,y+1);yy++)
           for(let xx=Math.max(0,x-1);xx<=Math.min(w-1,x+1);xx++){
             const j=yy*w+xx;
             if(support[j]||Math.max(p[j*4],p[j*4+1],p[j*4+2])>threshold)continue;
             support[j]=1;queue[end++]=j;
           }
       }
       for(let i=0;i<n;i++)if(support[i]){
         mask[i]=0;seedRadius[i]=0;
         if(raw[i]){protectedInk[i]=1;frameInk[i]=1;}
       }
     }
     // Validate tiny codec islands from their actual border, not merely a
     // dark-core bounding box. A contrasting observed halo and nearby owned
     // ink must surround them; connected artwork stays protected.
     if(measuredHalo&&Math.max(...foreground)-Math.min(...foreground)>=24){
       const visited=new Uint8Array(n),islands=[],fgMin=Math.min(...foreground),fgSpan=Math.max(...foreground)-fgMin;
       const halo=palette.stroke&&colorDistance(palette.stroke,palette.background)>=40;
       for(let start=0;start<n;start++){
         if(!protectedInk[start]||visited[start])continue;
         let head=0,end=1;queue[0]=start;visited[start]=1;
         while(head<end){
           const i=queue[head++],x=i%w,y=i/w|0;
           for(let yy=Math.max(0,y-1);yy<=Math.min(h-1,y+1);yy++)for(let xx=Math.max(0,x-1);xx<=Math.min(w-1,x+1);xx++){
             const j=yy*w+xx;if(!protectedInk[j]||visited[j])continue;
             visited[j]=1;queue[end++]=j;
           }
         }
         if(end>16)continue;
         let legacy=end<=4,owned=Boolean(halo),nearby=false,contacts=0,outline=0,compatible=0,inCore=true,neutral=false;
         for(let k=0;k<end;k++){
           const i=queue[k],x=i%w,y=i/w|0,rgb=[p[i*4],p[i*4+1],p[i*4+2]],lo=Math.min(...rgb),span=Math.max(...rgb)-lo;
           const shade=foreground.map((v,c)=>rgb[c]-v);
           if(raw[i])legacy=false;
           if(drawingSurface?.[i]||frameInk[i]){legacy=false;owned=false;break;}
           if(Math.max(...shade)-Math.min(...shade)>32||!accepted.some(a=>x>a[0]&&x<a[2]&&y>a[1]&&y<a[3]))legacy=false;
           const hueError=Math.max(...rgb.map((v,c)=>Math.abs((v-lo)/Math.max(1,span)-(foreground[c]-fgMin)/fgSpan)));
           const darkNeutral=span<12&&Math.max(...rgb)<Math.min(...palette.background)-24;
           neutral||=darkNeutral;
           if(!darkNeutral&&(span<12||hueError>.25)||x<b[0]||x>=b[0]+b[2]||y<b[1]||y>=b[1]+b[3])owned=false;
           if(!accepted.some(a=>x>=a[0]-1&&x<=a[2]+1&&y>=a[1]-1&&y<=a[3]+1))inCore=false;
           if(!owned)continue;
           for(let yy=y-1;yy<=y+1;yy++)for(let xx=x-1;xx<=x+1;xx++){
             const j=yy*w+xx;if(protectedInk[j])continue;
             contacts++;
             if(mask[j]){compatible++;nearby=true;}
             else {
               const color=[p[j*4],p[j*4+1],p[j*4+2]];
               if(colorDistance(color,palette.stroke)<=32){compatible++;outline++;}
               else if(onInkBlend(color,palette.stroke))compatible++;
             }
           }
         }
         if(owned&&!nearby){
           const x=queue[0]%w,y=queue[0]/w|0;
           for(let yy=Math.max(0,y-10);yy<=Math.min(h-1,y+10)&&!nearby;yy++)
             for(let xx=Math.max(0,x-10);xx<=Math.min(w-1,x+10);xx++)if(mask[yy*w+xx]){nearby=true;break;}
         }
         if(legacy||owned&&nearby&&contacts>=4&&(
             !neutral&&inCore&&compatible>=contacts*.6||
             compatible>=contacts*.875&&outline>=Math.max(2,contacts*(neutral?.5:.15))))
           for(let k=0;k<end;k++)islands.push(queue[k]);
       }
       for(const i of islands){mask[i]=1;protectedInk[i]=0;seedRadius[i]=radius;}
     }
     const coreCount=mask.reduce((sum,v)=>sum+v,0);
     // Keep the original substantial-stroke density gate stable when adding
     // raster fragments; a handful of one-pixel dots must not reject an
     // otherwise valid dense caption and bring its entire source text back.
     const substantialCoreCount=accepted.reduce((sum,c)=>sum+(c[5]>=2?c[5]:0),0);
     // Dense Kanji can exceed the generic artwork-density limit. Repeated
     // dark interiors with an independently detected light outline establish
     // text ownership; illustration/protected-ink checks below still apply.
     const outlinedDark=legacyDark&&palette.stroke&&Math.min(...palette.stroke)>=230&&
       (palette.confidence?.foreground||0)>=.6&&(palette.confidence?.stroke||0)>=.6&&
       palette.confidence?.reason==='repeated dark glyph interiors enclosed by white source outlines';
     if(substantialCoreCount>b[2]*b[3]*(options.flatPalette ? .48 : outlinedDark ? .42 : .3))return retryPrevious();
     // Reject unresolved dark ink inside the OCR box, including intersecting art.
     let unresolved=0;
     for(let y=Math.floor(b[1]);y<Math.ceil(b[1]+b[3]);y++)for(let x=Math.floor(b[0]);x<Math.ceil(b[0]+b[2]);x++)
       if(protectedInk[y*w+x]&&!frameInk[y*w+x])unresolved++;
     if(!options.slantedOwnership&&unresolved>Math.max(8,coreCount*.04))return retryPrevious();
     // Neighboring untranslated ink and its halo are not background donors.
     // Exclusion affects sampling only: their original pixels remain untouched.
     const donorBlocked=protectedInk.slice(),donorDistance=new Uint8Array(n);
     let donorTail=0;
     for(let i=0;i<n;i++)if(protectedInk[i])queue[donorTail++]=i;
     for(let head=0;head<donorTail;head++){
       const i=queue[head],x=i%w,y=i/w|0;if(donorDistance[i]>=8)continue;
       for(let yy=Math.max(0,y-1);yy<=Math.min(h-1,y+1);yy++)for(let xx=Math.max(0,x-1);xx<=Math.min(w-1,x+1);xx++){
         const j=yy*w+xx;if(donorBlocked[j])continue;
         donorBlocked[j]=1;donorDistance[j]=donorDistance[i]+1;queue[donorTail++]=j;
       }
     }
     if(drawingSurface)for(let i=0;i<n;i++)if(drawingSurface[i])donorBlocked[i]=1;
     // Tiny ruby outlines need less expansion than body lettering. Do not
     // blend a nearby white illustration edge into an otherwise gray reading.
     for(const r of auxiliary)for(let y=Math.max(0,Math.floor(r[1]-12));y<Math.min(h,Math.ceil(r[1]+r[3]+12));y++)
       for(let x=Math.max(0,Math.floor(r[0]-12));x<Math.min(w,Math.ceil(r[0]+r[2]+12));x++){
         const i=y*w+x;
         if(Math.max(...palette.background)<225&&Math.min(p[i*4],p[i*4+1],p[i*4+2])>240)donorBlocked[i]=1;
       }
     const distance=new Uint8Array(n);let tail=0;
     const preciseFringe=options.preciseFringe!==false;
     const followHalo=measuredHalo&&options.outlineFringe!==false&&palette.stroke&&
       colorDistance(palette.stroke,palette.background)>=40;
     for(let i=0;i<n;i++)if(mask[i])queue[tail++]=i;
     // Include halos even when the color estimator mistakes them for paper.
     // Native-resolution dilation is bounded; 24 px crop padding keeps its
     // boundary samples outside the source outline rather than inside it.
     for(let head=0;head<tail;head++){
     const i=queue[head],x=i%w,y=i/w|0,atLimit=distance[i]>=seedRadius[i];
     if(atLimit&&(!followHalo||distance[i]>=Math.min(20,seedRadius[i]+(preciseFringe?12:8))))continue;
     for(let yy=Math.max(1,y-1);yy<=Math.min(h-2,y+1);yy++)for(let xx=Math.max(1,x-1);xx<=Math.min(w-2,x+1);xx++){
     const j=yy*w+xx;
     // Keep the art margin, but include the immediate antialiased edge of
     // already owned lettering when it stays at least three pixels from art.
     const ownedFringe=distance[i]<2&&donorDistance[j]>=3;
     if(mask[j]||protectedInk[j]||drawingSurface?.[j]||(options.protectArtMargin&&donorBlocked[j]&&!ownedFringe))continue;
     if(atLimit){
       // Measured stroke width can miss its antialiased outer fringe. Follow
       // only the observed stroke-to-backing color ramp, with a hard distance
       // cap; widening every glyph would blur nearby illustration instead.
       if(donorBlocked[j])continue;
       const rgb=[p[j*4],p[j*4+1],p[j*4+2]];
       if(colorDistance(rgb,palette.background)<(preciseFringe?8:12)||!onInkBlend(rgb,palette.background,palette.stroke))continue;
       extendedHalo=true;
     }
     if(Math.hypot(xx-(i%w),yy-(i/w|0))>1.1&&distance[i]>radius-2)continue;
     mask[j]=1;distance[j]=distance[i]+1;seedRadius[j]=seedRadius[i];queue[tail++]=j;
     }}
     // A slanted outlined display glyph can enclose a wide white interior.
     // Dilation alone misses its center and then samples it as a white donor,
     // leaving the old letter's silhouette. Fill only enclosed, palette-matched
     // holes; any hole connected to the page or containing artwork is preserved.
     if(options.slantedOwnership&&palette.stroke&&(palette.confidence?.stroke||0)>=.6&&
         colorDistance(palette.stroke,palette.background)>=20){
       const exterior=new Uint8Array(n);let end=0;
       const visit=i=>{if(!mask[i]&&!exterior[i]){exterior[i]=1;queue[end++]=i;}};
       for(let x=0;x<w;x++){visit(x);visit((h-1)*w+x);}
       for(let y=0;y<h;y++){visit(y*w);visit(y*w+w-1);}
       for(let head=0;head<end;head++){
         const i=queue[head],x=i%w,y=i/w|0;
         if(x>0)visit(i-1);if(x<w-1)visit(i+1);if(y>0)visit(i-w);if(y<h-1)visit(i+w);
       }
       for(let start=0;start<n;start++){
         if(mask[start]||exterior[start])continue;
         let head=0,end=1,owned=true;queue[0]=start;exterior[start]=1;
         while(head<end){
           const i=queue[head++],x=i%w,y=i/w|0,rgb=[p[i*4],p[i*4+1],p[i*4+2]];
           if(x<b[0]||x>b[0]+b[2]||y<b[1]||y>b[1]+b[3]||protectedInk[i]||drawingSurface?.[i]||
               colorDistance(rgb,palette.stroke)>24&&colorDistance(rgb,palette.background)>24&&
               !onInkBlend(rgb,palette.stroke)&&!onInkBlend(rgb,palette.background,palette.stroke))owned=false;
           for(const j of [i-1,i+1,i-w,i+w])if(j>=0&&j<n&&!mask[j]&&!exterior[j]){
             exterior[j]=1;queue[end++]=j;
           }
         }
         if(owned&&end<=b[2]*b[3]*.15)for(let k=0;k<end;k++)mask[queue[k]]=1;
       }
       tail=0;for(let i=0;i<n;i++)if(mask[i])queue[tail++]=i;
     }
     // Connected drawing inside a textured OCR surface is not recoverable
     // from nearby paper. Do not let the drawing itself become missing donors.
     let frameInterior=0,innerArea=0;
     for(let y=Math.ceil(b[1]+3);y<Math.floor(b[1]+b[3]-3);y++)for(let x=Math.ceil(b[0]+3);x<Math.floor(b[0]+b[2]-3);x++){
       innerArea++;if(frameInk[y*w+x])frameInterior++;
     }
     // Texture outside a white balloon does not invalidate its isolated glyphs.
     // Reject periodic dots only when the final erasure would actually own them.

     if(hasPeriodicTexture&&!periodicInk&&texturePoints.reduce((sum,i)=>sum+mask[i],0)>Math.max(8,texturePoints.length*.05))return null;
     let surfaceQuality=options.readabilityGate?aidokuSourceSurfaceQuality(rgba,w,h,mask,donorBlocked):null;
     if((periodicInk||surfaceQuality?.safe&&surfaceQuality.rmse>3)&&frameInterior===0){
       const repeated=aidokuSourcePeriodicFill(rgba,w,h,mask,donorBlocked,periodicInk,texturePoints);
       if(repeated){
         const layoutSafe=new Uint8Array(n);
         for(let i=0;i<n;i++)if(!protectedInk[i]&&!drawingSurface?.[i])layoutSafe[i]=1;
         return {...repeated,layoutSafe,surfaceQuality:{...surfaceQuality,reason:'periodic',vectors:repeated.vectors,
           repetitionError:repeated.error},components:accepted.length,radius,companions,preservedPixels:0,preservedCore:0};
       }
     }
     if(periodicInk)return null;
     // A single average backing color can strand a halo on a gradient.
     // Recheck its bounded fringe against the independently fitted local
     // backing before admitting those pixels as diffusion donors.
     if(followHalo&&surfaceQuality?.safe&&surfaceQuality.reason==='smooth'&&frameInterior===0){
       const priorTail=tail;
       for(let head=0;head<tail;head++){
         const i=queue[head],x=i%w,y=i/w|0;
         if(distance[i]>=Math.min(20,seedRadius[i]+(preciseFringe?12:8)))continue;
         for(const [xx,yy] of [[x-1,y],[x+1,y],[x,y-1],[x,y+1]]){
           if(xx<1||yy<1||xx>=w-1||yy>=h-1)continue;
           const j=yy*w+xx;if(mask[j]||donorBlocked[j]||drawingSurface?.[j])continue;
           const backing=surfaceQuality.coefficients.map(a=>a[0]+a[1]*xx/w+a[2]*yy/h);
           const rgb=[p[j*4],p[j*4+1],p[j*4+2]];
           if(colorDistance(rgb,backing)<(preciseFringe?8:18)||!onInkBlend(rgb,backing,palette.stroke))continue;
           mask[j]=1;distance[j]=distance[i]+1;seedRadius[j]=seedRadius[i];queue[tail++]=j;
         }
       }
       if(tail>priorTail){extendedHalo=true;surfaceQuality=aidokuSourceSurfaceQuality(rgba,w,h,mask,donorBlocked);}
     }
     // A larger fringe must not turn a rejected irregular white balloon into
     // an apparently valid fill by consuming its interior surface. Keep the
     // previous mask on uncertain donors; its normal rejection still applies.
     if(preciseFringe&&extendedHalo&&surfaceQuality?.reason==='smooth'&&
         surfaceQuality.rmse>8&&surfaceQuality.outliers>.03)
       return aidokuRestoreObservedSourcePanel(rgba,w,h,b,palette,{...options,preciseFringe:false});
     // Sparse irregular donors cannot continue even a thin drawing line.
     // Dense connected print needs a stricter residual than an isolated contour.
     const sparseDrawing=surfaceQuality?.reason==='smooth'&&surfaceQuality.samples<96&&
       surfaceQuality.rmse>12&&surfaceQuality.outliers>.04&&frameInterior>Math.max(8,innerArea*.005);
     const denseDrawing=surfaceQuality?.rmse>4.5&&frameInterior>Math.max(8,innerArea*.05);
     const isolatedSlanted=options.slantedOwnership&&options.protectArtMargin&&surfaceQuality?.reason==='smooth'&&
       surfaceQuality.rmse<=8&&surfaceQuality.outliers<=.025;
     if(!isolatedSlanted&&(sparseDrawing||denseDrawing||surfaceQuality&&surfaceQuality.rmse>5&&frameInterior>Math.max(8,innerArea*.02)))return null;
     // A smooth ring can be the source outline itself, not exposed background.
     // Reject halo-only donors when their fitted center contradicts the observed
     // backing and instead matches a separately observed outline color.
     if(surfaceQuality?.safe&&palette.stroke&&colorDistance(palette.stroke,palette.background)>=20){
       const center=surfaceQuality.coefficients.map(a=>a[0]+a[1]*(b[0]+b[2]/2)/w+a[2]*(b[1]+b[3]/2)/h);
       if(colorDistance(center,palette.stroke)<=12&&colorDistance(center,palette.background)>=20)return null;
     }
     if(surfaceQuality&&(!surfaceQuality.safe||surfaceQuality.reason==='locally-smooth'&&!options.compactMask)){
       if(!options.compactMask)return aidokuRestoreObservedSourcePanel(rgba,w,h,b,palette,{...options,compactMask:true});
       return retryPrevious();
     }
     if(surfaceQuality?.safe&&surfaceQuality.reason==='smooth'&&surfaceQuality.rmse>3&&frameInterior===0){
       const textured=aidokuSourceExemplarFill(rgba,w,h,mask,palette,surfaceQuality,protectedInk,textureComponents);
       if(textured){
         const layoutSafe=new Uint8Array(n);for(let i=0;i<n;i++)if(!protectedInk[i]&&!drawingSurface?.[i])layoutSafe[i]=1;
         return {...textured,layoutSafe,surfaceQuality:{...surfaceQuality,reason:'exemplar-texture'},components:accepted.length,radius,companions,preservedPixels:0,preservedCore:0};
       }
     }
     // Give confirmed body lettering one extra crop pixel on clean, nearly
     // planar backgrounds. Freeze the old queue length: newly added pixels
     // never seed another ring. Ruby and protected art keep their old margin.
     if(surfaceQuality?.reason==='smooth'&&surfaceQuality.safe&&surfaceQuality.rmse<=3&&
         surfaceQuality.outliers===0&&surfaceQuality.samples>=64&&frameInterior===0){
       const priorTail=tail,previousQuality=surfaceQuality;
       // Existing ruby halos can reach 20 pixels; exclude that full halo plus the new ring.
       const rubyMargins=auxiliary.map(r=>[r[0]-21,r[1]-21,r[0]+r[2]+21,r[1]+r[3]+21]);
       for(let k=0;k<priorTail;k++){
         const i=queue[k];if(distance[i]<seedRadius[i])continue;
         const x=i%w,y=i/w|0;
         for(let yy=y-1;yy<=y+1;yy++)for(let xx=x-1;xx<=x+1;xx++){
           if(xx<1||xx>=w-1||yy<1||yy>=h-1)continue;
           const j=yy*w+xx;if(mask[j]||donorBlocked[j]||drawingSurface?.[j])continue;
           if(rubyMargins.some(r=>xx>=r[0]&&xx<=r[2]&&yy>=r[1]&&yy<=r[3]))continue;
           const backing=previousQuality.coefficients.map(a=>a[0]+a[1]*xx/w+a[2]*yy/h);
           const rgb=[p[j*4],p[j*4+1],p[j*4+2]],error=colorDistance(rgb,backing);
           if(error<4||!onInkBlend(rgb,backing)&&!(palette.stroke&&onInkBlend(rgb,backing,palette.stroke)))continue;
           mask[j]=1;distance[j]=distance[i]+1;seedRadius[j]=seedRadius[i];queue[tail++]=j;
         }
       }
       if(tail>priorTail){
         const expanded=aidokuSourceSurfaceQuality(rgba,w,h,mask,donorBlocked);
         if(expanded.safe&&expanded.reason==='smooth'&&expanded.rmse<=3&&expanded.outliers===0&&expanded.samples>=64)
           surfaceQuality=expanded;
         else {for(let k=priorTail;k<tail;k++)mask[queue[k]]=0;tail=priorTail;}
       }
     }
     // A plane is suitable only for nearly uniform paper/gradients. On a
     // translucent balloon, retain local donor colors through diffusion so
     // smaller masks do not leave flat, glyph-shaped patches in the artwork.
     // A measured contrasting outline can contaminate local diffusion donors.
     // Allow a small plane residual only with sparse outliers and no crossing art.
     if(surfaceQuality&&(surfaceQuality.rmse<=3||measuredHalo&&surfaceQuality.rmse<=8&&
         surfaceQuality.outliers<=.02&&frameInterior===0)&&(!options.compactMask||surfaceQuality.samples>=64)){
       const output=new Uint8ClampedArray(n*4),layoutSafe=new Uint8Array(n);
       for(let i=0;i<n;i++){
         if(!protectedInk[i]&&!drawingSurface?.[i])layoutSafe[i]=1;
         if(!mask[i])continue;
         const x=(i%w)/w,y=(i/w|0)/h;
         for(let c=0;c<3;c++){
           const a=surfaceQuality.coefficients[c];output[i*4+c]=a[0]+a[1]*x+a[2]*y;
         }
         output[i*4+3]=255;
       }
       return {rgba:output,layoutSafe,surfaceQuality,erased:tail,components:accepted.length,radius,companions,preservedPixels:0,preservedCore:0};
     }
     const paintMask=mask.slice(),queued=new Uint8Array(n);let frontier=[];
     const neighbors=i=>[i-1,i+1,i-w,i+w];
     for(let k=0;k<tail;k++)if(neighbors(queue[k]).some(j=>!mask[j]&&(!donorBlocked[j]||paintMask[j]))){frontier.push(queue[k]);queued[queue[k]]=1;}
     while(frontier.length){
     const rgb=new Float32Array(frontier.length*3);
     for(let k=0;k<frontier.length;k++){const i=frontier[k],valid=neighbors(i).filter(j=>!mask[j]&&(!donorBlocked[j]||paintMask[j]));for(let c=0;c<3;c++)rgb[k*3+c]=valid.reduce((sum,j)=>sum+p[j*4+c],0)/valid.length;}
     for(let k=0;k<frontier.length;k++){const i=frontier[k];for(let c=0;c<3;c++)p[i*4+c]=rgb[k*3+c];mask[i]=0;}
     const next=[];for(const i of frontier)for(const j of neighbors(i))if(mask[j]&&!queued[j]){queued[j]=1;next.push(j);}frontier=next;
     }
     // Retry a failed reconstruction with the illustration margin protected.
     // Successful existing masks retain their exact pixels and donor choices.
     if(!options.protectArtMargin&&mask.some(value=>value!==0))
       return aidokuRestoreObservedSourcePanel(rgba,w,h,b,palette,{...options,protectArtMargin:true});
     // Dilation can enter small pockets enclosed by protected illustration.
     // A pocket without a background donor is not evidence for a fill color.
     // Keep its original pixels instead of rejecting all recoverable lettering.
     // Large amounts of stranded ink still reject the entire proposal.
     let preservedPixels=0,preservedCore=0;
     for(let i=0;i<n;i++)if(mask[i]){preservedPixels++;if(raw[i])preservedCore++;}
     if(preservedCore>Math.min(64,coreCount*.02)||preservedPixels>tail*.15)return retryPrevious();
     let painted=0;
     for(let k=0;k<tail;k++){
       const i=queue[k];
       if(mask[i]){paintMask[i]=0;donorBlocked[i]=1;}
       else queue[painted++]=i;
     }
     tail=painted;
     if(!tail)return null;
     // Protected rules are neither erased nor used as background samples.
     const work=new Float32Array(n*3);for(let i=0;i<n;i++)for(let c=0;c<3;c++)work[i*3+c]=p[i*4+c];
     // Reuse the fixed donor topology and over-relax the harmonic solve.
     // Accelerate only a coherent surface without crossing art or donor
     // outliers. Faster diffusion of uncertain samples would spread drawing
     // colors into the cleared text; those cases retain the original solve.
     const accelerated=surfaceQuality?.reason==='smooth'&&surfaceQuality.outliers===0&&frameInterior===0;
     const links=new Uint8Array(tail),counts=new Uint8Array(16);
     for(let bits=1;bits<16;bits++)counts[bits]=(bits&1)+((bits>>1)&1)+((bits>>2)&1)+((bits>>3)&1);
     for(let k=0;k<tail;k++){
       const i=queue[k];
       links[k]=((!donorBlocked[i-1]||paintMask[i-1])?1:0)|((!donorBlocked[i+1]||paintMask[i+1])?2:0)|
         ((!donorBlocked[i-w]||paintMask[i-w])?4:0)|((!donorBlocked[i+w]||paintMask[i+w])?8:0);
     }
     for(let pass=0;pass<(accelerated?32:48);pass++){
       const check=accelerated&&(pass&3)===3;let maximumChange=0;
       for(let k=0;k<tail;k++){
         const i=queue[k],bits=links[k];if(!bits)continue;
         const left=(i-1)*3,right=(i+1)*3,up=(i-w)*3,down=(i+w)*3,count=counts[bits];
         for(let channel=0;channel<3;channel++){
           const at=i*3+channel,average=((bits&1?work[left+channel]:0)+(bits&2?work[right+channel]:0)+
             (bits&4?work[up+channel]:0)+(bits&8?work[down+channel]:0))/count;
           if(accelerated){
             const change=(average-work[at])*1.6;work[at]+=change;
             if(check)maximumChange=Math.max(maximumChange,Math.abs(change));
           }else work[at]=average;
         }
       }
       if(check&&maximumChange<.05)break;
     }
     for(let k=0;k<tail;k++){const i=queue[k];for(let c=0;c<3;c++)p[i*4+c]=work[i*3+c];}

          const output=new Uint8ClampedArray(n*4);
          for(let k=0;k<tail;k++){const i=queue[k];for(let c=0;c<3;c++)output[i*4+c]=p[i*4+c];output[i*4+3]=255;}
          // Reuse the reconstructed crop to keep translated glyphs off the
          // surviving balloon outline and illustration; no extra image decode.
          const layoutSafe=new Uint8Array(n);
          // Gradients and translucent clothing are valid background, not
          // balloon edges. Only surviving ink constrains the text footprint.
          for(let i=0;i<n;i++)if(!protectedInk[i]&&!drawingSurface?.[i])layoutSafe[i]=1;
          return {rgba:output,layoutSafe,surfaceQuality,erased:tail,components:accepted.length,radius,companions,preservedPixels,preservedCore};
        }
    function aidokuSoftenSourceGlyphs(rgba,w,h,b,palette,vertical) {
      const n=w*h;if(!Number.isInteger(w)||!Number.isInteger(h)||w<8||h<8||n>131072||!rgba||rgba.length!==n*4||
        !Array.isArray(b)||b.length!==4||!b.every(Number.isFinite)||b[0]<0||b[1]<0||b[2]<=0||b[3]<=0||b[0]+b[2]>w||b[1]+b[3]>h)return null;
      for(let i=3;i<rgba.length;i+=4)if(rgba[i]<254)return null;
      const raw=new Uint8Array(n),seen=new Uint8Array(n),mask=new Uint8Array(n),q=new Int32Array(n),sizes=[];
      const fg=palette?.foreground;
      const distance=(r,g,bl,c)=>c?Math.max(Math.abs(r-c[0]),Math.abs(g-c[1]),Math.abs(bl-c[2])):999;
      for(let i=0;i<n;i++){
        const r=rgba[i*4],g=rgba[i*4+1],bl=rgba[i*4+2],hi=Math.max(r,g,bl),lo=Math.min(r,g,bl);
        if(rgba[i*4+3]<254)continue;
        if(hi<110)raw[i]=1;
        else if(lo>215)raw[i]=2;
        else if(hi-lo>90&&lo<150){
          const hue=hi===r?((g-bl)/(hi-lo)+6)%6:hi===g?(bl-r)/(hi-lo)+2:(r-g)/(hi-lo)+4;
          raw[i]=3+Math.floor(hue);
        }else if(fg&&distance(r,g,bl,fg)<35)raw[i]=9;
      }
      const maxGlyph=Math.min(Math.max(b[2],b[3])*.6,Math.min(b[2],b[3])*2);
      for(let start=0;start<n;start++){
        if(!raw[start]||seen[start])continue;
        let head=0,tail=1,x0=w,y0=h,x1=0,y1=0;q[0]=start;seen[start]=1;
        while(head<tail){const i=q[head++],x=i%w,y=i/w|0;x0=Math.min(x0,x);x1=Math.max(x1,x);y0=Math.min(y0,y);y1=Math.max(y1,y);
          for(let yy=Math.max(0,y-1);yy<=Math.min(h-1,y+1);yy++)for(let xx=Math.max(0,x-1);xx<=Math.min(w-1,x+1);xx++){
            const j=yy*w+xx;if(raw[j]===raw[start]&&!seen[j]){seen[j]=1;q[tail++]=j;}
          }
        }
        const cx=(x0+x1)/2,cy=(y0+y1)/2,cw=x1-x0+1,ch=y1-y0+1;
        if(tail<2||x0<2||y0<2||x1>w-3||y1>h-3||x0<b[0]-2||x1>b[0]+b[2]+2||y0<b[1]-2||y1>b[1]+b[3]+2||cx<b[0]||cx>b[0]+b[2]||cy<b[1]||cy>b[1]+b[3]||
          Math.max(cw,ch)>maxGlyph||tail>n*.12||tail/(cw*ch)>.94)continue;
        for(let k=0;k<tail;k++)mask[q[k]]=1;sizes.push(Math.min(cw,ch));
      }
      if(!sizes.length)return null;
      sizes.sort((a,b)=>a-b);const glyph=Math.max(sizes[Math.floor(sizes.length*.75)],Math.min(b[2],b[3])*.6);
      const histogram=new Map();let samples=0;
      for(let y=Math.ceil(b[1]);y<Math.min(h,Math.floor(b[1]+b[3]));y++)for(let x=Math.ceil(b[0]);x<Math.min(w,Math.floor(b[0]+b[2]));x++){
        const i=(y*w+x)*4,key=(rgba[i]>>4)*256+(rgba[i+1]>>4)*16+(rgba[i+2]>>4);histogram.set(key,(histogram.get(key)||0)+1);samples++;
      }
      const peaks=[...histogram].sort((a,b)=>b[1]-a[1]);
      const flatCaption=!vertical&&peaks.length>1&&(peaks[0][1]+peaks[1][1])/samples>.72;
      const halo=flatCaption?Math.max(2,Math.min(5,Math.ceil(glyph*.12))):Math.max(3,Math.min(8,Math.ceil(glyph*.12)));
      const feather=flatCaption?2:6;
      const d=new Uint8Array(n);let tail=0;
      for(let i=0;i<n;i++)if(mask[i])q[tail++]=i;
      for(let head=0;head<tail;head++){
        const i=q[head],x=i%w,y=i/w|0;if(d[i]>=halo+feather)continue;
        for(let yy=Math.max(1,y-1);yy<=Math.min(h-2,y+1);yy++)for(let xx=Math.max(1,x-1);xx<=Math.min(w-2,x+1);xx++){
          const j=yy*w+xx;if(mask[j])continue;mask[j]=1;d[j]=d[i]+1;q[tail++]=j;
        }
      }
      // Fill from nearby unmasked pixels, then smooth only the owned glyph mask.
      // Outside that feathered mask the original illustration is untouched.
      const filled=new Uint8Array(n),rgb=new Float32Array(n*3);let end=0;
      for(let i=0;i<n;i++)if(!mask[i]){filled[i]=1;for(let c=0;c<3;c++)rgb[i*3+c]=rgba[i*4+c];}
      for(let i=0;i<n;i++)if(mask[i]){
        const x=i%w,y=i/w|0;
        if((x>0&&!mask[i-1])||(x<w-1&&!mask[i+1])||(y>0&&!mask[i-w])||(y<h-1&&!mask[i+w]))q[end++]=i;
      }
      const queued=new Uint8Array(n);for(let k=0;k<end;k++)queued[q[k]]=1;
      for(let head=0;head<end;head++){
        const i=q[head],x=i%w,y=i/w|0,neighbors=[];
        if(x>0)neighbors.push(i-1);if(x<w-1)neighbors.push(i+1);if(y>0)neighbors.push(i-w);if(y<h-1)neighbors.push(i+w);
        const donors=neighbors.filter(j=>filled[j]);if(!donors.length)continue;
        for(let c=0;c<3;c++)rgb[i*3+c]=donors.reduce((s,j)=>s+rgb[j*3+c],0)/donors.length;filled[i]=1;
        for(const j of neighbors)if(mask[j]&&!queued[j]){queued[j]=1;q[end++]=j;}
      }
      for(let pass=0;pass<64;pass++)for(let k=0;k<end;k++){
        const i=q[k],x=i%w,y=i/w|0;if(x<1||x>=w-1||y<1||y>=h-1)continue;
        for(let c=0;c<3;c++)rgb[i*3+c]=(rgb[(i-1)*3+c]+rgb[(i+1)*3+c]+rgb[(i-w)*3+c]+rgb[(i+w)*3+c])/4;
      }
      if(!flatCaption){
        // Smooth the locally reconstructed background, never the original ink.
        // The output is still restricted to a feathered glyph mask.
        const scratch=new Float32Array(n*3),radius=Math.max(2,Math.min(8,Math.round(glyph*.12))),diameter=radius*2+1;
        for(let pass=0;pass<3;pass++){
          for(let y=0;y<h;y++)for(let c=0;c<3;c++){
            let sum=0;for(let dx=-radius;dx<=radius;dx++)sum+=rgb[(y*w+Math.max(0,Math.min(w-1,dx)))*3+c];
            for(let x=0;x<w;x++){scratch[(y*w+x)*3+c]=sum/diameter;sum+=rgb[(y*w+Math.min(w-1,x+radius+1))*3+c]-rgb[(y*w+Math.max(0,x-radius))*3+c];}
          }
          for(let x=0;x<w;x++)for(let c=0;c<3;c++){
            let sum=0;for(let dy=-radius;dy<=radius;dy++)sum+=scratch[(Math.max(0,Math.min(h-1,dy))*w+x)*3+c];
            for(let y=0;y<h;y++){rgb[(y*w+x)*3+c]=sum/diameter;sum+=scratch[(Math.min(h-1,y+radius+1)*w+x)*3+c]-scratch[(Math.max(0,y-radius)*w+x)*3+c];}
          }
        }
      }
      const out=new Uint8ClampedArray(n*4);let painted=0;
      for(let i=0;i<n;i++)if(mask[i]&&filled[i]){
        let a=d[i]<=halo?1:Math.max(0,(halo+feather-d[i])/feather);
        const edge=Math.min(i%w,i/w|0,w-1-i%w,h-1-(i/w|0));a*=Math.min(1,edge/feather);
        a=a*a*(3-2*a);if(!a)continue;
        for(let c=0;c<3;c++)out[i*4+c]=rgb[i*3+c];out[i*4+3]=Math.round(255*a);painted++;
      }
      let inferredForeground=null,inferredBackground=null;
      if(flatCaption){
        const sum=[0,0,0];let count=0;for(let i=0;i<n;i++)if(mask[i]&&d[i]===0){for(let c=0;c<3;c++)sum[c]+=rgba[i*4+c];count++;}
        if(count)inferredForeground=sum.map(v=>Math.round(v/count));
        if(inferredForeground){
          const key=peaks.slice(0,2).sort((a,b)=>{
            const color=k=>[(k>>8)*16+8,((k>>4)&15)*16+8,(k&15)*16+8];
            const dist=k=>color(k).reduce((sum,v,c)=>sum+Math.abs(v-inferredForeground[c]),0);
            return dist(b[0])-dist(a[0]);
          })[0][0];
          const total=[0,0,0];let number=0;
          for(let i=0;i<n;i++)if((rgba[i*4]>>4)*256+(rgba[i*4+1]>>4)*16+(rgba[i*4+2]>>4)===key){for(let c=0;c<3;c++)total[c]+=rgba[i*4+c];number++;}
          if(number)inferredBackground=total.map(v=>Math.round(v/number));
        }
      }
      if(flatCaption&&inferredBackground){
        let x0=w,y0=h,x1=0,y1=0;
        for(let y=Math.ceil(b[1]);y<Math.min(h,b[1]+b[3]);y++)for(let x=Math.ceil(b[0]);x<Math.min(w,b[0]+b[2]);x++){
          const i=(y*w+x)*4;if(distance(rgba[i],rgba[i+1],rgba[i+2],inferredBackground)<24){x0=Math.min(x0,x);x1=Math.max(x1,x);y0=Math.min(y0,y);y1=Math.max(y1,y);}
        }
        for(let i=0;i<n;i++)if(out[i*4+3]){
          const x=i%w,y=i/w|0;if(x<x0||x>x1||y<y0||y>y1){out[i*4+3]=0;continue;}
          for(let c=0;c<3;c++)out[i*4+c]=inferredBackground[c];
        }
      }
      return {rgba:out,painted,components:sizes.length,inferredForeground,inferredBackground,flatCaption};
    }
    """
}
