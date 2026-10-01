@testable import Aidoku

// Test-only legacy browser reference.
// Bounded, model-free reconstruction of observed lettering on spatial backgrounds.
// Original pixels outside the glyph/outline mask are never painted over.
enum BrowserSourcePanelRestoration {
    // Large functions keep each outermost loop in `(()=>{...})();` (see BrowserOverlayView.renderScript).
    static let script = """
        // Allocation-free forms of the per-pixel color tests. Each evaluates the
        // same floating-point expressions, in the same order, as the array forms
        // (max |rgb-color| and the clamped projection onto an ink-to-paper ramp).
        function aidokuRestorationDistance(r,g,bl,color) {
          return Math.max(Math.abs(r-color[0]),Math.abs(g-color[1]),Math.abs(bl-color[2]));
        }
        function aidokuRestorationBlendAt(r,g,bl,e0,e1,e2,start) {
          const s0=start[0],s1=start[1],s2=start[2],d0=e0-s0,d1=e1-s1,d2=e2-s2,length=0+d0*d0+d1*d1+d2*d2;
          if(!length)return false;
          const t=Math.max(0,Math.min(1,(0+(r-s0)*d0+(g-s1)*d1+(bl-s2)*d2)/length));
          return Math.max(Math.abs(r-(s0+t*d0)),Math.abs(g-(s1+t*d1)),Math.abs(bl-(s2+t*d2)))<=24;
        }
        // A fixed ramp precomputes its direction once for a whole mask pass.
        function aidokuRestorationBlend(end,start) {
          if(!end||!start)return ()=>false;
          const s0=start[0],s1=start[1],s2=start[2],d0=end[0]-s0,d1=end[1]-s1,d2=end[2]-s2,length=0+d0*d0+d1*d1+d2*d2;
          if(!length)return ()=>false;
          return (r,g,bl)=>{
            const t=Math.max(0,Math.min(1,(0+(r-s0)*d0+(g-s1)*d1+(bl-s2)*d2)/length));
            return Math.max(Math.abs(r-(s0+t*d0)),Math.abs(g-(s1+t*d1)),Math.abs(bl-(s2+t*d2)))<=24;
          };
        }
        // Fit an RGB plane to unmasked donor pixels. Smooth gradients are safe;
        // texture and illustration edges are not recoverable by diffusion. Sampling
        // is bounded by the crop budget and never reads the page a second time.
        function aidokuSourceSurfaceQuality(rgba,w,h,mask,blocked,dense=false) {
          const matrix=[[0,0,0],[0,0,0],[0,0,0]],rhs=[[0,0,0],[0,0,0],[0,0,0]];
          let count=0;
          const stride=dense?1:Math.max(1,Math.ceil(Math.sqrt(w*h/4096)));
          // Summed-area table of the mask answers each 9x9 donor-window query
          // in constant time; the window bounds match the former direct scan.
          const summed=new Int32Array((w+1)*(h+1));
          (()=>{for(let y=0;y<h;y++){let row=0;for(let x=0;x<w;x++){row+=mask[y*w+x]?1:0;summed[(y+1)*(w+1)+x+1]=summed[y*(w+1)+x+1]+row;}}})();
          const isDonor=(x,y)=>{
            const i=y*w+x;if(mask[i]||blocked[i])return false;
            const x0=Math.max(0,x-4),x1=Math.min(w-1,x+4)+1,y0=Math.max(0,y-4),y1=Math.min(h-1,y+4)+1;
            return summed[y1*(w+1)+x1]-summed[y0*(w+1)+x1]-summed[y1*(w+1)+x0]+summed[y0*(w+1)+x0]>0;
          };
          (()=>{for(let y=1;y<h-1;y+=stride)for(let x=1;x<w-1;x+=stride){
            const i=y*w+x;if(!isDonor(x,y))continue;
            const a=[1,x/w,y/h];count++;
            for(let j=0;j<3;j++){
              for(let k=0;k<3;k++)matrix[j][k]+=a[j]*a[k];
              for(let c=0;c<3;c++)rhs[c][j]+=a[j]*rgba[i*4+c];
            }
          }})();
          if(count<24){
            // A sparse sampling lattice can miss narrow paper gaps between
            // small glyphs. Retry every pixel only after all normal restoration
            // paths fail; donor distance, art exclusions and quality stay fixed.
            if(!dense&&stride>1&&aidokuRestoreSourcePanel.classificationCache)
              aidokuRestoreSourcePanel.classificationCache.denseDonorCandidate=true;
            return {safe:false,reason:'insufficient-donors',samples:count};
          }
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
          (()=>{for(let y=1;y<h-1;y+=stride)for(let x=1;x<w-1;x+=stride){
            const i=y*w+x;if(!isDonor(x,y))continue;
            let error=0;
            for(let c=0;c<3;c++)error=Math.max(error,Math.abs(rgba[i*4+c]-(coefficients[c][0]+coefficients[c][1]*x/w+coefficients[c][2]*y/h)));
            squared+=error*error;if(error>22)outliers++;
          }})();
          const rmse=Math.sqrt(squared/count),fraction=outliers/count;
          // Dense sampling is a recovery path for clear paper gaps, not a
          // second chance for texture. Require a nearly exact surface and no
          // outlier donor before allowing a previously rejected restoration.
          if(dense&&(rmse>3||fraction>0))return {safe:false,reason:'textured',samples:count,rmse,outliers:fraction,coefficients};
          if(rmse<=14&&fraction<=.08)return {safe:true,reason:'smooth',samples:count,rmse,outliers:fraction,coefficients};
          // Colored lighting and curved gradients need not fit a single plane.
          // Validate local donor continuity before using the existing diffusion;
          // high-frequency texture and hard illustration edges still fail.
          let localCount=0,localSquared=0,localOutliers=0,edges=0;
          (()=>{for(let y=2;y<h-2;y+=stride)for(let x=2;x<w-2;x+=stride){
            const i=y*w+x;if(!isDonor(x,y))continue;
            if(mask[i-1]||blocked[i-1]||mask[i+1]||blocked[i+1]||mask[i-w]||blocked[i-w]||mask[i+w]||blocked[i+w])continue;
            let residual=0,edge=0;
            for(let c=0;c<3;c++){
              const center=rgba[i*4+c],left=rgba[(i-1)*4+c],right=rgba[(i+1)*4+c],up=rgba[(i-w)*4+c],down=rgba[(i+w)*4+c];
              const average=(0+left+right+up+down)/4;
              residual=Math.max(residual,Math.abs(center-average));
              edge=Math.max(edge,Math.abs(center-left),Math.abs(center-right),Math.abs(center-up),Math.abs(center-down));
            }
            localCount++;localSquared+=residual*residual;
            if(residual>12)localOutliers++;if(edge>28)edges++;
          }})();
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
            const i=(y*w+x)*4,r=rgba[i],g=rgba[i+1],bl=rgba[i+2],key=(r>>4)<<8|(g>>4)<<4|(bl>>4);
            let bin=bins.get(key);if(!bin){bin={count:0,sum:[0,0,0]};bins.set(key,bin);}
            bin.count++;count++;bin.sum[0]+=r;bin.sum[1]+=g;bin.sum[2]+=bl;
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
              if(aidokuRestorationDistance(rgba[i],rgba[i+1],rgba[i+2],background)<=20)support++;
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
          const matches=i=>rgba[i*4+3]>=250&&aidokuRestorationDistance(rgba[i*4],rgba[i*4+1],rgba[i*4+2],ink)<=28;
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
        // Row-end punctuation (。，～…!♡) often lies just past the detector box,
        // which stops at the last full glyph. The probe strip covers one side of
        // the box along the reading axis (box in strip pixels; the strip starts
        // inside the box). Return compact marks in the caption's ink inside the
        // rows' cross band: the first at most .75 glyph past the box end (.35
        // before its start unless it pairs with a closing mark), then up to two
        // more, each within .7 glyph of the previous, each on a clear ring of
        // background, with no frame, art or other ink between it and the row. A near mark that fails any test
        // makes the run ambiguous and nothing is returned.
        function aidokuRowEndMarks(rgba,w,h,box,glyph,palette,vertical,side,excluded=[],pair=null,allowDotRun=false) {
          const fg=palette?.foreground,bg=palette?.background;
          if(!fg||!bg||!(glyph>=6)||w<4||h<4||!rgba||rgba.length!==w*h*4||!Array.isArray(box)||box.length!==4)return [];
          const separation=Math.max(...fg.map((v,c)=>Math.abs(v-bg[c])));
          if(separation<60)return [];
          const n=w*h,ink=new Uint8Array(n),label=new Int32Array(n),queue=new Int32Array(n),comps=[];
          const inkLevel=Math.max(40,separation*.45),coreLevel=Math.max(24,separation*.3);
          const toBg=i=>Math.max(Math.abs(rgba[i*4]-bg[0]),Math.abs(rgba[i*4+1]-bg[1]),Math.abs(rgba[i*4+2]-bg[2]));
          const toFg=i=>Math.max(Math.abs(rgba[i*4]-fg[0]),Math.abs(rgba[i*4+1]-fg[1]),Math.abs(rgba[i*4+2]-fg[2]));
          const along0=vertical?box[1]:box[0],along1=along0+(vertical?box[3]:box[2]);
          const cross0=vertical?box[0]:box[1],cross1=cross0+(vertical?box[2]:box[3]);
          const a=c=>vertical?[c.y0,c.y1,c.x0,c.x1]:[c.x0,c.x1,c.y0,c.y1];
          const beyond=c=>{const centre=(a(c)[0]+a(c)[1])/2;return side==='end'?a(c)[1]>along1+3&&a(c)[0]>=along1-glyph:centre<along0-3;};
          (()=>{for(let i=0;i<n;i++){const d=toBg(i);if(d>=inkLevel&&toFg(i)<d)ink[i]=1;}})();
          (()=>{for(let s=0;s<n;s++){
            if(!ink[s]||label[s])continue;
            let head=0,tail=0,x0=w,y0=h,x1=-1,y1=-1,core=0;queue[tail++]=s;label[s]=comps.length+1;
            while(head<tail){
              const i=queue[head++],x=i%w,y=(i/w)|0;
              if(x<x0)x0=x;if(x>x1)x1=x;if(y<y0)y0=y;if(y>y1)y1=y;if(toFg(i)<=coreLevel)core++;
              for(let dy=-1;dy<=1;dy++)for(let dx=-1;dx<=1;dx++){
                const xx=x+dx,yy=y+dy;if(xx<0||yy<0||xx>=w||yy>=h)continue;
                const j=yy*w+xx;if(ink[j]&&!label[j]){label[j]=comps.length+1;queue[tail++]=j;}
              }
            }
            // The border inside the box is crossed by the body's own glyphs;
            // any other border crossing is a frame, outline or artwork.
            const inner=vertical?(side==='end'?y0<=0:y1>=h-1):(side==='end'?x0<=0:x1>=w-1);
            const outer=(vertical?x0<=0||x1>=w-1:y0<=0||y1>=h-1)||(vertical?(side==='end'?y1>=h-1:y0<=0):(side==='end'?x1>=w-1:x0<=0));
            comps.push({x0,y0,x1,y1,pixels:tail,core,inner,outer});
          }})();
          // Longer than a glyph: a balloon outline entering through the box side.
          // Specks below a mark's size are compression noise, never a mark or a block.
          const speck=Math.max(3,glyph*glyph*.004);
          (()=>{for(const c of comps){c.beyond=beyond(c);c.long=Math.max(c.x1-c.x0,c.y1-c.y0)+1>glyph*1.1;c.noise=c.pixels<speck;}})();
          // Clutter (texture, hatching) within reach of the row: no marks there.
          const near=c=>{const [a0,a1]=a(c);return side==='end'?a0<=along1+glyph*1.3:a1>=along0-glyph*1.3;};
          if(comps.filter(c=>c.beyond&&!c.noise&&near(c)).length>24)return [];
          // One glyph can hold several components (the bar and dot of !, ?); marks
          // of neighbouring columns (further apart across) stay separate.
          // Frames, outlines and art (border-touching or long) are no glyphs:
          // the corridor test below keeps them from ending up between.
          const glyphs=[];
          (()=>{for(let k=0;k<comps.length;k++){
            const c=comps[k];
            c.tailRule=side==='end'&&vertical&&c.long&&palette.stroke&&Math.min(...palette.stroke)>=230&&
              Math.max(...fg)-Math.min(...fg)>=60&&c.x1-c.x0+1<=glyph*.25&&c.y1-c.y0+1<=glyph*4&&
              c.y0>=along1-glyph&&c.pixels>=(c.x1-c.x0+1)*(c.y1-c.y0+1)*.55;
            if(!c.beyond||c.inner||c.outer||c.long&&!c.tailRule||c.noise)continue;
            const [a0,a1,c0,c1]=a(c);
            const into=glyphs.find(g=>a0<=g.a1+1&&a1>=g.a0-1&&c0<=g.c1+glyph*.2&&c1>=g.c0-glyph*.2);
            if(into){
              Object.assign(into,{a0:Math.min(into.a0,a0),a1:Math.max(into.a1,a1),c0:Math.min(into.c0,c0),c1:Math.max(into.c1,c1),
                pixels:into.pixels+c.pixels,core:into.core+c.core});
              into.members.push(k+1);
            } else glyphs.push({a0,a1,c0,c1,pixels:c.pixels,core:c.core,members:[k+1]});
          }})();
          const rect=g=>vertical?[g.c0,g.a0,g.c1-g.c0+1,g.a1-g.a0+1]:[g.a0,g.c0,g.a1-g.a0+1,g.c1-g.c0+1];
          const clearRing=g=>{
            const [x0,y0,rw,rh]=rect(g),x1=x0+rw-1,y1=y0+rh-1,r=Math.max(2,Math.round(glyph*.15));
            let samples=0,clear=0;
            for(let y=y0-r;y<=y1+r;y++)for(let x=x0-r;x<=x1+r;x++){
              if(x>=x0-1&&x<=x1+1&&y>=y0-1&&y<=y1+1||x<0||y<0||x>=w||y>=h)continue;
              samples++;if(toBg(y*w+x)<=40)clear++;
            }
            if(samples>=8&&clear>=samples*.95)return true;
            if(Math.max(...fg)-Math.min(...fg)<60)return false;
            // A white-outlined coloured mark can stand on translucent paper
            // whose local tone differs from the body's sampled background.
            // Verify the outline on both sides instead of flattening that paper.
            const white=(x,y)=>x>=0&&y>=0&&x<w&&y<h&&
              Math.min(rgba[(y*w+x)*4],rgba[(y*w+x)*4+1],rgba[(y*w+x)*4+2])>=230;
            let rows=0,outlined=0;
            const reach=Math.max(2,Math.min(6,Math.round(glyph*.08)));
            for(let y=y0;y<=y1;y++){
              let left=false,right=false;
              for(let d=1;d<=reach;d++){left ||= white(x0-d,y);right ||= white(x1+d,y);}
              rows++;if(left&&right)outlined++;
            }
            return rows>=4&&outlined>=rows*.9;
          };
          const qualifies=g=>{
            // Narrow along the row, or a flat wave/dash (～ ー) at most a glyph long.
            const along=g.a1-g.a0+1,cross=g.c1-g.c0+1;
            const tailRule=g.members.length===1&&comps[g.members[0]-1].tailRule;
            if(along>glyph*(tailRule?4:cross<=glyph*.35?1:.6)||cross>glyph*.95||g.pixels<speck||g.core*4<g.pixels)return false;
            if(g.c0<cross0-glyph*.12||g.c1>cross1+glyph*.12)return false;
            const [x,y,rw,rh]=rect(g);
            if(excluded.some(q=>x+rw>=q[0]-2&&x<=q[0]+q[2]+2&&y+rh>=q[1]-2&&y<=q[1]+q[3]+2))return false;
            return clearRing(g);
          };
          // Between the row (or the previous mark) and the mark, within .35 glyph
          // across it, only the body's own glyphs may have ink: a balloon
          // outline or tail (a frame-touching or longer-than-glyph component)
          // or other lettering there ends the caption's row.
          const corridorClear=(g,edge)=>{
            const from=side==='end'?Math.max(0,Math.ceil(edge)+1):g.a1+1,to=side==='end'?g.a0-1:Math.min(vertical?h:w,Math.floor(edge))-1;
            const c0=Math.max(0,Math.floor(Math.max(g.c0-glyph*.35,cross0-glyph*.12)));
            const c1=Math.min((vertical?w:h)-1,Math.ceil(Math.min(g.c1+glyph*.35,cross1+glyph*.12)));
            // Faint lines (a thin grey balloon outline) are below the ink level:
            // non-paper pixels with no ink beside them also block, except the
            // mark's own antialiased fringe.
            let faint=0;
            for(let s=from;s<=to;s++)for(let c=c0;c<=c1;c++){
              const i=vertical?s*w+c:c*w+s,k=label[i];
              if(k&&!g.members.includes(k)&&(comps[k-1].outer||comps[k-1].beyond&&!comps[k-1].noise||comps[k-1].long))return false;
              if(k||toBg(i)<=40||(side==='end'?s>=g.a0-2:s<=g.a1+2))continue;
              const x=i%w,y=(i/w)|0;let near=false;
              for(let dy=-1;dy<=1&&!near;dy++)for(let dx=-1;dx<=1;dx++){
                const xx=x+dx,yy=y+dy;if(xx>=0&&yy>=0&&xx<w&&yy<h&&label[yy*w+xx]){near=true;break;}
              }
              if(!near&&++faint>=3)return false;
            }
            return true;
          };
          const outward=glyphs.filter(g=>g.c1>=cross0-glyph*.12&&g.c0<=cross1+glyph*.12)
            .sort((p,q)=>side==='end'?p.a0-q.a0:q.a1-p.a1);
          // Opening marks (「“（) sit close to the first glyph; closing marks may
          // trail further. An opening mark matching the closing one found past
          // the end (■…■, ～…～; pair = its [along, cross] size) may too.
          const paired=g=>Array.isArray(pair)&&[g.a1-g.a0+1,g.c1-g.c0+1].every((v,k)=>v>=pair[k]*.75&&v<=pair[k]*1.33);
          // A repeat of the previous mark (widely spaced ellipsis dots) may follow further.
          const repeats=(g,q)=>q&&[[g.a1-g.a0,q.a1-q.a0],[g.c1-g.c0,q.c1-q.c0],[g.pixels,q.pixels]]
            .every(([u,v])=>u+1>=(v+1)*.75&&u+1<=(v+1)*1.33);
          const dotRun=allowDotRun&&side==='start'&&outward.length>=4&&outward.length<=24&&
            outward.every(g=>g.a1-g.a0+1<=glyph*.35&&g.c1-g.c0+1<=glyph*.35&&
              Math.abs((g.c0+g.c1-outward[0].c0-outward[0].c1)/2)<=glyph*.12&&
              repeats(g,outward[0]));
          const marks=[];let edge=side==='end'?along1:along0,last=null;
          for(const g of outward){
            const gap=side==='end'?g.a0-edge:edge-g.a1;
            if(gap>glyph*(marks.length?repeats(g,last)?1.2:.7:side==='end'||paired(g)?.75:.35)){
              // An unreached repeat of the run would be left behind: all or nothing.
              if(repeats(g,last)&&gap<=glyph*1.6)return [];
              break;
            }
            // A near mark that fails is ambiguous. A tall single stroke (a
            // bracket) must hug the row; a detached one is a letter or art.
            if(marks.length>=(dotRun?24:3)||!qualifies(g)||!corridorClear(g,edge)||
                g.members.length===1&&g.c1-g.c0+1>glyph*.6&&gap>glyph*.12)return [];
            marks.push(rect(g));last=g;edge=side==='end'?Math.max(edge,g.a1):Math.min(edge,g.a0);
          }
          // More small marks than a punctuation run: a dotted or dashed pattern.
          if(!dotRun&&outward.filter(g=>g.a1-g.a0+1<=glyph*.6&&g.c1-g.c0+1<=glyph*.6).length>4)return [];
          // A repeating run that reaches the strip's far end may continue out of
          // view: the caller probes a longer strip or keeps the whole run.
          if(marks.length>=2&&(side==='end'?(vertical?h:w)-1-edge:edge)<glyph*1.3)marks.open=true;
          return marks;
        }
    // A detached vertical ellipsis column beside a short reading. Require a
    // complete, regular run of compact circles in the independently sampled ink;
    // outlines, open runs, other captions and irregular texture are rejected.
    function aidokuAdjacentDotRun(rgba,w,h,box,glyph,palette,excluded=[]) {
      const fg=palette?.foreground;
      if(!fg||!(glyph>=8)||w*h>262144)return [];
      const mask=new Uint8Array(w*h),seen=new Uint8Array(w*h),components=[];
      for(let i=0;i<mask.length;i++)if(rgba[i*4+3]>=254&&
          Math.max(Math.abs(rgba[i*4]-fg[0]),Math.abs(rgba[i*4+1]-fg[1]),Math.abs(rgba[i*4+2]-fg[2]))<=40)mask[i]=1;
      for(let start=0;start<mask.length;start++){
        if(!mask[start]||seen[start])continue;
        const queue=[start];seen[start]=1;let l=w,r=0,t=h,b=0;
        for(let head=0;head<queue.length;head++){
          const i=queue[head],x=i%w,y=i/w|0;l=Math.min(l,x);r=Math.max(r,x);t=Math.min(t,y);b=Math.max(b,y);
          for(let yy=Math.max(0,y-1);yy<=Math.min(h-1,y+1);yy++)for(let xx=Math.max(0,x-1);xx<=Math.min(w-1,x+1);xx++){
            const j=yy*w+xx;if(mask[j]&&!seen[j]){seen[j]=1;queue.push(j);}
          }
        }
        const ww=r-l+1,hh=b-t+1;
        if(l<3||t<3||r>=w-3||b>=h-3||ww<glyph*.06||hh<glyph*.06||ww>glyph*.3||hh>glyph*.3||
            Math.max(ww,hh)>Math.min(ww,hh)*1.6||queue.length<ww*hh*.5)continue;
        if(excluded.some(q=>l<q[0]+q[2]+2&&r>q[0]-2&&t<q[1]+q[3]+2&&b>q[1]-2))continue;
        components.push({l,r,t,b,cx:(l+r)/2,cy:(t+b)/2,size:Math.sqrt(ww*hh)});
      }
      if(components.length>40)return [];
      const runs=[];
      for(const seed of components){
        if(seed.cx>=box[0]-glyph*.1&&seed.cx<=box[0]+box[2]+glyph*.1)continue;
        if(seed.cx<box[0]-glyph||seed.cx>box[0]+box[2]+glyph)continue;
        const run=components.filter(c=>Math.abs(c.cx-seed.cx)<=glyph*.12&&
          c.size>=seed.size*.7&&c.size<=seed.size*1.4).sort((a,b)=>a.cy-b.cy);
        if(run.length<5||run.length>24||run[run.length-1].b-run[0].t<glyph*1.2||
            run[0].t>box[1]+box[3]||run[run.length-1].b<box[1])continue;
        const gaps=run.slice(1).map((c,i)=>c.cy-run[i].cy),median=gaps.slice().sort((a,b)=>a-b)[gaps.length>>1];
        if(median<seed.size*1.2||median>seed.size*3||gaps.some(g=>g<median*.65||g>median*1.4)||
            run[0].t<median*1.5||h-1-run[run.length-1].b<median*1.5)continue;
        if(runs.some(c=>Math.abs(c.cx-seed.cx)<glyph*.25))continue;
        runs.push({cx:seed.cx,run});
      }
      return runs.flatMap(({run})=>run.map(c=>[c.l-2,c.t-2,c.r-c.l+5,c.b-c.t+5]));
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
          (()=>{for(const seed of candidates){
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
              if(aidokuRestorationDistance(rgba[i],rgba[i+1],rgba[i+2],background)>32){clear=false;break;}
            }
            // A balloon rule between the main text and the small column means
            // the two texts do not share a surface.
            for(let y=t;y<=d&&clear;y++)for(let x=Math.ceil(b[0]+b[2]+3);x<l-3;x++){
              const i=(y*w+x)*4;
              if(aidokuRestorationDistance(rgba[i],rgba[i+1],rgba[i+2],background)>32){clear=false;break;}
            }
            if(!clear)continue;
            const rect=[l-1,t-1,r-l+3,d-t+3];
            if(!result.some(q=>q.every((v,i)=>v===rect[i])))result.push(rect);
          }})();
          return result.slice(0,4);
        }
        // One restoration may run the observed pass several times (palette
        // fallbacks, compact/art-margin/fringe retries). Pixel classes are
        // shared only for the duration of the outermost call.
    // Isolated saturated lettering with a measured white outline may sit
    // over translucent artwork. Reconstruct only its connected glyphs and white halo;
    // the containing rectangle and every frame-connected component remain untouched.
    function aidokuRestoreChromaticBalloonGlyphs(rgba,w,h,b,palette,options={}) {
      const ordinary=aidokuRestoreChromaticBalloonGlyphPass(rgba,w,h,b,palette,options);
      if(ordinary)return ordinary;
      const ink=palette?.sourceInk||palette,fg=ink?.foreground,stroke=ink?.stroke;
      // Hue alone also selects translucent balloon borders and artwork. A
      // second, bounded pass isolates the independently measured solid fill;
      // component/white-halo/ownership and residual checks still apply.
      if(!fg||!stroke||Math.max(...fg)-Math.min(...fg)<90||Math.min(...stroke)<230||
          (ink.confidence?.foreground||0)<.75||(ink.confidence?.stroke||0)<.7)return null;
      return aidokuRestoreChromaticBalloonGlyphPass(rgba,w,h,b,palette,{...options,observedCoreDistance:48});
    }
    function aidokuRestoreChromaticBalloonGlyphPass(rgba,w,h,b,palette,options={}) {
      // Independent stroke sampling may resolve a white interior after the
      // erasure palette was frozen with its coloured outline as the fill.
      const resolvedOutline=palette?.foreground&&Math.min(...palette.foreground)>=220&&palette?.stroke&&
        (palette.confidence?.foreground||0)>=.7&&(palette.confidence?.stroke||0)>=.7&&
        !palette.sourceInk?.stroke&&palette.sourceInk?.foreground&&
        aidokuRestorationDistance(...palette.sourceInk.foreground,palette.stroke)<=32;
      const n=w*h,fill=resolvedOutline?palette.foreground:palette?.sourceInk?.foreground||palette?.foreground;
      const stroke=resolvedOutline?palette.stroke:palette?.sourceInk?.stroke||palette?.stroke;
      // Outlined captions often have a white fill. Ownership is established by
      // their colored/dark enclosing ink, not by the white artwork around it.
      const outlinedFill=fill&&Math.min(...fill)>=220&&stroke&&
        (Math.max(...stroke)-Math.min(...stroke)>=60||Math.max(...stroke)<=60);
      // A measured dark fill surrounded by a white ring is not white-filled
      // lettering. Keep its observed polarity: requiring closed white counters
      // rejects thin open strokes, while a generic <=90 mask absorbs shadows.
      const evidence=palette?.sourceInk||palette;
      const darkFill=fill&&Math.max(...fill)<=80&&stroke&&Math.min(...stroke)>=230&&
        (evidence.confidence?.stroke||0)>=.6&&evidence.widthEvidence?.method?.startsWith('outer stroke boundary');
      const fg=outlinedFill?stroke:fill,neutral=outlinedFill&&Math.max(...fg)<=60||darkFill;
      const darkCoreLimit=darkFill?Math.min(90,Math.max(...fg)+32):90;
      if(!fg||!options.readabilityGate||n>262144||n<64||rgba.length!==n*4||!aidokuRestorationOpaque(rgba)||
          !neutral&&Math.max(...fg)-Math.min(...fg)<(outlinedFill?60:90)||b[0]<2||b[1]<2||b[0]+b[2]>w-2||b[1]+b[3]>h-2)return null;
      const low=Math.min(...fg),span=Math.max(...fg)-low,color=fg.map(v=>(v-low)*255/span);
      const raw=new Uint8Array(n),seen=new Uint8Array(n),mask=new Uint8Array(n),blocked=new Uint8Array(n);
      const inside=(x,y)=>x>=b[0]-1&&x<=b[0]+b[2]+1&&y>=b[1]-1&&y<=b[1]+b[3]+1||
        (options.auxiliary||[]).some(r=>x>=r[0]&&x<=r[0]+r[2]&&y>=r[1]&&y<=r[1]+r[3]);
      for(let i=0;i<n;i++){
        const k=i*4,r=rgba[k],g=rgba[k+1],bb=rgba[k+2],lo=Math.min(r,g,bb),d=Math.max(r,g,bb)-lo;
        if(neutral?Math.max(r,g,bb)<=darkCoreLimit&&d<=35:
            Math.max(Math.abs(r-fg[0]),Math.abs(g-fg[1]),Math.abs(bb-fg[2]))<=(options.observedCoreDistance??Infinity)&&d>=65&&Math.max(Math.abs((r-lo)*255/d-color[0]),Math.abs((g-lo)*255/d-color[1]),Math.abs((bb-lo)*255/d-color[2]))<=28)raw[i]=1;
      }
      // A white-filled glyph is a closed bright island inside its enclosing
      // stroke. Flooding the complementary mask excludes open paper/clothing.
      // Keep left/right/up/down visitation order: donor propagation depends on it.
      // Scalar neighbors avoid a temporary array for each visited pixel.
      const holes=new Int32Array(n),holeGroups=[[]],antialiasedHoles=[];
      if(outlinedFill){
        const visited=new Uint8Array(n),limit=Math.max(12,Math.min(b[2],b[3]));
        for(let start=0;start<n;start++)if(!raw[start]&&!visited[start]){
          const group=[start];visited[start]=1;let edge=false,bright=0,pale=0,l=w,r=0,t=h,d=0;
          for(let head=0;head<group.length;head++){
            const i=group[head],x=i%w,y=i/w|0,k=i*4;
            edge ||= x===0||y===0||x===w-1||y===h-1;
            l=Math.min(l,x);r=Math.max(r,x);t=Math.min(t,y);d=Math.max(d,y);
            if(Math.min(rgba[k],rgba[k+1],rgba[k+2])>=220&&Math.max(rgba[k],rgba[k+1],rgba[k+2])-Math.min(rgba[k],rgba[k+1],rgba[k+2])<=35)bright++;
            if(options.outlinedComponentRecovery&&Math.min(rgba[k],rgba[k+1],rgba[k+2])>=200&&
                Math.max(rgba[k],rgba[k+1],rgba[k+2])-Math.min(rgba[k],rgba[k+1],rgba[k+2])<=45)pale++;
            if(x>0){const j=i-1;if(!raw[j]&&!visited[j]){visited[j]=1;group.push(j);}}
            if(x<w-1){const j=i+1;if(!raw[j]&&!visited[j]){visited[j]=1;group.push(j);}}
            if(y>0){const j=i-w;if(!raw[j]&&!visited[j]){visited[j]=1;group.push(j);}}
            if(y<h-1){const j=i+w;if(!raw[j]&&!visited[j]){visited[j]=1;group.push(j);}}
          }
          // Thin native-resampled fill retains both a bright core and a
          // pale antialias band. Dark counters cannot supply either proof.
          const brightFill=bright>=Math.max(3,group.length*.45)||options.outlinedComponentRecovery&&
            bright>=Math.max(3,group.length*.35)&&pale>=group.length*.7;
          const holeOwned=inside((l+r)/2,(t+d)/2)||options.outlinedComponentRecovery&&
            (l+r)/2>=b[0]&&(l+r)/2<=b[0]+b[2]&&t<b[1]+b[3]&&d>b[1]&&
            t>=b[1]-24&&d<=b[1]+b[3]+Math.min(80,limit*.85)&&
            !(options.inferredRubyExclusions||[]).some(a=>a[0]<=r&&a[0]+a[2]>=l&&a[1]<=d&&a[1]+a[3]>=t);
          if(!edge&&group.length>=3&&brightFill&&r-l<limit*2&&d-t<limit*2&&holeOwned){
            const id=holeGroups.length;holeGroups.push(group);for(const i of group)holes[i]=id;
          } else if(options.outlinedComponentRecovery&&!edge&&group.length>=3&&
              r-l<limit*2&&d-t<limit*2&&holeOwned){
            // Thin brackets can contain mostly stroke/white antialias mixtures.
            // Require a closed island, independently observed white lettering
            // elsewhere, and pixels on that same physical colour segment.
            let blended=0,peak=0;
            for(const i of group){const k=i*4;
              const a=Math.max(0,Math.min(1,((rgba[k]-fg[0])*(255-fg[0])+
                (rgba[k+1]-fg[1])*(255-fg[1])+(rgba[k+2]-fg[2])*(255-fg[2]))/
                Math.max(1,(255-fg[0])**2+(255-fg[1])**2+(255-fg[2])**2)));
              if(Math.max(...[0,1,2].map(c=>Math.abs(rgba[k+c]-(fg[c]+a*(255-fg[c])))))<=18)blended++;
              peak=Math.max(peak,Math.min(rgba[k],rgba[k+1],rgba[k+2]));
            }
            if(blended>=group.length*.65&&peak>=(neutral?240:210)&&
                (neutral?bright>=3:Math.max(bright,pale)>=Math.max(3,group.length*.15)))antialiasedHoles.push(group);
          }
        }
        if(holeGroups.length>=5)for(const group of antialiasedHoles){
          const id=holeGroups.length;holeGroups.push(group);for(const i of group)holes[i]=id;
        }
      }
      if(outlinedFill&&holeGroups.length>=5){
        // A stroke can touch a background of the same color (brickwork or a
        // dark garment). Keep only the measured ring around closed white fill;
        // do not let that connection flood an entire illustration component.
        const distance=new Uint8Array(n),front=[];
        for(let i=0;i<n;i++)if(holes[i]||raw[i]&&inside(i%w,i/w|0)&&
            aidokuRestorationDistance(rgba[i*4],rgba[i*4+1],rgba[i*4+2],fg)<=32){distance[i]=1;front.push(i);}
        const ring=Math.max(4,Math.min(12,Math.ceil(Math.min(b[2],b[3])*.16)));
        for(let head=0;head<front.length;head++){
          const i=front[head],x=i%w,y=i/w|0;if(distance[i]>ring)continue;
          if(x>0){const j=i-1;if(!distance[j]&&raw[j]){distance[j]=distance[i]+1;front.push(j);}}
          if(x<w-1){const j=i+1;if(!distance[j]&&raw[j]){distance[j]=distance[i]+1;front.push(j);}}
          if(y>0){const j=i-w;if(!distance[j]&&raw[j]){distance[j]=distance[i]+1;front.push(j);}}
          if(y<h-1){const j=i+w;if(!distance[j]&&raw[j]){distance[j]=distance[i]+1;front.push(j);}}
        }
        const connected=new Uint8Array(n);
        for(let start=0;start<n;start++)if(raw[start]&&!connected[start]){
          const group=[start];connected[start]=1;let edge=false;
          for(let head=0;head<group.length;head++){
            const i=group[head],x=i%w,y=i/w|0;edge ||= x<3||y<3||x>=w-3||y>=h-3;
            if(x>0){const j=i-1;if(raw[j]&&!connected[j]){connected[j]=1;group.push(j);}}
            if(x<w-1){const j=i+1;if(raw[j]&&!connected[j]){connected[j]=1;group.push(j);}}
            if(y>0){const j=i-w;if(raw[j]&&!connected[j]){connected[j]=1;group.push(j);}}
            if(y<h-1){const j=i+w;if(raw[j]&&!connected[j]){connected[j]=1;group.push(j);}}
          }
          if(edge)for(const i of group)if(!distance[i]){
            raw[i]=0;
            // Matching hue alone does not make a smooth warm background ink.
            // Excluding all of it starves one side of the fill and drags the
            // other side's colour through the removed glyph as a sharp patch.
            const k=i*4,x=i%w,y=i/w|0,bg=palette.background;
            let clean=bg&&aidokuRestorationDistance(rgba[k],rgba[k+1],rgba[k+2],bg)<=64&&
              aidokuRestorationDistance(rgba[k],rgba[k+1],rgba[k+2],fg)>64;
            if(clean)for(const j of [x?i-1:i,x+1<w?i+1:i,y?i-w:i,y+1<h?i+w:i])
              if(Math.max(Math.abs(rgba[k]-rgba[j*4]),Math.abs(rgba[k+1]-rgba[j*4+1]),Math.abs(rgba[k+2]-rgba[j*4+2]))>12){clean=false;break;}
            blocked[i]=clean?0:1;
          }
        }
      }
      const fragments=[],artSeeds=[],unresolvedGroups=[];let components=0,cores=0,unowned=0,framePixels=0,weakCores=0;
      for(let start=0;start<n;start++)if(raw[start]&&!seen[start]){
        const queue=[start];seen[start]=1;let head=0,l=w,r=0,t=h,d=0,owned=0,edge=false;
        while(head<queue.length){const i=queue[head++],x=i%w,y=i/w|0;
          l=Math.min(l,x);r=Math.max(r,x);t=Math.min(t,y);d=Math.max(d,y);owned+=inside(x,y);
          edge ||= x<3||y<3||x>=w-3||y>=h-3;
          if(x>0){const j=i-1;if(raw[j]&&!seen[j]){seen[j]=1;queue.push(j);}}
          if(x<w-1){const j=i+1;if(raw[j]&&!seen[j]){seen[j]=1;queue.push(j);}}
          if(y>0){const j=i-w;if(raw[j]&&!seen[j]){seen[j]=1;queue.push(j);}}
          if(y<h-1){const j=i+w;if(raw[j]&&!seen[j]){seen[j]=1;queue.push(j);}}
        }
        const area=(r-l+1)*(d-t+1);
        let border=0,white=0;const enclosed=new Set();
        for(const i of queue)for(const j of [i-1,i+1,i-w,i+w])if(j>=0&&j<n&&!raw[j]){
          if(holes[j])enclosed.add(holes[j]);border++;const k=j*4,lo=Math.min(rgba[k],rgba[k+1],rgba[k+2]),hi=Math.max(rgba[k],rgba[k+1],rgba[k+2]);
          let haloPixel=lo>=230&&hi-lo<=25;
          const direction=j-i;
          for(let step=1;!haloPixel&&step<=3;step++){
            const q=j+direction*step;if(q<0||q>=n||raw[q])break;
            const a=q*4,low=Math.min(rgba[a],rgba[a+1],rgba[a+2]),high=Math.max(rgba[a],rgba[a+1],rgba[a+2]);
            haloPixel=low>=238&&high-low<=20;
          }
          if(haloPixel)white++;
        }
        const halo=outlinedFill?enclosed.size>0||queue.length<=128&&border>=12&&white/border>=.65:border>=12&&white/border>=.6;
        // A detector edge can cut a white-ringed glyph. Admit its complete
        // connected component only within a small bounded spill, and never
        // across another OCR region. Do not truncate the erasure at the box.
        const spill=Math.min(options.outlinedComponentRecovery?80:8,Math.min(b[2],b[3])*(options.outlinedComponentRecovery?.85:.25));
        const enclosedEdge=options.outlinedComponentRecovery&&outlinedFill&&holeGroups.length>=5&&enclosed.size>0;
        const terminalCut=enclosedEdge&&options.vertical&&t<b[1]+b[3]&&t>b[1]+b[3]-Math.min(b[2],b[3])*.5&&
          (l+r)/2>=b[0]&&(l+r)/2<=b[0]+b[2];
        const edgeGlyph=(white/border>=.85||enclosedEdge)&&owned>=queue.length*(terminalCut?.2:.5)&&
          l>=b[0]-spill&&r<=b[0]+b[2]+spill&&t>=b[1]-spill&&d<=b[1]+b[3]+spill&&
          !(options.inferredRubyExclusions||[]).some(a=>a[0]<=r&&a[0]+a[2]>=l&&a[1]<=d&&a[1]+a[3]>=t);
        const enclosedStroke=options.outlinedComponentRecovery&&outlinedFill&&enclosed.size>0&&white/border>=.9;
        const valid=!edge&&halo&&queue.length>=12&&Math.min(r-l,d-t)>=3&&queue.length>=area*.025&&(queue.length<=area*.95||enclosedStroke||white/border>=.9&&Math.max(r-l,d-t)>=Math.min(r-l,d-t)*4)&&(owned>=queue.length*.8||edgeGlyph);
        if(!valid&&!edge&&queue.length<=(outlinedFill?128:64)&&owned===queue.length){
          // A detached dakuten/punctuation core can be several pixels from its
          // body. Only a tiny, independently white-ringed dark core receives
          // the measured glyph-scale reach; larger or unoutlined marks do not.
          const glyph=evidence.widthEvidence?.glyphPixels||0;
          const radius=outlinedFill?8:darkFill&&queue.length<=12&&white/border>=.75&&glyph>0?
            Math.max(3,Math.min(8,Math.ceil(glyph*.25))):3;
          fragments.push({pixels:queue,radius});
        }
        // A broad, unoutlined shape crossing the source box is background,
        // even when it shares the outline hue. Keep it blocked as a donor;
        // only independently enclosed white lettering authorizes this retry.
        const differentInk=options.outlinedComponentRecovery&&outlinedFill&&holeGroups.length>=5&&
          !halo&&enclosed.size===0&&white/Math.max(1,border)<.1&&queue.every(i=>
            aidokuRestorationDistance(rgba[i*4],rgba[i*4+1],rgba[i*4+2],fg)>48);
        const crossingArt=differentInk||options.outlinedComponentRecovery&&outlinedFill&&holeGroups.length>=5&&
          !halo&&enclosed.size===0&&white/Math.max(1,border)<.12&&
          (owned<queue.length*.95||
            Math.max(r-l,d-t)>Math.min(b[2],b[3])*.75&&
              (l<b[0]-2||r>b[0]+b[2]+2||t<b[1]-2||d>b[1]+b[3]+2)||
            Math.max(r-l,d-t)>Math.min(b[2],b[3])*.3&&Math.max(r-l,d-t)>=Math.max(1,Math.min(r-l,d-t))*5&&
              (l<b[0]+4||r>b[0]+b[2]-4||t<b[1]+4||d>b[1]+b[3]-4));
        if(crossingArt&&fragments.at(-1)?.pixels===queue)fragments.pop();
        if(crossingArt){for(const i of queue)artSeeds.push(i);}
        else if(!valid&&!edge&&owned>=queue.length*.5)unresolvedGroups.push({pixels:queue,owned});
        if(!valid){if(crossingArt||owned<queue.length*.5||edge&&(queue.length<area*.1||d<b[1]+b[3]*.2||t>b[1]+b[3]*.8||r<b[0]+b[2]*.2||l>b[0]+b[2]*.8))framePixels+=owned;else unowned+=owned;}
        for(const i of queue)(valid?mask:blocked)[i]=1;
        if(valid){components++;cores+=queue.length;if(!outlinedFill&&white/border<.7)weakCores+=queue.length;for(const id of enclosed)for(const i of holeGroups[id])mask[i]=1;}
      }
      if(options.outlinedComponentRecovery&&outlinedFill&&neutral&&holeGroups.length>=5&&artSeeds.length){
        // JPEG antialiasing splits a diagonal clothing seam into tiny dark
        // islands. Reconnect only to already protected crossing artwork through
        // dark original pixels; the white glyph interiors and masks are barriers.
        const connected=new Uint8Array(n),front=artSeeds.slice();
        for(const i of front)connected[i]=1;
        for(let head=0;head<front.length;head++){
          const i=front[head],x=i%w,y=i/w|0;
          for(let yy=Math.max(0,y-1);yy<=Math.min(h-1,y+1);yy++)for(let xx=Math.max(0,x-1);xx<=Math.min(w-1,x+1);xx++){
            const j=yy*w+xx,k=j*4;
            if(connected[j]||mask[j]||holes[j]||Math.max(rgba[k],rgba[k+1],rgba[k+2])>160)continue;
            connected[j]=1;front.push(j);
          }
        }
        for(const group of unresolvedGroups)if(group.pixels.every(i=>connected[i])){
          unowned-=group.owned;framePixels+=group.owned;
          const index=fragments.findIndex(f=>f.pixels===group.pixels);if(index>=0)fragments.splice(index,1);
        }
      }
      if(components<(outlinedFill&&holeGroups.length>=5?1:2)||cores<32||weakCores>cores*.2)return null;
      const ownedMask=mask.slice();
      for(const {pixels:fragment,radius} of fragments){
        const near=fragment.every(i=>{const x=i%w,y=i/w|0;
          for(let yy=Math.max(1,y-radius);yy<=Math.min(h-2,y+radius);yy++)for(let xx=Math.max(1,x-radius);xx<=Math.min(w-2,x+radius);xx++)
            if(ownedMask[yy*w+xx])return true;
          return false;
        });
        if(near)for(const i of fragment){mask[i]=1;blocked[i]=0;unowned--;cores++;}
      }
      if(unowned>Math.max(3,cores*.002)||framePixels>cores*.5)return null;
      const distance=new Uint8Array(n),queue=new Int32Array(n);let head=0,tail=0;
      for(let i=0;i<n;i++)if(mask[i])queue[tail++]=i;
      const radius=Math.max(4,Math.min(20,Math.ceil(Math.min(b[2],b[3])*.08)));
      while(head<tail){const i=queue[head++];if(distance[i]>=radius)continue;
        for(const j of [i-1,i+1,i-w,i+w]){
          const x=j%w,y=j/w|0;if(x<2||y<2||x>=w-2||y>=h-2||mask[j]||blocked[j])continue;
          const k=j*4,lo=Math.min(rgba[k],rgba[k+1],rgba[k+2]),hi=Math.max(rgba[k],rgba[k+1],rgba[k+2]);
          const d=hi-lo;
          const fringe=d>=15&&Math.max(Math.abs((rgba[k]-lo)*255/d-color[0]),Math.abs((rgba[k+1]-lo)*255/d-color[1]),Math.abs((rgba[k+2]-lo)*255/d-color[2]))<=32;
          if(distance[i]>=2&&!(lo>=200&&hi-lo<=35)&&!fringe)continue;
          mask[j]=1;distance[j]=distance[i]+1;queue[tail++]=j;
        }
      }
      {
        // The white halo fades into the artwork through a few antialiased
        // pixels. Do not use that fringe as donor colour: it leaves a pale
        // silhouette even after every dark/coloured core has been erased.
        // White-filled outlined type also has an outer antialias fringe. Leaving
        // it in the donor front spreads its colour into a glyph-shaped stain.
        for(let pass=0;pass<3;pass++){
          const end=tail;
          for(let k=0;k<end;k++)for(const j of [queue[k]-1,queue[k]+1,queue[k]-w,queue[k]+w]){
            const x=j%w,y=j/w|0;
            if(x<2||y<2||x>=w-2||y>=h-2||mask[j]||blocked[j])continue;
            mask[j]=1;queue[tail++]=j;
          }
        }
      }
      const painted=mask.slice(),p=rgba.slice();
      aidokuFillFromDonorFront(p,w,n,queue,tail,mask,blocked,painted);
      if(mask.some(Boolean))return null;
      aidokuHarmonicFill(p,w,n,queue,tail,blocked,painted,true);
      const out=new Uint8ClampedArray(n*4),safe=new Uint8Array(n);safe.fill(1);
      for(let i=0;i<n;i++){
        if(painted[i]){out[i*4]=p[i*4];out[i*4+1]=p[i*4+1];out[i*4+2]=p[i*4+2];out[i*4+3]=255;}
        if(blocked[i])safe[i]=0;
      }
      return {rgba:out,layoutSafe:safe,erased:tail,components,method:'chromatic-balloon-glyphs',
        ...(outlinedFill?{discoveredOutline:stroke}:{}),
        sourceForeground:fg,sourceBackground:palette.background,sourceGlyphsVerified:true,sourceErasureVerified:true,observedDarkInk:!!darkFill,
        sourceRemainingInk:unowned,sourceCorePixels:cores,sourceFramePixels:framePixels,preservedPixels:0,preservedCore:0,
        surfaceQuality:{safe:true,reason:'chromatic-local-donors'}};
    }
    // Tiny anti-aliased remnants can survive just outside an accepted glyph mask.
    // Only isolated same-ink fragments adjacent to opaque reconstructed donors are
    // eligible; connected rules, artwork and distant punctuation stay untouched.
    function aidokuRefineChromaticFringe(result,rgba,w,h,b,palette,options) {
      const originalFill=palette?.sourceInk?.foreground||palette?.foreground;
      const outlined=result?.method==='chromatic-balloon-glyphs'&&originalFill&&Math.min(...originalFill)>=220;
      const fg=outlined?result.sourceForeground:originalFill,n=w*h;
      if(!result?.sourceGlyphsVerified||options.slantedOwnership||!fg||n>262144)return result;
      const low=Math.min(...fg),span=Math.max(...fg)-low;
      if(span<90)return result;
      const color=fg.map(v=>(v-low)*255/span),out=result.rgba,remaining=new Uint8Array(n);
      for(let y=2;y<h-2;y++)for(let x=2;x<w-2;x++){
        const i=y*w+x,k=i*4;if(out[k+3])continue;
        const lo=Math.min(rgba[k],rgba[k+1],rgba[k+2]),d=Math.max(rgba[k],rgba[k+1],rgba[k+2])-lo;
        if((!outlined||Math.max(...[0,1,2].map(c=>Math.abs(rgba[k+c]-fg[c])))<=48)&&d>=30&&Math.max(...[0,1,2].map(c=>Math.abs((rgba[k+c]-lo)*255/d-color[c])))<=45)remaining[i]=1;
      }
      let changed=0;
      for(let start=0;start<n;start++)if(remaining[start]){
        const group=[start];remaining[start]=0;
        for(let head=0;head<group.length;head++){
          const i=group[head],x=i%w,y=i/w|0;
          for(let yy=Math.max(0,y-1);yy<=Math.min(h-1,y+1);yy++)for(let xx=Math.max(0,x-1);xx<=Math.min(w-1,x+1);xx++){
            const j=yy*w+xx;if(remaining[j]){remaining[j]=0;group.push(j);}
          }
        }
        if(group.length>(outlined?512:16)||changed+group.length>(outlined?2048:128))continue;
        const patches=[];
        for(const i of group){
          const x=i%w,y=i/w|0,sums=[0,0,0],radius=outlined?6:3;let donors=0;
          for(let yy=y-radius;yy<=y+radius;yy++)for(let xx=x-radius;xx<=x+radius;xx++){
            if(xx<0||yy<0||xx>=w||yy>=h)continue;
            const j=yy*w+xx,k=j*4;
            if(out[k+3]===255&&result.layoutSafe[j]){for(let c=0;c<3;c++)sums[c]+=out[k+c];donors++;}
          }
          if(donors<4)break;
          patches.push([i,...sums.map(v=>Math.round(v/donors))]);
        }
        if(patches.length!==group.length)continue;
        for(const [i,r,g,bb] of patches){out.set([r,g,bb,255],i*4);result.layoutSafe[i]=1;}
        changed+=group.length;
      }
      result.erased+=changed;result.chromaticFringePixels=changed;return result;
    }
    function aidokuFinishClearPaperCaption(result,rgba,w,h,b,palette,options) {
      const bg=palette?.background,fill=palette?.sourceInk?.foreground||palette?.foreground;
      const outline=palette?.sourceInk?.stroke||palette?.stroke;
      const fg=fill&&Math.min(...fill)>=220&&outline?outline:fill;
      if(!result||result.sourceErasureVerified||options.slantedOwnership||!bg||!fg||
          Math.min(...bg)<248||Math.max(...bg)-Math.min(...bg)>6||w*h>262144||result.erased<32)return result;
      const delta=(data,k,color)=>Math.max(...color.map((v,c)=>Math.abs(data[k+c]-v)));
      let boundary=0,clear=0;
      for(let y=0;y<h;y++)for(let x=0;x<w;x++)if(x<2||y<2||x>=w-2||y>=h-2){
        boundary++;if(rgba[(y*w+x)*4+3]===255&&delta(rgba,(y*w+x)*4,bg)<=10)clear++;
      }
      const low=Math.min(...fg),span=Math.max(...fg)-low,color=fg.map(v=>(v-low)*255/Math.max(1,span));
      if(clear<boundary*(span>=60&&!options.chromaticBalloon? .95:.98))return result;
      const pending=new Set(),foreign=new Set(),out=result.rgba;
      for(const box of [b,...(options.auxiliary||[])]){
        const l=Math.max(2,Math.floor(box[0]-2)),t=Math.max(2,Math.floor(box[1]-2));
        const r=Math.min(w-2,Math.ceil(box[0]+box[2]+2)),bottom=Math.min(h-2,Math.ceil(box[1]+box[3]+2));
        for(let y=t;y<bottom;y++)for(let x=l;x<r;x++){
          const i=y*w+x,k=i*4,data=out[k+3]?out:rgba;
          if(delta(data,k,bg)<=12)continue;
          const lo=Math.min(data[k],data[k+1],data[k+2]),hi=Math.max(data[k],data[k+1],data[k+2]),d=hi-lo;
          const owned=span>=60?d>=10&&Math.max(...[0,1,2].map(c=>Math.abs((data[k+c]-lo)*255/d-color[c])))<=45:
            Math.max(...fg)<90&&d<=20;
          if(!owned){
            if(d>(span>=60?24:3))return result;
            foreign.add(i);
          }
          pending.add(i);
        }
      }
      if(foreign.size>(span>=60?512:8))return result;
      const visited=new Set();
      for(const start of foreign)if(!visited.has(start)){
        const group=[start];visited.add(start);let boundary=0,repaired=0;
        for(let head=0;head<group.length;head++){
          const i=group[head];
          for(let dy=-1;dy<=1;dy++)for(let dx=-1;dx<=1;dx++)if(dx||dy){
            const j=i+dy*w+dx;
            if(foreign.has(j)){if(!visited.has(j)){visited.add(j);group.push(j);}}
            else {boundary++;if(out[j*4+3]===255||pending.has(j))repaired++;}
          }
        }
        if(group.length>(span>=60?64:8)||repaired<boundary*.5)return result;
      }
      if(pending.size>Math.max(32,result.erased*.1))return result;
      for(const i of pending){out.set([...bg,255],i*4);result.layoutSafe[i]=1;}
      result.erased+=pending.size;result.sourceRemainingInk=0;
      result.sourceGlyphsVerified=true;result.sourceErasureVerified=true;result.clearPaperCompletion=pending.size;
      return result;
    }
    // The hard glyph is gone before this pass. Extend only a thin, neutral
    // white halo into the already reconstructed neighboring surface. A white
    // paper donor needs no extension; crop edges and remote drawing stay intact.
    function aidokuRefineWhiteGlyphFringe(result,rgba,w,h,options) {
      if(!result?.sourceGlyphsVerified||options.slantedOwnership||w*h>262144)return result;
      const out=result.rgba;
      for(let pass=0;pass<2;pass++){
        const patches=[];
        for(let y=2;y<h-2;y++)for(let x=2;x<w-2;x++){
          const i=y*w+x,k=i*4;if(out[k+3]||!result.layoutSafe[i])continue;
          const lo=Math.min(rgba[k],rgba[k+1],rgba[k+2]),hi=Math.max(rgba[k],rgba[k+1],rgba[k+2]);
          if(lo<240||hi-lo>20)continue;
          const sum=[0,0,0];let count=0;
          for(let dy=-1;dy<=1;dy++)for(let dx=-1;dx<=1;dx++){
            const j=i+dy*w+dx,a=j*4;
            if(out[a+3]===255&&result.layoutSafe[j]){for(let c=0;c<3;c++)sum[c]+=out[a+c];count++;}
          }
          if(count<3)continue;
          const rgb=sum.map(v=>v/count);
          if(Math.max(...rgb)>238||Math.min(...rgb)<150||lo-Math.max(...rgb)<8)continue;
          patches.push([i,...rgb]);
        }
        for(const [i,r,g,b] of patches)out.set([r,g,b,255],i*4);
        result.erased+=patches.length;
        if(!patches.length)break;
      }
      return result;
    }
    // A display palette can lose or reverse white-fill/colored-outline roles.
    // Recover candidates from actual bright-edge pixels, then require the same
    // closed-fill, ownership, boundary and residual checks as an observed palette.
    function aidokuDiscoverOutlinedSource(rgba,w,h,b,palette,options) {
      if(!options.readabilityGate||options.slantedOwnership||w*h>262144||
          !aidokuRestorationOpaque(rgba))return null;
      const bins=new Map(),bright=i=>i>=0&&i<w*h&&Math.min(rgba[i*4],rgba[i*4+1],rgba[i*4+2])>=230;
      for(let y=Math.max(2,Math.floor(b[1]));y<Math.min(h-2,b[1]+b[3]);y++)
        for(let x=Math.max(2,Math.floor(b[0]));x<Math.min(w-2,b[0]+b[2]);x++){
          const i=y*w+x,k=i*4,r=rgba[k],g=rgba[k+1],bl=rgba[k+2];
          if(Math.max(r,g,bl)-Math.min(r,g,bl)<90||
              ![i-1,i+1,i-w,i+w,i-2,i+2,i-2*w,i+2*w].some(bright))continue;
          const key=(r>>5)*64+(g>>5)*8+(bl>>5),v=bins.get(key)||[0,0,0,0];
          v[0]+=r;v[1]+=g;v[2]+=bl;v[3]++;bins.set(key,v);
        }
      const candidates=[...bins.values()].filter(v=>v[3]>=24).sort((a,b)=>b[3]-a[3]).slice(0,2);
      for(const v of candidates){
        const stroke=v.slice(0,3).map(c=>Math.round(c/v[3]));
        const observed={...palette,sourceInk:null,foreground:[255,255,255],stroke};
        const result=aidokuRestoreChromaticBalloonGlyphs(rgba,w,h,b,observed,options)||
          aidokuRestoreChromaticBalloonGlyphs(rgba,w,h,b,observed,{...options,outlinedComponentRecovery:true});
        if(result)return {...result,discoveredOutline:stroke};
      }
      return null;
    }
    // A narrow OCR column can include the solid/dotted rim of its balloon.
    // Require dark, aligned glyph cores on neutral paper and an enclosing rim;
    // paint only their connected components. Rim pixels remain unsafe for layout.
    function aidokuNarrowPaperGlyphs(rgba,w,h,b,palette,options={}) {
      const n=w*h;
      if(!options.vertical||options.auxiliary?.length||!b?.every(Number.isFinite)||b.length!==4||
          b[2]<12||b[2]>64||b[3]<b[2]*2||b[3]>b[2]*7||n>65536||rgba.length!==n*4)return null;
      const [l,t,bw,bh]=b,r=l+bw,d=t+bh,cx=l+bw/2;
      if(l<3||t<3||r>w-3||d>h-3)return null;
      const ink=new Uint8Array(n),seen=new Uint8Array(n),safe=new Uint8Array(n),parts=[];
      let paper=0,total=0;const sums=[0,0,0];
      for(let y=0;y<h;y++)for(let x=0;x<w;x++){
        const i=y*w+x,k=i*4,lo=Math.min(rgba[k],rgba[k+1],rgba[k+2]),hi=Math.max(rgba[k],rgba[k+1],rgba[k+2]);
        ink[i]=lo<230?1:0;safe[i]=lo>=242?1:0;
        if(x>=l&&x<=r&&y>=t&&y<=d){
          if(rgba[k+3]!==255||hi-lo>12)return null;
          total++;if(lo>=248){paper++;for(let c=0;c<3;c++)sums[c]+=rgba[k+c];}
        }
      }
      if(paper<total*.6)return null;
      for(let start=0;start<n;start++)if(ink[start]&&!seen[start]){
        const q=[start];seen[start]=1;let x0=w,y0=h,x1=0,y1=0,dark=0;
        for(let head=0;head<q.length;head++){
          const i=q[head],x=i%w,y=i/w|0;
          x0=Math.min(x0,x);x1=Math.max(x1,x);y0=Math.min(y0,y);y1=Math.max(y1,y);
          if(Math.max(rgba[i*4],rgba[i*4+1],rgba[i*4+2])<100)dark++;
          for(let yy=Math.max(0,y-1);yy<=Math.min(h-1,y+1);yy++)for(let xx=Math.max(0,x-1);xx<=Math.min(w-1,x+1);xx++){
            const j=yy*w+xx;if(ink[j]&&!seen[j]){seen[j]=1;q.push(j);}
          }
        }
        if(x1<l||x0>r||y1<t||y0>d)continue;
        const contained=x0>=l&&x1<=r&&y0>=t&&y1<=d;
        const aligned=Math.abs((x0+x1)/2-cx)<=bw*.23&&x1-x0<bw*.8&&y1-y0<bw*1.25;
        parts.push({q,x0,y0,x1,y1,dark,contained,aligned});
      }
      const cores=parts.filter(p=>p.contained&&p.aligned&&p.dark>=2);
      if(cores.length<3||cores.reduce((s,p)=>s+p.dark,0)<24)return null;
      const top=Math.min(...cores.map(p=>p.y0)),bottom=Math.max(...cores.map(p=>p.y1));
      const coreLeft=Math.min(...cores.map(p=>p.x0)),coreRight=Math.max(...cores.map(p=>p.x1));
      if(bottom-top<bh*.35)return null;
      const owned=parts.filter(p=>cores.includes(p)||p.contained&&p.aligned&&p.q.length>=bw*.8&&
        p.x0>=coreLeft&&p.x1<=coreRight&&p.x1-p.x0>=bw*.22&&p.y0>=top-bw*.5&&p.y1<=bottom+bw*.65);
      const rim=parts.filter(p=>!owned.includes(p));
      if(rim.some(p=>p.contained&&p.dark>=2))return null;
      // A continuous enclosure or a repeated pale dotted rim must straddle the lettering.
      const left=rim.some(p=>p.x0<cx-bw*.3),right=rim.some(p=>p.x1>cx+bw*.3);
      if(!left||!right||!rim.some(p=>!p.contained)&&rim.length<6)return null;
      const excluded=options.excluded||options.inferredRubyExclusions||[];
      if(owned.some(p=>p.q.some(i=>excluded.some(a=>i%w>=a[0]&&i%w<=a[0]+a[2]&&
          (i/w|0)>=a[1]&&(i/w|0)<=a[1]+a[3]))))return null;
      const bg=sums.map(v=>Math.round(v/paper));
      const mask=new Uint8Array(n),out=new Uint8ClampedArray(n*4);
      for(const p of owned)for(const i of p.q)mask[i]=1;
      const originalMask=mask.slice();
      for(let i=0;i<n;i++)if(originalMask[i]){
        const x=i%w,y=i/w|0;
        for(let yy=Math.max(1,y-2);yy<=Math.min(h-2,y+2);yy++)for(let xx=Math.max(1,x-2);xx<=Math.min(w-2,x+2);xx++){
          const j=yy*w+xx;if(!ink[j]||originalMask[j])mask[j]=1;
        }
      }
      let erased=0;
      for(let i=0;i<n;i++)if(mask[i]){out.set([...bg,255],i*4);safe[i]=1;erased++;}
      return {rgba:out,layoutSafe:safe,erased,components:owned.length,radius:2,companions:0,
        preservedPixels:0,preservedCore:0,sourceRemainingInk:0,sourceCorePixels:cores.reduce((s,p)=>s+p.dark,0),
        sourceGlyphsVerified:true,sourceErasureVerified:true,sourceForeground:palette?.foreground||[50,50,50],
        sourceBackground:bg,method:'narrow-paper-glyphs',
        surfaceQuality:{safe:true,reason:'smooth',rmse:0,outliers:0,samples:paper}};
    }
        function aidokuRestoreSourcePanel(rgba,w,h,b,palette,options={}) {
          if(aidokuRestoreSourcePanel.classificationCache)return aidokuRestoreSourcePanelAttempts(rgba,w,h,b,palette,options);
          aidokuRestoreSourcePanel.classificationCache=[];
          const refine=result=>{
            const observed=result?.discoveredOutline?{...palette,sourceInk:null,foreground:[255,255,255],stroke:result.discoveredOutline}:palette;
            return aidokuRefineWhiteGlyphFringe(aidokuRefineChromaticFringe(
              aidokuFinishClearPaperCaption(result,rgba,w,h,b,observed,options),rgba,w,h,b,observed,options),rgba,w,h,options);
          };
          const ring=palette?.sourceInk?.stroke||palette?.stroke||palette?.sourceInk?.foreground||palette?.foreground;
          const outlineRecovery=()=>aidokuRestoreChromaticBalloonGlyphs(rgba,w,h,b,palette,options)
            ||(ring&&Math.max(...ring)-Math.min(...ring)>=60
              ?aidokuRestoreChromaticBalloonGlyphs(rgba,w,h,b,{...palette,sourceInk:null,foreground:[255,255,255],stroke:ring},options):null)
            ||aidokuDiscoverOutlinedSource(rgba,w,h,b,palette,options)
            ||aidokuRestoreChromaticBalloonGlyphs(rgba,w,h,b,{...palette,sourceInk:null,foreground:[255,255,255],stroke:[0,0,0]},options)
            ||aidokuRestoreChromaticBalloonGlyphs(rgba,w,h,b,{...palette,sourceInk:null,foreground:[255,255,255],stroke:[0,0,0]},
              {...options,outlinedComponentRecovery:true});
          const preferVerifiedErasure=result=>result.sourceErasureVerified?result:
            outlineRecovery()||result;

          try{
            const result=aidokuRestoreSourcePanelAttempts(rgba,w,h,b,palette,options);
            if(!result?.sourceErasureVerified){
              const narrow=aidokuNarrowPaperGlyphs(rgba,w,h,b,palette,options);
              if(narrow)return narrow;
            }
            // Run short-glyph recovery only after every existing palette path
            // fails, preserving successful masks and their donor pixels exactly.
            if(result)return refine(preferVerifiedErasure(result));
            const recovered=aidokuRestoreSourcePanel.classificationCache.shortGlyphCandidate
              ?aidokuRestoreSourcePanelAttempts(rgba,w,h,b,palette,{...options,shortGlyphRecovery:true}):null;
            if(recovered)return refine(options.slantedOwnership?recovered:preferVerifiedErasure(recovered));
            // Rectified slanted masks can merge a neighboring lettering
            // stroke into the target. Keep their established donor policy.
            if(options.slantedOwnership)return aidokuRestoreChromaticBalloonGlyphs(rgba,w,h,b,palette,options);
            const dense=aidokuRestoreSourcePanel.classificationCache.denseDonorCandidate?aidokuRestoreSourcePanelAttempts(rgba,w,h,b,palette,{...options,denseDonorSampling:true}):null;
            if(dense)return refine(preferVerifiedErasure(dense));
            const outline=palette?.stroke||palette?.sourceInk?.stroke;
            const distinctOutline=outline&&palette?.background&&Math.max(...outline.map((v,c)=>Math.abs(v-palette.background[c])))>24;
            const enclosed=aidokuRestoreSourcePanelAttempts(rgba,w,h,b,palette,
              {...options,enclosedWordRecovery:true,shortGlyphRecovery:true,segmentedSurfaceRecovery:!distinctOutline});
            return refine(enclosed?preferVerifiedErasure(enclosed):
              outlineRecovery());
          }
          finally{aidokuRestoreSourcePanel.classificationCache=null;}
        }
        function aidokuRestoreSourcePanelAttempts(rgba,w,h,b,palette,options) {
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
              if(joint)(()=>{for(let i=0;i<w*h;i++){
                if(!result.rgba[i*4+3]||joint.rgba[i*4+3])continue;
                const r=rgba[i*4],g=rgba[i*4+1],bl=rgba[i*4+2];
                if(aidokuRestorationDistance(r,g,bl,usedPalette.foreground)<=48&&aidokuRestorationDistance(r,g,bl,usedPalette.background)>=32){preservesPrimary=false;break;}
              }})();
              if(preservesPrimary){joint.secondaryInkPixels=Math.max(0,joint.erased-result.erased);result=joint;}
            }
            const chromatic=usedPalette?.foreground&&Math.max(...usedPalette.foreground)-Math.min(...usedPalette.foreground)>=40;
            // WebKit downsamples the transparent patch separately from the
            // page. Without a sampling guard its alpha edge exposes the old
            // white outline, even when every native glyph pixel was erased.
            // Copy only matching original background into a two-pixel guard;
            // source ink and artwork are never reconstructed by this step.
            if(options.readabilityGate&&usedPalette?.background&&(chromatic||usedPalette.stroke&&
                distance(usedPalette.stroke,usedPalette.background)>=32)){
              const rgbaOut=result.rgba,guard=new Uint8Array(w*h);
              (()=>{for(let pass=0;pass<2;pass++){
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
              }})();
            }
            return {...result,method,...(options.slantedOwnership?
              {sourceForeground:usedPalette.foreground,sourceBackground:usedPalette.background}: {})};
          };
          // Display-role rejection must not discard independently observed
          // outline pixels. Neutral outlines require repeated dark interiors
          // enclosed by independently observed white source strokes.
          const observedStroke=palette?.sourceInk?.stroke;
          const chromaticObservedStroke=options.vertical&&!options.slantedOwnership&&observedStroke&&
            Math.max(...observedStroke)-Math.min(...observedStroke)>=40&&
            Math.max(...observedStroke.map((v,c)=>Math.abs(v-palette.sourceInk.foreground[c])))<48&&
            (palette.sourceInk.confidence?.stroke||0)>=.6;
          const neutralObservedStroke=options.vertical&&!options.slantedOwnership&&observedStroke&&Math.min(...observedStroke)>=230&&
            palette.sourceInk.widthEvidence?.method?.startsWith('outer stroke boundary')&&
            (palette.sourceInk.confidence?.stroke||0)>=.6&&Math.max(...palette.sourceInk.foreground)<=80&&
            palette.sourceInk.confidence?.reason==='repeated dark glyph interiors enclosed by white source outlines';
          if((options.connectedGlyphRecovery||chromaticObservedStroke||neutralObservedStroke)&&options.readabilityGate&&
              palette?.sourceInk&&!palette.stroke&&observedStroke){
            const observed=aidokuRestoreObservedSourcePanel(rgba,w,h,b,palette.sourceInk,options);
            if(observed)return finish(observed,palette.sourceInk,'observed-ink-evidence');
          }
          // A white outline may dominate the OCR box's background estimate.
          // Independent, stable exposed-surface samples distinguish that halo
          // from the actual translucent backing before donor selection.
          const surface=palette?.surface,stroke=palette?.stroke||observedStroke;
          const delta=(a,b)=>Math.max(...a.map((v,c)=>Math.abs(v-b[c])));
          if(options.readabilityGate&&options.vertical&&!options.slantedOwnership&&stroke&&surface?.color&&surface.stops?.length>=4&&
              Math.max(...palette.foreground)<=80&&Math.min(...stroke)>=230&&
              (palette.confidence?.stroke||0)>=.6&&(palette.confidence?.background||0)<.4&&
              delta(stroke,palette.background)<8&&delta(stroke,surface.color)>=24&&
              surface.stops.every(stop=>delta(stop,surface.color)<=8)){
            const exposed={...palette,background:surface.color};
            const recovered=aidokuRestoreObservedSourcePanel(rgba,w,h,b,exposed,options);
            if(recovered?.sourceErasureVerified&&recovered.preservedCore===0)
              return finish(recovered,exposed,'observed-surface-outline');
          }
          const original=aidokuRestoreObservedSourcePanel(rgba,w,h,b,palette,options);
          if(original)return finish(original,palette,original.surfaceQuality?.reason==='locally-smooth'?'local-diffusion':'observed-palette');
          if(!options.readabilityGate)return null;
          if(palette?.sourceInk){
            const observed=aidokuRestoreObservedSourcePanel(rgba,w,h,b,palette.sourceInk,options);
            if(observed)return finish(observed,palette.sourceInk,'observed-ink-evidence');
          }
          const ink=palette?.sourceInk||palette;
          if(options.vertical&&ink?.stroke&&Math.min(...ink.foreground)>230&&
              Math.max(...ink.stroke)-Math.min(...ink.stroke)>=40&&(ink.confidence?.stroke||0)>=.6){
            const outline={...ink,foreground:ink.stroke,stroke:ink.foreground};
            const restored=aidokuRestoreObservedSourcePanel(rgba,w,h,b,outline,options);
            if(restored)return finish(restored,outline,'observed-outline-ink');
          }
          const flat=aidokuFlatInpaintingPalette(rgba,w,h,b);
          const recovered=flat?aidokuRestoreObservedSourcePanel(rgba,w,h,b,flat,{...options,compactMask:true,flatPalette:true}):null;
          if(recovered)return finish(recovered,flat,'flat-surface-palette');
          // Preserve every already successful mask. Connected-outline recovery
          // is a bounded retry for rejected vertical captions only.
          return !options.connectedGlyphRecovery&&options.vertical&&!options.slantedOwnership
            ?aidokuRestoreSourcePanel(rgba,w,h,b,palette,{...options,connectedGlyphRecovery:true}):null;
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
          if(supported)(()=>{for(const i of texturePoints){const x=i%w,y=i/w|0;
            for(let yy=Math.max(3,y-3);yy<Math.min(h-3,y+4);yy++)for(let xx=Math.max(3,x-3);xx<Math.min(w-3,x+4);xx++)supported[yy*w+xx]=1;
          }})();
          (()=>{for(let y=3;y<h-3;y++)for(let x=3;x<w-3;x++){
            const i=y*w+x;if(mask[i]||blocked[i]||supported&&!supported[i])continue;
            valid[i]=1;total++;
            if(x%stride===0&&y%stride===0)samples.push(i);
          }})();
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
          (()=>{for(let dy=0;dy<=Math.min(64,h>>1);dy+=(halftone?1:2))for(let dx=-Math.min(128,w>>1);dx<=Math.min(128,w>>1);dx+=(halftone?1:2)){
            if(dy===0&&dx<=0||Math.max(Math.abs(dx),dy)<8)continue;
            const v=evaluate(dx,dy,probes,halftone?12:2.5);if(v&&v.error<=(halftone?12:2.5)&&v.deviation>=3&&v.outliers<=(halftone?.3:.02))coarse.push(v);
          }})();
          coarse.sort((a,b)=>a.error-b.error||(halftone?Math.hypot(a.dx,a.dy)-Math.hypot(b.dx,b.dy):0));
          const refined=[],visited=new Set();
          (()=>{for(const v of coarse.slice(0,halftone?96:24))for(let dy=v.dy-1;dy<=v.dy+1;dy++)for(let dx=v.dx-1;dx<=v.dx+1;dx++){
            if(dy<0||dy===0&&dx<=0)continue;
            const key=dx+','+dy;if(visited.has(key))continue;visited.add(key);
            const q=evaluate(dx,dy,samples);
            if(!q||q.error>(halftone?9:1.5)||q.deviation<3||q.outliers>(halftone?.2:.01))continue;
            const nearby=[evaluate(dx+4,dy,samples),evaluate(dx,dy+4,samples)].filter(Boolean);
            if(nearby.length<2||nearby.some(p=>p.error<q.error*(halftone?1.25:1.5)+1))continue;
            refined.push(q);
          }})();
          refined.sort((a,b)=>a.error-b.error||(halftone?Math.hypot(a.dx,a.dy)-Math.hypot(b.dx,b.dy):0));
          const vectors=[];
          // Equal-error horizontal periods must not crowd out the independent
          // vertical/diagonal witness needed to continue a two-dimensional tone.
          if(halftone&&refined.length){const first=refined[0];
            const independent=refined.find(v=>Math.abs(v.dx*first.dy-v.dy*first.dx)>Math.hypot(v.dx,v.dy)*Math.hypot(first.dx,first.dy)*.2);
            if(independent)vectors.push(first,independent);
          }
          (()=>{for(const v of refined){
            if(vectors.some(q=>Math.hypot(q.dx-v.dx,q.dy-v.dy)<6))continue;
            vectors.push(v);if(vectors.length===6)break;
          }})();
          if(vectors.length<2||!vectors.some(v=>Math.abs(v.dx*vectors[0].dy-v.dy*vectors[0].dx)>
              Math.hypot(v.dx,v.dy)*Math.hypot(vectors[0].dx,vectors[0].dy)*.2))return null;
          const shifts=[];
          (()=>{for(const v of vectors)for(const scale of [1,-1,2,-2,3,-3,4,-4])shifts.push({dx:v.dx*scale,dy:v.dy*scale,error:v.error*Math.abs(scale)});})();
          // A diagonal period and a horizontal period together can reach an
          // exposed row even when a whole dialogue line hides its own row.
          (()=>{for(const shift of shifts.slice())for(const scale of [-2,-1,1,2]){
            const dx=shift.dx+vectors[0].dx*scale,dy=shift.dy+vectors[0].dy*scale;
            if(Math.abs(dx)<w-6&&Math.abs(dy)<h-6&&!shifts.some(v=>v.dx===dx&&v.dy===dy))
              shifts.push({dx,dy,error:shift.error+vectors[0].error*Math.abs(scale)});
          }})();
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
              const da=donors[a]*4,db=donors[b]*4,agreement=halftone?24:6;
              if(Math.abs(rgba[da]-rgba[db])<=agreement&&Math.abs(rgba[da+1]-rgba[db+1])<=agreement&&Math.abs(rgba[da+2]-rgba[db+2])<=agreement){const shade=Math.abs((rgba[donors[a]*4+1]+rgba[donors[b]*4+1])/2-tone);if(shade<pairShade){pair=[donors[a],donors[b]];pairShade=shade;}if(!halftone)break;}
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
          const kernels=typeof aidokuPixelKernels==='function'&&rgba.length===n*4&&mask.length===n&&protectedInk.length===n&&
            palette.foreground.slice(0,3).every(Number.isFinite)&&surface.coefficients.every(a=>a.slice(0,3).every(Number.isFinite))?
            aidokuPixelKernels(n*44+(w+h)*8+8192):null;
          if(kernels) {
            // Same donor scan, patch priorities, matching and fill in WebAssembly (Float32 residuals, Float64 arithmetic).
            const forbidden=protectedInk.slice();(()=>{for(const points of textureComponents)for(const i of points)forbidden[i]=0;})();
            // work reuses the rgba copy (read only before the patch loop).
            const at=kernels.heap,maskAt=at+n*4,forbiddenAt=maskAt+n,workAt=at,pendingAt=forbiddenAt+n;
            const residualAt=(pendingAt+n+7)&~7,filledAt=residualAt+n*12,integralAt=filledAt+n*12,outputAt=integralAt+(w+1)*(h+1)*4;
            const donorsAt=outputAt+n*4,cellAt=(donorsAt+n+64+7)&~7,gridXAt=(cellAt+n*2+64+3)&~3,gridYAt=gridXAt+w*4,fgAt=(gridYAt+h*4+7)&~7;
            const coefficientsAt=fgAt+24,statsAt=coefficientsAt+72,buffer=kernels.memory.buffer;
            new Uint8Array(buffer,at,n*4).set(rgba);new Uint8Array(buffer,maskAt,n).set(mask);new Uint8Array(buffer,forbiddenAt,n).set(forbidden);
            new Float64Array(buffer,fgAt,3).set(palette.foreground.slice(0,3));
            new Float64Array(buffer,coefficientsAt,9).set(surface.coefficients.flatMap(a=>a.slice(0,3)));
            const ok=kernels.exports.exemplar_fill(at,w,h,maskAt,forbiddenAt,fgAt,coefficientsAt,erased,workAt,pendingAt,residualAt,filledAt,
              integralAt,outputAt,donorsAt,cellAt,gridXAt,gridYAt,statsAt);
            if(!ok)return null;
            const stats=new Float64Array(buffer,statsAt,7),filledValues=new Float32Array(buffer,filledAt,n*3);
            let resultSquares=0;(()=>{for(let i=0;i<n;i++)if(mask[i])resultSquares+=filledValues[i*3+1]**2;})();
            const textureRatio=Math.sqrt((resultSquares/erased)/(stats[5]/stats[6]));
            if(textureRatio<.5||textureRatio>1.8)return null;
            return {rgba:new Uint8ClampedArray(buffer.slice(outputAt,outputAt+n*4)),erased,patches:stats[0],maxError:stats[1],
              comparisons:stats[2],operations:stats[3],donors:stats[4],textureRatio};
          }
          const output=new Uint8ClampedArray(n*4),work=rgba.slice(),pending=mask.slice();
          const residual=new Float32Array(n*3);
          (()=>{for(let i=0;i<n;i++)for(let c=0;c<3;c++){const a=surface.coefficients[c];residual[i*3+c]=rgba[i*4+c]-(a[0]+a[1]*(i%w)/w+a[2]*(i/w|0)/h);}})();
          const filled=residual.slice();
          const forbidden=protectedInk.slice();(()=>{for(const points of textureComponents)for(const i of points)forbidden[i]=0;})();
          const integral=new Int32Array((w+1)*(h+1));
          (()=>{for(let y=0;y<h;y++){let row=0;for(let x=0;x<w;x++){row+=Boolean(mask[y*w+x]||forbidden[y*w+x]);integral[(y+1)*(w+1)+x+1]=integral[y*(w+1)+x+1]+row;}}})();
          const box=(x,y)=>integral[(y+r+1)*(w+1)+x+r+1]-integral[(y-r)*(w+1)+x+r+1]-integral[(y+r+1)*(w+1)+x-r]+integral[(y-r)*(w+1)+x-r];
          const donors=[];let donorSquares=0,donorCount=0,activePatches=0;
          (()=>{for(let y=r+1;y<h-r-1;y+=2)for(let x=r+1;x<w-r-1;x+=2){
            if(box(x,y))continue;let bad=0;
            for(let yy=y-r;yy<=y+r;yy++)for(let xx=x-r;xx<=x+r;xx++){
              const i=(yy*w+xx)*4,dr=rgba[i]-palette.foreground[0],dg=rgba[i+1]-palette.foreground[1],db=rgba[i+2]-palette.foreground[2];
              if(dr<48&&dr>-48&&dg<48&&dg>-48&&db<48&&db>-48)bad++;
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
          }})();
          if(donors.length<24||activePatches<donors.length*.4||donorSquares/donorCount<9)return null;
          const sample=donors.filter((_,i)=>i%Math.max(1,Math.ceil(donors.length/192))===0);
          let patches=0,maxError=0;
          // Boundary-patch priorities on the stride-2 grid. A fill changes
          // pending and work only within r of its centre, so only cells
          // within 2r are re-evaluated; each scan still counts its 25 window
          // reads per candidate cell in `operations`.
          const gridX=[],gridY=[];
          (()=>{for(let x=r+1;x<w-r-1;x+=2)gridX.push(x);})();
          (()=>{for(let y=r+1;y<h-r-1;y+=2)gridY.push(y);})();
          const gridW=gridX.length,gridH=gridY.length,cellValue=new Float64Array(gridW*gridH);let candidates=0;
          const patchPriority=(gx,gy)=>{
            const i=gridY[gy]*w+gridX[gx];
            if(!pending[i]||pending[i-1]&&pending[i+1]&&pending[i-w]&&pending[i+w])return -1;
            let count=0,lo=255,hi=0;
            for(let dy=-r;dy<=r;dy+=2)for(let dx=-r;dx<=r;dx+=2){
              const j=i+dy*w+dx;if(pending[j])continue;count++;lo=Math.min(lo,work[j*4+1]);hi=Math.max(hi,work[j*4+1]);
            }
            return count*(1+Math.min(hi-lo,80)/80);
          };
          (()=>{for(let gy=0,g=0;gy<gridH;gy++)for(let gx=0;gx<gridW;gx++,g++){
            const value=patchPriority(gx,gy);cellValue[g]=value;if(value>=0)candidates++;
          }})();
          const knownOffset=new Int32Array((2*r+1)*(2*r+1)),knownPixel=new Int32Array((2*r+1)*(2*r+1));
          while(left){
            if(++patches>1200)return null;
            if(operations+25*candidates>24000000)return null;
            operations+=25*candidates;
            // High-confidence boundary patches first; gradients prefer continuous edges.
            let at=-1,priority=-1;
            for(let g=0;g<cellValue.length;g++)if(cellValue[g]>priority){priority=cellValue[g];at=gridY[(g/gridW)|0]*w+gridX[g%gridW];}
            if(at<0){at=pending.findIndex(v=>v);if(at<0)break;}
            const ax=at%w,ay=at/w|0;
            if(ax<r||ay<r||ax>=w-r||ay>=h-r)return null;
            let known=0;
            for(let dy=-r;dy<=r;dy++)for(let dx=-r;dx<=r;dx++){
              const j=at+dy*w+dx;if(!pending[j]){knownOffset[known]=dy*w+dx;knownPixel[known]=j;known++;}
            }
            if(known<12)return null;
            let best=-1,error=Infinity;
            for(const donor of sample){
              let s=0;
              for(let k=0;k<known;k++){
                const q=donor+knownOffset[k],j=knownPixel[k];
                for(let c=0;c<3;c++){const d=filled[j*3+c]-residual[q*3+c];s+=d*d;}
                comparisons++;if(++operations>24000000)return null;
                if(s>error)break;
              }
              if(s<error){error=s;best=donor;}
            }
            const rmse=Math.sqrt(error/(known*3));maxError=Math.max(maxError,rmse);
            if(best<0||rmse>24)return null;
            for(let dy=-r;dy<=r;dy++)for(let dx=-r;dx<=r;dx++){
              const j=at+dy*w+dx;if(!pending[j])continue;const q=(best+dy*w+dx)*4;
              for(let c=0;c<3;c++){
                const a=surface.coefficients[c],v=residual[(q/4)*3+c];filled[j*3+c]=v;
                output[j*4+c]=work[j*4+c]=v+a[0]+a[1]*(j%w)/w+a[2]*(j/w|0)/h;
              }output[j*4+3]=255;pending[j]=0;left--;
            }
            const gx0=Math.max(0,Math.ceil((ax-2*r-(r+1))/2)),gx1=Math.min(gridW-1,Math.floor((ax+2*r-(r+1))/2));
            const gy0=Math.max(0,Math.ceil((ay-2*r-(r+1))/2)),gy1=Math.min(gridH-1,Math.floor((ay+2*r-(r+1))/2));
            for(let gy=gy0;gy<=gy1;gy++)for(let gx=gx0;gx<=gx1;gx++){
              const g=gy*gridW+gx,value=patchPriority(gx,gy);
              if(cellValue[g]>=0)candidates--;if(value>=0)candidates++;cellValue[g]=value;
            }
          }
          let resultSquares=0;(()=>{for(let i=0;i<n;i++)if(mask[i])resultSquares+=filled[i*3+1]**2;})();
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
        // Thick outlines can join several vertical characters into one long
        // component. Repeated enclosed glyph interiors distinguish that run
        // from a frame or illustration contour; length alone cannot do so.
        function aidokuConnectedOutlineRun(rgba,w,b,palette,points,box) {
          const [x0,y0,x1,y1]=box,height=y1-y0+1,width=x1-x0+1,cross=Math.min(b[2],width*1.25);
          if(height<cross*1.6||width>cross*1.1||x0<b[0]-3||x1>b[0]+b[2]+3||
              y0<b[1]-3||y1>b[1]+b[3]+3||points.length>width*height*.72||
              (palette.confidence?.foreground||0)<.6)return false;
          const localWidth=width+2,localHeight=height+2,n=localWidth*localHeight;
          if(n>262144)return false;
          const samples=[[],[],[]],stride=Math.max(1,Math.ceil(points.length/256));
          for(let k=0;k<points.length;k+=stride)for(let c=0;c<3;c++)samples[c].push(rgba[points[k]*4+c]);
          const edgeColor=samples.map(values=>values.sort((a,b)=>a-b)[values.length>>1]);
          if(![palette.foreground,palette.stroke,palette.sourceInk?.foreground,palette.sourceInk?.stroke]
              .some(color=>color&&Math.max(...color.map((v,c)=>Math.abs(v-edgeColor[c])))<=32))return false;
          const wall=new Uint8Array(n),seen=new Uint8Array(n),queue=new Int32Array(n);
          for(const i of points)wall[((i/w|0)-y0+1)*localWidth+i%w-x0+1]=1;
          let holes=0,minY=Infinity,maxY=-Infinity;const bands=new Set();
          for(let start=0;start<n;start++){
            if(wall[start]||seen[start])continue;
            let head=0,tail=1,l=localWidth,t=localHeight,r=0,bottom=0,edge=false,distinct=0;
            queue[0]=start;seen[start]=1;
            while(head<tail){
              const i=queue[head++],x=i%localWidth,y=i/localWidth|0;
              l=Math.min(l,x);r=Math.max(r,x);t=Math.min(t,y);bottom=Math.max(bottom,y);
              if(x===0||y===0||x===localWidth-1||y===localHeight-1)edge=true;
              else {
                const p=((y+y0-1)*w+x+x0-1)*4;
                if(Math.max(...edgeColor.map((v,c)=>Math.abs(v-rgba[p+c])))>=48)distinct++;
              }
              for(const [xx,yy] of [[x-1,y],[x+1,y],[x,y-1],[x,y+1]]){
                if(xx<0||yy<0||xx>=localWidth||yy>=localHeight)continue;
                const j=yy*localWidth+xx;if(wall[j]||seen[j])continue;seen[j]=1;queue[tail++]=j;
              }
            }
            if(edge||tail<6||r-l<2||bottom-t<2||r-l>cross||bottom-t>cross*1.5||distinct<tail*.7)continue;
            const cy=(t+bottom)/2;holes++;minY=Math.min(minY,cy);maxY=Math.max(maxY,cy);
            bands.add(Math.floor(cy/Math.max(4,cross*.6)));
          }
          return holes>=2&&bands.size>=2&&maxY-minY>=height*.45;
        }
        // The per-pixel passes below live in small functions so that the
        // engine's optimizing tiers can compile them; the large restoration
        // body only sequences them. Each keeps the original visiting order.
        function aidokuRestorationOpaque(rgba) {
          for(let q=3;q<rgba.length;q+=4)if(rgba[q]<254)return false;
          return true;
        }
        // First index >= from that is set in `on` and not yet seen, or n.
        function aidokuNextSeed(on,seen,from,n) {
          for(let i=from;i<n;i++)if(on[i]&&!seen[i])return i;
          return n;
        }
        // Queue every mask pixel in raster order; returns the count.
        function aidokuMaskQueue(mask,queue,n) {
          let tail=0;for(let i=0;i<n;i++)if(mask[i])queue[tail++]=i;
          return tail;
        }
        function aidokuMaskCount(mask,n) {
          let count=0;for(let i=0;i<n;i++)count+=mask[i];
          return count;
        }
        // [masked pixels, masked raw-ink pixels]
        function aidokuCountPreserved(mask,raw,n) {
          let pixels=0,core=0;
          for(let i=0;i<n;i++)if(mask[i]){pixels++;if(raw[i])core++;}
          return [pixels,core];
        }
        // Protected, non-frame ink within the OCR rectangle's pixel span.
        function aidokuCountUnresolvedInk(protectedInk,frameInk,w,b) {
          let unresolved=0;
          for(let y=Math.floor(b[1]);y<Math.ceil(b[1]+b[3]);y++)for(let x=Math.floor(b[0]);x<Math.ceil(b[0]+b[2]);x++)
            if(protectedInk[y*w+x]&&!frameInk[y*w+x])unresolved++;
          return unresolved;
        }
        // A resampled contour can leave a non-core antialias pixel just inside
        // the OCR edge. Keep it with its already protected, crop-connected
        // frame instead of treating it as an unerased character. This changes
        // ownership only: no frame pixel enters the restoration mask.
        function aidokuPreserveFrameFringe(rgba,w,h,b,background,raw,mask,protectedInk,frameInk) {
          const pending=[];
          for(let y=Math.max(1,Math.floor(b[1]));y<Math.min(h-1,Math.ceil(b[1]+b[3]));y++)
            for(let x=Math.max(1,Math.floor(b[0]));x<Math.min(w-1,Math.ceil(b[0]+b[2]));x++){
              if(x>=b[0]+3&&x<b[0]+b[2]-3&&y>=b[1]+3&&y<b[1]+b[3]-3)continue;
              const i=y*w+x;
              if(!protectedInk[i]||raw[i]||mask[i]||frameInk[i])continue;
              let support=0,neighbors=0;
              for(let yy=y-1;yy<=y+1;yy++)for(let xx=x-1;xx<=x+1;xx++){
                const j=yy*w+xx;if(!frameInk[j]||!raw[j]||mask[j])continue;
                neighbors++;
                if(aidokuRestorationBlendAt(rgba[i*4],rgba[i*4+1],rgba[i*4+2],
                    background[0],background[1],background[2],rgba.subarray(j*4,j*4+3)))support++;
              }
              if(neighbors>=2&&support>=1)pending.push(i);
            }
          // One ring only; newly classified fringe cannot recruit more pixels.
          for(const i of pending)frameInk[i]=1;
          return pending.length;
        }
        // [frame-ink pixels, pixels] of the OCR rectangle inset by three.
        function aidokuFrameInterior(frameInk,w,b) {
          let frameInterior=0,innerArea=0;
          for(let y=Math.ceil(b[1]+3);y<Math.floor(b[1]+b[3]-3);y++)for(let x=Math.ceil(b[0]+3);x<Math.floor(b[0]+b[2]-3);x++){
            innerArea++;if(frameInk[y*w+x])frameInterior++;
          }
          return [frameInterior,innerArea];
        }
        function aidokuRectHasInk(protectedInk,frameInk,w,r) {
          for(let y=Math.floor(r[1]);y<Math.ceil(r[1]+r[3]);y++)for(let x=Math.floor(r[0]);x<Math.ceil(r[0]+r[2]);x++)
            if(protectedInk[y*w+x]||frameInk[y*w+x])return true;
          return false;
        }
        // Surviving ink and connected drawing constrain the translated text.
        function aidokuLayoutSafe(protectedInk,drawingSurface,n) {
          const layoutSafe=new Uint8Array(n);
          for(let i=0;i<n;i++)if(!protectedInk[i]&&!drawingSurface?.[i])layoutSafe[i]=1;
          return layoutSafe;
        }
        // Extrapolated planes must use the same finite RGB gamut as the
        // Uint8ClampedArray restoration. Values outside [0,255] are not colors
        // and must not make unchanged white/black paper fail exterior checks.
        function aidokuSurfacePlaneRGB(coefficients,x,y) {
          return coefficients.map(a=>Math.max(0,Math.min(255,a[0]+a[1]*x+a[2]*y)));
        }
        // Paint the fitted RGB plane into every mask pixel.
        function aidokuPlaneFill(mask,coefficients,w,h) {
          const n=w*h,output=new Uint8ClampedArray(n*4);
          for(let i=0;i<n;i++){
            if(!mask[i])continue;
            const x=(i%w)/w,y=(i/w|0)/h;
            for(let c=0;c<3;c++){
              const a=coefficients[c];output[i*4+c]=a[0]+a[1]*x+a[2]*y;
            }
            output[i*4+3]=255;
          }
          return output;
        }
        // Eight-connected flood of `on` pixels from start. Returns the component
        // size (its pixels are queue[0..size)) and writes [x0,y0,x1,y1] to bounds.
        function aidokuFloodComponent(on,seen,queue,start,w,h,bounds) {
          let head=0,tail=1,x0=w,y0=h,x1=0,y1=0;queue[0]=start;seen[start]=1;
          while(head<tail){
            const i=queue[head++],x=i%w,y=i/w|0;x0=Math.min(x0,x);y0=Math.min(y0,y);x1=Math.max(x1,x);y1=Math.max(y1,y);
            const yEnd=Math.min(h-1,y+1),xStart=Math.max(0,x-1),xEnd=Math.min(w-1,x+1);
            for(let yy=Math.max(0,y-1);yy<=yEnd;yy++)for(let xx=xStart;xx<=xEnd;xx++){const j=yy*w+xx;if(on[j]&&!seen[j]){seen[j]=1;queue[tail++]=j;}}
          }
          bounds[0]=x0;bounds[1]=y0;bounds[2]=x1;bounds[3]=y1;
          return tail;
        }
        // Frame-connected drawing grows through darker-than-paper pixels. Those
        // pixels leave the glyph mask; raw ink among them becomes protected frame ink.
        function aidokuGrowDrawingSupport(p,w,h,threshold,frameInk,raw,mask,seedRadius,protectedInk,queue) {
          const n=w*h,support=new Uint8Array(n);
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
          return support;
        }
        // Block donors within eight rings of protected ink.
        function aidokuBlockProtectedDonors(protectedInk,w,h,queue) {
          const n=w*h,donorBlocked=protectedInk.slice(),donorDistance=new Uint8Array(n);
          let donorTail=0;
          for(let i=0;i<n;i++)if(protectedInk[i])queue[donorTail++]=i;
          for(let head=0;head<donorTail;head++){
            const i=queue[head],x=i%w,y=i/w|0;if(donorDistance[i]>=8)continue;
            for(let yy=Math.max(0,y-1);yy<=Math.min(h-1,y+1);yy++)for(let xx=Math.max(0,x-1);xx<=Math.min(w-1,x+1);xx++){
              const j=yy*w+xx;if(donorBlocked[j])continue;
              donorBlocked[j]=1;donorDistance[j]=donorDistance[i]+1;queue[donorTail++]=j;
            }
          }
          return {donorBlocked,donorDistance};
        }
        // Bounded dilation of the owned glyph mask from queue[0..tail).
        // Returns the grown queue length; flags[0] is set when a halo was followed.
        function aidokuDilateOwnedMask(p,w,h,queue,tail,mask,distance,seedRadius,protectedInk,drawingSurface,donorBlocked,donorDistance,
            protectArtMargin,followHalo,preciseFringe,radius,background,strokeBackgroundBlend,flags,glyphMargin=Infinity,foreground=null,owned=[]) {
          // Light end of the ink-to-backing ramp: the glyphs' soft outer fringe.
          const f0=foreground?.[0],f1=foreground?.[1],f2=foreground?.[2],g0=background[0],g1=background[1],g2=background[2];
          const d0=f0-g0,d1=f1-g1,d2=f2-g2,length=foreground?d0*d0+d1*d1+d2*d2:0;
          let known=null;
          const plain=j=>{
            if(!known)known=new Uint8Array(w*h);
            if(known[j])return known[j]===1;
            known[j]=plainAt(j)?1:2;return known[j]===1;
          };
          const plainAt=j=>{
            const r=p[j*4],g=p[j*4+1],bl=p[j*4+2];
            if(Math.max(Math.abs(r-g0),Math.abs(g-g1),Math.abs(bl-g2))<=24)return true;
            if(length<1600)return false;
            const t=((r-g0)*d0+(g-g1)*d1+(bl-g2)*d2)/length;
            return t<=.5&&Math.max(Math.abs(r-g0-t*d0),Math.abs(g-g1-t*d1),Math.abs(bl-g2-t*d2))<=24;
          };
          // Artwork = connected non-plain structure outside the owned rectangles
          // at least half a glyph long; specks and small marks stay erasable.
          // Each query floods only until that extent is reached (cached).
          let art=null,stack=null,visit=null,stamp=0;
          const artAt=j=>{
            if(!art){art=new Uint8Array(w*h);stack=new Int32Array(w*h);visit=new Int32Array(w*h);}
            if(art[j])return art[j]===1;
            if(plain(j))return false;
            const reach=Math.max(6,glyphMargin*1.5);stamp++;
            let top=0,count=0,x0=w,y0=h,x1=0,y1=0,long=false;stack[top++]=j;visit[j]=stamp;
            while(top&&!long){const i=stack[--top],x=i%w,y=i/w|0;stack[w*h-1-count++]=i;
              if(x<x0)x0=x;if(x>x1)x1=x;if(y<y0)y0=y;if(y>y1)y1=y;
              if(Math.max(x1-x0,y1-y0)+1>=reach||art[i]===1){long=true;break;}
              for(let yy=Math.max(0,y-1);yy<=Math.min(h-1,y+1);yy++)for(let xx=Math.max(0,x-1);xx<=Math.min(w-1,x+1);xx++){
                const k=yy*w+xx;if(visit[k]!==stamp&&!inside[k]&&!plain(k)){visit[k]=stamp;stack[top++]=k;}}}
            // Visited pixels share the verdict (an unfinished flood of a long
            // component has only visited that component).
            for(let c=0;c<count;c++)art[stack[w*h-1-c]]=long?1:2;
            return long;
          };
          // Owned rectangles (+2 px) as a map: the rule applies outside them.
          let inside=null;
          if(glyphMargin<Infinity){inside=new Uint8Array(w*h);
            (()=>{for(const r of owned)for(let y=Math.max(0,Math.ceil(r[1]-2));y<Math.min(h,Math.ceil(r[1]+r[3]+2));y++)
              for(let x=Math.max(0,Math.ceil(r[0]-2));x<Math.min(w,Math.ceil(r[0]+r[2]+2));x++)inside[y*w+x]=1;})();}
          (()=>{for(let head=0;head<tail;head++){
            const i=queue[head],x=i%w,y=i/w|0,atLimit=distance[i]>=seedRadius[i];
            if(atLimit&&(!followHalo||distance[i]>=Math.min(20,seedRadius[i]+(preciseFringe?12:8))))continue;
            // Past the lettering's own fringe (a third of a glyph), outside the
            // owned rectangles, the margin only takes plain backing (a halo the
            // estimator reads as paper) or the light half of the ink ramp (soft
            // print and codec halos).
            // Screentone, hatching, a balloon edge or a coloured shape there is
            // artwork beside the text, never part of the erasure.
            const wide=!atLimit&&distance[i]>=glyphMargin;
            const yEnd=Math.min(h-2,y+1),xStart=Math.max(1,x-1),xEnd=Math.min(w-2,x+1);
            for(let yy=Math.max(1,y-1);yy<=yEnd;yy++)for(let xx=xStart;xx<=xEnd;xx++){
              const j=yy*w+xx;
              // Keep the art margin, but include the immediate antialiased edge of
              // already owned lettering when it stays at least three pixels from art.
              const ownedFringe=distance[i]<2&&donorDistance[j]>=3;
              if(mask[j]||protectedInk[j]||drawingSurface?.[j]||(protectArtMargin&&donorBlocked[j]&&!ownedFringe))continue;
              // That artwork is not a fill donor either: it stays as it is.
              if(wide&&!inside[j]&&artAt(j)){donorBlocked[j]=1;continue;}
              if(atLimit){
                // Measured stroke width can miss its antialiased outer fringe. Follow
                // only the observed stroke-to-backing color ramp, with a hard distance
                // cap; widening every glyph would blur nearby illustration instead.
                if(donorBlocked[j])continue;
                const pr=p[j*4],pg=p[j*4+1],pb=p[j*4+2];
                if(aidokuRestorationDistance(pr,pg,pb,background)<(preciseFringe?8:12)||!strokeBackgroundBlend(pr,pg,pb))continue;
                flags[0]=1;
              }
              // Neighbor offsets are in {-1,0,1}: a length above 1.1 means diagonal.
              if(xx!==x&&yy!==y&&distance[i]>radius-2)continue;
              mask[j]=1;distance[j]=distance[i]+1;seedRadius[j]=seedRadius[i];queue[tail++]=j;
            }
          }})();
          return tail;
        }
        // Follow the stroke-to-backing ramp one four-neighbor at a time against
        // the fitted plane, up to each seed's fringe limit. Returns the queue length.
        function aidokuFollowPlanarHalo(p,w,h,queue,tail,mask,distance,seedRadius,donorBlocked,drawingSurface,coefficients,stroke,preciseFringe) {
          for(let head=0;head<tail;head++){
            const i=queue[head],x=i%w,y=i/w|0;
            if(distance[i]>=Math.min(20,seedRadius[i]+(preciseFringe?12:8)))continue;
            for(let k=0;k<4;k++){
              const xx=k===0?x-1:k===1?x+1:x,yy=k===2?y-1:k===3?y+1:y;
              if(xx<1||yy<1||xx>=w-1||yy>=h-1)continue;
              const j=yy*w+xx;if(mask[j]||donorBlocked[j]||drawingSurface?.[j])continue;
              const q0=coefficients[0],q1=coefficients[1],q2=coefficients[2];
              const e0=q0[0]+q0[1]*xx/w+q0[2]*yy/h,e1=q1[0]+q1[1]*xx/w+q1[2]*yy/h,e2=q2[0]+q2[1]*xx/w+q2[2]*yy/h;
              const pr=p[j*4],pg=p[j*4+1],pb=p[j*4+2];
              if(Math.max(Math.abs(pr-e0),Math.abs(pg-e1),Math.abs(pb-e2))<(preciseFringe?8:18)||
                  !(stroke&&aidokuRestorationBlendAt(pr,pg,pb,e0,e1,e2,stroke)))continue;
              mask[j]=1;distance[j]=distance[i]+1;seedRadius[j]=seedRadius[i];queue[tail++]=j;
            }
          }
          return tail;
        }
        // One extra ring around confirmed body lettering on a clean plane. Only
        // queue[0..priorTail) seeds it; ruby margins are excluded. Returns the queue length.
        function aidokuExpandPlanarRing(p,w,h,queue,priorTail,mask,distance,seedRadius,donorBlocked,drawingSurface,rubyMargins,coefficients,foreground,stroke) {
          let tail=priorTail;
          for(let k=0;k<priorTail;k++){
            const i=queue[k];if(distance[i]<seedRadius[i])continue;
            const x=i%w,y=i/w|0;
            for(let yy=y-1;yy<=y+1;yy++)for(let xx=x-1;xx<=x+1;xx++){
              if(xx<1||xx>=w-1||yy<1||yy>=h-1)continue;
              const j=yy*w+xx;if(mask[j]||donorBlocked[j]||drawingSurface?.[j])continue;
              let rubyMargin=false;
              for(const r of rubyMargins)if(xx>=r[0]&&xx<=r[2]&&yy>=r[1]&&yy<=r[3]){rubyMargin=true;break;}
              if(rubyMargin)continue;
              const q0=coefficients[0],q1=coefficients[1],q2=coefficients[2];
              const e0=q0[0]+q0[1]*xx/w+q0[2]*yy/h,e1=q1[0]+q1[1]*xx/w+q1[2]*yy/h,e2=q2[0]+q2[1]*xx/w+q2[2]*yy/h;
              const pr=p[j*4],pg=p[j*4+1],pb=p[j*4+2],error=Math.max(Math.abs(pr-e0),Math.abs(pg-e1),Math.abs(pb-e2));
              if(error<4||!aidokuRestorationBlendAt(pr,pg,pb,e0,e1,e2,foreground)&&
                  !(stroke&&aidokuRestorationBlendAt(pr,pg,pb,e0,e1,e2,stroke)))continue;
              mask[j]=1;distance[j]=distance[i]+1;seedRadius[j]=seedRadius[i];queue[tail++]=j;
            }
          }
          return tail;
        }
        // Fill enclosed, palette-matched holes of the mask. Returns the rebuilt
        // queue length of mask pixels.
        function aidokuFillEnclosedHoles(p,w,h,b,mask,queue,protectedInk,drawingSurface,stroke,background,inkStrokeBlend,strokeBackgroundBlend) {
          const n=w*h,exterior=new Uint8Array(n);let end=0;
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
              const i=queue[head++],x=i%w,y=i/w|0,pr=p[i*4],pg=p[i*4+1],pb=p[i*4+2];
              if(x<b[0]||x>b[0]+b[2]||y<b[1]||y>b[1]+b[3]||protectedInk[i]||drawingSurface?.[i]||
                  aidokuRestorationDistance(pr,pg,pb,stroke)>24&&aidokuRestorationDistance(pr,pg,pb,background)>24&&
                  !inkStrokeBlend(pr,pg,pb)&&!strokeBackgroundBlend(pr,pg,pb))owned=false;
              for(let k=0;k<4;k++){
                const j=k===0?i-1:k===1?i+1:k===2?i-w:i+w;
                if(j>=0&&j<n&&!mask[j]&&!exterior[j]){exterior[j]=1;queue[end++]=j;}
              }
            }
            if(owned&&end<=b[2]*b[3]*.15)for(let k=0;k<end;k++)mask[queue[k]]=1;
          }
          let tail=0;for(let i=0;i<n;i++)if(mask[i])queue[tail++]=i;
          return tail;
        }
        // Fill masked pixels ring by ring from the average of their valid
        // four-neighbors (left, right, up, down). Unreachable pixels stay masked.
        function aidokuFillFromDonorFront(p,w,n,queue,tail,mask,donorBlocked,paintMask) {
          const queued=new Uint8Array(n);let frontier=[];
          const neighbor=(i,k)=>k===0?i-1:k===1?i+1:k===2?i-w:i+w;
          const donorAt=j=>!mask[j]&&(!donorBlocked[j]||paintMask[j]);
          for(let k=0;k<tail;k++){const i=queue[k];if(donorAt(i-1)||donorAt(i+1)||donorAt(i-w)||donorAt(i+w)){frontier.push(i);queued[i]=1;}}
          while(frontier.length){
            const rgb=new Float32Array(frontier.length*3);
            for(let k=0;k<frontier.length;k++){
              const i=frontier[k];let count=0,sum0=0,sum1=0,sum2=0;
              for(let d=0;d<4;d++){const j=neighbor(i,d);if(!donorAt(j))continue;count++;sum0+=p[j*4];sum1+=p[j*4+1];sum2+=p[j*4+2];}
              rgb[k*3]=sum0/count;rgb[k*3+1]=sum1/count;rgb[k*3+2]=sum2/count;
            }
            for(let k=0;k<frontier.length;k++){const i=frontier[k];for(let c=0;c<3;c++)p[i*4+c]=rgb[k*3+c];mask[i]=0;}
            const next=[];for(const i of frontier)for(let d=0;d<4;d++){const j=neighbor(i,d);if(mask[j]&&!queued[j]){queued[j]=1;next.push(j);}}frontier=next;
          }
        }
        // Contaminated donor front on a verified planar surface: front donors
        // (unmasked, unblocked pixels next to the painted queue) off the fitted
        // plane by more than max(16, 3x the median front residual) whose tint
        // does not continue across the erased region. Marching from the donor
        // through the painted pixels, the first pixel beyond them must be an
        // unblocked donor with a similar plane residual (a shading band or a
        // crossing gradient); otherwise the donor is the antialiased fringe of
        // an outline, a rule, a tone band or a neighbouring caption, which the
        // front fill would drag across the whole interior. Returns their indices.
        function aidokuContaminatedFrontDonors(p,w,h,queue,tail,donorBlocked,paintMask,coefficients,strokes=[],inks=[]) {
          const n=w*h,q0=coefficients[0],q1=coefficients[1],q2=coefficients[2];
          const residual=(i,c)=>{
            const x=(i%w)/w,y=(i/w|0)/h,a=c===0?q0:c===1?q1:q2;
            return p[i*4+c]-(a[0]+a[1]*x+a[2]*y);
          };
          const size=i=>Math.max(Math.abs(residual(i,0)),Math.abs(residual(i,1)),Math.abs(residual(i,2)));
          const seen=new Uint8Array(n),front=[],errors=[],inward=[];
          (()=>{for(let k=0;k<tail;k++){
            const i=queue[k],x=i%w;
            for(let d=0;d<4;d++){
              if(d===0&&x===0||d===1&&x===w-1)continue;
              const j=d===0?i-1:d===1?i+1:d===2?i-w:i+w;
              if(j<0||j>=n||seen[j]||paintMask[j]||donorBlocked[j])continue;
              // Direction from the donor into the painted region.
              seen[j]=1;front.push(j);errors.push(size(j));inward.push(d===0?1:d===1?-1:d===2?w:-w);
            }
          }})();
          if(!front.length)return [];
          const sorted=errors.slice().sort((a,b)=>a-b),tolerance=Math.max(16,sorted[sorted.length>>1]*3),out=[];
          out.specks=[];
          (()=>{for(let k=0;k<front.length;k++){
            if(errors[k]<=tolerance)continue;
            const j=front[k],step=inward[k],horizontal=Math.abs(step)===1;
            // The measured contrasting outline of the lettering keeps its
            // established donor role (its fringe is handled by the outline guard).
            if(strokes.some(ink=>aidokuRestorationDistance(p[j*4],p[j*4+1],p[j*4+2],ink)<=24))continue;
            let at=j+step,continued=false;
            while(at>=0&&at<n&&paintMask[at]&&(!horizontal||(at-step)%w!==(step>0?w-1:0)))at+=step;
            if(at>=0&&at<n&&!paintMask[at]&&!donorBlocked[at]&&(!horizontal||Math.abs(at%w-(at-step)%w)===1)){
              continued=true;
              for(let c=0;c<3;c++){
                const r=residual(j,c),o=residual(at,c);
                if(Math.abs(r-o)>Math.max(12,Math.abs(r)*.4)){continued=false;break;}
              }
            }
            if(continued)continue;
            // A smooth surface feature (a soft gradient step) is not a fringe:
            // require an edge among the unpainted 3x3 neighbours (range >= 24),
            // or a tint toward the lettering ink (a blurred ink or outline fringe).
            const r0=residual(j,0),r1=residual(j,1),r2=residual(j,2);
            const inkward=inks.some(ink=>{
              const x=(j%w)/w,y=(j/w|0)/h,d0=ink[0]-(q0[0]+q0[1]*x+q0[2]*y),d1=ink[1]-(q1[0]+q1[1]*x+q1[2]*y),
                d2=ink[2]-(q2[0]+q2[1]*x+q2[2]*y),length=d0*d0+d1*d1+d2*d2;
              if(length<1600)return false;
              const t=(r0*d0+r1*d1+r2*d2)/length;
              return t>=.12&&Math.max(Math.abs(r0-t*d0),Math.abs(r1-t*d1),Math.abs(r2-t*d2))<=Math.max(12,errors[k]*.5);
            });
            if(!inkward){
              const x=j%w,y=j/w|0,lo=[255,255,255],hi=[0,0,0];
              for(let yy=Math.max(0,y-1);yy<=Math.min(h-1,y+1);yy++)for(let xx=Math.max(0,x-1);xx<=Math.min(w-1,x+1);xx++){
                const m=yy*w+xx;if(paintMask[m])continue;
                for(let c=0;c<3;c++){lo[c]=Math.min(lo[c],p[m*4+c]);hi[c]=Math.max(hi[c],p[m*4+c]);}
              }
              if(Math.max(hi[0]-lo[0],hi[1]-lo[1],hi[2]-lo[2])<24)continue;
            }
            out.push(j);
            // Paint it too when it is a lone off-plane speck (at most one
            // off-plane or blocked unpainted neighbour) of the erased ink.
            const x=j%w,y=j/w|0;let structure=0;
            for(let yy=Math.max(0,y-1);yy<=Math.min(h-1,y+1);yy++)for(let xx=Math.max(0,x-1);xx<=Math.min(w-1,x+1);xx++){
              const m=yy*w+xx;if(m===j||paintMask[m])continue;
              if(donorBlocked[m]||size(m)>tolerance)structure++;
            }
            // Interior pixels only: the fills read all four neighbours of a painted pixel.
            if(structure<=1&&x>0&&y>0&&x<w-1&&y<h-1)out.specks.push(j);
          }})();
          return out;
        }
        // Relax queue[0..tail) toward the average of its linked four-neighbors
        // and write the solution back to p.
        function aidokuHarmonicFill(p,w,n,queue,tail,donorBlocked,paintMask,accelerated) {
          const kernels=typeof aidokuPixelKernels==='function'&&p.length===n*4&&donorBlocked.length>=n&&paintMask.length>=n?
            aidokuPixelKernels(n*14+tail*5+256):null;
          if(kernels) {
            // Same relaxation (Float64 arithmetic, Float32 work values) in WebAssembly. The pixels are copied into
            // the last third of the work array, which the kernel converts in place.
            const workAt=kernels.heap,at=workAt+n*8,blockedAt=workAt+n*12,paintAt=blockedAt+n,queueAt=(paintAt+n+3)&~3,linksAt=queueAt+tail*4;
            new Uint8Array(kernels.memory.buffer,at,n*4).set(p);
            new Uint8Array(kernels.memory.buffer,blockedAt,n).set(donorBlocked.subarray(0,n));
            new Uint8Array(kernels.memory.buffer,paintAt,n).set(paintMask.subarray(0,n));
            new Int32Array(kernels.memory.buffer,queueAt,tail).set(queue.subarray(0,tail));
            kernels.exports.harmonic_fill(at,w,n,queueAt,tail,blockedAt,paintAt,accelerated?1:0,workAt,linksAt);
            const work=new Float32Array(kernels.memory.buffer,workAt,n*3);
            for(let k=0;k<tail;k++){const i=queue[k];for(let c=0;c<3;c++)p[i*4+c]=work[i*3+c];}
            return;
          }
          const work=new Float32Array(n*3);for(let i=0;i<n;i++)for(let c=0;c<3;c++)work[i*3+c]=p[i*4+c];
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
        }
        // Faded body letters, punctuation and fine ruby can have no dark core.
        // Recruit ink-to-paper blend pixels inside regions with a clear ring
        // into raw/faintInk. Returns whether any faint body component was added.
        function aidokuRecruitFaintInk(p,w,h,faintRegions,background,separation,inkBackgroundBlend,raw,faintInk,queue) {
          const n=w*h;let added=false;
          (()=>{for(const {rect:r,ruby} of faintRegions){
            const x0=Math.floor(r[0]),y0=Math.floor(r[1]),x1=Math.ceil(r[0]+r[2]),y1=Math.ceil(r[1]+r[3]);
            let samples=0,clear=0,rough=0;
            // Visit the same ordered ring pixels without scanning the discarded interior.
            for(let y=y0-2;y<=y1+1;y++)for(let x=x0-2,step=(y===y0-2||y===y1+1)?1:Math.max(1,x1-x0+3);x<=x1+1;x+=step){
              const i=(y*w+x)*4;samples++;
              if(aidokuRestorationDistance(p[i],p[i+1],p[i+2],background)<=20)clear++;
              // Grain near the OCR box cannot establish ownership of faint glyphs.
              // Otherwise isolated background noise recruits a much wider erase mask.
              if(!ruby&&x>0&&y>0&&x<w-1&&y<h-1&&[0,1,2].some(c=>Math.abs(p[i+c]-(p[i-4+c]+p[i+4+c]+p[i-w*4+c]+p[i+w*4+c])/4)>6))rough++;
            }
            if(samples<(ruby?8:16)||clear/samples<(ruby?.85:.95)||!ruby&&rough/samples>.2)continue;
            const soft=ruby?null:new Uint8Array(n);
            for(let y=y0;y<y1;y++)for(let x=x0;x<x1;x++){
              const i=y*w+x,pr=p[i*4],pg=p[i*4+1],pb=p[i*4+2];
              if(aidokuRestorationDistance(pr,pg,pb,background)<Math.max(ruby?24:16,separation*.08)||!inkBackgroundBlend(pr,pg,pb))continue;
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
                    const j=(yy*w+xx)*4,pr=p[j],pg=p[j+1],pb=p[j+2];
                    if(aidokuRestorationDistance(pr,pg,pb,background)>=Math.max(16,separation*.08)&&inkBackgroundBlend(pr,pg,pb))crosses=true;
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
              if(tail>=2&&!strong&&!solid&&!crosses)for(let k=0;k<tail;k++){raw[queue[k]]=1;faintInk[queue[k]]=1;added=true;}
            }
          }})();
          return added;
        }
        // Initial per-pixel ownership classes for one palette. They depend only
        // on the crop pixels, the palette object and the second ink, so retries
        // within one aidokuRestoreSourcePanel call reuse them. Every caller
        // receives private copies: later passes mutate raw and protectedInk.
        function aidokuObservedPixelClasses(rgba,n,palette,secondaryInk,inkTolerance,separation,matchedInk) {
          const cache=aidokuRestoreSourcePanel.classificationCache;
          const hit=cache?.find(e=>e.rgba===rgba&&e.n===n&&e.palette===palette&&e.secondaryInk===secondaryInk);
          if(hit)return {raw:hit.raw.slice(),observedInk:hit.observedInk&&hit.observedInk.slice(),protectedInk:hit.protectedInk.slice()};
          const raw=new Uint8Array(n),protectedInk=new Uint8Array(n),observedInk=matchedInk?new Uint8Array(n):null;
          const foreground=palette.foreground,strokeColor=palette.stroke;
          const inkStrokeBlend=aidokuRestorationBlend(strokeColor,foreground);
          const inkBackgroundBlend=aidokuRestorationBlend(palette.background,foreground);
          const strokeBackgroundBlend=aidokuRestorationBlend(palette.background,strokeColor);
          // Palette channels are read once; each distance is max |pixel-color|.
          const lightSurface=Math.min(...palette.background)>=140,haloSeparation=Math.max(32,separation*.55);
          const f0=foreground[0],f1=foreground[1],f2=foreground[2],g0=palette.background[0],g1=palette.background[1],g2=palette.background[2];
          const k0=secondaryInk?secondaryInk[0]:0,k1=secondaryInk?secondaryInk[1]:0,k2=secondaryInk?secondaryInk[2]:0;
          const s0=strokeColor?strokeColor[0]:0,s1=strokeColor?strokeColor[1]:0,s2=strokeColor?strokeColor[2]:0;
          const kernels=typeof aidokuPixelKernels==='function'&&rgba.length>=n*4&&
            [f0,f1,f2,g0,g1,g2,k0,k1,k2,s0,s1,s2,inkTolerance,haloSeparation].every(Number.isFinite)?aidokuPixelKernels(n*7+256):null;
          if(kernels) {
            // Same per-pixel ownership classes in WebAssembly.
            const at=kernels.heap,rawAt=at+n*4,observedAt=rawAt+n,protectedAt=observedAt+n,colorsAt=(protectedAt+n+7)&~7;
            const buffer=kernels.memory.buffer;
            new Uint8Array(buffer,at,n*4).set(rgba.subarray(0,n*4));
            new Float64Array(buffer,colorsAt,12).set([f0,f1,f2,g0,g1,g2,k0,k1,k2,s0,s1,s2]);
            kernels.exports.pixel_classes(at,n,colorsAt,(secondaryInk?1:0)|(strokeColor?2:0)|(observedInk?4:0)|(lightSurface?8:0),
              inkTolerance,haloSeparation,rawAt,observedAt,protectedAt);
            raw.set(new Uint8Array(buffer,rawAt,n));protectedInk.set(new Uint8Array(buffer,protectedAt,n));
            if(observedInk)observedInk.set(new Uint8Array(buffer,observedAt,n));
          } else (()=>{for(let i=0;i<n;i++){
            const pr=rgba[4*i],pg=rgba[4*i+1],pb=rgba[4*i+2];
            const inkDistance=Math.max(Math.abs(pr-f0),Math.abs(pg-f1),Math.abs(pb-f2)),backgroundDistance=Math.max(Math.abs(pr-g0),Math.abs(pg-g1),Math.abs(pb-g2));
            const secondaryDistance=secondaryInk?Math.max(Math.abs(pr-k0),Math.abs(pg-k1),Math.abs(pb-k2)):Infinity;
            const secondaryMatch=secondaryDistance<=inkTolerance&&secondaryDistance+8<backgroundDistance;
            if(observedInk&&(inkDistance<=inkTolerance&&inkDistance+8<backgroundDistance||secondaryMatch))observedInk[i]=1;
            // Dark rules on a light surface still enter component protection. On a
            // dark surface the dark pixels are background, not an enormous ink component.
            if(secondaryMatch||observedInk?.[i]||(lightSurface&&Math.max(pr,pg,pb)<110))raw[i]=1;
            // The outer antialias ramp runs from stroke to backing, independently
            // of the fill hue. Treating it as artwork strands valid colored halos.
            if(observedInk&&!raw[i]&&backgroundDistance>=haloSeparation&&
                inkDistance>inkTolerance&&(!strokeColor||Math.max(Math.abs(pr-s0),Math.abs(pg-s1),Math.abs(pb-s2))>inkTolerance)&&
                !inkStrokeBlend(pr,pg,pb)&&!inkBackgroundBlend(pr,pg,pb)&&
                !strokeBackgroundBlend(pr,pg,pb))
              protectedInk[i]=1;
          }})();
          if(cache){
            cache.push({rgba,n,palette,secondaryInk,raw:raw.slice(),observedInk:observedInk&&observedInk.slice(),protectedInk:protectedInk.slice()});
            if(cache.length>8)cache.shift();
          }
          return {raw,observedInk,protectedInk};
        }
        function aidokuRestoreObservedSourcePanel(rgba,w,h,b,palette,options={}) {
          const n=w*h;
          if(!Number.isInteger(w)||!Number.isInteger(h)||w<8||h<8||n>262144||
              !rgba||rgba.length!==n*4||!Array.isArray(b)||b.length!==4||!b.every(Number.isFinite)||
              b[0]<2||b[1]<2||b[2]<=0||b[3]<=0||b[0]+b[2]>w-2||b[1]+b[3]>h-2||
              !palette?.foreground||!palette?.background)return null;
          // WebKit crop resampling can round opaque alpha to 254. Accept that
          // one-byte error without flattening genuinely transparent source art.
          if(!aidokuRestorationOpaque(rgba))return null;
          // Suppressed white readings on a dark caption retain the same verified
          // ownership. Reuse the bounded mask in opposite polarity; alpha and
          // protected illustration components are unchanged.
          if(Math.min(...palette.foreground)>=175&&Math.max(...palette.background)<=115&&options.auxiliary?.length){
            const inverted=rgba.slice();
            (()=>{for(let i=0;i<n;i++)for(let c=0;c<3;c++)inverted[i*4+c]=255-inverted[i*4+c];})();
            const flip=c=>c?c.map(v=>255-v):null;
            const restored=aidokuRestoreObservedSourcePanel(inverted,w,h,b,{...palette,foreground:flip(palette.foreground),
              background:flip(palette.background),stroke:flip(palette.stroke)},
              options.secondaryInk?{...options,secondaryInk:flip(options.secondaryInk)}:options);
            if(!restored)return null;
            (()=>{for(let i=0;i<n;i++)if(restored.rgba[i*4+3])for(let c=0;c<3;c++)restored.rgba[i*4+c]=255-restored.rgba[i*4+c];})();
            if(restored.surfaceQuality?.coefficients)restored.surfaceQuality={...restored.surfaceQuality,
              coefficients:restored.surfaceQuality.coefficients.map(a=>[255-a[0],-a[1],-a[2]])};
            return restored;
          }
          const foreground=palette.foreground;
          const colorDistance=(a,b)=>Math.max(...a.map((v,c)=>Math.abs(v-b[c])));
          const separation=colorDistance(foreground,palette.background);
          // Whether a pixel lies on the straight ramp between two observed colors
          // (fill to stroke, fill to backing, stroke to backing), within 24 levels.
          const inkStrokeBlend=aidokuRestorationBlend(palette.stroke,foreground);
          const inkBackgroundBlend=aidokuRestorationBlend(palette.background,foreground);
          const strokeBackgroundBlend=aidokuRestorationBlend(palette.background,palette.stroke);
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
          const verifiedWhiteOutline=!options.slantedOwnership&&legacyDark&&palette.stroke&&Math.min(...palette.stroke)>=230&&
            (palette.confidence?.stroke||0)>=.6&&
            palette.confidence?.reason==='repeated dark glyph interiors enclosed by white source outlines';
          const radius=measuredRadius??(options.compactMask&&!verifiedWhiteOutline?(palette.stroke?6:3):12);
          
     const p=rgba.slice(),seen=new Uint8Array(n),mask=new Uint8Array(n),frameInk=new Uint8Array(n),queue=new Int32Array(n),seedRadius=new Uint8Array(n),accepted=[],isolatedBodyInk=[],readingCandidates=[],edgeFragments=[];
     const {raw,observedInk,protectedInk}=aidokuObservedPixelClasses(rgba,n,palette,options.secondaryInk,inkTolerance,separation,matchedInk);
     const rowEndMarks=(options.rowEndMarks||[]).slice(0,32).filter(r=>Array.isArray(r)&&r.length===4&&r.every(Number.isFinite));
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
     faintBodyAdded=aidokuRecruitFaintInk(p,w,h,faintRegions,palette.background,separation,inkBackgroundBlend,raw,faintInk,queue);
     const retryPrevious=()=>faintBodyAdded||extendedHalo?
       aidokuRestoreObservedSourcePanel(rgba,w,h,b,palette,{...options,faintBody:false,outlineFringe:false}):null;
     let companions=0,connectedOutlineRuns=0;const bodyRules=[];const texturePoints=[],textureComponents=[];
     const bounds=new Int32Array(4);
     // Scan for the next seed outside the body: its closures would otherwise
     // allocate a scope for every pixel visited.
     (()=>{for(let start=aidokuNextSeed(raw,seen,0,n);start<n;start=aidokuNextSeed(raw,seen,start+1,n)){
     const tail=aidokuFloodComponent(raw,seen,queue,start,w,h,bounds),x0=bounds[0],y0=bounds[1],x1=bounds[2],y1=bounds[3];
     const cx=(x0+x1)/2,cy=(y0+y1)/2;
     if(options.readabilityGate&&tail<=4&&texturePoints.length<8192){texturePoints.push((cy|0)*w+(cx|0));textureComponents.push(Array.from(queue.subarray(0,tail)));}
     // Touching the rectified ownership boundary alone is not a glyph seed.
     // Otherwise a tiny coordinate round-off can recruit a detached drawing
     // stroke exactly three pixels outside the OCR body.
     const boundaryInset=options.slantedOwnership?1e-6:0;
     const body=cx>=b[0]-3+boundaryInset&&cx<=b[0]+b[2]+3-boundaryInset&&
       cy>=b[1]-3+boundaryInset&&cy<=b[1]+b[3]+3-boundaryInset;
     const ruby=auxiliary.some(r=>cx>=r[0]-2&&cx<=r[0]+r[2]+2&&cy>=r[1]-2&&cy<=r[1]+r[3]+2);
     // Row-end punctuation just past the OCR box (aidokuRowEndMarks). It is
     // masked like ruby but never counted as a glyph or a companion.
     const rowEnd=!body&&!ruby&&rowEndMarks.some(r=>x0>=r[0]-3&&x1<=r[0]+r[2]+3&&y0>=r[1]-3&&y1<=r[1]+r[3]+3);
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
     const connectedOutline=options.connectedGlyphRecovery&&options.readabilityGate&&!options.slantedOwnership&&options.vertical&&body&&
       b[3]>=b[2]*2.5&&y1-y0>=100&&x0>2&&y0>2&&x1<w-3&&y1<h-3&&
       aidokuConnectedOutlineRun(p,w,b,palette,queue.subarray(0,tail),[x0,y0,x1,y1]);
     let enclosedWord=false;
     if(options.enclosedWordRecovery&&body&&!options.slantedOwnership&&tail>=12&&
         x0>=b[0]&&y0>=b[1]&&x1<b[0]+b[2]&&y1<b[1]+b[3]&&
         tail<(x1-x0+1)*(y1-y0+1)*.7&&Math.min(x1-x0+1,y1-y0+1)>=3){
       let samples=0,clear=0;
       for(let yy=y0-3;yy<=y1+3;yy++)for(let xx=x0-3;xx<=x1+3;xx++){
         if(xx>x0-2&&xx<x1+2&&yy>y0-2&&yy<y1+2)continue;
         if(xx<0||yy<0||xx>=w||yy>=h)continue;
         const j=(yy*w+xx)*4;samples++;
         if(aidokuRestorationDistance(p[j],p[j+1],p[j+2],palette.background)<=18)clear++;
       }
       enclosedWord=samples>=40&&clear>=samples*.98;
     }
     // A long thin stroke lying mostly outside the OCR box (a balloon or
     // frame edge, a speed line, the rim of a drawn shape) is drawing that
     // reaches into the box: it stays protected like other unowned ink.
     let artLine=false;
     if(body&&!ruby&&!rule&&!rowEnd&&!options.slantedOwnership&&tail>=8){
       const extent=Math.max(x1-x0,y1-y0)+1;
       if(extent>=12&&tail<=Math.max(2.5,extent*.2)*extent){
         let outside=0,reach=0;
         for(let k=0;k<tail;k++){const i=queue[k],x=i%w,y=i/w|0;
           const d=Math.max(b[0]-x,x-(b[0]+b[2]),b[1]-y,y-(b[1]+b[3]));
           if(d>=2){outside++;reach=Math.max(reach,d);}}
         // Mostly outside, or a long stroke leaving the box; punctuation just
         // past the box edge (a closing bracket) stays lettering.
         artLine=reach>Math.max(4,Math.min(b[2],b[3])*.15)&&
           (outside>=tail*.6||outside>=tail*.4&&extent>=Math.max(16,Math.max(b[2],b[3])*.35));
       }
     }
     const keep=!artLine&&(!observedInk||observedCount>=Math.max(ruby||rowEnd?1:2,tail*.1))&&(tail>=2||((ruby||rowEnd)&&tail===1))&&
       x0>2&&y0>2&&x1<w-3&&y1<h-3&&(body||ruby||rule||rowEnd)&&
       (slantedWord||enclosedWord||connectedOutline||Math.max(x1-x0,y1-y0)<(rule?121:Math.min(100,Math.max(b[2],b[3])*.6)));
     if(!keep&&body&&options.readabilityGate&&options.vertical&&!options.slantedOwnership&&
         observedCount>=tail*.9&&palette.stroke&&(palette.confidence?.stroke||0)>=.6&&
         Math.max(...foreground)-Math.min(...foreground)>=40&&
         x0>=b[0]&&x1<b[0]+b[2]&&y0>=b[1]&&y1<b[1]+b[3]&&
         x1-x0<=Math.max(6,b[2]*.045)&&y1-y0>=Math.max(100,(x1-x0)*10)&&y1-y0<=b[3]*.55){
       let samples=0,outlined=0;
       for(let yy=y0+3;yy<y1-2;yy++)for(const xx of [x0-3,x1+3]){
         const i=(yy*w+xx)*4;samples++;
         if(aidokuRestorationDistance(p[i],p[i+1],p[i+2],palette.stroke)<=24)outlined++;
       }
       if(samples>20&&outlined>=samples*.9)bodyRules.push({box:[x0,y0,x1,y1],pixels:Array.from(queue.subarray(0,tail))});
     }
     if(keep&&connectedOutline)connectedOutlineRuns++;
     if(keep&&!body&&!rowEnd)companions++;
     if(!keep&&body&&tail===1&&x0>2&&y0>2&&x1<w-3&&y1<h-3)isolatedBodyInk.push(start);
     for(let k=0;k<tail;k++){
       (keep?mask:protectedInk)[queue[k]]=1;
       if(keep)seedRadius[queue[k]]=(ruby||rowEnd)&&!body?Math.min(6,radius):radius;
       if(!keep&&(x0<=2||y0<=2||x1>=w-3||y1>=h-3))frameInk[queue[k]]=1;
     }
     if(keep&&!rowEnd)accepted.push([x0,y0,x1,y1,tail,observedInk?observedCount:tail]);
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
     }})();
     // An outlined em dash may be longer than the generic component limit.
     // Require the same observed chromatic ink, a white/colored enclosing band,
     // and a neighboring accepted glyph on its reading axis.
     (()=>{for(const rule of bodyRules){
       const [x0,y0,x1,y1]=rule.box,cx=(x0+x1)/2;
       if(!accepted.some(a=>a[4]>=8&&cx>=a[0]&&cx<=a[2]&&
           (y0-a[3]>=0&&y0-a[3]<=24||a[1]-y1>=0&&a[1]-y1<=24)))continue;
       for(const i of rule.pixels){mask[i]=1;protectedInk[i]=0;seedRadius[i]=radius;}
       accepted.push([...rule.box,rule.pixels.length,rule.pixels.length]);
     }})();
     const hasPeriodicTexture=options.readabilityGate&&aidokuSourceHasPeriodicInk(texturePoints,w,h,b);
     const periodicInk=hasPeriodicTexture&&texturePoints.filter(i=>accepted.some(a=>a[4]>4&&i%w>=a[0]-12&&i%w<=a[2]+12&&(i/w|0)>=a[1]-12&&(i/w|0)<=a[3]+12)).length>=32;
     // Independent tiny-dot repetition establishes texture ownership. Keep
     // these components out of glyph seeds, including one-pixel body fragments;
     // only the bounded neighborhood of substantial glyphs is reconstructed.
     if(periodicInk){
       (()=>{for(let k=accepted.length-1;k>=0;k--)if(accepted[k][4]<=4)accepted.splice(k,1);})();
       (()=>{for(const points of textureComponents)for(const i of points){mask[i]=0;protectedInk[i]=0;seedRadius[i]=0;}})();
       (()=>{for(let i=0;i<n;i++)if(mask[i])seedRadius[i]=8;})();
     }
     // A single kana or two connected letters can be complete OCR text.
     // Count alone is not ownership evidence: require substantial compact ink
     // strictly inside OCR and an independently observed clear paper ring.
     // All later drawing, unresolved-ink and donor-quality guards still apply.
     if(accepted.length<(options.flatPalette?2:3)){
       let isolated=options.readabilityGate&&!hasPeriodicTexture&&accepted.length>0&&companions===0;
       let x0=w,y0=h,x1=0,y1=0,pixels=0;
       (()=>{for(const a of accepted){
         const cw=a[2]-a[0]+1,ch=a[3]-a[1]+1;
         if(a[0]<b[0]+2||a[1]<b[1]+2||a[2]>=b[0]+b[2]-2||a[3]>=b[1]+b[3]-2||
             a[4]<8||Math.min(cw,ch)<3||a[4]>cw*ch*.7)isolated=false;
         x0=Math.min(x0,a[0]);y0=Math.min(y0,a[1]);x1=Math.max(x1,a[2]);y1=Math.max(y1,a[3]);pixels+=a[4];
       }})();
       if(pixels<b[2]*b[3]*.025||x1-x0<b[2]*.25||y1-y0<b[3]*.25)isolated=false;
       if(isolated){
         let samples=0,clear=0;
         (()=>{for(let y=y0-3;y<=y1+3;y++)for(let x=x0-3;x<=x1+3;x++){
           if(x>x0-2&&x<x1+2&&y>y0-2&&y<y1+2)continue;
           const i=(y*w+x)*4;samples++;
           if(aidokuRestorationDistance(p[i],p[i+1],p[i+2],palette.background)<=24)clear++;
         }})();
         isolated=samples>=32&&clear>=samples*.98;
       }
       if(!isolated)return retryPrevious();
       if(!options.shortGlyphRecovery){
         if(aidokuRestoreSourcePanel.classificationCache)aidokuRestoreSourcePanel.classificationCache.shortGlyphCandidate=true;
         return retryPrevious();
       }
     }
     // Recover at most one compact continuation glyph below an observed ruby
     // column. A clear, flat outer ring is required; connected rays, frame
     // strokes, distant marks and a second line never establish ownership.
     (()=>{for(const r of auxiliary){
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
     }})();
     // Rasterized small glyphs can have a disconnected one-pixel stroke.
     // Only attach it to already validated ink nearby; isolated paper specks
     // cannot seed cleanup or recruit one another across the panel.
     const bodyFragments=[];
     (()=>{for(const i of (periodicInk?[]:isolatedBodyInk)){
       const x=i%w,y=i/w|0;let nearby=false;
       for(let yy=Math.max(0,y-6);yy<=Math.min(h-1,y+6)&&!nearby;yy++)
         for(let xx=Math.max(0,x-6);xx<=Math.min(w-1,x+6);xx++)if(mask[yy*w+xx]){nearby=true;break;}
       if(nearby)bodyFragments.push(i);
     }})();
     (()=>{for(const i of bodyFragments){mask[i]=1;protectedInk[i]=0;seedRadius[i]=6;}})();
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
     (()=>{for(const pixels of ownedEdgeFragments){
       for(const i of pixels){mask[i]=1;protectedInk[i]=0;seedRadius[i]=2;}
       companions++;
     }})();
     // Antialiased drawing strokes can split into apparently isolated dark
     // components inside a merged OCR rectangle. From the first gated attempt,
     // reconnect them to known frame artwork through darker-than-paper pixels
     // before deciding which components belong to lettering.
     let drawingSurface=null;
     if(options.protectArtMargin||options.readabilityGate)
       drawingSurface=aidokuGrowDrawingSupport(p,w,h,Math.min(210,Math.min(...palette.background)-40),
         frameInk,raw,mask,seedRadius,protectedInk,queue);
     if(options.readabilityGate&&!options.slantedOwnership)
       aidokuPreserveFrameFringe(rgba,w,h,b,palette.background,raw,mask,protectedInk,frameInk);
     // Validate tiny codec islands from their actual border, not merely a
     // dark-core bounding box. A contrasting observed halo and nearby owned
     // ink must surround them; connected artwork stays protected.
     if(measuredHalo&&Math.max(...foreground)-Math.min(...foreground)>=24){
       const visited=new Uint8Array(n),islands=[],fgMin=Math.min(...foreground),fgSpan=Math.max(...foreground)-fgMin;
       const halo=palette.stroke&&colorDistance(palette.stroke,palette.background)>=40;
       (()=>{for(let start=aidokuNextSeed(protectedInk,visited,0,n);start<n;start=aidokuNextSeed(protectedInk,visited,start+1,n)){
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
               const pr=p[j*4],pg=p[j*4+1],pb=p[j*4+2];
               if(aidokuRestorationDistance(pr,pg,pb,palette.stroke)<=32){compatible++;outline++;}
               else if(inkStrokeBlend(pr,pg,pb))compatible++;
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
       }})();
       (()=>{for(const i of islands){mask[i]=1;protectedInk[i]=0;seedRadius[i]=radius;}})();
     }
     // JPEG chroma subsampling makes small brown/purple fringes that no
     // longer lie on the straight RGB ink-to-paper blend. Recruit only tiny
     // unseeded islands around repeated, already owned vertical glyphs. The
     // original mask is frozen during this check, so islands cannot chain
     // across a drawing, and boundary-connected artwork remains protected.
     if(options.readabilityGate&&options.vertical&&(!options.slantedOwnership||measuredHalo)&&
         b[3]>=b[2]&&accepted.length>=6){
       const colors=[palette.foreground,palette.stroke].filter(c=>c&&Math.max(...c)-Math.min(...c)>=40);
       const visited=new Uint8Array(n),islands=[];
       (()=>{for(let start=aidokuNextSeed(protectedInk,visited,0,n);colors.length&&start<n;start=aidokuNextSeed(protectedInk,visited,start+1,n)){
         let head=0,end=1;queue[0]=start;visited[start]=1;
         while(head<end){
           const i=queue[head++],x=i%w,y=i/w|0;
           for(let yy=Math.max(0,y-1);yy<=Math.min(h-1,y+1);yy++)for(let xx=Math.max(0,x-1);xx<=Math.min(w-1,x+1);xx++){
             const j=yy*w+xx;if(!protectedInk[j]||visited[j])continue;
             visited[j]=1;queue[end++]=j;
           }
         }
         if(end>96)continue;
         let owned=true,offHue=0,tight=true;
         for(let k=0;k<end&&owned;k++){
           const i=queue[k],x=i%w,y=i/w|0,rgb=[p[i*4],p[i*4+1],p[i*4+2]];
           if(raw[i]||frameInk[i]||drawingSurface?.[i]||x<b[0]||y<b[1]||x>=b[0]+b[2]||y>=b[1]+b[3]){owned=false;break;}
           const lo=Math.min(...rgb),span=Math.max(...rgb)-lo;
           if(span<12||!colors.some(color=>{
             const low=Math.min(...color),range=Math.max(...color)-low;
             return Math.max(...rgb.map((v,c)=>Math.abs((v-lo)/span-(color[c]-low)/range)))<=.28;
           }))offHue++;
           let nearby=false;
           for(let yy=Math.max(0,y-radius);yy<=Math.min(h-1,y+radius)&&!nearby;yy++)
             for(let xx=Math.max(0,x-radius);xx<=Math.min(w-1,x+radius);xx++)if(mask[yy*w+xx]){nearby=true;break;}
           if(!nearby)owned=false;
           let close=false;
           for(let yy=Math.max(0,y-2);yy<=Math.min(h-1,y+2)&&!close;yy++)
             for(let xx=Math.max(0,x-2);xx<=Math.min(w-1,x+2);xx++)if(mask[yy*w+xx]){close=true;break;}
           tight&&=close&&accepted.some(a=>x>a[0]&&x<a[2]&&y>a[1]&&y<a[3]);
         }
         if(owned&&(offHue<=Math.min(4,end*.25)||end<=4&&tight))for(let k=0;k<end;k++)islands.push(queue[k]);
       }})();
       (()=>{for(const i of islands){mask[i]=1;protectedInk[i]=0;seedRadius[i]=Math.min(radius,6);}})();
     }
     const coreCount=aidokuMaskCount(mask,n);
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
     if(substantialCoreCount>b[2]*b[3]*(options.flatPalette ? .48 : outlinedDark ? .42 : connectedOutlineRuns>0&&palette.stroke&&(palette.confidence?.stroke||0)>=.6 ? .48 : .3))return retryPrevious();
     // Reject unresolved dark ink inside the OCR box, including intersecting art.
     let unresolved=aidokuCountUnresolvedInk(protectedInk,frameInk,w,b);
     if(!options.slantedOwnership&&!options.segmentedSurfaceRecovery&&unresolved>Math.max(8,coreCount*.04))return retryPrevious();
     // Neighboring untranslated ink and its halo are not background donors.
     // Exclusion affects sampling only: their original pixels remain untouched.
     const {donorBlocked,donorDistance}=aidokuBlockProtectedDonors(protectedInk,w,h,queue);
     if(drawingSurface)(()=>{for(let i=0;i<n;i++)if(drawingSurface[i])donorBlocked[i]=1;})();
     // Tiny ruby outlines need less expansion than body lettering. Do not
     // blend a nearby white illustration edge into an otherwise gray reading.
     const dimSurface=Math.max(...palette.background)<225;
     (()=>{for(const r of auxiliary)for(let y=Math.max(0,Math.floor(r[1]-12));y<Math.min(h,Math.ceil(r[1]+r[3]+12));y++)
       for(let x=Math.max(0,Math.floor(r[0]-12));x<Math.min(w,Math.ceil(r[0]+r[2]+12));x++){
         const i=y*w+x;
         if(dimSurface&&Math.min(p[i*4],p[i*4+1],p[i*4+2])>240)donorBlocked[i]=1;
       }})();
     const distance=new Uint8Array(n);let tail=0;
     const preciseFringe=options.preciseFringe!==false;
     const followHalo=measuredHalo&&options.outlineFringe!==false&&palette.stroke&&
       (colorDistance(palette.stroke,palette.background)>=40||Math.min(...palette.stroke)>=230&&
         (palette.confidence?.stroke||0)>=.7&&colorDistance(palette.stroke,foreground)>=80);
     tail=aidokuMaskQueue(mask,queue,n);
     // Include halos even when the color estimator mistakes them for paper.
     // Native-resolution dilation is bounded; 24 px crop padding keeps its
     // boundary samples outside the source outline rather than inside it.
     const dilationFlags=new Uint8Array(1);
     // Glyph size from the owned body components (the larger half of their
     // extents, capped by the OCR box's short side).
     const extents=accepted.filter(a=>a[4]>=8).map(a=>Math.max(a[2]-a[0],a[3]-a[1])+1).sort((u,v)=>u-v);
     const glyphSize=Math.min(Math.min(b[2],b[3]),extents.length?extents[Math.floor(extents.length*.75)]:Infinity);
     tail=aidokuDilateOwnedMask(p,w,h,queue,tail,mask,distance,seedRadius,protectedInk,drawingSurface,donorBlocked,donorDistance,
       options.protectArtMargin,followHalo,preciseFringe,radius,palette.background,strokeBackgroundBlend,dilationFlags,
       Math.max(3,Math.ceil(glyphSize*.3)),foreground,[b,...auxiliary,...rowEndMarks]);
     if(dilationFlags[0])extendedHalo=true;
     // A slanted outlined display glyph can enclose a wide white interior.
     // Dilation alone misses its center and then samples it as a white donor,
     // leaving the old letter's silhouette. Fill only enclosed, palette-matched
     // holes; any hole connected to the page or containing artwork is preserved.
     if((options.slantedOwnership||outlinedDark&&colorDistance(palette.stroke,palette.background)<40||options.readabilityGate&&options.vertical&&Math.max(...foreground)-Math.min(...foreground)>=40)&&palette.stroke&&(palette.confidence?.stroke||0)>=.6&&
         colorDistance(palette.stroke,palette.background)>=8)
       tail=aidokuFillEnclosedHoles(p,w,h,b,mask,queue,protectedInk,drawingSurface,palette.stroke,palette.background,inkStrokeBlend,strokeBackgroundBlend);
     // Connected drawing inside a textured OCR surface is not recoverable
     // from nearby paper. Do not let the drawing itself become missing donors.
     // Chroma subsampling can leave a small interior island whose hue no
     // longer matches the ink. Require a nearly closed border of already owned
     // glyph pixels; never grow through connected drawing or a balloon edge.
     if(options.readabilityGate&&options.vertical&&!options.slantedOwnership&&unresolved>0&&unresolved<=32&&
         ([palette.foreground,palette.stroke].some(c=>c&&Math.max(...c)-Math.min(...c)>=40)||
          palette.stroke&&(palette.confidence?.stroke||0)>=.6)){
       const pending=[],visited=new Uint8Array(n);
       const outlined=palette.stroke&&(palette.confidence?.stroke||0)>=.6&&
         colorDistance(palette.stroke,palette.foreground)>=40;
       (()=>{for(let y=Math.ceil(b[1]);y<Math.floor(b[1]+b[3]);y++)for(let x=Math.ceil(b[0]);x<Math.floor(b[0]+b[2]);x++){
         const start=y*w+x;if(visited[start]||!protectedInk[start]||raw[start]||frameInk[start]||drawingSurface?.[start])continue;
         const island=[start];visited[start]=1;let valid=true,left=x,right=x,top=y,bottom=y;
         for(let head=0;head<island.length;head++){
           const i=island[head],cx=i%w,cy=i/w|0;
           left=Math.min(left,cx);right=Math.max(right,cx);top=Math.min(top,cy);bottom=Math.max(bottom,cy);
           if(raw[i]||frameInk[i]||drawingSurface?.[i]||cx<b[0]-2||cx>=b[0]+b[2]+2||cy<b[1]-2||cy>=b[1]+b[3]+2)valid=false;
           for(let yy=Math.max(0,cy-1);yy<=Math.min(h-1,cy+1);yy++)for(let xx=Math.max(0,cx-1);xx<=Math.min(w-1,cx+1);xx++){
             const j=yy*w+xx;if(protectedInk[j]&&!visited[j]){visited[j]=1;island.push(j);}
           }
           if(island.length>32){valid=false;break;}
         }
         if(!valid||(!outlined&&island.length>4)||right-left>12||bottom-top>12)continue;
         const own=new Set(island);let border=0,owned=0;
         for(const i of island){const cx=i%w,cy=i/w|0;
           for(let yy=cy-1;yy<=cy+1;yy++)for(let xx=cx-1;xx<=cx+1;xx++){
             const j=yy*w+xx;if(own.has(j))continue;border++;
             if(frameInk[j]||drawingSurface?.[j])valid=false;
             if(mask[j])owned++;
           }
         }
         // Tiny codec fragments at a glyph's concave corner can have only six of eight
         // immediate neighbours owned. Require the surrounding 5x5 ring instead;
         // this never admits drawing, frame ink, raw cores, or a larger component.
         let widerBorder=0,widerOwned=0;
         if(valid&&island.length<=4&&owned/border>=.6){
           const ring=new Set();
           for(const i of island){const cx=i%w,cy=i/w|0;
             for(let yy=cy-2;yy<=cy+2;yy++)for(let xx=cx-2;xx<=cx+2;xx++){
               const j=yy*w+xx;if(own.has(j))continue;ring.add(j);
             }
           }
           for(const j of ring){widerBorder++;if(mask[j])widerOwned++;
             if(frameInk[j]||drawingSurface?.[j])valid=false;}
         }
         if(valid&&border>0&&(owned/border>=.9||widerBorder>0&&widerOwned/widerBorder>=.85))pending.push(...island);
       }})();
       (()=>{for(const i of pending){mask[i]=1;protectedInk[i]=0;}})();
       if(pending.length){tail=aidokuMaskQueue(mask,queue,n);unresolved=aidokuCountUnresolvedInk(protectedInk,frameInk,w,b);}
     }
     const interior=aidokuFrameInterior(frameInk,w,b),frameInterior=interior[0],innerArea=interior[1];
     // A smooth donor surface does not establish ownership of unresolved ink
     // where the OCR rectangle also intersects a connected balloon contour.
     if(options.segmentedSurfaceRecovery&&frameInterior>0&&unresolved>Math.max(8,coreCount*.04))return null;
     // Frame-connected drawing is retained independently of recognized body ink.
     // A resolved body may support partial display, but never certifies that
     // the entire OCR rectangle (including artwork) was erased.
     let sourceGlyphsVerified=unresolved===0;
     if(sourceGlyphsVerified)(()=>{for(const r of auxiliary)
       if(aidokuRectHasInk(protectedInk,frameInk,w,r))sourceGlyphsVerified=false;})();
     let sourceErasureVerified=sourceGlyphsVerified&&frameInterior===0;
     if(sourceErasureVerified)(()=>{for(const r of auxiliary)
       if(aidokuRectHasInk(protectedInk,frameInk,w,r))sourceErasureVerified=false;})();
     // Texture outside a white balloon does not invalidate its isolated glyphs.
     // Reject periodic dots only when the final erasure would actually own them.

     if(hasPeriodicTexture&&!periodicInk&&texturePoints.reduce((sum,i)=>sum+mask[i],0)>Math.max(8,texturePoints.length*.05))return null;
     let surfaceQuality=options.readabilityGate?aidokuSourceSurfaceQuality(rgba,w,h,mask,donorBlocked,options.denseDonorSampling):null;
     // A flat-surface retry may miss a compressed, partially covered pixel
     // beside owned lettering. Remove that local ink blend before diffusion,
     // otherwise it becomes a tinted donor and recreates a faint silhouette.
     if(options.flatPalette&&options.vertical&&!options.slantedOwnership&&surfaceQuality?.safe&&
         surfaceQuality.rmse<=8&&Math.max(...foreground)-Math.min(...foreground)>=40){
       const pending=[],planes=surfaceQuality.coefficients;
       (()=>{for(let y=Math.ceil(b[1]);y<Math.floor(b[1]+b[3]);y++)for(let x=Math.ceil(b[0]);x<Math.floor(b[0]+b[2]);x++){
         const i=y*w+x;if(mask[i]||protectedInk[i]||drawingSurface?.[i])continue;
         const q0=planes[0],q1=planes[1],q2=planes[2];
         const bg0=q0[0]+q0[1]*x/w+q0[2]*y/h,bg1=q1[0]+q1[1]*x/w+q1[2]*y/h,bg2=q2[0]+q2[1]*x/w+q2[2]*y/h;
         const pr=p[i*4],pg=p[i*4+1],pb=p[i*4+2];
         const d0=foreground[0]-bg0,d1=foreground[1]-bg1,d2=foreground[2]-bg2,length=0+d0*d0+d1*d1+d2*d2;
         if(length<1600||Math.max(Math.abs(pr-bg0),Math.abs(pg-bg1),Math.abs(pb-bg2))<24)continue;
         const t=(0+(pr-bg0)*d0+(pg-bg1)*d1+(pb-bg2)*d2)/length;
         if(t<.1||t>=.95||Math.max(Math.abs(pr-(bg0+t*d0)),Math.abs(pg-(bg1+t*d1)),Math.abs(pb-(bg2+t*d2)))>18)continue;
         let owned=0;for(let yy=y-1;yy<=y+1;yy++)for(let xx=x-1;xx<=x+1;xx++)if(mask[yy*w+xx])owned++;
         if(owned>=3)pending.push(i);
       }})();
       for(const i of pending)mask[i]=1;
       if(pending.length){
         tail=aidokuMaskQueue(mask,queue,n);
         surfaceQuality=aidokuSourceSurfaceQuality(rgba,w,h,mask,donorBlocked,options.denseDonorSampling);
       }
     }
     if((periodicInk||surfaceQuality?.safe&&surfaceQuality.rmse>3)&&frameInterior===0){
       const repeated=aidokuSourcePeriodicFill(rgba,w,h,mask,donorBlocked,periodicInk,texturePoints);
       if(repeated){
         const layoutSafe=aidokuLayoutSafe(protectedInk,drawingSurface,n);
         return {...repeated,layoutSafe,surfaceQuality:{...surfaceQuality,reason:'periodic',vectors:repeated.vectors,
           repetitionError:repeated.error},components:accepted.length,radius,companions,sourceRemainingInk:unresolved,sourceCorePixels:coreCount,sourceFramePixels:frameInterior,sourceGlyphsVerified,sourceErasureVerified,preservedPixels:0,preservedCore:0};
       }
     }
     if(periodicInk)return null;
     // A single average backing color can strand a halo on a gradient.
     // Recheck its bounded fringe against the independently fitted local
     // backing before admitting those pixels as diffusion donors.
     if(followHalo&&surfaceQuality?.safe&&surfaceQuality.reason==='smooth'&&frameInterior===0){
       const priorTail=tail;
       tail=aidokuFollowPlanarHalo(p,w,h,queue,tail,mask,distance,seedRadius,donorBlocked,drawingSurface,
         surfaceQuality.coefficients,palette.stroke,preciseFringe);
       if(tail>priorTail){extendedHalo=true;surfaceQuality=aidokuSourceSurfaceQuality(rgba,w,h,mask,donorBlocked,options.denseDonorSampling);}
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
     if(!isolatedSlanted&&!options.segmentedSurfaceRecovery&&(sparseDrawing||denseDrawing||surfaceQuality&&surfaceQuality.rmse>5&&frameInterior>Math.max(8,innerArea*.02)))return null;
     // A smooth ring can be the source outline itself, not exposed background.
     // Reject halo-only donors when their fitted center contradicts the observed
     // backing and instead matches a separately observed outline color.
     if(surfaceQuality?.safe&&palette.stroke&&colorDistance(palette.stroke,palette.background)>=20){
       const center=surfaceQuality.coefficients.map(a=>a[0]+a[1]*(b[0]+b[2]/2)/w+a[2]*(b[1]+b[3]/2)/h);
       if(colorDistance(center,palette.stroke)<=12&&colorDistance(center,palette.background)>=20)return null;
     }
     if(options.segmentedSurfaceRecovery&&(!surfaceQuality?.safe||surfaceQuality.rmse>3||surfaceQuality.outliers>0))return null;
     // A globally varying balloon can still have independently smooth local
     // donors. Shrinking a fully owned colored mask here leaves the white
     // source outline behind. Keep its full halo only with complete erasure,
     // no interior frame, and a well-supported, edge-free local donor field.
     const verifiedLocalSurface=sourceErasureVerified&&frameInterior===0&&matchedInk&&
       Math.max(...foreground)-Math.min(...foreground)>=40&&surfaceQuality?.localSamples>=128&&
       surfaceQuality.localRMSE<=2&&surfaceQuality.edgeFraction===0;
     if(surfaceQuality&&(!surfaceQuality.safe||surfaceQuality.reason==='locally-smooth'&&!options.compactMask&&!verifiedLocalSurface)){
       if(!options.compactMask)return aidokuRestoreObservedSourcePanel(rgba,w,h,b,palette,{...options,compactMask:true});
       return retryPrevious();
     }
     if(surfaceQuality?.safe&&surfaceQuality.reason==='smooth'&&surfaceQuality.rmse>3&&frameInterior===0){
       const textured=aidokuSourceExemplarFill(rgba,w,h,mask,palette,surfaceQuality,protectedInk,textureComponents);
       if(textured){
         const layoutSafe=aidokuLayoutSafe(protectedInk,drawingSurface,n);
         return {...textured,layoutSafe,surfaceQuality:{...surfaceQuality,reason:'exemplar-texture'},components:accepted.length,radius,companions,sourceRemainingInk:unresolved,sourceCorePixels:coreCount,sourceFramePixels:frameInterior,sourceGlyphsVerified,sourceErasureVerified,preservedPixels:0,preservedCore:0};
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
       tail=aidokuExpandPlanarRing(p,w,h,queue,priorTail,mask,distance,seedRadius,donorBlocked,drawingSurface,
         rubyMargins,previousQuality.coefficients,foreground,palette.stroke);
       if(tail>priorTail){
         const expanded=aidokuSourceSurfaceQuality(rgba,w,h,mask,donorBlocked,options.denseDonorSampling);
         if(expanded.safe&&expanded.reason==='smooth'&&expanded.rmse<=3&&expanded.outliers===0&&expanded.samples>=64)
           surfaceQuality=expanded;
         else {(()=>{for(let k=priorTail;k<tail;k++)mask[queue[k]]=0;})();tail=priorTail;}
       }
     }
     // A plane is suitable only for nearly uniform paper/gradients. On a
     // translucent balloon, retain local donor colors through diffusion so
     // smaller masks do not leave flat, glyph-shaped patches in the artwork.
     // A measured contrasting outline can contaminate local diffusion donors.
     // Allow a small plane residual only with sparse outliers and no crossing art.
     if(surfaceQuality&&(surfaceQuality.rmse<=3||measuredHalo&&surfaceQuality.rmse<=8&&
         surfaceQuality.outliers<=.02&&frameInterior===0)&&(!options.compactMask||surfaceQuality.samples>=64)){
       const output=aidokuPlaneFill(mask,surfaceQuality.coefficients,w,h),layoutSafe=aidokuLayoutSafe(protectedInk,drawingSurface,n);
       return {rgba:output,layoutSafe,surfaceQuality,erased:tail,components:accepted.length,radius,companions,sourceRemainingInk:unresolved,sourceCorePixels:coreCount,sourceFramePixels:frameInterior,sourceGlyphsVerified,sourceErasureVerified,preservedPixels:0,preservedCore:0};
     }
     const paintMask=mask.slice();
     // Original values of the painted pixels, kept for a cleaner refill below.
     let planarFront=null;
     if(surfaceQuality?.safe&&surfaceQuality.reason==='smooth'){
       planarFront={index:queue.slice(0,tail),rgb:new Uint8ClampedArray(tail*3)};
       (()=>{for(let k=0;k<tail;k++){const i=queue[k];for(let c=0;c<3;c++)planarFront.rgb[k*3+c]=p[i*4+c];}})();
     }
     aidokuFillFromDonorFront(p,w,n,queue,tail,mask,donorBlocked,paintMask);
     // Retry a failed reconstruction with the illustration margin protected.
     // Successful existing masks retain their exact pixels and donor choices.
     if(!options.protectArtMargin&&mask.some(value=>value!==0))
       return aidokuRestoreObservedSourcePanel(rgba,w,h,b,palette,{...options,protectArtMargin:true});
     // Dilation can enter small pockets enclosed by protected illustration.
     // A pocket without a background donor is not evidence for a fill color.
     // Keep its original pixels instead of rejecting all recoverable lettering.
     // Large amounts of stranded ink still reject the entire proposal.
     const preserved=aidokuCountPreserved(mask,raw,n),preservedPixels=preserved[0],preservedCore=preserved[1];
     if(preservedCore>Math.min(64,coreCount*.02)||preservedPixels>tail*.15)return retryPrevious();
     let painted=0;
     (()=>{for(let k=0;k<tail;k++){
       const i=queue[k];
       if(mask[i]){paintMask[i]=0;donorBlocked[i]=1;}
       else queue[painted++]=i;
     }})();
     tail=painted;
     if(!tail)return null;
     // Protected rules are neither erased nor used as background samples.
     // Reuse the fixed donor topology and over-relax the harmonic solve.
     // Accelerate only a coherent surface without crossing art or donor
     // outliers. Faster diffusion of uncertain samples would spread drawing
     // colors into the cleared text; those cases retain the original solve.
     const accelerated=surfaceQuality?.reason==='smooth'&&surfaceQuality.outliers===0&&frameInterior===0;
     // A starved or contaminated donor front (outline antialiasing, a neighbour's
     // fringe) spreads its tint across the whole erased interior as a blob. On a
     // verified planar surface, refill from the front without those donors; keep
     // the first fill when the cleaner front cannot reach every painted pixel.
     if(planarFront){
       const tainted=aidokuContaminatedFrontDonors(p,w,h,queue,tail,donorBlocked,paintMask,surfaceQuality.coefficients,
         [palette.stroke].filter(ink=>Array.isArray(ink)&&aidokuRestorationDistance(ink[0],ink[1],ink[2],palette.background)>=32),
         [palette.foreground,options.secondaryInk].filter(Array.isArray));
       if(tainted.length){
         // Refill in place: keep the first fill for rollback, restore the
         // original painted pixels, add the specks and unlink the other donors.
         const first=new Uint8ClampedArray(tail*3),specks=tainted.specks,start=tail;
         (()=>{for(let k=0;k<tail;k++){const i=queue[k];for(let c=0;c<3;c++){first[k*3+c]=p[i*4+c];}}})();
         (()=>{for(let k=0;k<planarFront.index.length;k++){const i=planarFront.index[k];for(let c=0;c<3;c++)p[i*4+c]=planarFront.rgb[k*3+c];}})();
         const speckSet=new Set(specks),unlinked=tainted.filter(j=>!speckSet.has(j)),speckRGB=specks.map(j=>[p[j*4],p[j*4+1],p[j*4+2]]);
         (()=>{for(const j of unlinked)donorBlocked[j]=1;})();
         (()=>{for(const j of specks){paintMask[j]=1;queue[tail++]=j;}})();
         (()=>{for(let k=0;k<tail;k++)mask[queue[k]]=1;})();
         aidokuFillFromDonorFront(p,w,n,queue,tail,mask,donorBlocked,paintMask);
         let reached=true;(()=>{for(let k=0;k<tail;k++)if(mask[queue[k]]){reached=false;break;}})();
         if(!reached){
           (()=>{for(let k=0;k<tail;k++)mask[queue[k]]=0;})();
           specks.forEach((j,k)=>{paintMask[j]=0;for(let c=0;c<3;c++)p[j*4+c]=speckRGB[k][c];});
           tail=start;
           (()=>{for(let k=0;k<tail;k++){const i=queue[k];for(let c=0;c<3;c++)p[i*4+c]=first[k*3+c];}})();
           (()=>{for(const j of unlinked)donorBlocked[j]=0;})();
         }
       }
     }
     aidokuHarmonicFill(p,w,n,queue,tail,donorBlocked,paintMask,accelerated);

          const output=new Uint8ClampedArray(n*4);
          (()=>{for(let k=0;k<tail;k++){const i=queue[k];for(let c=0;c<3;c++)output[i*4+c]=p[i*4+c];output[i*4+3]=255;}})();
          // Reuse the reconstructed crop to keep translated glyphs off the
          // surviving balloon outline and illustration; no extra image decode.
          // Gradients and translucent clothing are valid background, not
          // balloon edges. Only surviving ink constrains the text footprint.
          const layoutSafe=aidokuLayoutSafe(protectedInk,drawingSurface,n);
          return {rgba:output,layoutSafe,surfaceQuality,erased:tail,components:accepted.length,radius,companions,sourceRemainingInk:unresolved,sourceCorePixels:coreCount,sourceFramePixels:frameInterior,sourceGlyphsVerified:sourceGlyphsVerified&&preservedCore===0&&preservedPixels===0,sourceErasureVerified:sourceErasureVerified&&preservedCore===0&&preservedPixels===0,preservedPixels,preservedCore};
        }
    // A retained border may touch the OCR rectangle; surviving interior lettering
    // may not be replaced by an outline-only caption.
    function aidokuOutlineSourceResolved(c,core){
     if(!Number.isInteger(c.w)||!Number.isInteger(c.h)||c.w<1||c.h<1||c.w*c.h>262144||c.safe?.length!==c.w*c.h||
         !Array.isArray(core)||!core.length||!core.every(a=>Array.isArray(a)&&a.length===4&&a.every(Number.isFinite)))return false;
     if(c.sourceErasureVerified)return true;
     if(!c.sourceGlyphsVerified||!c.safe)return false;
     const px=Math.max(1,Math.min(3,1.5*c.iw/c.frame[2]*c.sx));
     for(const a of core){
      const l=Math.max(0,Math.floor(a[0])),t=Math.max(0,Math.floor(a[1])),r=Math.min(c.w,Math.ceil(a[0]+a[2])),b=Math.min(c.h,Math.ceil(a[1]+a[3]));
      let all=0,interior=0;
      for(let y=t;y<b;y++)for(let x=l;x<r;x++)if(!c.safe[y*c.w+x]){all++;if(x>=l+px&&x<r-px&&y>=t+px&&y<b-px)interior++;}
      if(interior>Math.min(8,(r-l)*(b-t)*.003)||all>(r-l)*(b-t)*.06)return false;
     }
     return true;
    }
    function aidokuEnclosedPaperRestore(rgba,w,h,b,options={}){
     const n=w*h;if(n>262144||w<8||h<8||rgba?.length!==n*4||!b?.every(Number.isFinite)||b.length!==4||b[2]<3||b[3]<3)return null;
     if((options.auxiliary||[]).some(a=>!Array.isArray(a)||a.length!==4||!a.every(Number.isFinite)||a[0]<0||a[1]<0||a[2]<=0||a[3]<=0||a[0]+a[2]>w||a[1]+a[3]>h))return null;
     const l=Math.max(0,Math.floor(b[0])),t=Math.max(0,Math.floor(b[1])),r=Math.min(w,Math.ceil(b[0]+b[2])),bottom=Math.min(h,Math.ceil(b[1]+b[3]));
     const auxiliary=options.auxiliary||[],excludedRects=options.excluded||[];
     const kernels=typeof aidokuPixelKernels==='function'&&Number.isInteger(w)&&Number.isInteger(h)&&
       excludedRects.every(a=>Array.isArray(a)&&a.length===4&&a.every(Number.isFinite))?
       aidokuPixelKernels(n*26+(auxiliary.length+excludedRects.length)*32+256):null;
     if(kernels) {
      // Same paper component, exterior flood, holes and fills in WebAssembly.
      const at=kernels.heap,paperAt=at+n*4,seenAt=paperAt+n,qAt=(seenAt+n+3)&~3,bestAt=qAt+n*4,regionAt=bestAt+n*4,outsideAt=regionAt+n;
      const pointsAt=(outsideAt+n+3)&~3,outputAt=pointsAt+n*4,safeAt=outputAt+n*4,rectsAt=(safeAt+n+7)&~7;
      const statsAt=rectsAt+(auxiliary.length+excludedRects.length)*32,buffer=kernels.memory.buffer;
      new Uint8Array(buffer,at,n*4).set(rgba);
      new Float64Array(buffer,rectsAt,(auxiliary.length+excludedRects.length)*4).set([...auxiliary,...excludedRects].flatMap(a=>a.slice(0,4)));
      if(!kernels.exports.enclosed_paper(at,w,h,l,t,r,bottom,rectsAt,auxiliary.length,excludedRects.length,paperAt,seenAt,qAt,bestAt,regionAt,
          outsideAt,pointsAt,bestAt,outputAt,safeAt,statsAt))return null;
      const stats=new Int32Array(buffer,statsAt,3);
      return aidokuEnclosedPaperFinish(rgba,w,h,[l,t,r,bottom],auxiliary,{rgba:new Uint8ClampedArray(buffer.slice(outputAt,outputAt+n*4)),
        layoutSafe:new Uint8Array(buffer.slice(safeAt,safeAt+n)),
        erased:stats[0],components:stats[1],method:'enclosed-paper-ink',radius:0,companions:0,preservedPixels:0,preservedCore:0,
        sourceGlyphsVerified:true,sourceErasureVerified:stats[2]===0,surfaceQuality:{safe:false,reason:'enclosed-paper-ink'}});
     }
     const paper=new Uint8Array(n),seen=new Uint8Array(n),q=new Int32Array(n);let best=null,score=0;
     (()=>{for(let i=0;i<n;i++)paper[i]=rgba[i*4+3]>=254&&Math.min(rgba[i*4],rgba[i*4+1],rgba[i*4+2])>=232&&Math.max(rgba[i*4],rgba[i*4+1],rgba[i*4+2])-Math.min(rgba[i*4],rgba[i*4+1],rgba[i*4+2])<=12?1:0;})();
     (()=>{for(let start=0;start<n;start++){
      if(!paper[start]||seen[start])continue;let head=0,end=1,inside=0;q[0]=start;seen[start]=1;
      while(head<end){const i=q[head++],x=i%w,y=i/w|0;if(x>=l&&x<r&&y>=t&&y<bottom)inside++;
       // Neighbours in the original order (left, right, up, down).
       if(x>0&&paper[i-1]&&!seen[i-1]){seen[i-1]=1;q[end++]=i-1;}
       if(x<w-1&&paper[i+1]&&!seen[i+1]){seen[i+1]=1;q[end++]=i+1;}
       if(y>0&&paper[i-w]&&!seen[i-w]){seen[i-w]=1;q[end++]=i-w;}
       if(y<h-1&&paper[i+w]&&!seen[i+w]){seen[i+w]=1;q[end++]=i+w;}
      }
      if(inside>score&&inside>=(r-l)*(bottom-t)*.4){score=inside;best=q.slice(0,end);}
     }})();
     if(!best)return null;
     const region=new Uint8Array(n),outside=new Uint8Array(n);for(const i of best)region[i]=1;
     let head=0,end=0;const seed=i=>{if(!region[i]&&!outside[i]){outside[i]=1;q[end++]=i}};
     (()=>{for(let x=0;x<w;x++){seed(x);seed((h-1)*w+x)}})();(()=>{for(let y=0;y<h;y++){seed(y*w);seed(y*w+w-1)}})();
     (()=>{while(head<end){const i=q[head++],x=i%w,y=i/w|0;
       if(x>0&&!region[i-1]&&!outside[i-1]){outside[i-1]=1;q[end++]=i-1}
       if(x<w-1&&!region[i+1]&&!outside[i+1]){outside[i+1]=1;q[end++]=i+1}
       if(y>0&&!region[i-w]&&!outside[i-w]){outside[i-w]=1;q[end++]=i-w}
       if(y<h-1&&!region[i+w]&&!outside[i+w]){outside[i+w]=1;q[end++]=i+w}}})();
     const output=new Uint8ClampedArray(n*4),safe=region.slice(),holes=[];seen.fill(0);let tinyOutside=0;
     (()=>{for(let start=0;start<n;start++){
      if(region[start]||outside[start]||seen[start])continue;head=0;end=1;q[0]=start;seen[start]=1;let x0=w,x1=0,y0=h,y1=0;
      while(head<end){const i=q[head++],x=i%w,y=i/w|0;x0=Math.min(x0,x);x1=Math.max(x1,x);y0=Math.min(y0,y);y1=Math.max(y1,y);
       for(let yy=Math.max(0,y-1);yy<=Math.min(h-1,y+1);yy++)for(let xx=Math.max(0,x-1);xx<=Math.min(w-1,x+1);xx++){const j=yy*w+xx;if(!region[j]&&!outside[j]&&!seen[j]){seen[j]=1;q[end++]=j}}
      }
      const cx=(x0+x1)/2,cy=(y0+y1)/2,body=cx>=l-3&&cx<=r+3&&cy>=t-3&&cy<=bottom+3;
      const aux=(options.auxiliary||[]).some(a=>cx>=a[0]-2&&cx<=a[0]+a[2]+2&&cy>=a[1]-2&&cy<=a[1]+a[3]+2);
      const excluded=(options.excluded||[]).some(a=>x0<a[0]+a[2]&&x1>=a[0]&&y0<a[1]+a[3]&&y1>=a[1]);
      if(end<=5&&!body)tinyOutside++;
      if((body||aux)&&!excluded&&end<Math.max(48,(r-l)*(bottom-t)*.35))holes.push(q.slice(0,end));
     }})();
     if(!holes.length||tinyOutside>=8)return null;
     let erased=0;(()=>{for(const points of holes){let samples=0,color=[0,0,0];
      for(const i of points){const x=i%w,y=i/w|0;for(let yy=Math.max(0,y-1);yy<=Math.min(h-1,y+1);yy++)for(let xx=Math.max(0,x-1);xx<=Math.min(w-1,x+1);xx++){const j=yy*w+xx;if(!region[j])continue;samples++;for(let c=0;c<3;c++)color[c]+=rgba[j*4+c]}}
      if(samples<4)continue;color=color.map(v=>v/samples);
      for(const i of points){safe[i]=1;erased++;for(let c=0;c<3;c++)output[i*4+c]=color[c];output[i*4+3]=255;}
     }})();
     if(erased<8||erased>(r-l)*(bottom-t)*.65)return null;
     let unresolved=0,frame=0;(()=>{for(let y=t;y<bottom;y++)for(let x=l;x<r;x++){const i=y*w+x;if(!safe[i]){if(outside[i])frame++;else unresolved++;}}})();
     (()=>{for(const a of options.auxiliary||[])for(let y=Math.max(0,Math.floor(a[1]));y<Math.min(h,Math.ceil(a[1]+a[3]));y++)for(let x=Math.max(0,Math.floor(a[0]));x<Math.min(w,Math.ceil(a[0]+a[2]));x++)if(!safe[y*w+x])unresolved++;})();
     if(unresolved)return null;
     return aidokuEnclosedPaperFinish(rgba,w,h,[l,t,r,bottom],auxiliary,{rgba:output,layoutSafe:safe,erased,components:holes.length,
       method:'enclosed-paper-ink',radius:0,companions:0,preservedPixels:0,preservedCore:0,sourceGlyphsVerified:true,
       sourceErasureVerified:frame===0,surfaceQuality:{safe:false,reason:'enclosed-paper-ink'}});
    }
    // Shared by both enclosed-paper paths. (1) A painted part that runs well
    // past the owned rectangles (a sign frame with its arrows, a rule) is
    // drawing that only happens to be enclosed by the same paper: it keeps
    // its original pixels; when it also enters an owned rectangle the proof
    // fails. (2) The patch is drawn scaled with a soft alpha edge; exactly
    // painted holes leave the lettering's antialiased outline visible under
    // that edge, as do the JPEG halos of the glyphs on the paper around them.
    // Two rings of the adjacent paint colour over that paper move the edge
    // onto clean paper.
    function aidokuEnclosedPaperFinish(rgba,w,h,box,auxiliary,result){
     const n=w*h,out=result.rgba,safe=result.layoutSafe,[l,t,r,bottom]=box;
     const owned=[[l,t,r-l,bottom-t],...auxiliary],reach=Math.max(3,Math.min(r-l,bottom-t)*.25);
     const inside=(x,y,rects,m)=>rects.some(a=>x>=a[0]-m&&x<a[0]+a[2]+m&&y>=a[1]-m&&y<a[1]+a[3]+m);
     const seen=new Uint8Array(n),queue=new Int32Array(n);let erased=0,failed=false;
     (()=>{for(let start=0;start<n&&!failed;start++){
      if(!out[start*4+3]||seen[start])continue;
      let head=0,end=1,far=false;queue[0]=start;seen[start]=1;
      while(head<end){const i=queue[head++],x=i%w,y=i/w|0;
       if(!inside(x,y,owned,reach))far=true;
       for(let yy=Math.max(0,y-1);yy<=Math.min(h-1,y+1);yy++)for(let xx=Math.max(0,x-1);xx<=Math.min(w-1,x+1);xx++){
        const j=yy*w+xx;if(out[j*4+3]&&!seen[j]){seen[j]=1;queue[end++]=j;}}
      }
      if(!far){erased+=end;continue;}
      for(let k=0;k<end;k++){const i=queue[k];out[i*4+3]=0;safe[i]=0;if(inside(i%w,i/w|0,owned,0))failed=true;}
     }})();
     if(failed||erased<8)return null;
     const paper=i=>rgba[i*4+3]>=254&&Math.min(rgba[i*4],rgba[i*4+1],rgba[i*4+2])>=232&&
       Math.max(rgba[i*4],rgba[i*4+1],rgba[i*4+2])-Math.min(rgba[i*4],rgba[i*4+1],rgba[i*4+2])<=12;
     // Each painted part takes the median of the plain paper two to four
     // pixels away: the paper right beside a coloured glyph carries its tint.
     seen.fill(0);
     (()=>{for(let start=0;start<n;start++){
      if(out[start*4+3]!==255||seen[start])continue;
      let head=0,end=1,x0=w,y0=h,x1=0,y1=0;queue[0]=start;seen[start]=1;
      while(head<end){const i=queue[head++],x=i%w,y=i/w|0;x0=Math.min(x0,x);x1=Math.max(x1,x);y0=Math.min(y0,y);y1=Math.max(y1,y);
       for(let yy=Math.max(0,y-1);yy<=Math.min(h-1,y+1);yy++)for(let xx=Math.max(0,x-1);xx<=Math.min(w-1,x+1);xx++){
        const j=yy*w+xx;if(out[j*4+3]===255&&!seen[j]){seen[j]=1;queue[end++]=j;}}}
      const near=new Uint8Array((x1-x0+9)*(y1-y0+9)),nw=x1-x0+9,samples=[[],[],[]];
      for(let k=0;k<end;k++){const i=queue[k],x=i%w,y=i/w|0;
       for(let yy=Math.max(0,y-4);yy<=Math.min(h-1,y+4);yy++)for(let xx=Math.max(0,x-4);xx<=Math.min(w-1,x+4);xx++){
        const c=(yy-y0+4)*nw+xx-x0+4,d=Math.max(Math.abs(xx-x),Math.abs(yy-y));if(d<2||near[c])continue;
        const j=yy*w+xx;if(out[j*4+3]||!paper(j))continue;
        let close=false;
        for(let v=Math.max(0,yy-1);v<=Math.min(h-1,yy+1)&&!close;v++)
         for(let u=Math.max(0,xx-1);u<=Math.min(w-1,xx+1);u++)if(out[(v*w+u)*4+3]===255){close=true;break;}
        if(close)continue;near[c]=1;for(let q=0;q<3;q++)samples[q].push(rgba[j*4+q]);}}
      if(samples[0].length<4)continue;
      const colour=samples.map(v=>v.sort((a,z)=>a-z)[v.length>>1]);
      for(let k=0;k<end;k++){const i=queue[k]*4;out[i]=colour[0];out[i+1]=colour[1];out[i+2]=colour[2];}
     }})();
     (()=>{for(let pass=0;pass<2;pass++){
      const ring=[];
      for(let i=0;i<n;i++){if(out[i*4+3]||!paper(i))continue;const x=i%w,y=i/w|0;let count=0,r0=0,r1=0,r2=0;
       for(let yy=Math.max(0,y-1);yy<=Math.min(h-1,y+1);yy++)for(let xx=Math.max(0,x-1);xx<=Math.min(w-1,x+1);xx++){
        const j=(yy*w+xx)*4;if(out[j+3]!==255)continue;count++;r0+=out[j];r1+=out[j+1];r2+=out[j+2];}
       if(count)ring.push(i,r0/count,r1/count,r2/count);}
      for(let k=0;k<ring.length;k+=4){const i=ring[k]*4;out[i]=ring[k+1];out[i+1]=ring[k+2];out[i+2]=ring[k+3];out[i+3]=254;}
      for(let k=0;k<ring.length;k+=4)out[ring[k]*4+3]=255;
     }})();
     return {...result,erased};
    }

    // Local exposed-paper support around OCR-owned connected ink.
    // WebAssembly path of aidokuLocalComponentRestore after its background mode: same ink/paper masks, 8-connected parts,
    // ring colours and paint. Returns the proposal, null, or 2 when the parts outgrow the scratch table.
    function aidokuLocalComponentKernel(kernels,rgba,w,h,n,l,t,right,bottom,b,bg,excluded,samples,options){
     const at=kernels.heap,excludedAt=at+n*4,inkAt=excludedAt+n,seenAt=inkAt+n,safeAt=seenAt+n,paintAt=safeAt+n,outputAt=(paintAt+n+3)&~3;
     const qAt=outputAt+n*4,pointsAt=qAt+n*4,partsAt=pointsAt+n*4,capacity=Math.max(64,(n>>4)),statsAt=partsAt+capacity*32,bgAt=(statsAt+16+7)&~7;
     const buffer=kernels.memory.buffer;
     new Uint8Array(buffer,at,n*4).set(rgba);new Uint8Array(buffer,excludedAt,n).set(excluded);new Float64Array(buffer,bgAt,3).set(bg);
     const status=kernels.exports.local_components(at,w,h,l,t,right,bottom,bgAt,Math.max(b[2],b[3]),excludedAt,inkAt,seenAt,safeAt,qAt,paintAt,
       seenAt,outputAt,partsAt,capacity,pointsAt,statsAt);
     if(status===2)return 2;
     if(!status)return null;
     const stats=new Int32Array(buffer,statsAt,4),erased=stats[0],components=stats[1],unresolved=stats[2],frame=stats[3];
     if(erased<8||components<1||erased>samples*.7)return null;
     const safe=new Uint8Array(buffer.slice(safeAt,safeAt+n));
     for(const a of options.auxiliary||[])for(let y=Math.floor(a[1]);y<Math.ceil(a[1]+a[3]);y++)
       for(let x=Math.floor(a[0]);x<Math.ceil(a[0]+a[2]);x++)if(x<0||y<0||x>=w||y>=h||!safe[y*w+x])return null;
     return {rgba:new Uint8ClampedArray(buffer.slice(outputAt,outputAt+n*4)),layoutSafe:safe,erased,components,radius:1,companions:0,
       preservedPixels:0,preservedCore:0,sourceGlyphsVerified:unresolved===0,sourceErasureVerified:unresolved===0&&frame===0,
       method:'local-component-paper',surfaceQuality:{safe:true,reason:'local-component-paper',coefficients:bg.map(v=>[v,0,0]),rmse:0,outliers:0}};
    }
    function aidokuLocalComponentRestore(rgba,w,h,b,palette,options={}){
     const n=w*h;
     if(options.slantedOwnership||!Number.isInteger(w)||!Number.isInteger(h)||w<8||h<8||n>262144||rgba?.length!==n*4||!Array.isArray(b)||b.length!==4||!b.every(Number.isFinite)||b[0]<2||b[1]<2||b[2]<3||b[3]<3||b[0]+b[2]>w-2||b[1]+b[3]>h-2)return null;
     if((options.auxiliary||[]).some(a=>!Array.isArray(a)||a.length!==4||!a.every(Number.isFinite)||a[0]<0||a[1]<0||a[2]<=0||a[3]<=0||a[0]+a[2]>w||a[1]+a[3]>h))return null;
     const excluded=new Uint8Array(n);
     for(const a of options.excluded||[]){
      if(!Array.isArray(a)||a.length!==4||!a.every(Number.isFinite))return null;
      for(let y=Math.max(0,Math.floor(a[1]));y<Math.min(h,Math.ceil(a[1]+a[3]));y++)
       for(let x=Math.max(0,Math.floor(a[0]));x<Math.min(w,Math.ceil(a[0]+a[2]));x++)excluded[y*w+x]=1;
     }
     const l=Math.floor(b[0]),t=Math.floor(b[1]),right=Math.ceil(b[0]+b[2]),bottom=Math.ceil(b[1]+b[3]);
     const bins=new Map();let samples=0;
     for(let y=t;y<bottom;y++)for(let x=l;x<right;x++){
      const i=(y*w+x)*4;if(rgba[i+3]<254)return null;
      const key=(rgba[i]>>4)*256+(rgba[i+1]>>4)*16+(rgba[i+2]>>4);let q=bins.get(key);if(!q){q=[0,0,0,0];bins.set(key,q)}q[0]++;for(let c=0;c<3;c++)q[c+1]+=rgba[i+c];samples++;
     }
     const rank=[...bins.values()].sort((a,b)=>b[0]-a[0]);if(!rank.length||rank[0][0]<samples*.18)return null;
     const bg=rank[0].slice(1).map(v=>v/rank[0][0]);
     const kernels=typeof aidokuPixelKernels==='function'?aidokuPixelKernels(n*23+4096):null;
     const kernelResult=kernels?aidokuLocalComponentKernel(kernels,rgba,w,h,n,l,t,right,bottom,b,bg,excluded,samples,options):2;
     if(kernelResult!==2)return kernelResult;
     const diff=i=>Math.max(Math.abs(rgba[i*4]-bg[0]),Math.abs(rgba[i*4+1]-bg[1]),Math.abs(rgba[i*4+2]-bg[2]));
     const ink=new Uint8Array(n),seen=new Uint8Array(n),safe=new Uint8Array(n),q=new Int32Array(n),paint=new Uint8Array(n),output=new Uint8ClampedArray(n*4);
     (()=>{for(let i=0;i<n;i++){ink[i]=diff(i)>22?1:0;safe[i]=diff(i)<=22?1:0;}})();
     const parts=[];let outsideDots=0,insideDots=0;
     (()=>{for(let start=0;start<n;start++){
      if(!ink[start]||seen[start])continue;
      let head=0,tail=1,x0=w,y0=h,x1=0,y1=0,inside=0;q[0]=start;seen[start]=1;
      while(head<tail){const i=q[head++],x=i%w,y=i/w|0;x0=Math.min(x0,x);x1=Math.max(x1,x);y0=Math.min(y0,y);y1=Math.max(y1,y);if(x>=l&&x<right&&y>=t&&y<bottom)inside++;
       for(let yy=Math.max(0,y-1);yy<=Math.min(h-1,y+1);yy++)for(let xx=Math.max(0,x-1);xx<=Math.min(w-1,x+1);xx++){const j=yy*w+xx;if(ink[j]&&!seen[j]){seen[j]=1;q[tail++]=j}}
      }
      if(tail<=5){if(inside)insideDots++;else outsideDots++;}
      if(!inside)continue;
      const contained=x0>=l-1&&y0>=t-1&&x1<=right&&y1<=bottom&&x0>2&&y0>2&&x1<w-3&&y1<h-3;
      parts.push({points:Array.from(q.subarray(0,tail)),x0,y0,x1,y1,inside,contained});
     }})();
     if(insideDots>=8&&outsideDots>=8)return null;
     let erased=0,components=0,unresolved=0,frame=0;
     (()=>{for(const part of parts){
      const {x0,y0,x1,y1,points,inside,contained}=part;
      if(!contained){frame+=inside;continue;}
      if(points.some(i=>excluded[i])){unresolved+=inside;continue;}
      if(points.length>(x1-x0+1)*(y1-y0+1)*.98&&points.length>24||Math.max(x1-x0+1,y1-y0+1)>Math.max(b[2],b[3])*1.1){unresolved+=inside;continue;}
      let total=0,good=0,sums=[0,0,0],sq=[0,0,0];
      for(let yy=y0-2;yy<=y1+2;yy++)for(let xx=x0-2;xx<=x1+2;xx++){
       if(xx>x0-2&&xx<x1+2&&yy>y0-2&&yy<y1+2)continue;
       const j=yy*w+xx;total++;if(ink[j])continue;good++;for(let c=0;c<3;c++){const v=rgba[j*4+c];sums[c]+=v;sq[c]+=v*v;}
      }
      if(good<12||good<total*.55){unresolved+=inside;continue;}
      const color=sums.map(v=>v/good),deviation=Math.max(...sq.map((v,c)=>Math.sqrt(Math.max(0,v/good-color[c]**2))));
      if(deviation>18){unresolved+=inside;continue;}
      const members=new Set(points);
      for(const i of points){
       const x=i%w,y=i/w|0;
       for(let yy=y-1;yy<=y+1;yy++)for(let xx=x-1;xx<=x+1;xx++){
        const j=yy*w+xx;if(excluded[j]||xx<l-1||xx>right||yy<t-1||yy>bottom||ink[j]&&!members.has(j))continue;
        if(!paint[j])erased++;paint[j]=1;safe[j]=1;for(let c=0;c<3;c++)output[j*4+c]=color[c];output[j*4+3]=255;
       }
      }
      components++;
     }})();
     if(erased<8||components<1||erased>samples*.7)return null;
     // Auxiliary OCR is mandatory; this simple proposal cannot silently omit it.
     for(const a of options.auxiliary||[])for(let y=Math.floor(a[1]);y<Math.ceil(a[1]+a[3]);y++)for(let x=Math.floor(a[0]);x<Math.ceil(a[0]+a[2]);x++)if(x<0||y<0||x>=w||y>=h||!safe[y*w+x])return null;
     return {rgba:output,layoutSafe:safe,erased,components,radius:1,companions:0,preservedPixels:0,preservedCore:0,sourceGlyphsVerified:unresolved===0,sourceErasureVerified:unresolved===0&&frame===0,method:'local-component-paper',surfaceQuality:{safe:true,reason:'local-component-paper',coefficients:bg.map(v=>[v,0,0]),rmse:0,outliers:0}};
    }

    // Lettering written on grid paper (manuscript squares, table cells). Straight
    // rules that cross the whole OCR body are not glyphs: every other restorer
    // either keeps them as unresolved ink or erases them with the letters,
    // leaving a blank slab. Here long thin bands of one colour that span the body
    // (rows and columns, evenly spaced) are kept, glyph pixels on them are redrawn
    // in the band's own colour, and only the remaining glyph components are
    // painted with the ring paper. Returns a verified restoration or null.
    function aidokuRuledGridRestore(rgba,w,h,b,options={}){
     const n=w*h;
     // Auxiliary ink (ruby, split marks) needs the general restorers' proof.
     if((options.auxiliary||[]).length||options.vertical===undefined)return null;
     if(!Number.isInteger(w)||!Number.isInteger(h)||w<16||h<16||n>262144||rgba?.length!==n*4||!Array.isArray(b)||b.length!==4||
       !b.every(Number.isFinite))return null;
     const l=Math.max(1,Math.floor(b[0])),t=Math.max(1,Math.floor(b[1])),r=Math.min(w-1,Math.ceil(b[0]+b[2])),bt=Math.min(h-1,Math.ceil(b[1]+b[3]));
     const bw=r-l,bh=bt-t;if(bw<24||bh<16)return null;
     // Paper: the dominant colour of the body.
     const counts=new Int32Array(4096),sums=new Float64Array(4096*3);let samples=0,opaque=true;
     // Every second pixel of every second row: the paper is the dominant colour either way.
     (()=>{for(let y=t;y<bt;y+=2)for(let x=l;x<r;x+=2){
      const i=(y*w+x)*4;if(rgba[i+3]<254){opaque=false;continue;}
      const key=(rgba[i]>>4)*256+(rgba[i+1]>>4)*16+(rgba[i+2]>>4);
      counts[key]++;sums[key*3]+=rgba[i];sums[key*3+1]+=rgba[i+1];sums[key*3+2]+=rgba[i+2];samples++;
     }})();
     if(!opaque||!samples)return null;
     let top=0;(()=>{for(let k=1;k<4096;k++)if(counts[k]>counts[top])top=k;})();
     if(counts[top]<samples*.3)return null;
     const paper=[sums[top*3]/counts[top],sums[top*3+1]/counts[top],sums[top*3+2]/counts[top]];
     if(Math.min(...paper)<150)return null;
     const dist=(i,c)=>Math.max(Math.abs(rgba[i*4]-c[0]),Math.abs(rgba[i*4+1]-c[1]),Math.abs(rgba[i*4+2]-c[2]));
     // Bands: rows (columns) whose longest ink run covers the body extent.
     let ink=null;
     const bands=(horizontal)=>{
      const from=horizontal?Math.max(0,t-4):Math.max(0,l-4),to=horizontal?Math.min(h,bt+4):Math.min(w,r+4);
      const a0=horizontal?l:t,a1=horizontal?r:bt,span=a1-a0,hit=new Uint8Array(to),cover=new Float64Array(to);
      (()=>{for(let k=from;k<to;k++){
       // A run over 85 % of the span holds at least 12 of 16 evenly spaced samples.
       if(!ink){let found=0;for(let j=0;j<16;j++){const a=a0+Math.floor((j+.5)*span/16),i=horizontal?k*w+a:a*w+k;if(dist(i,paper)>24)found++;}
        if(found<12){cover[k]=found/16;continue;}}
       let run=0,best=0,sum=0;
       for(let a=a0;a<a1;a++){const i=horizontal?k*w+a:a*w+k;if(ink?ink[i]:dist(i,paper)>24){run++;sum++;if(run>best)best=run;}else run=0;}
       hit[k]=best>=span*.85?1:0;cover[k]=sum/span;
      }})();
      // A rule doubled by a frame line a few pixels away is one band.
      const raw=[],out=[],limit=Math.max(4,Math.round(Math.min(bw,bh)*.12));
      for(let k=from;k<to;k++){
       if(!hit[k])continue;let e=k;while(e+1<to&&hit[e+1])e++;
       if(raw.length&&k-raw[raw.length-1][1]<=4)raw[raw.length-1][1]=e;else raw.push([k,e]);
       k=e;
      }
      for(const [k,e] of raw){
       const before=k-3>=0?cover[k-3]:0,after=e+3<to?cover[e+3]:0;
       if(e-k+1<=limit&&before<.5&&after<.5)out.push({start:k,end:e,center:(k+e)/2});
      }
      return out;
     };
     // Rules are evenly spaced and longer than their spacing; glyph strokes of a
     // short caption line are neither.
     const pitch=list=>{if(list.length<2)return 0;const gaps=list.slice(1).map((q,i)=>q.center-list[i].center).sort((p,q)=>p-q);
      return gaps[gaps.length>>1];};
     // Rows first, without per-pixel buffers: most captions have none and stop here.
     const rows=(list=>list.length>=2&&bw<pitch(list)?[]:list)(bands(true));
     if(rows.length<2)return null;
     const away=new Uint8Array(n);ink=new Uint8Array(n);
     (()=>{for(let i=0;i<n;i++){const d=dist(i,paper);away[i]=d;ink[i]=d>24?1:0;}})();
     const cols=(list=>list.length>=2&&bh<pitch(list)?[]:list)(bands(false));
     const even=list=>{if(list.length<3)return true;const gaps=list.slice(1).map((q,i)=>q.center-list[i].center),mid=pitch(list);
      return mid>=6&&gaps.filter(g=>Math.abs(g-mid)<=mid*.2).length>=gaps.length*.75;};
     const inside=(list,a,z)=>list.filter(q=>q.center>a+(z-a)*.12&&q.center<z-(z-a)*.12).length;
     // A boxed caption has only its frame; a grid has rules between the letters. Rules in
     // one direction only (underlined lines, a notebook) would cross the translation's
     // lines like a strikethrough, so they keep the general restorers.
     const grid=rows.length>=2&&cols.length>=2&&(inside(rows,t,bt)+inside(cols,l,r))>=2;
     if(!grid||!even(rows)||!even(cols))return null;
     // Rule mask and each rule's own colour, from its pixels that are not glyph ink.
     const rule=new Int16Array(n).fill(-1),refs=[];
     const median=values=>{values.sort((p,q)=>p-q);return values.length?values[values.length>>1]:0;};
     const histogram=new Uint32Array(768);
     (()=>{for(const [horizontal,list] of [[true,rows],[false,cols]])for(const band of list){
      const a0=horizontal?l:t,a1=horizontal?r:bt;
      for(let k=band.start-1;k<=band.end+1;k++){
       if(k<0||k>=(horizontal?h:w))continue;
       histogram.fill(0);
       for(let a=a0;a<a1;a++){const i=(horizontal?k*w+a:a*w+k)*4;histogram[rgba[i]]++;histogram[256+rgba[i+1]]++;histogram[512+rgba[i+2]]++;}
       const ref=[0,1,2].map(c=>{let seen=0,v=0;while(v<255&&(seen+=histogram[c*256+v])<=(a1-a0)>>1)v++;return v;});
       const id=refs.length;refs.push(ref);
       const edge=k<band.start||k>band.end;
       // Antialiased edge rows join only where they lean toward the rule.
       // Past the body the rule continues only through pixels of its colour.
       if(edge&&Math.max(...ref.map((v,c)=>Math.abs(v-paper[c])))<24)continue;
       for(let a=0;a<(horizontal?w:h);a++){const i=horizontal?k*w+a:a*w+k;
        if((a<a0-6||a>=a1+6)&&dist(i,ref)>40)continue;rule[i]=id;}
      }
     }})();
     const ruleInk=refs.map(ref=>Math.max(...ref.map((v,c)=>Math.abs(v-paper[c]))));
     // One coloured rule stock, distinct from dark lettering, identifies its stubs.
     const coloured=refs.filter((ref,i)=>ruleInk[i]>=24);
     let ruleColour=coloured.length?[0,1,2].map(c=>median(coloured.map(ref=>ref[c]))):null;
     if(ruleColour&&Math.max(...ruleColour)<120)ruleColour=null;
     // Glyph components: ink off the rules, 8-connected, inside the crop.
     const seen=new Uint8Array(n),q=new Int32Array(n),paint=new Uint8Array(n),foreign=new Uint8Array(n);
     const pitchH=rows.length>=2?(rows[rows.length-1].center-rows[0].center)/(rows.length-1):bh;
     const pitchV=cols.length>=2?(cols[cols.length-1].center-cols[0].center)/(cols.length-1):bw;
     const cell=Math.max(pitchH,pitchV)*1.6,label=new Int32Array(n).fill(-1),sizes=[],glyphLike=[];let components=0,failed=false;
     (()=>{for(let start=0;start<n&&!failed;start++){
      if(!ink[start]||rule[start]>=0||seen[start])continue;
      let head=0,tail=1,x0=w,y0=h,x1=0,y1=0,hits=0;q[0]=start;seen[start]=1;
      while(head<tail){const i=q[head++],x=i%w,y=i/w|0;x0=Math.min(x0,x);x1=Math.max(x1,x);y0=Math.min(y0,y);y1=Math.max(y1,y);
       if(x>=l&&x<r&&y>=t&&y<bt)hits++;
       for(let yy=Math.max(0,y-1);yy<=Math.min(h-1,y+1);yy++)for(let xx=Math.max(0,x-1);xx<=Math.min(w-1,x+1);xx++){
        const j=yy*w+xx;if(ink[j]&&rule[j]<0&&!seen[j]){seen[j]=1;q[tail++]=j;}}
      }
      const id=sizes.length;sizes.push(tail);glyphLike.push(x0>0&&y0>0&&x1<w-1&&y1<h-1&&tail<=cell*cell*.6);
      for(let k=0;k<tail;k++)label[q[k]]=id;
      // A neighbour that only grazes the body stays; it is not this caption's ink
      // (a piece across the outer rule is settled after the rules are redrawn).
      if(hits<Math.max(4,tail*.25)){if(tail>=12)for(let k=0;k<tail;k++)foreign[q[k]]=1;continue;}
      // Art reaching past the crop (a neighbouring title box, a frame) stays; it is not lettering.
      if(x0<=0||y0<=0||x1>=w-1||y1>=h-1){
       // Lettering cut by the crop or the page edge cannot be verified here.
       if(hits>=tail*.8){failed=true;break;}
       for(let k=0;k<tail;k++)foreign[q[k]]=1;continue;
      }
      // A drawing or a solid box inside the body: not handwriting on rules.
      if(x1-x0+1>cell||y1-y0+1>cell||tail>(x1-x0+1)*(y1-y0+1)*.9&&tail>cell*cell*.2){failed=true;break;}
      // A stub of a rule (its end or a tick past the body) keeps its pixels.
      if(ruleColour&&tail<=cell*4){let sum=[0,0,0];for(let k=0;k<tail;k++)for(let c=0;c<3;c++)sum[c]+=rgba[q[k]*4+c];
       if(Math.max(...sum.map((v,c)=>Math.abs(v/tail-ruleColour[c])))<=40)continue;}
      for(let k=0;k<tail;k++)paint[q[k]]=1;components++;
     }})();
     if(failed||!components)return null;
     // Glyph pixels lying on a rule (and their antialiasing, darker than the rule):
     // redraw that rule row's own colour.
     let redrawn=0,ruleTotal=0;
     (()=>{for(let i=0;i<n;i++){const id=rule[i];if(id<0)continue;ruleTotal++;
      const ref=refs[id],darker=ref[0]+ref[1]+ref[2]-rgba[i*4]-rgba[i*4+1]-rgba[i*4+2];
      if(away[i]>ruleInk[id]+24&&dist(i,ref)>Math.max(40,ruleInk[id]*.5)||darker>60){paint[i]=2;redrawn++;}}})();
     if(redrawn>ruleTotal*.35)return null;
     // A glyph cut by a rule is two pieces facing each other across it. The larger piece
     // tells whose glyph it is: a dakuten or tip beyond the block's outer rule is erased
     // with its glyph; the tip of a neighbouring line's glyph reaching into the block stays,
     // and so does its crossing of the rule. Another caption's box keeps its pieces.
     const owned=i=>{const x=i%w,y=i/w|0;return (options.excluded||[]).some(a=>x>=a[0]&&x<a[0]+a[2]&&y>=a[1]&&y<a[1]+a[3]);};
     const state=sizes.map(()=>0);
     (()=>{for(let i=0;i<n;i++)if(label[i]>=0&&paint[i]===1)state[label[i]]=1;})();
     const pairs=new Map();
     const facing=(horizontal,band,a)=>{
      const at=k=>horizontal?k*w+a:a*w+k,limit=horizontal?h:w;let before=-1,after=-1;
      for(let k=band.start-2;k>=Math.max(0,band.start-3)&&before<0;k--)before=label[at(k)];
      for(let k=band.end+2;k<=Math.min(limit-1,band.end+3)&&after<0;k++)after=label[at(k)];
      if(before>=0&&after>=0&&before!==after)pairs.set(before*sizes.length+after,[before,after]);
     };
     (()=>{for(const band of rows)for(let a=0;a<w;a++)facing(true,band,a);})();
     (()=>{for(const band of cols)for(let a=0;a<h;a++)facing(false,band,a);})();
     const drop=new Set(),take=new Set();
     (()=>{for(const [x,y] of pairs.values()){
      if(state[x]===state[y]||!glyphLike[x]||!glyphLike[y])continue;
      const [inside,outside]=state[x]?[x,y]:[y,x];
      if(sizes[outside]>sizes[inside])drop.add(inside);else take.add(outside);
     }})();
     (()=>{for(let i=0;i<n;i++){const id=label[i];if(id<0)continue;
      if(drop.has(id)){paint[i]=0;foreign[i]=1;}else if(take.has(id)&&!drop.has(id)&&!owned(i)){paint[i]=1;foreign[i]=0;}}})();
     // The crossings of a neighbour's glyph keep its original pixels.
     (()=>{for(let pass=0;pass<4;pass++)(()=>{const keep=[];for(let i=0;i<n;i++){if(paint[i]!==2)continue;const x=i%w,y=i/w|0;
      if(x>0&&foreign[i-1]||x<w-1&&foreign[i+1]||y>0&&foreign[i-w]||y<h-1&&foreign[i+w])keep.push(i);}
      for(const i of keep){paint[i]=0;foreign[i]=1;}})();})();
     // Antialiased fringe of the painted glyphs, two pixels deep.
     (()=>{for(let ring=0;ring<2;ring++){const fringe=[];
      (()=>{for(let i=0;i<n;i++){if(paint[i]||rule[i]>=0||away[i]<=6)continue;const x=i%w,y=i/w|0;
       if(x>0&&paint[i-1]===1||x<w-1&&paint[i+1]===1||y>0&&paint[i-w]===1||y<h-1&&paint[i+w]===1)fringe.push(i);}})();
      for(const i of fringe)paint[i]=1;}})();
     // Rule pixels beside a repaint take their rule's colour too, so a scaled canvas
     // never shows a sliver of the crossing glyph between opaque and clear pixels.
     (()=>{const edge=[];for(let i=0;i<n;i++){if(paint[i]||rule[i]<0)continue;const x=i%w,y=i/w|0;
      if(x>0&&paint[i-1]||x<w-1&&paint[i+1]||y>0&&paint[i-w]||y<h-1&&paint[i+w])edge.push(i);}
      for(const i of edge)paint[i]=2;})();
     // Two more pixels of paper, so the restored edge never lands on glyph antialiasing
     // when the canvas is scaled over the page.
     (()=>{for(let ring=0;ring<2;ring++)(()=>{const edge=[];for(let i=0;i<n;i++){if(paint[i]||rule[i]>=0||foreign[i])continue;const x=i%w,y=i/w|0;
      if(x>0&&paint[i-1]===1||x<w-1&&paint[i+1]===1||y>0&&paint[i-w]===1||y<h-1&&paint[i+w]===1)edge.push(i);}
      for(const i of edge)paint[i]=1;})();})();
     // Light rules read as paper under the translation: a thin pale line
     // crossing the letters does not cost their contrast. Dark rules count.
     const readable=new Uint8Array(n);
     (()=>{for(let i=0;i<n;i++){const id=rule[i];if(id<0||paint[i]===1)continue;const ref=refs[id];
      if(.2126*ref[0]+.7152*ref[1]+.0722*ref[2]>=110)readable[i]=1;}})();
     const output=new Uint8ClampedArray(n*4),safe=new Uint8Array(n);let erased=0;
     (()=>{for(let i=0;i<n;i++){
      // Ink left in place (a neighbour's lettering, art reaching in) is not a surface for text.
      const x=i%w,y=i/w|0;if(x>=l-1&&x<=r&&y>=t-1&&y<=bt&&!foreign[i])safe[i]=1;
      if(!paint[i])continue;const c=paint[i]===2?refs[rule[i]]:paper;
      output[i*4]=c[0];output[i*4+1]=c[1];output[i*4+2]=c[2];output[i*4+3]=255;erased++;safe[i]=1;
     }})();
     if(erased<8||erased>bw*bh*.6)return null;
     return {rgba:output,layoutSafe:safe,erased,components,radius:0,companions:0,preservedPixels:0,preservedCore:0,
       sourceGlyphsVerified:true,sourceErasureVerified:true,method:'ruled-grid',rules:[rows.length,cols.length],readableRules:readable,paper,
       surfaceQuality:{safe:false,reason:'ruled-grid'}};
    }

    // Completes an accepted in-place erasure along the caption's own lettering.
    // A glyph fused with a balloon rule, a panel border or a background shape
    // is one component with that structure, so the restorers above keep it as
    // art and only part of a word is erased (CH|ARACT|ER). Leftover pixels of
    // the erased ink colour inside the OCR body are opened by a fifth of the
    // measured stroke width, so thin rules fall away and glyph strokes remain.
    // A remaining part is lettering only when it stays inside the body, lies in
    // the text lines of the erased glyphs, is at least as thick as their strokes
    // (thinner drawing lines stay) and glyph-sized, is chained to the erased text,
    // and its ring is one or two flat colours. Rules it touches keep their pixels.
    // Everything else keeps the original pixels. Returns the repainted pixels.
    function aidokuCompleteConnectedLettering(original,w,h,b,restored,exclusions=[],vertical=null){
     const n=w*h,out=restored?.rgba,safe=restored?.layoutSafe;
     if(!out||out.length!==n*4||!original||original.length!==n*4||!Array.isArray(b)||!b.every(Number.isFinite))return 0;
     const l=Math.max(1,Math.floor(b[0])),t=Math.max(1,Math.floor(b[1])),r=Math.min(w-1,Math.ceil(b[0]+b[2])),bt=Math.min(h-1,Math.ceil(b[1]+b[3]));
     if(r-l<6||bt-t<6)return 0;
     // Exemplar: original colour of pixels the restoration repainted substantially.
     const hist=[new Uint32Array(256),new Uint32Array(256),new Uint32Array(256)];
     const fhist=[new Uint32Array(256),new Uint32Array(256),new Uint32Array(256)];
     const erasedInk=new Uint8Array(n);let inkCount=0;
     (()=>{for(let i=0;i<n;i++){
      if(!out[i*4+3])continue;const k=i*4;
      if(Math.max(Math.abs(original[k]-out[k]),Math.abs(original[k+1]-out[k+1]),Math.abs(original[k+2]-out[k+2]))<48)continue;
      erasedInk[i]=1;inkCount++;for(let c=0;c<3;c++){hist[c][original[k+c]]++;fhist[c][out[k+c]]++;}
     }})();
     if(inkCount<16)return 0;
     const median=hh=>{let half=inkCount/2,acc=0;for(let v=0;v<256;v++){acc+=hh[v];if(acc>=half)return v;}return 255;};
     const ink=hist.map(median),fill=fhist.map(median);
     const sep=Math.max(...ink.map((v,c)=>Math.abs(v-fill[c])));
     if(sep<48)return 0;
     const tol=Math.max(24,sep*.45);
     const cand=new Uint8Array(n);let inside=0;
     (()=>{for(let i=0;i<n;i++){
      if(out[i*4+3])continue;const k=i*4;
      const di=Math.max(Math.abs(original[k]-ink[0]),Math.abs(original[k+1]-ink[1]),Math.abs(original[k+2]-ink[2]));
      const df=Math.max(Math.abs(original[k]-fill[0]),Math.abs(original[k+1]-fill[1]),Math.abs(original[k+2]-fill[2]));
      if(di<=tol&&df>=sep*.5){cand[i]=1;const x=i%w,y=i/w|0;if(x>=l&&x<r&&y>=t&&y<bt)inside++;}
     }})();
     // Ink-like (glyph core, blends, shading): never a fill donor or a ring colour.
     const inkish=j=>{if(out[j*4+3])return false;const q=j*4;
      return Math.max(Math.abs(original[q]-ink[0]),Math.abs(original[q+1]-ink[1]),Math.abs(original[q+2]-ink[2]))<=sep*.85;};
     if(inside<Math.max(12,inkCount*.03))return 0;
     // Chamfer (3-4) distance to the nearest non-member pixel.
     const chamfer=(member,d)=>{
      for(let i=0;i<n;i++)d[i]=member[i]?65535:0;
      for(let y=0;y<h;y++)for(let x=0;x<w;x++){const i=y*w+x;if(!d[i])continue;let v=d[i];
       if(x>0)v=Math.min(v,d[i-1]+3);else v=Math.min(v,3);
       if(y>0){v=Math.min(v,d[i-w]+3);if(x>0)v=Math.min(v,d[i-w-1]+4);if(x<w-1)v=Math.min(v,d[i-w+1]+4);}else v=Math.min(v,3);
       d[i]=v;}
      for(let y=h-1;y>=0;y--)for(let x=w-1;x>=0;x--){const i=y*w+x;if(!d[i])continue;let v=d[i];
       if(x<w-1)v=Math.min(v,d[i+1]+3);else v=Math.min(v,3);
       if(y<h-1){v=Math.min(v,d[i+w]+3);if(x<w-1)v=Math.min(v,d[i+w+1]+4);if(x>0)v=Math.min(v,d[i+w-1]+4);}else v=Math.min(v,3);
       d[i]=v;}
     };
     const dist=new Uint16Array(n);chamfer(erasedInk,dist);
     let sum=0;(()=>{for(let i=0;i<n;i++)if(erasedInk[i])sum+=dist[i];})();
     // Mean inner distance of a stroke is about a quarter of its width.
     const stroke=Math.max(2,4*sum/inkCount/3),radius=Math.max(1,Math.min(3,Math.round(stroke*.2)));
     chamfer(cand,dist);
     const core=new Uint8Array(n);(()=>{for(let i=0;i<n;i++)core[i]=dist[i]>radius*3?1:0;})();
     // Opening: members within the radius of a surviving core.
     const outsideCore=new Uint8Array(n);(()=>{for(let i=0;i<n;i++)outsideCore[i]=core[i]?0:1;})();
     const reach=new Uint16Array(n);chamfer(outsideCore,reach);
     const opened=new Uint8Array(n);(()=>{for(let i=0;i<n;i++)opened[i]=cand[i]&&reach[i]<=radius*3+2?1:0;})();
     const label=new Int32Array(n),queue=new Int32Array(n),ringMark=new Uint8Array(n);let accepted=0,acceptedInk=0;const fillSet=new Uint8Array(n);
     const thickness=Math.min(b[2],b[3]),horizontal=vertical===null?b[2]>=b[3]:!vertical;
     // Text lines of the erased glyphs: rows (horizontal) or columns (vertical)
     // of the body holding erased ink. A part must lie in them, not between them.
     const lineAxis=horizontal?h:w,profile=new Uint32Array(lineAxis);let peak=0;
     (()=>{for(let i=0;i<n;i++){if(!erasedInk[i])continue;const x=i%w,y=i/w|0;if(x<l||x>=r||y<t||y>=bt)continue;
      const k=horizontal?y:x;profile[k]++;if(profile[k]>peak)peak=profile[k];}})();
     const onLine=new Uint8Array(lineAxis);(()=>{for(let k=0;k<lineAxis;k++)onLine[k]=profile[k]>=Math.max(2,peak*.05)?1:0;})();
     const excludedMask=new Uint8Array(n);
     (()=>{for(const a of exclusions){if(!Array.isArray(a)||a.length!==4||!a.every(Number.isFinite))continue;
      for(let y=Math.max(0,Math.floor(a[1]));y<Math.min(h,Math.ceil(a[1]+a[3]));y++)
       for(let x=Math.max(0,Math.floor(a[0]));x<Math.min(w,Math.ceil(a[0]+a[2]));x++)excludedMask[y*w+x]=1;}})();
     const excluded=(x,y)=>excludedMask[y*w+x]===1;
     let next=0;const parts=[];
     (()=>{for(let s=0;s<n;s++){
      if(!opened[s]||label[s])continue;next++;let head=0,tail=1;queue[0]=s;label[s]=next;
      let x0=w,x1=-1,y0=h,y1=-1,inBody=0,thick=0,touchesExclusion=false;
      while(head<tail){const i=queue[head++],x=i%w,y=i/w|0;
       if(x<x0)x0=x;if(x>x1)x1=x;if(y<y0)y0=y;if(y>y1)y1=y;
       if(x>=l&&x<r&&y>=t&&y<bt)inBody++;if(dist[i]>thick)thick=dist[i];
       if(!touchesExclusion&&excluded(x,y))touchesExclusion=true;
       for(let yy=Math.max(0,y-1);yy<=Math.min(h-1,y+1);yy++)for(let xx=Math.max(0,x-1);xx<=Math.min(w-1,x+1);xx++){
        const j=yy*w+xx;if(opened[j]&&!label[j]){label[j]=next;queue[tail++]=j;}}}
      const slack=Math.max(2,stroke*.25);
      let lined=0;for(let k=0;k<tail;k++){const i=queue[k];if(onLine[horizontal?i/w|0:i%w])lined++;}
      if(tail<8||inBody<tail*.9||touchesExclusion||x0<l-slack||x1>=r+slack||y0<t-slack||y1>=bt+slack||
          thick>(stroke*.75+1.5)*3||thick<stroke||Math.max(x1-x0+1,y1-y0+1)>thickness*1.4||lined<tail*.7)continue;
      parts.push({points:Array.from(queue.subarray(0,tail)),small:tail<stroke*stroke*.5});
     }})();
     if(!parts.length)return 0;
     // Member runs per row and column: a rule is a run reaching well past the part.
     const runLeft=new Uint16Array(n),runRight=new Uint16Array(n),runTop=new Uint16Array(n),runBottom=new Uint16Array(n);
     (()=>{for(let y=0;y<h;y++){let start=-1;for(let x=0;x<=w;x++){const on=x<w&&cand[y*w+x];
      if(on&&start<0)start=x;if(!on&&start>=0){for(let k=start;k<x;k++){runLeft[y*w+k]=start;runRight[y*w+k]=x-1;}start=-1;}}}})();
     (()=>{for(let x=0;x<w;x++){let start=-1;for(let y=0;y<=h;y++){const on=y<h&&cand[y*w+x];
      if(on&&start<0)start=y;if(!on&&start>=0){for(let k=start;k<y;k++){runTop[k*w+x]=start;runBottom[k*w+x]=y-1;}start=-1;}}}})();
     // Length of the member run through (x, y) along the body edge: a rule in the band.
     const runAlong=(x,y,horizontalRun)=>{let k=1;
      if(horizontalRun){for(let xx=x-1;xx>=0&&cand[y*w+xx];xx--)k++;for(let xx=x+1;xx<w&&cand[y*w+xx];xx++)k++;}
      else{for(let yy=y-1;yy>=0&&cand[yy*w+x];yy--)k++;for(let yy=y+1;yy<h&&cand[yy*w+x];yy++)k++;}return k;};
     const consider=part=>{
      // Fill region: the opened part with the thin ink next to it (never along
      // the body's edge where rules run), blends around it, and a halo of
      // non-ink pixels (glints) so the fill is interpolated from the surroundings.
      // Pixels an accepted part already took stay filled and are counted once.
      const points=part.points.filter(i=>fillSet[i]!==1);
      if(!points.length)return;
      const region=[];
      (()=>{for(const i of points){fillSet[i]=2;region.push(i);}})();
      // Thin arms (E, serifs) are followed for up to three stroke widths while they
      // stay at least a third of a stroke thick; edge pixels for radius+3 steps.
      const armSteps=Math.max(radius+3,Math.round(stroke*3)),armThickness=Math.max(3,stroke*.5);
      (()=>{for(let head2=0,step=0,end=region.length;step<armSteps&&head2<region.length;step++,end=region.length){
       for(;head2<end;head2++){const i=region[head2],x=i%w,y=i/w|0;
        for(let yy=Math.max(t+2,y-1);yy<=Math.min(bt-3,y+1);yy++)for(let xx=Math.max(l+2,x-1);xx<=Math.min(r-3,x+1);xx++){
         const j=yy*w+xx;if(fillSet[j]||!cand[j]||step>=radius+3&&dist[j]<armThickness)continue;fillSet[j]=2;region.push(j);}}}})();
      // Tips: three more steps without the thickness limit (frontier only).
      (()=>{for(let step=0,from=0;step<3;step++){const end=region.length;
       for(let m=from;m<end;m++){const i=region[m],x=i%w,y=i/w|0;
        for(let yy=Math.max(t+2,y-1);yy<=Math.min(bt-3,y+1);yy++)for(let xx=Math.max(l+2,x-1);xx<=Math.min(r-3,x+1);xx++){
         const j=yy*w+xx;if(fillSet[j]||!cand[j])continue;fillSet[j]=2;region.push(j);}}
       from=end;}})();
      // Glyph ends reach into the body's edge band: follow ink only straight
      // outwards there (three pixels), never along a rule running in the band.
      (()=>{for(let step=0,from=0;step<3;step++){const end=region.length;
       for(let m=from;m<end;m++){const i=region[m],x=i%w,y=i/w|0;
        for(let d=0;d<4;d++){const dx=d<2?0:d===2?-1:1,dy=d===0?-1:d===1?1:0,xx=x+dx,yy=y+dy;
         if(xx<l||xx>=r||yy<t||yy>=bt)continue;const j=yy*w+xx;if(fillSet[j]||!cand[j])continue;
         const topOrBottom=yy<t+2||yy>=bt-2,sideways=xx<l+2||xx>=r-2;
         if(!topOrBottom&&!sideways||topOrBottom&&dx!==0||sideways&&dy!==0)continue;
         if(runAlong(xx,yy,topOrBottom)>stroke*2)continue;
         fillSet[j]=2;region.push(j);}}
       from=end;}})();
      (()=>{for(let m=0,end=region.length;m<end;m++){const i=region[m],x=i%w,y=i/w|0;
       for(let yy=Math.max(0,y-2);yy<=Math.min(h-1,y+2);yy++)for(let xx=Math.max(0,x-2);xx<=Math.min(w-1,x+2);xx++){
        const j=yy*w+xx;if(fillSet[j]||out[j*4+3]||cand[j]||!inkish(j))continue;fillSet[j]=2;region.push(j);}}})();
      (()=>{for(let m=0,end=region.length;m<end;m++){const i=region[m],x=i%w,y=i/w|0;
       for(let yy=Math.max(0,y-2);yy<=Math.min(h-1,y+2);yy++)for(let xx=Math.max(0,x-2);xx<=Math.min(w-1,x+2);xx++){
        const j=yy*w+xx;if(fillSet[j]||out[j*4+3]||inkish(j))continue;fillSet[j]=2;region.push(j);}}})();
      // Ink on a run reaching a stroke width past the glyph is a rule the glyph
      // touches (panel border, balloon outline): it keeps its original pixels.
      {let px0=w,px1=-1,py0=h,py1=-1;
       (()=>{for(const i of region){if(!cand[i])continue;const x=i%w,y=i/w|0;if(x<px0)px0=x;if(x>px1)px1=x;if(y<py0)py0=y;if(y>py1)py1=y;}})();
       const reachOut=Math.max(3,stroke);let kept=0;
       (()=>{for(const i of region){
        if(cand[i]&&(runLeft[i]<px0-reachOut||runRight[i]>px1+reachOut||runTop[i]<py0-reachOut||runBottom[i]>py1+reachOut)){fillSet[i]=0;continue;}
        region[kept++]=i;}})();
       region.length=kept;}
      // Ring: one or two flat colours and little ink, or the part stays.
      const ring=[];
      (()=>{for(const i of region){const x=i%w,y=i/w|0;
       for(let yy=Math.max(0,y-1);yy<=Math.min(h-1,y+1);yy++)for(let xx=Math.max(0,x-1);xx<=Math.min(w-1,x+1);xx++){
        const j=yy*w+xx;if(!fillSet[j]&&!ringMark[j]){ringMark[j]=1;ring.push(j);}}}})();
      for(const j of ring)ringMark[j]=0;
      let ringInk=0,count=0;const colors=new Float32Array(ring.length*3);
      (()=>{for(const j of ring){if(inkish(j)){ringInk++;continue;}const src=out[j*4+3]?out:original,q=j*4;
       colors[count*3]=src[q];colors[count*3+1]=src[q+1];colors[count*3+2]=src[q+2];count++;}})();
      let flat=count>=12&&ringInk<=ring.length*.25;
      if(flat){
       // One or two flat colours (a shape edge may cross the part): two-means
       // from the most distant pair; 85 % of the ring within 24 of a centre.
       const gap=(k,c)=>Math.max(Math.abs(colors[k*3]-c[0]),Math.abs(colors[k*3+1]-c[1]),Math.abs(colors[k*3+2]-c[2]));
       const mean=[0,0,0];(()=>{for(let k=0;k<count;k++)for(let c=0;c<3;c++)mean[c]+=colors[k*3+c]/count;})();
       const far=from=>{let best=-1,at=0;for(let k=0;k<count;k++){const d=gap(k,from);if(d>best){best=d;at=k;}}
        return [colors[at*3],colors[at*3+1],colors[at*3+2]];};
       const centres=[far(mean)];centres.push(far(centres[0]));
       (()=>{for(let iteration=0;iteration<4;iteration++){
        const sums=[0,0,0,0,0,0,0,0];
        for(let k=0;k<count;k++){const o=gap(k,centres[0])<=gap(k,centres[1])?0:4;
         sums[o]+=colors[k*3];sums[o+1]+=colors[k*3+1];sums[o+2]+=colors[k*3+2];sums[o+3]++;}
        for(let c=0;c<2;c++)if(sums[c*4+3])centres[c]=[sums[c*4]/sums[c*4+3],sums[c*4+1]/sums[c*4+3],sums[c*4+2]/sums[c*4+3]];
       }})();
       let near=0;(()=>{for(let k=0;k<count;k++)if(Math.min(gap(k,centres[0]),gap(k,centres[1]))<=24)near++;})();
       if(near<count*.85)flat=false;
      }
      if(!flat){for(const i of region)fillSet[i]=0;return;}
      (()=>{for(const i of region){fillSet[i]=1;if(cand[i])acceptedInk++;}})();
      accepted+=region.length;
     };
     // Parts are lettering of this caption only when chained to the erased text:
     // within two stroke widths of erased ink or of a part accepted before.
     // (Art inside a loose OCR box, e.g. a drawn mark under a shout, is not.)
     const reachLimit=Math.max(6,stroke*2)*3,near=new Uint16Array(n),seeds=new Uint8Array(n),done=new Uint8Array(parts.length);
     (()=>{for(let round=0;round<4;round++){
      for(let i=0;i<n;i++)seeds[i]=erasedInk[i]||fillSet[i]===1?0:1;
      chamfer(seeds,near);let changed=false;
      parts.forEach((part,k)=>{if(done[k])return;
       let closest=65535;for(const i of part.points)if(near[i]<closest)closest=near[i];
       if(closest>reachLimit||part.small&&closest>6)return;
       done[k]=1;const before=accepted;consider(part);if(accepted>before)changed=true;});
      if(!changed)break;
     }})();
     if(!accepted||acceptedInk>inkCount*1.5)return 0;
     // Onion-peel fill from the known surroundings (restored colour where repainted).
     // Filled colours are written straight into the restoration output.
     let pending=[];(()=>{for(let i=0;i<n;i++)if(fillSet[i]===1)pending.push(i);})();
     (()=>{for(let pass=0;pending.length&&pass<64;pass++){
      const ready=[],waiting=[];
      for(const i of pending){const x=i%w,y=i/w|0;let k=0,s0=0,s1=0,s2=0;
       for(let yy=Math.max(0,y-1);yy<=Math.min(h-1,y+1);yy++)for(let xx=Math.max(0,x-1);xx<=Math.min(w-1,x+1);xx++){
        const j=yy*w+xx;if(fillSet[j]===1||!fillSet[j]&&inkish(j))continue;k++;
        const src=fillSet[j]===3||out[j*4+3]?out:original,q=j*4;s0+=src[q];s1+=src[q+1];s2+=src[q+2];}
       if(k>=2)ready.push(i,s0/k,s1/k,s2/k);else waiting.push(i);}
      if(!ready.length)break;
      for(let m=0;m<ready.length;m+=4){const q=ready[m]*4;out[q]=ready[m+1];out[q+1]=ready[m+2];out[q+2]=ready[m+3];fillSet[ready[m]]=3;}
      pending=waiting;
     }})();
     let painted=0;
     (()=>{for(let i=0;i<n;i++){if(fillSet[i]!==3)continue;out[i*4+3]=255;if(safe)safe[i]=1;painted++;}})();
     return painted;
    }

    """
}
