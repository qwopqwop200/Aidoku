@testable import Aidoku

// Test-only legacy browser reference.
/// Independently segments the observed source lettering for the bounded inpainting fallback.
/// The result is a local crop mask; pixels outside the measured text components remain untouched.
enum BrowserSourceGlyphSegmentation {
    static let script = """
    // Source-coordinate quads are evidence of ownership, not rectangular paint
    // plates. Rasterize once per bounded crop; a small fringe admits antialias
    // and clipped outlines, while neighbouring OCR owns its own fringe.
    function aidokuOCRGeometryMask(w,h,polygons,excluded=[],margin=0) {
      const valid=p=>Array.isArray(p)&&p.length>=3&&p.length<=32&&
        p.every(v=>Array.isArray(v)&&v.length===2&&v.every(Number.isFinite))&&
        Math.abs(p.reduce((s,v,i)=>{const q=p[(i+1)%p.length];return s+v[0]*q[1]-q[0]*v[1];},0))>=8;
      if(!Number.isInteger(w)||!Number.isInteger(h)||w<1||h<1||w*h>750000||
          !Array.isArray(polygons)||!polygons.some(valid))return null;
      const raster=shapes=>{
        const mask=new Uint8Array(w*h);
        for(const p of shapes.filter(valid).filter(p=>Math.min(...p.map(v=>v[0]))<w&&
            Math.max(...p.map(v=>v[0]))>0&&Math.min(...p.map(v=>v[1]))<h&&Math.max(...p.map(v=>v[1]))>0).slice(0,64)){
          const x0=Math.max(0,Math.floor(Math.min(...p.map(v=>v[0])))),x1=Math.min(w,Math.ceil(Math.max(...p.map(v=>v[0]))));
          const y0=Math.max(0,Math.floor(Math.min(...p.map(v=>v[1])))),y1=Math.min(h,Math.ceil(Math.max(...p.map(v=>v[1]))));
          for(let y=y0;y<y1;y++)for(let x=x0;x<x1;x++){
            let inside=false;const px=x+.5,py=y+.5;
            for(let i=0,j=p.length-1;i<p.length;j=i++){
              const a=p[i],b=p[j];if((a[1]>py)!==(b[1]>py)&&px<(b[0]-a[0])*(py-a[1])/(b[1]-a[1])+a[0])inside=!inside;
            }
            if(inside)mask[y*w+x]=1;
          }
        }
        return mask;
      };
      const core=raster(polygons),radius=Math.min(12,Math.max(0,Math.ceil(Number(margin)||0)));
      let mask=core.slice();
      if(radius){
        // Separable square dilation is O(crop pixels), independent of glyph count.
        const horizontal=new Uint8Array(w*h);mask=new Uint8Array(w*h);
        for(let y=0;y<h;y++){
          let count=0;for(let x=0;x<Math.min(w,radius);x++)count+=core[y*w+x];
          for(let x=0;x<w;x++){
            if(x+radius<w)count+=core[y*w+x+radius];
            if(x-radius-1>=0)count-=core[y*w+x-radius-1];
            horizontal[y*w+x]=count>0?1:0;
          }
        }
        for(let x=0;x<w;x++){
          let count=0;for(let y=0;y<Math.min(h,radius);y++)count+=horizontal[y*w+x];
          for(let y=0;y<h;y++){
            if(y+radius<h)count+=horizontal[(y+radius)*w+x];
            if(y-radius-1>=0)count-=horizontal[(y-radius-1)*w+x];
            mask[y*w+x]=count>0?1:0;
          }
        }
      }
      const other=raster(Array.isArray(excluded)?excluded:[]);
      for(let i=0;i<mask.length;i++)if(other[i]&&!core[i])mask[i]=0;
      mask.core=core;
      return mask;
    }
    function aidokuForcedTextMask(rgba,w,h,b,palette,options={}) {
      const n=w*h,ink=palette?.sourceInk||palette,fg=ink?.foreground;
      if(!fg||fg.length<3||!fg.every(Number.isFinite)||!rgba||rgba.length!==n*4||
          !Number.isInteger(w)||!Number.isInteger(h)||w<5||h<5||n<64||n>262144||
          !Array.isArray(b)||b.length!==4||!b.every(Number.isFinite)||b[2]<=0||b[3]<=0)return null;
      const dark=Math.max(...fg)<=135,chromatic=Math.max(...fg)-Math.min(...fg)>=75;
      const background=ink?.background,backgroundContrast=background&&background.length>=3?
        Math.max(...background.map((v,k)=>Math.abs(v-fg[k]))):0;
      // Muted colored ink and cream paper can both fail a white-halo test.
      // Use the independently measured background only when its evidence is strong.
      const observedSurface=backgroundContrast>=60&&(ink?.confidence?.background||0)>=.55;
      if(!dark&&!chromatic&&!observedSurface)return null;
      const raw=new Uint8Array(n),seen=new Uint8Array(n),mask=new Uint8Array(n),coreCandidate=new Uint8Array(n);
      const ownership=aidokuOCRGeometryMask(w,h,options.polygons,options.excludedPolygons,7);
      const x0=Math.max(2,Math.floor(b[0]-7)),y0=Math.max(2,Math.floor(b[1]-7));
      const x1=Math.min(w-3,Math.ceil(b[0]+b[2]+7));
      // OCR boxes commonly stop at the final complete glyph. Search at most
      // one further vertical glyph for trailing kana or punctuation.
      const y1=Math.min(h-3,Math.ceil(b[1]+b[3]+Math.min(46,Math.max(14,b[3]*.13))));
      const close=(i)=>{const k=i*4;return Math.max(Math.abs(rgba[k]-fg[0]),Math.abs(rgba[k+1]-fg[1]),Math.abs(rgba[k+2]-fg[2]))<=40;};
      const bright=(i)=>{const k=i*4,a=rgba[k],c=rgba[k+1],d=rgba[k+2];return Math.min(a,c,d)>=210&&Math.max(a,c,d)-Math.min(a,c,d)<=48;};
      const surface=(i)=>{const k=i*4;return bright(i)||observedSurface&&
        Math.max(Math.abs(rgba[k]-background[0]),Math.abs(rgba[k+1]-background[1]),Math.abs(rgba[k+2]-background[2]))<=28;};
      for(let y=y0;y<=y1;y++)for(let x=x0;x<=x1;x++){const i=y*w+x;if((!ownership||ownership[i])&&close(i))raw[i]=1;}
      const maxDimension=Math.min(78,Math.max(48,Math.min(b[2],b[3])*.48));
      const strong=[],weak=[];
      for(let start=0;start<n;start++)if(raw[start]&&!seen[start]){
        const pixels=[start];seen[start]=1;let l=w,r=0,t=h,d=0;
        for(let head=0;head<pixels.length;head++){
          const i=pixels[head],x=i%w,y=i/w|0;l=Math.min(l,x);r=Math.max(r,x);t=Math.min(t,y);d=Math.max(d,y);
          if(x>0){const j=i-1;if(raw[j]&&!seen[j]){seen[j]=1;pixels.push(j);}}
          if(x+1<w){const j=i+1;if(raw[j]&&!seen[j]){seen[j]=1;pixels.push(j);}}
          if(y>0){const j=i-w;if(raw[j]&&!seen[j]){seen[j]=1;pixels.push(j);}}
          if(y+1<h){const j=i+w;if(raw[j]&&!seen[j]){seen[j]=1;pixels.push(j);}}
        }
        const cw=r-l+1,ch=d-t+1,area=cw*ch;
        // Search padding recovers clipped glyph edges, but a component wholly
        // outside the text rectangle belongs to neighbouring text or artwork.
        if(r<b[0]-1||l>b[0]+b[2]+1||d<b[1]-1||t>b[1]+b[3]+1)continue;
        if(pixels.length<3||cw>maxDimension||ch>maxDimension||area>Math.max(1800,b[2]*b[3]*.08)||
            l<2||t<2||r>=w-2||d>=h-2)continue;
        let ring2=0,ring4=0,total2=0,total4=0,interior=0;
        for(let y=Math.max(2,t-4);y<=Math.min(h-3,d+4);y++)for(let x=Math.max(2,l-4);x<=Math.min(w-3,r+4);x++){
          const distance=Math.max(Math.max(l-x,x-r,0),Math.max(t-y,y-d,0)),i=y*w+x;
          if(distance===2){total2++;if(surface(i))ring2++;}
          if(distance===4){total4++;if(surface(i))ring4++;}
          if(distance===0&&bright(i))interior++;
        }
        const halo=ring2/Math.max(1,total2),outer=ring4/Math.max(1,total4);
        const whiteFill=interior/area;
        const by=b[1]+b[3],bx=b[0]+b[2];
        const outside=l<b[0]-2||r>bx+2||t<b[1]-2||d>by+2;
        const boundaryArtifact=outside&&pixels.length<60||
          (l<b[0]+3||r>bx-3)&&cw>35&&pixels.length<180;
        const solid=!(boundaryArtifact)&&
          ((dark||observedSurface)?halo>=.30&&outer>=.22: whiteFill>=.16&&pixels.length>=Math.max(18,area*.13));
        const component={pixels,l,r,t,d,halo,outer,whiteFill,boundaryArtifact,outside};
        if(solid)strong.push(component);else weak.push(component);
      }
      if(strong.length<2)return null;
      // This census is separate from the returned mask: a lower evidence
      // threshold inventories plausible source cores without counting large
      // same-colour illustration components as text.
      for(const c of [...strong,...weak])if(!c.boundaryArtifact&&
          (dark?c.halo>=.22&&c.outer>=.15:c.whiteFill>=.10))
        for(const i of c.pixels)coreCandidate[i]=1;
      // Dots and separated kana strokes inherit ownership only from a nearby
      // independently outlined glyph, never from hue matching alone.
      const accepted=strong.slice();
      for(const c of weak)if(!c.boundaryArtifact&&c.pixels.length<=140&&c.r-c.l<34&&c.d-c.t<36&&
          strong.some(s=>Math.max(s.l-c.r,c.l-s.r,0)<=9&&Math.max(s.t-c.d,c.t-s.d,0)<=14))accepted.push(c);
      // Spatially accepted detached dots are source cores too. Omitting them
      // from the census skipped their thick outline while certifying erasure.
      for(const c of accepted)for(const i of c.pixels)mask[i]=coreCandidate[i]=1;
      // A final kana stroke can share the exact navy RGB of clothing. The
      // connected component is then huge, but only the short stroke next to
      // an accepted glyph has white outline on opposite sides. Recover those
      // pixels locally instead of accepting the whole art component.
      if(dark){
        const owned=mask.slice();
        for(let y=y0;y<=y1;y++)for(let x=x0;x<=x1;x++){
          const i=y*w+x;if(!raw[i]||mask[i])continue;
          let near=false;
          for(let yy=Math.max(y0,y-13);!near&&yy<=Math.min(y1,y+13);yy++)
            for(let xx=Math.max(x0,x-13);xx<=Math.min(x1,x+13);xx++)if(owned[yy*w+xx]){near=true;break;}
          if(!near)continue;
          const probe=(dx,dy)=>{for(let step=1;step<=6;step++){
            const xx=x+dx*step,yy=y+dy*step;
            if(xx<2||yy<2||xx>=w-2||yy>=h-2)break;
            if(bright(yy*w+xx))return true;
          }return false;};
          const left=probe(-1,0),right=probe(1,0),up=probe(0,-1),down=probe(0,1);
          if(left&&right||up&&down)mask[i]=1;
        }
      }
      // Closed white glyph interiors are part of the printed lettering. Flood
      // non-core islands locally; open artwork/paper never qualifies.
      const seenHole=new Uint8Array(n);
      for(const c of accepted)if(chromatic&&c.whiteFill>=.12){
        for(let y=c.t;y<=c.d;y++)for(let x=c.l;x<=c.r;x++){
          const start=y*w+x;if(raw[start]||seenHole[start]||!bright(start))continue;
          const group=[start];seenHole[start]=1;let edge=false;
          for(let head=0;head<group.length&&group.length<=400;head++){
            const i=group[head],xx=i%w,yy=i/w|0;
            if(xx<=c.l||xx>=c.r||yy<=c.t||yy>=c.d){edge=true;break;}
            for(const j of [i-1,i+1,i-w,i+w])if(!raw[j]&&!seenHole[j]&&bright(j)){
              seenHole[j]=1;group.push(j);
            }
          }
          if(!edge&&group.length<=400)for(const i of group)mask[i]=1;
        }
      }
      // A five-pixel halo unnecessarily includes white paper around plain
      // lettering. Keep a narrow paper fringe without losing nearby ink.
      // Retain the outline allowance only when the observed ink has a stroke
      // or contains closed white interiors.
      const observedStroke=(palette?.confidence?.stroke||0)>=.55&&Array.isArray(palette?.foreground)&&
        palette.foreground.length===3&&Math.max(...palette.foreground.map((v,k)=>Math.abs(v-fg[k])))<=24
        ?palette.stroke:null;
      const stroke=ink?.stroke||ink?.outline||observedStroke;
      const outlined=stroke&&stroke.length>=3&&stroke.every(Number.isFinite)&&
        Math.max(...stroke.map((v,k)=>Math.abs(v-fg[k])))>=48;
      // A short dilation covers the observed outline or antialias fringe.
      // It stays inside the OCR box plus seven pixels and never reaches crop edges.
      const seeds=[];for(let i=0;i<n;i++)if(mask[i])seeds.push(i);
      const radius=5,plain=!outlined&&!chromatic;for(const i of seeds){const x=i%w,y=i/w|0;
        for(let yy=Math.max(2,y-radius);yy<=Math.min(h-3,y+radius);yy++)for(let xx=Math.max(2,x-radius);xx<=Math.min(w-3,x+radius);xx++){
          if(Math.abs(xx-x)+Math.abs(yy-y)>radius||xx<x0||xx>x1||yy<y0||yy>y1)continue;
          const target=yy*w+xx,k=target*4;
          // Disconnected thin strokes can be weak components. Keep every
          // non-paper pixel covered by the old halo, including faint antialias.
          if(plain&&Math.abs(xx-x)+Math.abs(yy-y)>2&&
              Math.min(rgba[k],rgba[k+1],rgba[k+2])>=248)continue;
          mask[target]=1;
        }
      }
      mask.sourceCorePixels=seeds.length;
      mask.sourceComponents=accepted.length;
      if(ownership)for(let i=0;i<n;i++)if(!ownership[i])mask[i]=0;
      let candidateCount=0,candidateCovered=0,outlineCount=0,outlineCovered=0;
      const outlineCandidate=new Uint8Array(n);
      const separateOutline=outlined&&background&&
        Math.max(...stroke.map((v,c)=>Math.abs(v-background[c])))>=48;
      const outlineRadius=separateOutline?Math.min(14,Math.max(4,Math.ceil((Number(options.glyphSize)||0)*.13))):4;
      for(let i=0;i<n;i++)if(coreCandidate[i]){
        candidateCount++;if(mask[i])candidateCovered++;
        const x=i%w,y=i/w|0;
        for(let yy=Math.max(2,y-outlineRadius);yy<=Math.min(h-3,y+outlineRadius);yy++)
          for(let xx=Math.max(2,x-outlineRadius);xx<=Math.min(w-3,x+outlineRadius);xx++){
            if(Math.abs(xx-x)+Math.abs(yy-y)>outlineRadius)continue;
            const j=yy*w+xx;if((!ownership||ownership[j])&&!coreCandidate[j]&&bright(j)){
              outlineCandidate[j]=1;
              // Recovered disconnected cores were absent from the initial
              // dilation seeds. Their observed white outline needs its own
              // narrow fringe, still bounded by the final source geometry.
              if(outlined&&Math.min(...stroke)>=200&&mask[i])mask[j]=1;
            }
          }
      }
      for(let i=0;i<n;i++)if(outlineCandidate[i]){
        outlineCount++;if(mask[i])outlineCovered++;
      }
      mask.sourceCoreCandidateCount=candidateCount;
      mask.sourceCoreCandidateCovered=candidateCovered;
      mask.sourceOutlineCandidateCount=outlineCount;
      mask.sourceOutlineCandidateCovered=outlineCovered;
      mask.sourceCoreCandidateMask=coreCandidate;
      mask.sourceOutlineCandidateMask=outlineCandidate;
      return mask;
    }
    """
}
