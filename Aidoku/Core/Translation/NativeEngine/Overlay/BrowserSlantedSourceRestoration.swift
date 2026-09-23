// Rectify only the bounded OCR neighborhood. Reconstruction owns glyph pixels,
// never an opaque enclosing rectangle that also contains nearby illustration.
enum BrowserSlantedSourceRestoration {
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
      const left=Math.min(0,...auxiliary.flatMap(q=>q.map(p=>p[0])))-24;
      const top=Math.min(vertical?0:-ruby,...auxiliary.flatMap(q=>q.map(p=>p[1])))-24;
      const right=Math.max(box[2]+(vertical?ruby:0),...auxiliary.flatMap(q=>q.map(p=>p[0])))+24;
      const bottom=Math.max(box[3],...auxiliary.flatMap(q=>q.map(p=>p[1])))+24;
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
    function aidokuRestoreSlantedSource(rgba,w,h,box,angle,palette,vertical=false,options={}) {
      if(!rgba||rgba.length!==w*h*4||w*h>262144||!Array.isArray(box)||box.length!==4||
          !box.every(Number.isFinite)||!Number.isFinite(angle)||box[2]<3||box[3]<3)return null;
      const geometry=aidokuSlantedLocalGeometry(box,angle,vertical,options),{lw,lh,b}=geometry,n=lw*lh;
      if(n>262144)return null;
      const cx=box[0]+box[2]/2,cy=box[1]+box[3]/2,c=Math.cos(angle),s=Math.sin(angle);
      const local=new Uint8ClampedArray(n*4),ox=b[0]+box[2]/2,oy=b[1]+box[3]/2;
      // Pixel centers matter: a half-pixel shift leaves the old antialias fringe.
      for(let y=0;y<lh;y++)for(let x=0;x<lw;x++){
        const dx=x+.5-ox,dy=y+.5-oy,px=cx+dx*c-dy*s-.5,py=cy+dx*s+dy*c-.5;
        const fx=Math.floor(px),fy=Math.floor(py),tx=px-fx,ty=py-fy;
        for(let k=0;k<4;k++){
          let value=0;
          for(let yy=0;yy<2;yy++)for(let xx=0;xx<2;xx++){
            const ix=Math.max(0,Math.min(w-1,fx+xx)),iy=Math.max(0,Math.min(h-1,fy+yy));
            value+=rgba[(iy*w+ix)*4+k]*(xx?tx:1-tx)*(yy?ty:1-ty);
          }
          local[(y*lw+x)*4+k]=value;
        }
      }
      const auxiliary=geometry.auxiliary;
      if(options.inferRuby&&auxiliary.length===0&&palette?.background){
        const raw=Uint8Array.from({length:n},(_,i)=>Math.max(local[i*4],local[i*4+1],local[i*4+2])<110?1:0);
        let inferred;
        if(vertical)inferred=aidokuInferVerticalRuby(raw,local,lw,lh,b,palette.background);
        else {
          // Horizontal readings above the body become right-hand columns in
          // this temporary 90-degree raster, using the same ownership rules.
          const turned=new Uint8ClampedArray(n*4),ink=new Uint8Array(n);
          for(let y=0;y<lh;y++)for(let x=0;x<lw;x++){
            const i=y*lw+x,j=x*lh+lh-1-y;turned.set(local.subarray(i*4,i*4+4),j*4);ink[j]=raw[i];
          }
          inferred=aidokuInferVerticalRuby(ink,turned,lh,lw,[lh-b[1]-b[3],b[0],b[3],b[2]],palette.background)
            .map(r=>[r[1],lh-r[0]-r[2],r[3],r[2]]);
        }
        auxiliary.push(...inferred.filter(r=>!geometry.exclusions.some(q=>
          r[0]<q[0]+q[2]&&r[0]+r[2]>q[0]&&r[1]<q[1]+q[3]&&r[1]+r[3]>q[1])));
      }
      const attempt=colors=>{
        const r=aidokuRestoreSourcePanel(local,lw,lh,b,colors,
          {readabilityGate:true,compactMask:true,protectArtMargin:true,slantedOwnership:true,vertical,sampleScale:1,
            auxiliary,inferredRubyExclusions:geometry.exclusions});
        return r&&r.erased&&r.preservedCore<=8&&r.layoutSafe&&aidokuSlantedSurfaceFits(r)&&
          !aidokuSlantedResidualInk(local,lw,lh,b,r)?r:null;
      };
      let result=attempt(palette);
      // The page-axis sample may be dominated by artwork in the empty corners
      // of a steep quad. Retry its actual upright lettering, within the same
      // decoded crop and the color estimator's existing 24K-pixel limit.
      if(!result&&typeof aidokuEstimateSourceColors==='function'){
        const scale=Math.min(1,Math.sqrt(24576/(b[2]*b[3]))),sw=Math.floor(b[2]*scale),sh=Math.floor(b[3]*scale);
        if(sw>=8&&sh>=8){
          const sample=new Uint8ClampedArray(sw*sh*4);
          for(let y=0;y<sh;y++)for(let x=0;x<sw;x++){
            const j=(Math.floor(b[1]+(y+.5)*b[3]/sh)*lw+Math.floor(b[0]+(x+.5)*b[2]/sw))*4;
            sample.set(local.subarray(j,j+4),(y*sw+x)*4);
          }
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
        for(let i=0;i<n;i++)if(result.rgba[i*4+3]){
          const x=(i%lw)/lw,y=(i/lw|0)/lh;
          for(let k=0;k<3;k++){
            const a=quality.coefficients[k];result.rgba[i*4+k]=a[0]+a[1]*x+a[2]*y;
          }
        }
      }
      const output=new Uint8ClampedArray(w*h*4),luminance=new Uint8Array(n);
      const linear=v=>{v/=255;return v<=.04045?v/12.92:((v+.055)/1.055)**2.4;};
      for(let i=0;i<n;i++){
        const a=result.rgba[i*4+3]/255;
        const color=[0,1,2].map(k=>result.rgba[i*4+k]*a+local[i*4+k]*(1-a));
        luminance[i]=Math.round(255*(.2126*linear(color[0])+.7152*linear(color[1])+.0722*linear(color[2])));
      }
      let erased=0;
      for(let y=0;y<h;y++)for(let x=0;x<w;x++){
        const dx=x+.5-cx,dy=y+.5-cy,lx=dx*c+dy*s+ox-.5,ly=-dx*s+dy*c+oy-.5;
        const ix=Math.round(lx),iy=Math.round(ly);
        if(ix<1||iy<1||ix>=lw-1||iy>=lh-1||!result.layoutSafe[iy*lw+ix])continue;
        // Only owned mask pixels are projected back. Unmodified page pixels
        // stay on the original image and never undergo a second resampling.
        const dst=(y*w+x)*4;let weight=0;const color=[0,0,0];
        const fx=Math.floor(lx),fy=Math.floor(ly),tx=lx-fx,ty=ly-fy;
        for(let yy=0;yy<2;yy++)for(let xx=0;xx<2;xx++){
          const j=((fy+yy)*lw+fx+xx)*4;if(!result.rgba[j+3])continue;
          const a=(xx?tx:1-tx)*(yy?ty:1-ty);weight+=a;
          for(let k=0;k<3;k++)color[k]+=result.rgba[j+k]*a;
        }
        if(weight<=0)continue;
        for(let k=0;k<3;k++)output[dst+k]=color[k]/weight;
        output[dst+3]=255;erased++;
      }
      // The second sampling pass can strand soft native edges around an
      // otherwise erased glyph. Complete only the same connected ink whose
      // overwhelming majority was already owned; detached drawing is intact.
      if(result.surfaceQuality?.reason==='smooth'){
        const seen=new Uint8Array(w*h),raw=new Uint8Array(w*h),queue=new Int32Array(w*h);
        const fg=result.sourceForeground,bg=result.sourceBackground,axis=fg.map((v,k)=>v-bg[k]);
        const norm=axis.reduce((a,v)=>a+v*v,0);
        for(let i=0;i<w*h;i++){
          const t=axis.reduce((a,v,k)=>a+v*(rgba[i*4+k]-bg[k]),0)/Math.max(1,norm);
          if(t>.06&&t<1.6&&Math.max(...axis.map((v,k)=>Math.abs(rgba[i*4+k]-bg[k]-v*t)))<=20)raw[i]=1;
        }
        for(let start=0;start<raw.length;start++){
          if(!raw[start]||seen[start])continue;
          let head=0,tail=1,painted=0,inside=0,left=w,top=h,right=0,bottom=0,ul=Infinity,ut=Infinity,ur=-Infinity,ub=-Infinity;queue[0]=start;seen[start]=1;
          while(head<tail){
            const i=queue[head++],x=i%w,y=i/w|0;painted+=Boolean(output[i*4+3]);
            left=Math.min(left,x);right=Math.max(right,x);top=Math.min(top,y);bottom=Math.max(bottom,y);
            const dx=x+.5-cx,dy=y+.5-cy,u=dx*c+dy*s+ox,v=-dx*s+dy*c+oy;
            ul=Math.min(ul,u);ut=Math.min(ut,v);ur=Math.max(ur,u);ub=Math.max(ub,v);
            if([b,...auxiliary].some(r=>u>=r[0]-2&&u<=r[0]+r[2]+2&&v>=r[1]-2&&v<=r[1]+r[3]+2))inside++;
            for(let yy=Math.max(0,y-1);yy<=Math.min(h-1,y+1);yy++)for(let xx=Math.max(0,x-1);xx<=Math.min(w-1,x+1);xx++){
              const j=yy*w+xx;if(raw[j]&&!seen[j]){seen[j]=1;queue[tail++]=j;}
            }
          }
          let enclosedFringe=false;
          if(tail<=16&&painted<tail*.85&&inside===tail){
            let contacts=0,covered=0,soft=true;
            for(let k=0;k<tail;k++){
              const i=queue[k],x=i%w,y=i/w|0;
              if(Math.max(...fg.map((v,j)=>Math.abs(v-rgba[i*4+j])))<40)soft=false;
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
        }
      }
      // Fill isolated codec/resampling holes surrounded by an already owned
      // glyph. This cannot grow a box over the artwork: every added pixel must
      // touch at least five painted neighbours and match the ink polarity.
      if(result.surfaceQuality?.reason==='smooth'){
        const fg=result.sourceForeground,bg=result.sourceBackground,axis=fg.map((v,k)=>v-bg[k]);
        const norm=axis.reduce((a,v)=>a+v*v,0);
        for(let pass=0;pass<2;pass++){
          const holes=[];
          for(let y=1;y<h-1;y++)for(let x=1;x<w-1;x++){
            const i=y*w+x;if(output[i*4+3])continue;
            const dx=x+.5-cx,dy=y+.5-cy,u=dx*c+dy*s+ox,v=-dx*s+dy*c+oy;
            if(![b,...auxiliary].some(r=>u>=r[0]&&u<=r[0]+r[2]&&v>=r[1]&&v<=r[1]+r[3]))continue;
            const projection=axis.reduce((a,q,k)=>a+q*(rgba[i*4+k]-bg[k]),0)/Math.max(1,norm);
            const error=Math.max(...axis.map((q,k)=>Math.abs(rgba[i*4+k]-bg[k]-q*projection)));
            if(projection<=.15||projection>=1.6||error>60)continue;
            let covered=0,donor=-1;
            for(let yy=y-1;yy<=y+1;yy++)for(let xx=x-1;xx<=x+1;xx++){
              const j=yy*w+xx;if(output[j*4+3]){covered++;donor=j;}
            }
            if(covered>=5)holes.push([i,donor]);
          }
          for(const [i,donor] of holes){output.set(output.subarray(donor*4,donor*4+4),i*4);erased++;}
        }
      }
      // The rectified mask alone cannot prove that projecting it back covered
      // the native source raster. Check exposed ink immediately beside the
      // projected mask before committing any replacement.
      const remaining=[];
      for(let y=1;y<h-1;y++)for(let x=1;x<w-1;x++){
        const i=y*w+x;if(output[i*4+3])continue;
        const dx=x+.5-cx,dy=y+.5-cy,u=dx*c+dy*s,v=-dx*s+dy*c;
        if(Math.abs(u)>box[2]/2+2||Math.abs(v)>box[3]/2+2)continue;
        if(Math.max(...result.sourceForeground.map((value,k)=>Math.abs(value-rgba[i*4+k])))>36||
            Math.max(...result.sourceBackground.map((value,k)=>Math.abs(value-rgba[i*4+k])))<40)continue;
        let adjacent=false;
        for(let yy=y-1;yy<=y+1&&!adjacent;yy++)for(let xx=x-1;xx<=x+1;xx++)
          if(output[(yy*w+xx)*4+3]){adjacent=true;break;}
        if(adjacent)remaining.push(i);
      }
      if(remaining.length>=3){
        const seen=new Uint8Array(w*h),queue=new Int32Array(w*h);
        const fg=result.sourceForeground,bg=result.sourceBackground,axis=fg.map((v,k)=>v-bg[k]);
        const norm=axis.reduce((a,v)=>a+v*v,0);
        const ink=i=>{
          const t=axis.reduce((a,v,k)=>a+v*(rgba[i*4+k]-bg[k]),0)/Math.max(1,norm);
          return t>.08&&t<1.2&&Math.max(...axis.map((v,k)=>Math.abs(rgba[i*4+k]-bg[k]-v*t)))<=24;
        };
        for(const start of remaining){
          if(seen[start])continue;
          let head=0,tail=1,cores=0,painted=0;queue[0]=start;seen[start]=1;
          while(head<tail){
            const i=queue[head++],x=i%w,y=i/w|0;
            if(Math.max(...fg.map((v,k)=>Math.abs(v-rgba[i*4+k])))<=36){cores++;if(output[i*4+3])painted++;}
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
      for(let y=0;y<lh;y++)for(let x=0;x<lw;x++){
        const dx=x+.5-ox,dy=y+.5-oy,px=cx+dx*c-dy*s-.5,py=cy+dx*s+dy*c-.5;
        const fx=Math.floor(px),fy=Math.floor(py);
        if(fx<0||fy<0||fx+1>=w||fy+1>=h)continue;
        const tx=px-fx,ty=py-fy,color=[0,0,0];let owned=true;
        for(let yy=0;yy<2;yy++)for(let xx=0;xx<2;xx++){
          const j=((fy+yy)*w+fx+xx)*4;if(output[j+3]!==255)owned=false;
          const weight=(xx?tx:1-tx)*(yy?ty:1-ty);
          for(let k=0;k<3;k++)color[k]+=(output[j+3]===255?output[j+k]:rgba[j+k])*weight;
        }
        const i=y*lw+x;
        if(owned)result.layoutSafe[i]=1;
        // Contrast is measured on the actual composite, including untouched
        // paper beside an erased edge. Requiring four owned donors here kept
        // the old glyph's dark luminance after its native pixels were erased.
        luminance[i]=Math.round(255*(.2126*linear(color[0])+.7152*linear(color[1])+.0722*linear(color[2])));
      }
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
      const distance=(i,color)=>Math.max(...color.map((v,k)=>Math.abs(v-rgba[i*4+k])));
      for(let i=0;i<n;i++){
        const t=delta.reduce((a,v,k)=>a+v*(rgba[i*4+k]-bg[k]),0)/norm;
        const error=Math.max(...delta.map((v,k)=>Math.abs(rgba[i*4+k]-bg[k]-v*t)));
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
          const i=queue[k],x=i%w,y=i/w|0;
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
      for(let i=0;i<w*h;i++){
        const rgb=[0,1,2].map(k=>original[i*4+k]),projection=axis.reduce((a,v,k)=>a+v*(rgb[k]-bg[k]),0)/Math.max(1,norm);
        if(projection>.08&&projection<1.2&&Math.max(...rgb.map((v,k)=>Math.abs(v-bg[k]-axis[k]*projection)))<=24)raw[i]=1;
        if(!result.rgba[i*4+3]&&Math.max(...fg.map((v,k)=>Math.abs(v-rgb[k])))<=tolerance)core[i]=1;
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

    // Glyph rectangles are measured before rotation, in the card's local axes.
    // A clear center alone cannot authorize drawing over a nearby outline.
    function aidokuSlantedInkFits(restored,rects,scale,foreground,audit=null) {
      if(!restored||!rects.length||!Number.isFinite(scale)||scale<=0)return false;
      const {lw:w,lh:h,box:b,layoutSafe:safe,luminance}=restored;
      const linear=v=>{v/=255;return v<=.04045?v/12.92:((v+.055)/1.055)**2.4;};
      const fg=.2126*linear(foreground[0])+.7152*linear(foreground[1])+.0722*linear(foreground[2]);
      let samples=0,minimumContrast=Infinity;
      for(const r of rects){
        const l=Math.floor(b[0]+r[0]*scale)-1,t=Math.floor(b[1]+r[1]*scale)-1;
        const right=Math.ceil(b[0]+r[2]*scale)+1,bottom=Math.ceil(b[1]+r[3]*scale)+1;
        if(l<0||t<0||right>w||bottom>h)return false;
        for(let y=t;y<bottom;y++)for(let x=l;x<right;x++){
          if(++samples>262144)return false;
          const i=y*w+x;if(!safe[i])return false;
          const quantized=luminance[i]/255;
          const bg=quantized>=fg?Math.max(fg,quantized-1/510):Math.min(fg,quantized+1/510);
          const contrast=(Math.max(bg,fg)+.05)/(Math.min(bg,fg)+.05);
          if(contrast<4.5)return false;
          minimumContrast=Math.min(minimumContrast,contrast);
        }
      }
      if(audit)audit.minimumContrast=minimumContrast;
      return Number.isFinite(minimumContrast);
    }
    """
}
