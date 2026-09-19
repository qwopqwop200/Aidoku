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
          return {safe:rmse<=14&&fraction<=.08,reason:rmse<=14&&fraction<=.08?'smooth':'textured',samples:count,rmse,outliers:fraction,coefficients};
        }
        function aidokuRestoreSourcePanel(rgba,w,h,b,palette,options={}) {
          const n=w*h;
          if(!Number.isInteger(w)||!Number.isInteger(h)||w<8||h<8||n>131072||
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
            const restored=aidokuRestoreSourcePanel(inverted,w,h,b,{foreground:flip(palette.foreground),
              background:flip(palette.background),stroke:flip(palette.stroke)},options);
            if(!restored)return null;
            for(let i=0;i<n;i++)if(restored.rgba[i*4+3])for(let c=0;c<3;c++)restored.rgba[i*4+c]=255-restored.rgba[i*4+c];
            return restored;
          }
          const foreground=palette.foreground;
          const colorDistance=(a,b)=>Math.max(...a.map((v,c)=>Math.abs(v-b[c])));
          const separation=colorDistance(foreground,palette.background);
          const onInkBlend=(rgb,end)=>{
            if(!end)return false;
            const delta=end.map((v,c)=>v-foreground[c]);
            const length=delta.reduce((sum,v)=>sum+v*v,0);
            if(!length)return false;
            const t=Math.max(0,Math.min(1,delta.reduce((sum,v,c)=>sum+(rgb[c]-foreground[c])*v,0)/length));
            return colorDistance(rgb,foreground.map((v,c)=>v+t*delta[c]))<=24;
          };
          const legacyDark=Math.max(...foreground)<=80&&Math.min(...palette.background)>=140;
          // Match observed ink in RGB space, independent of hue or panel polarity.
          // Color is evidence for ownership, never a reason to replace the panel.
          const matchedInk=!legacyDark&&separation>=24&&(palette.confidence?.foreground||0)>=.55;
          if(!legacyDark&&!matchedInk)return null;
          const inkTolerance=Math.max(10,Math.min(48,separation*.4));
          
     const p=rgba.slice(),raw=new Uint8Array(n),seen=new Uint8Array(n),mask=new Uint8Array(n),protectedInk=new Uint8Array(n),frameInk=new Uint8Array(n),queue=new Int32Array(n),seedRadius=new Uint8Array(n),accepted=[],isolatedBodyInk=[],readingCandidates=[],edgeFragments=[];
     const observedInk=matchedInk?new Uint8Array(n):null;
     for(let i=0;i<n;i++){
       const rgb=[p[4*i],p[4*i+1],p[4*i+2]];
       const inkDistance=colorDistance(rgb,foreground),backgroundDistance=colorDistance(rgb,palette.background);
       if(observedInk&&inkDistance<=inkTolerance&&inkDistance+8<backgroundDistance)observedInk[i]=1;
       // Dark rules on a light surface still enter component protection. On a
       // dark surface the dark pixels are background, not an enormous ink component.
       if(observedInk?.[i]||(Math.min(...palette.background)>=140&&Math.max(...rgb)<110))raw[i]=1;
       if(observedInk&&!raw[i]&&backgroundDistance>=Math.max(32,separation*.55)&&
           inkDistance>inkTolerance&&(!palette.stroke||colorDistance(rgb,palette.stroke)>inkTolerance)&&
           !onInkBlend(rgb,palette.stroke)&&!onInkBlend(rgb,palette.background))
         protectedInk[i]=1;
     }
     const auxiliary=(options.auxiliary||[]).slice(0,32).filter(r=>Array.isArray(r)&&r.length===4&&r.every(Number.isFinite)&&r[0]>=2&&r[1]>=2&&r[2]>0&&r[3]>0&&r[0]+r[2]<w-2&&r[1]+r[3]<h-2);
     let companions=0;
     for(let start=0;start<n;start++){
     if(!raw[start]||seen[start])continue;let head=0,tail=1,x0=w,y0=h,x1=0,y1=0;queue[0]=start;seen[start]=1;
     while(head<tail){const i=queue[head++],x=i%w,y=i/w|0;x0=Math.min(x0,x);y0=Math.min(y0,y);x1=Math.max(x1,x);y1=Math.max(y1,y);
     for(let yy=Math.max(0,y-1);yy<=Math.min(h-1,y+1);yy++)for(let xx=Math.max(0,x-1);xx<=Math.min(w-1,x+1);xx++){const j=yy*w+xx;if(raw[j]&&!seen[j]){seen[j]=1;queue[tail++]=j;}}
     }
     const cx=(x0+x1)/2,cy=(y0+y1)/2;
     const body=cx>=b[0]-3&&cx<=b[0]+b[2]+3&&cy>=b[1]-3&&cy<=b[1]+b[3]+3;
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
     if(observedInk)for(let k=0;k<tail;k++)observedCount+=observedInk[queue[k]];
     const keep=(!observedInk||observedCount>=Math.max(2,tail*.1))&&(tail>=2||(ruby&&tail===1))&&x0>2&&y0>2&&x1<w-3&&y1<h-3&&(body||ruby||rule)&&
       Math.max(x1-x0,y1-y0)<(rule?121:Math.min(100,Math.max(b[2],b[3])*.6));
     if(keep&&!body)companions++;
     if(!keep&&body&&tail===1&&x0>2&&y0>2&&x1<w-3&&y1<h-3)isolatedBodyInk.push(start);
     for(let k=0;k<tail;k++){
       (keep?mask:protectedInk)[queue[k]]=1;
       if(keep)seedRadius[queue[k]]=ruby&&!body?6:12;
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
     if(accepted.length<3)return null;
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
     for(const i of isolatedBodyInk){
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
     // components inside a merged OCR rectangle. On the conservative retry,
     // reconnect them to known frame artwork through darker-than-paper pixels
     // before deciding which components belong to lettering.
     let drawingSurface=null;
     if(options.protectArtMargin){
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
     const coreCount=mask.reduce((sum,v)=>sum+v,0);
     // Keep the original substantial-stroke density gate stable when adding
     // raster fragments; a handful of one-pixel dots must not reject an
     // otherwise valid dense caption and bring its entire source text back.
     const substantialCoreCount=accepted.reduce((sum,c)=>sum+(c[5]>=2?c[5]:0),0);
     if(substantialCoreCount>b[2]*b[3]*.3)return null;
     // Reject unresolved dark ink inside the OCR box, including intersecting art.
     let unresolved=0;
     for(let y=Math.floor(b[1]);y<Math.ceil(b[1]+b[3]);y++)for(let x=Math.floor(b[0]);x<Math.ceil(b[0]+b[2]);x++)
       if(protectedInk[y*w+x]&&!frameInk[y*w+x])unresolved++;
     if(unresolved>Math.max(8,coreCount*.04))return null;
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
     for(let i=0;i<n;i++)if(mask[i])queue[tail++]=i;
     // Include halos even when the color estimator mistakes them for paper.
     // Native-resolution dilation is bounded; 24 px crop padding keeps its
     // boundary samples outside the source outline rather than inside it.
     const radius=12;
     for(let head=0;head<tail;head++){
     const i=queue[head],x=i%w,y=i/w|0;if(distance[i]>=seedRadius[i])continue;
     for(let yy=Math.max(1,y-1);yy<=Math.min(h-2,y+1);yy++)for(let xx=Math.max(1,x-1);xx<=Math.min(w-2,x+1);xx++){
     const j=yy*w+xx;
     // Keep the art margin, but include the immediate antialiased edge of
     // already owned lettering when it stays at least three pixels from art.
     const ownedFringe=distance[i]<2&&donorDistance[j]>=3;
     if(mask[j]||protectedInk[j]||drawingSurface?.[j]||(options.protectArtMargin&&donorBlocked[j]&&!ownedFringe))continue;
     if(Math.hypot(xx-(i%w),yy-(i/w|0))>1.1&&distance[i]>radius-2)continue;
     mask[j]=1;distance[j]=distance[i]+1;seedRadius[j]=seedRadius[i];queue[tail++]=j;
     }}
     const surfaceQuality=options.readabilityGate?aidokuSourceSurfaceQuality(rgba,w,h,mask,donorBlocked):null;
     if(surfaceQuality&&!surfaceQuality.safe)return null;
     if(surfaceQuality){
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
       return aidokuRestoreSourcePanel(rgba,w,h,b,palette,{...options,protectArtMargin:true});
     // Dilation can enter small pockets enclosed by protected illustration.
     // A pocket without a background donor is not evidence for a fill color.
     // Keep its original pixels instead of rejecting all recoverable lettering.
     // Large amounts of stranded ink still reject the entire proposal.
     let preservedPixels=0,preservedCore=0;
     for(let i=0;i<n;i++)if(mask[i]){preservedPixels++;if(raw[i])preservedCore++;}
     if(preservedCore>Math.min(64,coreCount*.02)||preservedPixels>tail*.15)return null;
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
     for(let pass=0;pass<48;pass++)for(let k=0;k<tail;k++){
       const i=queue[k],left=i-1,right=i+1,up=i-w,down=i+w;
       const a=!donorBlocked[left]||paintMask[left],b=!donorBlocked[right]||paintMask[right],c=!donorBlocked[up]||paintMask[up],d=!donorBlocked[down]||paintMask[down];
       const count=a+b+c+d;if(!count)continue;
       for(let channel=0;channel<3;channel++)work[i*3+channel]=
         ((a?work[left*3+channel]:0)+(b?work[right*3+channel]:0)+
          (c?work[up*3+channel]:0)+(d?work[down*3+channel]:0))/count;
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
