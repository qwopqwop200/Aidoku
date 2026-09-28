// Rectify only the bounded OCR neighborhood. Reconstruction owns glyph pixels,
// never an opaque enclosing rectangle that also contains nearby illustration.
enum BrowserSlantedSourceRestoration {
    // Large functions keep each outermost loop in `(()=>{...})();` (see BrowserOverlayView.renderScript).
    static let script = """
    // Auxiliary OCR rectangles are in page pixels too. Transform all four
    // corners, including the reading's extent when allocating the local crop.
    function aidokuSlantedLocalGeometry(box,angle,vertical=false,options={}) {
      const c=Math.cos(angle),s=Math.sin(angle),cx=box[0]+box[2]/2,cy=box[1]+box[3]/2;
      const transform=r=>[[r[0],r[1]],[r[0]+r[2],r[1]],[r[0]+r[2],r[1]+r[3]],[r[0],r[1]+r[3]]]
        .map(([x,y])=>[(x-cx)*c+(y-cy)*s+box[2]/2,-(x-cx)*s+(y-cy)*c+box[3]/2]);
      const valid=r=>Array.isArray(r)&&r.length===4&&r.every(Number.isFinite)&&r[2]>0&&r[3]>0;
      let auxiliary=(options.auxiliary||[]).filter(valid).slice(0,32).map(r=>{
        const q=transform(r),ac=Math.abs(c),as=Math.abs(s),det=ac*ac-as*as;
        // OCR stores page-axis envelopes. Taking their envelope once more in
        // local axes grows a narrow reading into nearby artwork. Recover the
        // shared-angle rectangle only when that inverse is well conditioned.
        const rw=(r[2]*ac-r[3]*as)/det,rh=(r[3]*ac-r[2]*as)/det;
        if(Math.abs(det)>=.15&&rw>=2&&rh>=2&&rw<=box[2]*1.2&&rh<=box[3]*1.2){
          const x=q.reduce((a,p)=>a+p[0],0)/4,y=q.reduce((a,p)=>a+p[1],0)/4;
          return [[x-rw/2,y-rh/2],[x+rw/2,y-rh/2],[x+rw/2,y+rh/2],[x-rw/2,y+rh/2]];
        }
        return q;
      });
      const polygons=(options.auxiliaryPolygons||[]).filter(q=>Array.isArray(q)&&q.length===4&&
        q.every(p=>Array.isArray(p)&&p.length===2&&p.every(Number.isFinite))).slice(0,32);
      if(polygons.length)auxiliary=polygons.map(q=>q.map(([x,y])=>
        [(x-cx)*c+(y-cy)*s+box[2]/2,-(x-cx)*s+(y-cy)*c+box[3]/2]));
      const exclusions=(options.inferredRubyExclusions||[]).filter(valid).slice(0,256).map(transform);
      const ruby=options.inferRuby?Math.min(96,(vertical?box[2]:box[3])*.8):0;
      // An upright replacement card is checked on this raster too. It widens
      // only the inspected extent; it is never treated as source ink.
      const cover=valid(options.cover)?transform(options.cover):[];
      const extent=[...auxiliary,cover].flatMap(q=>q);
      const left=Math.min(0,...extent.map(p=>p[0]))-24;
      const top=Math.min(vertical?0:-ruby,...extent.map(p=>p[1]))-24;
      const right=Math.max(box[2]+(vertical?ruby:0),...extent.map(p=>p[0]))+24;
      const bottom=Math.max(box[3],...extent.map(p=>p[1]))+24;
      // Mapping a quad through normalized page coordinates can turn 287 into
      // 287.00000000000006. Ceil must not add a row and shift all source ink by
      // half a pixel merely because of that round-trip error.
      const stable=value=>Math.round(value*1e7)/1e7;
      const spanX=stable(right-left),spanY=stable(bottom-top);
      const lw=Math.ceil(spanX),lh=Math.ceil(spanY),dx=(lw-spanX)/2,dy=(lh-spanY)/2;
      const bounds=q=>{const xs=q.map(p=>p[0]-left+dx),ys=q.map(p=>p[1]-top+dy);
        return [Math.min(...xs),Math.min(...ys),Math.max(...xs)-Math.min(...xs),Math.max(...ys)-Math.min(...ys)].map(stable);};
      return {lw,lh,b:[-left+dx,-top+dy,box[2],box[3]].map(stable),
        auxiliary:auxiliary.map(bounds),exclusions:exclusions.map(bounds)};
    }
    // Per-pixel passes of the rectified restoration live in small functions
    // so the engine's optimizing tiers can compile them. Each keeps the
    // original arithmetic and visiting order.
    // Bilinear page-to-local resampling. Clamped taps and weights are shared by
    // all four channels; the sum keeps the tap order (top-left, top-right,
    // bottom-left, bottom-right).
    function aidokuSlantedResample(rgba,w,h,local,lw,lh,cx,cy,c,s,ox,oy) {
      for(let y=0;y<lh;y++)for(let x=0;x<lw;x++){
        const dx=x+.5-ox,dy=y+.5-oy,px=cx+dx*c-dy*s-.5,py=cy+dx*s+dy*c-.5;
        const fx=Math.floor(px),fy=Math.floor(py),tx=px-fx,ty=py-fy;
        const ix0=Math.max(0,Math.min(w-1,fx)),ix1=Math.max(0,Math.min(w-1,fx+1));
        const iy0=Math.max(0,Math.min(h-1,fy)),iy1=Math.max(0,Math.min(h-1,fy+1));
        const t00=(iy0*w+ix0)*4,t01=(iy0*w+ix1)*4,t10=(iy1*w+ix0)*4,t11=(iy1*w+ix1)*4,ux=1-tx,uy=1-ty,out=(y*lw+x)*4;
        for(let k=0;k<4;k++)
          local[out+k]=0+rgba[t00+k]*ux*uy+rgba[t01+k]*tx*uy+rgba[t10+k]*ux*ty+rgba[t11+k]*tx*ty;
      }
    }
    function aidokuSlantedLinear(v) {v/=255;return v<=.04045?v/12.92:((v+.055)/1.055)**2.4;}
    // Relative luminance of the restored patch composited over the local crop.
    // Opaque or cleared cells composite to integer bytes; those reuse the
    // exact per-byte values of the same transfer function.
    function aidokuSlantedCompositeLuminance(restored,local,luminance,n) {
      const linearByte=new Float64Array(256);for(let v=0;v<256;v++)linearByte[v]=aidokuSlantedLinear(v);
      const linearOf=v=>v>=0&&v<=255&&(v|0)===v?linearByte[v]:aidokuSlantedLinear(v);
      for(let i=0;i<n;i++){
        const a=restored[i*4+3]/255;
        const c0=restored[i*4]*a+local[i*4]*(1-a),c1=restored[i*4+1]*a+local[i*4+1]*(1-a),c2=restored[i*4+2]*a+local[i*4+2]*(1-a);
        luminance[i]=Math.round(255*(.2126*linearOf(c0)+.7152*linearOf(c1)+.0722*linearOf(c2)));
      }
    }
    // Project owned local pixels back to the page raster. Returns the count.
    function aidokuSlantedProjectOwned(restored,layoutSafe,output,w,h,lw,lh,cx,cy,c,s,ox,oy) {
      let erased=0;
      for(let y=0;y<h;y++)for(let x=0;x<w;x++){
        const dx=x+.5-cx,dy=y+.5-cy,lx=dx*c+dy*s+ox-.5,ly=-dx*s+dy*c+oy-.5;
        const ix=Math.round(lx),iy=Math.round(ly);
        if(ix<1||iy<1||ix>=lw-1||iy>=lh-1||!layoutSafe[iy*lw+ix])continue;
        const dst=(y*w+x)*4;let weight=0,c0=0,c1=0,c2=0;
        const fx=Math.floor(lx),fy=Math.floor(ly),tx=lx-fx,ty=ly-fy;
        for(let yy=0;yy<2;yy++)for(let xx=0;xx<2;xx++){
          const j=((fy+yy)*lw+fx+xx)*4;if(!restored[j+3])continue;
          const a=(xx?tx:1-tx)*(yy?ty:1-ty);weight+=a;
          c0+=restored[j]*a;c1+=restored[j+1]*a;c2+=restored[j+2]*a;
        }
        if(weight<=0)continue;
        output[dst]=c0/weight;output[dst+1]=c1/weight;output[dst+2]=c2/weight;
        output[dst+3]=255;erased++;
      }
      return erased;
    }
    // Page pixels on the straight background-to-ink ramp (fringe tolerance).
    function aidokuSlantedRampPixels(rgba,raw,n,axis,bg,scale) {
      const a0=axis[0],a1=axis[1],a2=axis[2],b0=bg[0],b1=bg[1],b2=bg[2];
      for(let i=0;i<n;i++){
        const r0=rgba[i*4]-b0,r1=rgba[i*4+1]-b1,r2=rgba[i*4+2]-b2,t=(0+a0*r0+a1*r1+a2*r2)/scale;
        if(t>.06&&t<1.6&&Math.max(Math.abs(r0-a0*t),Math.abs(r1-a1*t),Math.abs(r2-a2*t))<=20)raw[i]=1;
      }
    }
    // One hole-filling pass: unpainted ink-polarity pixels inside the OCR
    // regions with at least five painted neighbours copy the last one found.
    // All candidates are chosen before any is filled. Returns the count.
    function aidokuSlantedFillHoles(rgba,output,w,h,axis,bg,scale,regions,cx,cy,c,s,ox,oy) {
      const a0=axis[0],a1=axis[1],a2=axis[2],b0=bg[0],b1=bg[1],b2=bg[2],holes=[];
      for(let y=1;y<h-1;y++)for(let x=1;x<w-1;x++){
        const i=y*w+x;if(output[i*4+3])continue;
        const dx=x+.5-cx,dy=y+.5-cy,u=dx*c+dy*s+ox,v=-dx*s+dy*c+oy;
        if(!regions.some(r=>u>=r[0]&&u<=r[0]+r[2]&&v>=r[1]&&v<=r[1]+r[3]))continue;
        const r0=rgba[i*4]-b0,r1=rgba[i*4+1]-b1,r2=rgba[i*4+2]-b2,projection=(0+a0*r0+a1*r1+a2*r2)/scale;
        const error=Math.max(Math.abs(r0-a0*projection),Math.abs(r1-a1*projection),Math.abs(r2-a2*projection));
        if(projection<=.15||projection>=1.6||error>60)continue;
        let covered=0,donor=-1;
        for(let yy=y-1;yy<=y+1;yy++)for(let xx=x-1;xx<=x+1;xx++){
          const j=yy*w+xx;if(output[j*4+3]){covered++;donor=j;}
        }
        if(covered>=5)holes.push([i,donor]);
      }
      for(const [i,donor] of holes)output.set(output.subarray(donor*4,donor*4+4),i*4);
      return holes.length;
    }
    // Unpainted source-ink pixels inside the OCR box that touch the projected mask.
    function aidokuSlantedExposedInk(rgba,output,w,h,box,cx,cy,c,s,sf,sb) {
      const remaining=[];
      for(let y=1;y<h-1;y++)for(let x=1;x<w-1;x++){
        const i=y*w+x;if(output[i*4+3])continue;
        const dx=x+.5-cx,dy=y+.5-cy,u=dx*c+dy*s,v=-dx*s+dy*c;
        if(Math.abs(u)>box[2]/2+2||Math.abs(v)>box[3]/2+2)continue;
        if(Math.max(Math.abs(sf[0]-rgba[i*4]),Math.abs(sf[1]-rgba[i*4+1]),Math.abs(sf[2]-rgba[i*4+2]))>36||
            Math.max(Math.abs(sb[0]-rgba[i*4]),Math.abs(sb[1]-rgba[i*4+1]),Math.abs(sb[2]-rgba[i*4+2]))<40)continue;
        let adjacent=false;
        for(let yy=y-1;yy<=y+1&&!adjacent;yy++)for(let xx=x-1;xx<=x+1;xx++)
          if(output[(yy*w+xx)*4+3]){adjacent=true;break;}
        if(adjacent)remaining.push(i);
      }
      return remaining;
    }
    // A local cell is newly safe only when every native bilinear donor was
    // erased; its luminance is taken from the composited page raster.
    function aidokuSlantedLayoutProof(rgba,output,w,h,layoutSafe,luminance,lw,lh,cx,cy,c,s,ox,oy) {
      for(let y=0;y<lh;y++)for(let x=0;x<lw;x++){
        const dx=x+.5-ox,dy=y+.5-oy,px=cx+dx*c-dy*s-.5,py=cy+dx*s+dy*c-.5;
        const fx=Math.floor(px),fy=Math.floor(py);
        if(fx<0||fy<0||fx+1>=w||fy+1>=h)continue;
        const tx=px-fx,ty=py-fy;let owned=true,c0=0,c1=0,c2=0;
        for(let yy=0;yy<2;yy++)for(let xx=0;xx<2;xx++){
          const j=((fy+yy)*w+fx+xx)*4,opaque=output[j+3]===255;if(!opaque)owned=false;
          const weight=(xx?tx:1-tx)*(yy?ty:1-ty),source=opaque?output:rgba;
          c0+=source[j]*weight;c1+=source[j+1]*weight;c2+=source[j+2]*weight;
        }
        const i=y*lw+x;
        if(owned)layoutSafe[i]=1;
        luminance[i]=Math.round(255*(.2126*aidokuSlantedLinear(c0)+.7152*aidokuSlantedLinear(c1)+.0722*aidokuSlantedLinear(c2)));
      }
    }
    function aidokuRestoreSlantedSource(rgba,w,h,box,angle,palette,vertical=false,options={}) {
      if(!rgba||rgba.length!==w*h*4||w*h>262144||!Array.isArray(box)||box.length!==4||
          !box.every(Number.isFinite)||!Number.isFinite(angle)||box[2]<3||box[3]<3)return null;
      const geometry=aidokuSlantedLocalGeometry(box,angle,vertical,options),{lw,lh,b}=geometry,n=lw*lh;
      if(n>262144)return null;
      const cx=box[0]+box[2]/2,cy=box[1]+box[3]/2,c=Math.cos(angle),s=Math.sin(angle);
      const local=new Uint8ClampedArray(n*4),ox=b[0]+box[2]/2,oy=b[1]+box[3]/2;
      // Pixel centers matter: a half-pixel shift leaves the old antialias fringe.
      aidokuSlantedResample(rgba,w,h,local,lw,lh,cx,cy,c,s,ox,oy);
      const auxiliary=geometry.auxiliary;
      if(options.inferRuby&&auxiliary.length===0&&palette?.background){
        const raw=new Uint8Array(n);
        (()=>{for(let i=0;i<n;i++)raw[i]=Math.max(local[i*4],local[i*4+1],local[i*4+2])<110?1:0;})();
        let inferred;
        if(vertical)inferred=aidokuInferVerticalRuby(raw,local,lw,lh,b,palette.background);
        else {
          // Horizontal readings above the body become right-hand columns in
          // this temporary 90-degree raster, using the same ownership rules.
          const turned=new Uint8ClampedArray(n*4),ink=new Uint8Array(n);
          (()=>{for(let y=0;y<lh;y++)for(let x=0;x<lw;x++){
            const i=y*lw+x,j=x*lh+lh-1-y;turned.set(local.subarray(i*4,i*4+4),j*4);ink[j]=raw[i];
          }})();
          inferred=aidokuInferVerticalRuby(ink,turned,lh,lw,[lh-b[1]-b[3],b[0],b[3],b[2]],palette.background)
            .map(r=>[r[1],lh-r[0]-r[2],r[3],r[2]]);
        }
        auxiliary.push(...inferred.filter(r=>!geometry.exclusions.some(q=>
          r[0]<q[0]+q[2]&&r[0]+r[2]>q[0]&&r[1]<q[1]+q[3]&&r[1]+r[3]>q[1])));
      }
      // Record the first failing gate for diagnostics (audit only).
      const failures=options.failures;
      const attempt=colors=>{
        const r=aidokuRestoreSourcePanel(local,lw,lh,b,colors,
          {readabilityGate:true,compactMask:true,protectArtMargin:true,slantedOwnership:true,vertical,sampleScale:1,
            auxiliary,inferredRubyExclusions:geometry.exclusions});
        const reason=!r?'panel':!r.erased?'nothing-erased':r.preservedCore>8?'preserved-core':!r.layoutSafe?'layout':
          !aidokuSlantedSurfaceFits(r)?'surface:'+(r.surfaceQuality?.reason||'none'):
          aidokuSlantedResidualInk(local,lw,lh,b,r)?'residual':null;
        if(reason&&Array.isArray(failures))failures.push(reason);
        return reason?null:r;
      };
      let result=attempt(palette);
      // The page-axis sample may be dominated by artwork in the empty corners
      // of a steep quad. Retry its actual upright lettering, within the same
      // decoded crop and the color estimator's existing 24K-pixel limit.
      if(!result&&typeof aidokuEstimateSourceColors==='function'){
        const scale=Math.min(1,Math.sqrt(24576/(b[2]*b[3]))),sw=Math.floor(b[2]*scale),sh=Math.floor(b[3]*scale);
        if(sw>=8&&sh>=8){
          const sample=new Uint8ClampedArray(sw*sh*4);
          (()=>{for(let y=0;y<sh;y++)for(let x=0;x<sw;x++){
            const j=(Math.floor(b[1]+(y+.5)*b[3]/sh)*lw+Math.floor(b[0]+(x+.5)*b[2]/sw))*4;
            sample.set(local.subarray(j,j+4),(y*sw+x)*4);
          }})();
          const colors=aidokuEstimateSourceColors(sample,sw,sh);
          if(colors?.foreground&&colors?.background){
            result=attempt(colors)||aidokuSlantedFlatGlyphs(local,lw,lh,b,colors);
            if(result&&aidokuSlantedResidualInk(local,lw,lh,b,result))result=null;
          }
        }
      }
      if(!result)return null;
      // A few antialias donors can contaminate diffusion even on flat paper.
      // Use the independently fitted surface for the owned pixels when its
      // residual and outlier checks passed; never repaint its enclosing box.
      const quality=result.surfaceQuality;
      if(quality?.reason==='smooth'&&quality.rmse>3&&quality.rmse<=8&&quality.outliers<=.025){
        (()=>{for(let i=0;i<n;i++)if(result.rgba[i*4+3]){
          const x=(i%lw)/lw,y=(i/lw|0)/lh;
          for(let k=0;k<3;k++){
            const a=quality.coefficients[k];result.rgba[i*4+k]=a[0]+a[1]*x+a[2]*y;
          }
        }})();
      }
      const output=new Uint8ClampedArray(w*h*4),luminance=new Uint8Array(n);
      aidokuSlantedCompositeLuminance(result.rgba,local,luminance,n);
      // Only owned mask pixels are projected back. Unmodified page pixels
      // stay on the original image and never undergo a second resampling.
      let erased=aidokuSlantedProjectOwned(result.rgba,result.layoutSafe,output,w,h,lw,lh,cx,cy,c,s,ox,oy);
      // The second sampling pass can strand soft native edges around an
      // otherwise erased glyph. Complete only the same connected ink whose
      // overwhelming majority was already owned; detached drawing is intact.
      if(result.surfaceQuality?.reason==='smooth'){
        const seen=new Uint8Array(w*h),raw=new Uint8Array(w*h),queue=new Int32Array(w*h);
        const fg=result.sourceForeground,bg=result.sourceBackground,axis=fg.map((v,k)=>v-bg[k]);
        const norm=axis.reduce((a,v)=>a+v*v,0);
        aidokuSlantedRampPixels(rgba,raw,w*h,axis,bg,Math.max(1,norm));
        const regions=[b,...auxiliary];
        (()=>{for(let start=0;start<raw.length;start++){
          if(!raw[start]||seen[start])continue;
          let head=0,tail=1,painted=0,inside=0,left=w,top=h,right=0,bottom=0,ul=Infinity,ut=Infinity,ur=-Infinity,ub=-Infinity;queue[0]=start;seen[start]=1;
          while(head<tail){
            const i=queue[head++],x=i%w,y=i/w|0;painted+=Boolean(output[i*4+3]);
            left=Math.min(left,x);right=Math.max(right,x);top=Math.min(top,y);bottom=Math.max(bottom,y);
            const dx=x+.5-cx,dy=y+.5-cy,u=dx*c+dy*s+ox,v=-dx*s+dy*c+oy;
            ul=Math.min(ul,u);ut=Math.min(ut,v);ur=Math.max(ur,u);ub=Math.max(ub,v);
            if(regions.some(r=>u>=r[0]-2&&u<=r[0]+r[2]+2&&v>=r[1]-2&&v<=r[1]+r[3]+2))inside++;
            for(let yy=Math.max(0,y-1);yy<=Math.min(h-1,y+1);yy++)for(let xx=Math.max(0,x-1);xx<=Math.min(w-1,x+1);xx++){
              const j=yy*w+xx;if(raw[j]&&!seen[j]){seen[j]=1;queue[tail++]=j;}
            }
          }
          let enclosedFringe=false;
          if(tail<=16&&painted<tail*.85&&inside===tail){
            let contacts=0,covered=0,soft=true;
            for(let k=0;k<tail;k++){
              const i=queue[k],x=i%w,y=i/w|0;
              if(Math.max(Math.abs(fg[0]-rgba[i*4]),Math.abs(fg[1]-rgba[i*4+1]),Math.abs(fg[2]-rgba[i*4+2]))<40)soft=false;
              for(let yy=Math.max(0,y-1);yy<=Math.min(h-1,y+1);yy++)for(let xx=Math.max(0,x-1);xx<=Math.min(w-1,x+1);xx++){
                const j=yy*w+xx;if(raw[j])continue;contacts++;covered+=Boolean(output[j*4+3]);
              }
            }
            enclosedFringe=soft&&contacts>=6&&covered>=contacts*.75;
          }
          const compactGlyph=tail<=128&&painted>=tail*.3&&inside===tail&&
            right-left<=16&&bottom-top<=16&&tail<(right-left+1)*(bottom-top+1)*.8;
          const smallFringe=tail<=32&&painted>=tail*.08&&inside===tail&&right-left<=8&&bottom-top<=8;
          let readingContinuation=false;
          if(vertical&&tail>=2&&tail<=256&&inside===tail&&ur-ul<=14&&ub-ut<=40&&
              Math.max(...fg)<=100&&Math.min(...bg)>=220&&auxiliary.some(r=>
                ul>=r[0]-2&&ur<=r[0]+r[2]+2&&ut>=r[1]&&ut<=r[1]+r[3]+96)){
            let support=0;
            for(let y=Math.max(1,top-20);y<=Math.min(h-2,bottom+20);y++)for(let x=Math.max(1,left-20);x<=Math.min(w-2,right+20);x++){
              if(!output[(y*w+x)*4+3])continue;
              const dx=x+.5-cx,dy=y+.5-cy,u=dx*c+dy*s+ox,v=-dx*s+dy*c+oy;
              if(u>=ul-16&&u<ul-2&&v>=ut-6&&v<=ub+6)support++;
            }
            readingContinuation=support>=6;
          }
          if(!enclosedFringe&&!compactGlyph&&!smallFringe&&!readingContinuation&&painted<tail*.85||inside<tail*.98){
            const longRule=Math.max(ur-ul,ub-ut)>Math.min(ur-ul+1,ub-ut+1)*12||
              Math.max(ur-ul,ub-ut)>=40&&tail<(ur-ul+1)*(ub-ut+1)*.12;
            // Projection may touch a few pixels of an otherwise intact rule.
            // Return those pixels to the original instead of nicking the art.
            if(painted&&tail>=12&&painted<tail*.5&&longRule){
              const untouched=new Set();
              for(let k=0;k<tail;k++){
                const x=queue[k]%w,y=queue[k]/w|0;
                // Curved clothing folds also have a pale antialias edge.
                for(let yy=Math.max(0,y-1);yy<=Math.min(h-1,y+1);yy++)
                  for(let xx=Math.max(0,x-1);xx<=Math.min(w-1,x+1);xx++)untouched.add(yy*w+xx);
              }
              for(const i of untouched){
                if(!output[i*4+3])continue;
                output[i*4+3]=0;erased--;
                const x=i%w,y=i/w|0,dx=x+.5-cx,dy=y+.5-cy;
                const xx=Math.round(dx*c+dy*s+ox-.5),yy=Math.round(-dx*s+dy*c+oy-.5);
                if(xx>=0&&xx<lw&&yy>=0&&yy<lh)result.layoutSafe[yy*lw+xx]=0;
              }
            }
            continue;
          }
          for(let k=0;k<tail;k++){
            const i=queue[k];if(output[i*4+3])continue;
            const x=i%w,y=i/w|0;let donor=-1,distance=Infinity;
            for(let yy=Math.max(0,y-3);yy<=Math.min(h-1,y+3);yy++)for(let xx=Math.max(0,x-3);xx<=Math.min(w-1,x+3);xx++){
              const j=yy*w+xx,d=(x-xx)**2+(y-yy)**2;
              if(output[j*4+3]&&d<distance){distance=d;donor=j;}
            }
            if(donor<0&&(readingContinuation||smallFringe)){
              const dx=x+.5-cx,dy=y+.5-cy,u=(dx*c+dy*s+ox)/lw,v=(-dx*s+dy*c+oy)/lh;
              for(let k=0;k<3;k++){const a=quality.coefficients[k];output[i*4+k]=a[0]+a[1]*u+a[2]*v;}
              output[i*4+3]=255;erased++;
            }
            if(donor>=0){output.set(output.subarray(donor*4,donor*4+4),i*4);erased++;}
          }
        }})();
      }
      // Fill isolated codec/resampling holes surrounded by an already owned
      // glyph. This cannot grow a box over the artwork: every added pixel must
      // touch at least five painted neighbours and match the ink polarity.
      if(result.surfaceQuality?.reason==='smooth'){
        const fg=result.sourceForeground,bg=result.sourceBackground,axis=fg.map((v,k)=>v-bg[k]);
        const norm=axis.reduce((a,v)=>a+v*v,0),regions=[b,...auxiliary];
        (()=>{for(let pass=0;pass<2;pass++)
          erased+=aidokuSlantedFillHoles(rgba,output,w,h,axis,bg,Math.max(1,norm),regions,cx,cy,c,s,ox,oy);})();
      }
      // The rectified mask alone cannot prove that projecting it back covered
      // the native source raster. Check exposed ink immediately beside the
      // projected mask before committing any replacement.
      const remaining=aidokuSlantedExposedInk(rgba,output,w,h,box,cx,cy,c,s,result.sourceForeground,result.sourceBackground);
      if(remaining.length>=3){
        const seen=new Uint8Array(w*h),queue=new Int32Array(w*h);
        const fg=result.sourceForeground,bg=result.sourceBackground,axis=fg.map((v,k)=>v-bg[k]);
        const norm=axis.reduce((a,v)=>a+v*v,0);
        const a0=axis[0],a1=axis[1],a2=axis[2],b0=bg[0],b1=bg[1],b2=bg[2],scale=Math.max(1,norm);
        const ink=i=>{
          const r0=rgba[i*4]-b0,r1=rgba[i*4+1]-b1,r2=rgba[i*4+2]-b2,t=(0+a0*r0+a1*r1+a2*r2)/scale;
          return t>.08&&t<1.2&&Math.max(Math.abs(r0-a0*t),Math.abs(r1-a1*t),Math.abs(r2-a2*t))<=24;
        };
        for(const start of remaining){
          if(seen[start])continue;
          let head=0,tail=1,cores=0,painted=0;queue[0]=start;seen[start]=1;
          while(head<tail){
            const i=queue[head++],x=i%w,y=i/w|0;
            if(Math.max(Math.abs(fg[0]-rgba[i*4]),Math.abs(fg[1]-rgba[i*4+1]),Math.abs(fg[2]-rgba[i*4+2]))<=36){cores++;if(output[i*4+3])painted++;}
            for(let yy=Math.max(0,y-1);yy<=Math.min(h-1,y+1);yy++)for(let xx=Math.max(0,x-1);xx<=Math.min(w-1,x+1);xx++){
              const j=yy*w+xx;if(!seen[j]&&ink(j)){seen[j]=1;queue[tail++]=j;}
            }
          }
          // A surviving contour may touch the mask. It is not a partially
          // erased letter unless most of that same ink component was owned.
          if(cores-painted>=3&&painted>cores*.5)return null;
        }
      }
      // Native fringe completion must also update the layout proof. A local
      // cell is newly safe only when every native bilinear donor was erased;
      // unowned drawing cannot become available to the translated glyphs.
      // Contrast is measured on the actual composite, including untouched
      // paper beside an erased edge. Requiring four owned donors here kept
      // the old glyph's dark luminance after its native pixels were erased.
      aidokuSlantedLayoutProof(rgba,output,w,h,result.layoutSafe,luminance,lw,lh,cx,cy,c,s,ox,oy);
      return {rgba:output,layoutSafe:result.layoutSafe,luminance,lw,lh,box:b,erased,
        localPixels:n,auxiliary,method:'rectified-'+result.method,surfaceQuality:result.surfaceQuality};
    }

    // Resampling a tilted outline can make a textured or illustrated backing
    // look locally smooth. Such a fit leaves pale letter silhouettes or paints
    // flat spots across the drawing. Require a well-supported reconstruction,
    // including the local residual when diffusion supplies the donor colors.
    function aidokuSlantedSurfaceFits(result) {
      const q=result.surfaceQuality;
      if(!q?.safe)return false;
      if(q.reason==='smooth')return q.rmse<=8&&q.outliers<=.025;
      if(q.reason==='locally-smooth')return q.localRMSE<=1.5&&q.edgeFraction<=.015;
      return q.reason==='periodic'||q.reason==='exemplar-texture'||q.reason==='flat-glyph-boundary';
    }

    // Tiny flat labels can have no diffusion donors after the illustration
    // margin is reserved. A verified two-color glyph boundary permits direct
    // replacement of its ink, without filling the label's rectangle.
    function aidokuSlantedFlatGlyphs(rgba,w,h,b,palette) {
      const fg=palette?.foreground,bg=palette?.background,n=w*h;
      if(!fg||!bg||n>262144)return null;
      const delta=fg.map((v,k)=>v-bg[k]),norm=delta.reduce((a,v)=>a+v*v,0);
      if(norm<3600)return null;
      const raw=new Uint8Array(n),core=new Uint8Array(n),seen=new Uint8Array(n),mask=new Uint8Array(n),queue=new Int32Array(n);
      const distance=(i,color)=>Math.max(Math.abs(color[0]-rgba[i*4]),Math.abs(color[1]-rgba[i*4+1]),Math.abs(color[2]-rgba[i*4+2]));
      const d0=delta[0],d1=delta[1],d2=delta[2],b0=bg[0],b1=bg[1],b2=bg[2];
      for(let i=0;i<n;i++){
        const r0=rgba[i*4]-b0,r1=rgba[i*4+1]-b1,r2=rgba[i*4+2]-b2,t=(0+d0*r0+d1*r1+d2*r2)/norm;
        const error=Math.max(Math.abs(r0-d0*t),Math.abs(r1-d1*t),Math.abs(r2-d2*t));
        if(t>.05&&t<1.15&&error<=12)raw[i]=1;
        if(distance(i,fg)<=24)core[i]=1;
      }
      let components=0,owned=0;
      for(let start=0;start<n;start++){
        if(!raw[start]||seen[start])continue;
        let head=0,tail=1,l=w,t=h,r=0,d=0,strong=0;queue[0]=start;seen[start]=1;
        while(head<tail){
          const i=queue[head++],x=i%w,y=i/w|0;l=Math.min(l,x);r=Math.max(r,x);t=Math.min(t,y);d=Math.max(d,y);strong+=core[i];
          for(let yy=Math.max(0,y-1);yy<=Math.min(h-1,y+1);yy++)for(let xx=Math.max(0,x-1);xx<=Math.min(w-1,x+1);xx++){
            const j=yy*w+xx;if(raw[j]&&!seen[j]){seen[j]=1;queue[tail++]=j;}
          }
        }
        if(strong<2||l<b[0]-1||t<b[1]-1||r>b[0]+b[2]+1||d>b[1]+b[3]+1||
            l<2||t<2||r>=w-2||d>=h-2||r-l>b[2]*.96||d-t>b[3]*.96||tail>(r-l+1)*(d-t+1)*.88)continue;
        let donors=0,agree=0;
        for(let k=0;k<tail;k++){
          const i=queue[k];
          for(const j of [i-1,i+1,i-w,i+w])if(!raw[j]){donors++;if(distance(j,bg)<=16)agree++;}
        }
        if(donors<6||agree<donors*.97)continue;
        components++;owned+=strong;for(let k=0;k<tail;k++)mask[queue[k]]=1;
      }
      if(components<2||owned<8)return null;
      // No unexplained interior color may be mistaken for blank backing.
      let surface=0,total=0;
      for(let y=Math.ceil(b[1]);y<b[1]+b[3];y++)for(let x=Math.ceil(b[0]);x<b[0]+b[2];x++){
        const i=y*w+x;total++;if(mask[i]||distance(i,bg)<=16)surface++;
      }
      if(surface<total*.96)return null;
      const output=new Uint8ClampedArray(n*4),safe=new Uint8Array(n);let erased=0;
      for(let i=0;i<n;i++){
        if(mask[i]){output.set([...bg,255],i*4);erased++;}
        if(mask[i]||distance(i,bg)<=16)safe[i]=1;
      }
      return {rgba:output,layoutSafe:safe,erased,method:'flat-glyph-boundary',sourceForeground:fg,sourceBackground:bg,
        surfaceQuality:{safe:true,reason:'flat-glyph-boundary'}};
    }

    function aidokuSlantedResidualInk(original,w,h,b,result) {
      const fg=result.sourceForeground,bg=result.sourceBackground;
      if(!fg||!bg)return true;
      const separation=Math.max(...fg.map((v,k)=>Math.abs(v-bg[k]))),tolerance=Math.min(32,separation*.3);
      const seen=new Uint8Array(w*h),raw=new Uint8Array(w*h),core=new Uint8Array(w*h),queue=new Int32Array(w*h);
      const axis=fg.map((v,k)=>v-bg[k]),norm=axis.reduce((a,v)=>a+v*v,0);
      const a0=axis[0],a1=axis[1],a2=axis[2],b0=bg[0],b1=bg[1],b2=bg[2],f0=fg[0],f1=fg[1],f2=fg[2],scale=Math.max(1,norm);
      for(let i=0;i<w*h;i++){
        const v0=original[i*4],v1=original[i*4+1],v2=original[i*4+2];
        const r0=v0-b0,r1=v1-b1,r2=v2-b2,projection=(0+a0*r0+a1*r1+a2*r2)/scale;
        if(projection>.08&&projection<1.2&&Math.max(Math.abs(r0-a0*projection),Math.abs(r1-a1*projection),Math.abs(r2-a2*projection))<=24)raw[i]=1;
        if(!result.rgba[i*4+3]&&Math.max(Math.abs(f0-v0),Math.abs(f1-v1),Math.abs(f2-v2))<=tolerance)core[i]=1;
      }
      for(let start=0;start<raw.length;start++){
        if(!raw[start]||seen[start])continue;
        let head=0,tail=1,l=w,t=h,r=0,d=0,inside=0;queue[0]=start;seen[start]=1;
        while(head<tail){
          const i=queue[head++],x=i%w,y=i/w|0;l=Math.min(l,x);t=Math.min(t,y);r=Math.max(r,x);d=Math.max(d,y);
          if(core[i]&&x>=b[0]-3&&x<=b[0]+b[2]+3&&y>=b[1]-3&&y<=b[1]+b[3]+3)inside++;
          for(let yy=Math.max(0,y-1);yy<=Math.min(h-1,y+1);yy++)for(let xx=Math.max(0,x-1);xx<=Math.min(w-1,x+1);xx++){
            const j=yy*w+xx;if(raw[j]&&!seen[j]){seen[j]=1;queue[tail++]=j;}
          }
        }
        // Continuous rules/contours leave the crop; isolated remaining glyphs
        // do not. Partial erasure is never committed beneath a translation.
        const contained=l>=b[0]-3&&r<=b[0]+b[2]+3&&t>=b[1]-3&&d<=b[1]+b[3]+3;
        const line=Math.max(r-l+1,d-t+1)>Math.min(r-l+1,d-t+1)*12;
        if(inside>=3&&!line&&(contained||inside>tail*.5)&&
            (l>2&&t>2&&r<w-3&&d<h-3||inside>tail*.7))return true;
      }
      return false;
    }

    // A page-axis restoration of a slanted caption owns pixels of the quad's
    // axis-aligned box, whose corners can hold neighbouring lettering or
    // drawing. Visible changes are confined to the slanted quad (with a small
    // ink margin) and its auxiliary readings, the area the rotated plate would
    // hide. A connected visible change entirely off the quad is returned to
    // the original and, with its neighbours, made unavailable for layout. One
    // that crosses the quad edge would leave a partial glyph or a cut drawing
    // either way, so the proposal is rejected, as it is when most of the
    // visible change lies off the quad. The cached result is never modified.
    function aidokuPageErasureInQuad(panel,quad,angle,auxiliary,palette) {
      const {w,h,result,original,sx,sy,x:ox,y:oy}=panel,n=w*h;
      if(!result?.rgba||result.rgba.length!==n*4||!result.layoutSafe||original?.length!==n*4||!(sx>0)||!(sy>0)||
          quad.length!==4||!quad.every(Number.isFinite))return null;
      const c=Math.cos(angle),s=Math.sin(angle),cx=quad[0]+quad[2]/2,cy=quad[1]+quad[3]/2;
      const margin=Math.max(2,Math.min(8,Math.min(quad[2],quad[3])*.15));
      const rgba=result.rgba.slice(),safe=result.layoutSafe.slice(),changed=new Uint8Array(n);
      for(let i=0;i<n;i++)if(rgba[i*4+3]&&Math.max(Math.abs(rgba[i*4]-original[i*4]),Math.abs(rgba[i*4+1]-original[i*4+1]),
        Math.abs(rgba[i*4+2]-original[i*4+2]))>24)changed[i]=1;
      const on=i=>{
        const px=(i%w+.5)/sx+ox,py=((i/w|0)+.5)/sy+oy,dx=px-cx,dy=py-cy;
        return Math.max(Math.abs(dx*c+dy*s)-quad[2]/2,Math.abs(-dx*s+dy*c)-quad[3]/2)<=margin||
          auxiliary.some(r=>px>=r[0]-margin&&px<=r[0]+r[2]+margin&&py>=r[1]-margin&&py<=r[1]+r[3]+margin);
      };
      const seen=new Uint8Array(n),queue=new Int32Array(n);
      let inside=0,outside=0;
      for(let start=0;start<n;start++){
        if(!changed[start]||seen[start])continue;
        let head=0,tail=1,count=0;queue[0]=start;seen[start]=1;
        while(head<tail){
          const i=queue[head++],x=i%w,y=i/w|0;if(on(i))count++;
          for(let yy=Math.max(0,y-1);yy<=Math.min(h-1,y+1);yy++)for(let xx=Math.max(0,x-1);xx<=Math.min(w-1,x+1);xx++){
            const j=yy*w+xx;if(changed[j]&&!seen[j]){seen[j]=1;queue[tail++]=j;}
          }
        }
        if(count===tail){inside+=tail;continue;}
        if(count>0)return null;
        outside+=tail;
        for(let k=0;k<tail;k++){
          const i=queue[k],x=i%w,y=i/w|0;rgba[i*4+3]=0;
          for(let yy=Math.max(0,y-1);yy<=Math.min(h-1,y+1);yy++)for(let xx=Math.max(0,x-1);xx<=Math.min(w-1,x+1);xx++)safe[yy*w+xx]=0;
        }
      }
      if(!inside||outside>inside)return null;
      // The plate hid all lettering on the quad. Source-colored ink left
      // inside it (another reading, a part the proposal did not own) would
      // stay visible beside the translation.
      const fg=palette?.foreground,bg=palette?.background;
      if(!fg||!bg)return null;
      let residual=0;
      for(let i=0;i<n;i++){
        if(changed[i])continue;
        const px=(i%w+.5)/sx+ox,py=((i/w|0)+.5)/sy+oy,dx=px-cx,dy=py-cy;
        if(Math.max(Math.abs(dx*c+dy*s)-quad[2]/2,Math.abs(-dx*s+dy*c)-quad[3]/2)>-1)continue;
        const r=original[i*4],g=original[i*4+1],b=original[i*4+2];
        if(Math.max(Math.abs(r-fg[0]),Math.abs(g-fg[1]),Math.abs(b-fg[2]))<=36&&
            Math.max(Math.abs(r-bg[0]),Math.abs(g-bg[1]),Math.abs(b-bg[2]))>=40)residual++;
      }
      if(residual>Math.max(8,inside*.03))return null;
      return {...panel,result:{...result,rgba,layoutSafe:safe},safe,dropped:outside};
    }
    // Erased pixels of a page raster (origin and pixels per image pixel) that
    // lie off the slanted quad (image pixels, same ink margin as above) and
    // off its auxiliary readings.
    function aidokuErasureOffQuad(rgba,w,h,ox,oy,scale,quad,angle,auxiliary) {
      const c=Math.cos(angle),s=Math.sin(angle),cx=quad[0]+quad[2]/2,cy=quad[1]+quad[3]/2;
      const margin=Math.max(2,Math.min(8,Math.min(quad[2],quad[3])*.15));
      let erased=0,off=0;
      for(let y=0;y<h;y++)for(let x=0;x<w;x++){
        if(!rgba[(y*w+x)*4+3])continue;
        erased++;
        const px=(x+.5)/scale+ox,py=(y+.5)/scale+oy,dx=px-cx,dy=py-cy;
        if(Math.max(Math.abs(dx*c+dy*s)-quad[2]/2,Math.abs(-dx*s+dy*c)-quad[3]/2)<=margin)continue;
        if(auxiliary.some(r=>px>=r[0]-margin&&px<=r[0]+r[2]+margin&&py>=r[1]-margin&&py<=r[1]+r[3]+margin))continue;
        off++;
      }
      return {erased,off};
    }
    // Outcome of a glyph-surface check. A survey (audit.survey) inspects
    // every pixel instead of stopping at the first failure and reports the
    // quantized surface luminance range under the glyphs and how many pixels
    // were unsafe or too close to the ink; the ink then fits only if none
    // was. audit.histogram (256 bins) collects the surface luminance.
    function aidokuSlantedInkAudit(audit,minimumContrast,low,high,unsafe,unsafeDim,dim,samples) {
      if(audit)Object.assign(audit,{minimumContrast,unsafe,unsafeDim,dim,samples,range:Number.isFinite(low)?[low,high]:null});
      return !unsafe&&!dim&&Number.isFinite(minimumContrast);
    }
    // Rotated glyph rectangles (node-local CSS px, before the rotation about
    // the node centre) on a page-axis restoration: every raster pixel under a
    // glyph must be proven clean surface with contrast of at least 4.5.
    // toImage maps a page CSS point to image pixels.
    function aidokuRotatedPageInkFits(panel,rects,node,angle,toImage,foreground,audit=null) {
      const {w,h,safe,luminance,sx,sy,x:ox,y:oy}=panel;
      if(!safe||!luminance||!rects.length||!(sx>0)||!(sy>0))return false;
      const linear=v=>{v/=255;return v<=.04045?v/12.92:((v+.055)/1.055)**2.4;};
      const fg=.2126*linear(foreground[0])+.7152*linear(foreground[1])+.0722*linear(foreground[2]);
      const c=Math.cos(angle),s=Math.sin(angle),cx=node[0]+node[2]/2,cy=node[1]+node[3]/2;
      const page=(lx,ly)=>{const dx=lx-node[2]/2,dy=ly-node[3]/2;return [cx+dx*c-dy*s,cy+dx*s+dy*c];};
      const origin=toImage(cx,cy),unitX=toImage(cx+1,cy),unitY=toImage(cx,cy+1);
      // Image pixels per CSS pixel along the page axes (an affine map).
      const ax=[unitX[0]-origin[0],unitX[1]-origin[1]],ay=[unitY[0]-origin[0],unitY[1]-origin[1]];
      const det=ax[0]*ay[1]-ax[1]*ay[0];
      if(!(Math.abs(det)>1e-9))return false;
      let samples=0,minimumContrast=Infinity,low=Infinity,high=-Infinity,unsafe=0,unsafeDim=0,dim=0;
      const survey=Boolean(audit?.survey),histogram=audit?.histogram||null;
      for(const r of rects){
        const corners=[[r[0],r[1]],[r[2],r[1]],[r[2],r[3]],[r[0],r[3]]].map(([lx,ly])=>{
          const [px,py]=toImage(...page(lx,ly));return [(px-ox)*sx,(py-oy)*sy];});
        const l=Math.floor(Math.min(...corners.map(p=>p[0])))-1,t=Math.floor(Math.min(...corners.map(p=>p[1])))-1;
        const right=Math.ceil(Math.max(...corners.map(p=>p[0])))+1,bottom=Math.ceil(Math.max(...corners.map(p=>p[1])))+1;
        if(l<0||t<0||right>w||bottom>h)return false;
        // One raster pixel of guard around the rectangle, in node-local units.
        const guard=1/Math.min(Math.hypot(ax[0]*sx,ax[1]*sy),Math.hypot(ay[0]*sx,ay[1]*sy));
        for(let y=t;y<bottom;y++)for(let x=l;x<right;x++){
          // Raster pixel centre -> image -> page CSS -> node-local.
          const ix=(x+.5)/sx+ox-origin[0],iy=(y+.5)/sy+oy-origin[1];
          const px=cx+(ix*ay[1]-iy*ay[0])/det,py=cy+(iy*ax[0]-ix*ax[1])/det;
          const dx=px-cx,dy=py-cy,lx=dx*c+dy*s+node[2]/2,ly=-dx*s+dy*c+node[3]/2;
          if(lx<r[0]-guard||lx>r[2]+guard||ly<r[1]-guard||ly>r[3]+guard)continue;
          if(++samples>262144)return false;
          const i=y*w+x;if(!safe[i]&&!survey)return false;
          const quantized=luminance[i]/255;
          const bg=quantized>=fg?Math.max(fg,quantized-1/510):Math.min(fg,quantized+1/510);
          const contrast=(Math.max(bg,fg)+.05)/(Math.min(bg,fg)+.05);
          // A survey also reads unsafe pixels: one that no ink could read
          // on is counted apart from one merely unproven.
          if(!safe[i]){unsafe++;if(contrast<4.5)unsafeDim++;continue;}
          low=Math.min(low,luminance[i]);high=Math.max(high,luminance[i]);if(histogram)histogram[luminance[i]]++;
          if(contrast<4.5){if(!survey)return false;dim++;continue;}
          minimumContrast=Math.min(minimumContrast,contrast);
        }
      }
      return aidokuSlantedInkAudit(audit,minimumContrast,low,high,unsafe,unsafeDim,dim,samples);
    }
    // Source-coloured pixels left on the area a rotated plate would hide:
    // composite luminance nearer the sampled ink than a third of the way
    // to the sampled background. inside(i) selects the plate's pixels of the
    // luminance raster. Null when the palette cannot separate ink from paper.
    function aidokuPlateLeftoverInk(luminance,n,inside,palette) {
      const fg=palette?.foreground,bg=palette?.background;
      if(!luminance||!Array.isArray(fg)||!Array.isArray(bg))return null;
      const lum=rgb=>.2126*aidokuSlantedLinear(rgb[0])+.7152*aidokuSlantedLinear(rgb[1])+.0722*aidokuSlantedLinear(rgb[2]);
      const f=lum(fg)*255,b=lum(bg)*255;
      if(Math.abs(f-b)<24)return null;
      let area=0,ink=0;
      for(let i=0;i<n;i++){
        if(!inside(i))continue;
        area++;if(Math.abs(luminance[i]-f)*2<Math.abs(luminance[i]-b))ink++;
      }
      return area?{area,ink}:null;
    }
    // Corners of a w x h card centred at (cx,cy), rotated by angle about its
    // centre, each side moved out by margin (page CSS px).
    function aidokuRotatedCard(cx,cy,w,h,angle,margin=0) {
      const c=Math.cos(angle),s=Math.sin(angle),a=w/2+margin,b=h/2+margin;
      return [[-a,-b],[a,-b],[a,b],[-a,b]].map(([x,y])=>[cx+x*c-y*s,cy+x*s+y*c]);
    }
    // Separating-axis test: do two convex polygons share interior area?
    function aidokuConvexOverlap(p,q) {
      for(const poly of [p,q])for(let i=0;i<poly.length;i++){
        const a=poly[i],b=poly[(i+1)%poly.length],nx=b[1]-a[1],ny=a[0]-b[0];
        let p0=Infinity,p1=-Infinity,q0=Infinity,q1=-Infinity;
        for(const v of p){const d=v[0]*nx+v[1]*ny;p0=Math.min(p0,d);p1=Math.max(p1,d);}
        for(const v of q){const d=v[0]*nx+v[1]*ny;q0=Math.min(q0,d);q1=Math.max(q1,d);}
        if(p1<=q0||q1<=p0)return false;
      }
      return true;
    }
    // Separating-axis penetration depth of two convex polygons (0 when clear).
    function aidokuConvexDepth(p,q) {
      let least=Infinity;
      for(const poly of [p,q])for(let i=0;i<poly.length;i++){
        const a=poly[i],b=poly[(i+1)%poly.length],l=Math.hypot(b[0]-a[0],b[1]-a[1])||1;
        const nx=(b[1]-a[1])/l,ny=(a[0]-b[0])/l;
        let p0=Infinity,p1=-Infinity,q0=Infinity,q1=-Infinity;
        for(const v of p){const d=v[0]*nx+v[1]*ny;p0=Math.min(p0,d);p1=Math.max(p1,d);}
        for(const v of q){const d=v[0]*nx+v[1]*ny;q0=Math.min(q0,d);q1=Math.max(q1,d);}
        least=Math.min(least,Math.max(0,Math.min(p1,q1)-Math.max(p0,q0)));
      }
      return least;
    }
    // Push-pull diffusion: fills the unknown pixels of an RGB float image
    // from its known ones (coarser levels first); null when none is known.
    function aidokuPushPull(values,known,w,h) {
      const w2=(w+1)>>1,h2=(h+1)>>1;
      if(w<=2&&h<=2||w2*h2>=w*h){
        const mean=[0,0,0];let count=0;
        for(let i=0;i<w*h;i++)if(known[i]){count++;for(let c=0;c<3;c++)mean[c]+=values[i*3+c];}
        if(!count)return null;
        for(let i=0;i<w*h;i++)if(!known[i])for(let c=0;c<3;c++)values[i*3+c]=mean[c]/count;
        return values;
      }
      const small=new Float32Array(w2*h2*3),weight=new Float32Array(w2*h2);
      for(let y=0;y<h;y++)for(let x=0;x<w;x++){
        const i=y*w+x;if(!known[i])continue;
        const j=(y>>1)*w2+(x>>1);weight[j]++;for(let c=0;c<3;c++)small[j*3+c]+=values[i*3+c];
      }
      const smallKnown=new Uint8Array(w2*h2);
      for(let j=0;j<w2*h2;j++)if(weight[j]>0){smallKnown[j]=1;for(let c=0;c<3;c++)small[j*3+c]/=weight[j];}
      if(!aidokuPushPull(small,smallKnown,w2,h2))return null;
      for(let y=0;y<h;y++)for(let x=0;x<w;x++){
        const i=y*w+x;if(known[i])continue;
        const sx=Math.min(w2-1,Math.max(0,(x+.5)/2-.5)),sy=Math.min(h2-1,Math.max(0,(y+.5)/2-.5));
        const x0=Math.floor(sx),y0=Math.floor(sy),x1=Math.min(w2-1,x0+1),y1=Math.min(h2-1,y0+1),fx=sx-x0,fy=sy-y0;
        for(let c=0;c<3;c++)values[i*3+c]=(small[(y0*w2+x0)*3+c]*(1-fx)+small[(y0*w2+x1)*3+c]*fx)*(1-fy)+
          (small[(y1*w2+x0)*3+c]*(1-fx)+small[(y1*w2+x1)*3+c]*fx)*fy;
      }
      return values;
    }
    // Is point p inside (or on) the convex polygon poly (either winding)?
    function aidokuPointInConvex(poly,p) {
      let sign=0;
      for(let i=0;i<poly.length;i++){
        const a=poly[i],b=poly[(i+1)%poly.length],c=(b[0]-a[0])*(p[1]-a[1])-(b[1]-a[1])*(p[0]-a[0]);
        if(Math.abs(c)<1e-9)continue;
        if(sign&&Math.sign(c)!==sign)return false;
        sign=Math.sign(c);
      }
      return true;
    }
    // The convex polygon subject clipped by the convex polygon clip
    // (Sutherland-Hodgman); both in the same coordinates, either winding.
    function aidokuClipConvex(subject,clip) {
      let area=0;
      for(let i=0;i<clip.length;i++){const a=clip[i],b=clip[(i+1)%clip.length];area+=a[0]*b[1]-a[1]*b[0];}
      const winding=Math.sign(area)||1;
      let out=subject;
      for(let i=0;i<clip.length&&out.length;i++){
        const a=clip[i],b=clip[(i+1)%clip.length];
        const side=p=>((b[0]-a[0])*(p[1]-a[1])-(b[1]-a[1])*(p[0]-a[0]))*winding;
        const input=out;out=[];
        for(let j=0;j<input.length;j++){
          const p=input[j],q=input[(j+1)%input.length],sp=side(p),sq=side(q);
          if(sp>=0)out.push(p);
          if((sp>=0)!==(sq>=0)){const t=sp/(sp-sq);out.push([p[0]+(q[0]-p[0])*t,p[1]+(q[1]-p[1])*t]);}
        }
      }
      return out;
    }
    // Upright glyph rectangles (page CSS px) as local-axis envelopes of the
    // slanted card: the rotated quad's box, same units as aidokuSlantedInkFits.
    function aidokuSlantedLocalRects(rects,box,angle) {
      const c=Math.cos(angle),s=Math.sin(angle),cx=box[0]+box[2]/2,cy=box[1]+box[3]/2;
      return rects.map(r=>{
        const q=[[r[0],r[1]],[r[2],r[1]],[r[2],r[3]],[r[0],r[3]]]
          .map(([x,y])=>[(x-cx)*c+(y-cy)*s+box[2]/2,-(x-cx)*s+(y-cy)*c+box[3]/2]);
        const xs=q.map(p=>p[0]),ys=q.map(p=>p[1]);
        return [Math.min(...xs),Math.min(...ys),Math.max(...xs),Math.max(...ys)];
      });
    }
    // The source ink judged on the 2nd..98th percentile of the surface under
    // the glyphs (histogram: 256 bins of 255 x relative luminance). A few
    // dark (light) specks there - speckle, a crossing balloon line, erasure
    // remnants - must not veto an ink that reads on the surface itself. The
    // ink takes its smallest correction on that range and keeps its side of
    // it (a sample inside the range is more likely the surface than the
    // lettering); at most 2 % of the surface pixels may read below 4.5, and
    // each of them must be a speck, clearly apart from the range (1.5:1),
    // not the continuing tail of a gradient.
    // Returns {ink,contrast,dim,total,range} or null.
    function aidokuRobustSurfaceInk(source,histogram) {
      if(!Array.isArray(source)||source.length!==3||!source.every(Number.isFinite)||!histogram)return null;
      let total=0;for(let v=0;v<256;v++)total+=histogram[v];
      if(total<64)return null;
      const at=q=>{let n=0;for(let v=0;v<256;v++){n+=histogram[v];if(n>q)return v;}return 255;};
      const lo=Math.max(0,(at(Math.floor((total-1)*.02))-.5)/255),hi=Math.min(1,(at(Math.ceil((total-1)*.98))+.5)/255);
      const lum=rgb=>.2126*aidokuSlantedLinear(rgb[0])+.7152*aidokuSlantedLinear(rgb[1])+.0722*aidokuSlantedLinear(rgb[2]);
      const contrast=rgb=>{const l=lum(rgb);return l<lo?(lo+.05)/(l+.05):l>hi?(l+.05)/(hi+.05):1;};
      const side=l=>l<lo?-1:l>hi?1:0,polarity=side(lum(source));
      if(!polarity)return null;
      const ink=aidokuAdjustInkForContrast(source,contrast);
      if(side(lum(ink))!==polarity||contrast(ink)<4.5)return null;
      // Pixels the ink does not read on, with the glyph checks' half-step
      // quantization headroom.
      const fg=lum(ink);let dim=0;
      for(let v=0;v<256;v++){
        if(!histogram[v])continue;
        const q=v/255,bg=q>=fg?Math.max(fg,q-1/510):Math.min(fg,q+1/510);
        if((Math.max(bg,fg)+.05)/(Math.min(bg,fg)+.05)>=4.5)continue;
        if((q<lo?(lo+.05)/(q+.05):q>hi?(q+.05)/(hi+.05):1)<1.5)return null;
        dim+=histogram[v];
      }
      if(dim*50>total)return null;
      return {ink,contrast:contrast(ink),dim,total,range:[lo,hi]};
    }
    // Glyph rectangles are measured before rotation, in the card's local axes.
    // A clear center alone cannot authorize drawing over a nearby outline.
    function aidokuSlantedInkFits(restored,rects,scale,foreground,audit=null) {
      if(!restored||!rects.length||!Number.isFinite(scale)||scale<=0)return false;
      const {lw:w,lh:h,box:b,layoutSafe:safe,luminance}=restored;
      const linear=v=>{v/=255;return v<=.04045?v/12.92:((v+.055)/1.055)**2.4;};
      const fg=.2126*linear(foreground[0])+.7152*linear(foreground[1])+.0722*linear(foreground[2]);
      let samples=0,minimumContrast=Infinity,low=Infinity,high=-Infinity,unsafe=0,unsafeDim=0,dim=0;
      const survey=Boolean(audit?.survey),histogram=audit?.histogram||null;
      for(const r of rects){
        const l=Math.floor(b[0]+r[0]*scale)-1,t=Math.floor(b[1]+r[1]*scale)-1;
        const right=Math.ceil(b[0]+r[2]*scale)+1,bottom=Math.ceil(b[1]+r[3]*scale)+1;
        if(l<0||t<0||right>w||bottom>h)return false;
        for(let y=t;y<bottom;y++)for(let x=l;x<right;x++){
          if(++samples>262144)return false;
          const i=y*w+x;if(!safe[i]&&!survey)return false;
          const quantized=luminance[i]/255;
          const bg=quantized>=fg?Math.max(fg,quantized-1/510):Math.min(fg,quantized+1/510);
          const contrast=(Math.max(bg,fg)+.05)/(Math.min(bg,fg)+.05);
          // A survey also reads unsafe pixels: one that no ink could read
          // on is counted apart from one merely unproven.
          if(!safe[i]){unsafe++;if(contrast<4.5)unsafeDim++;continue;}
          low=Math.min(low,luminance[i]);high=Math.max(high,luminance[i]);if(histogram)histogram[luminance[i]]++;
          if(contrast<4.5){if(!survey)return false;dim++;continue;}
          minimumContrast=Math.min(minimumContrast,contrast);
        }
      }
      return aidokuSlantedInkAudit(audit,minimumContrast,low,high,unsafe,unsafeDim,dim,samples);
    }
    """
}
