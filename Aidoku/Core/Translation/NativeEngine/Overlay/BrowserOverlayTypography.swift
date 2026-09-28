import Foundation
import CoreGraphics

/// Page-local typography. Source evidence separates emphasis from ordinary
/// dialogue; measured layout remains the final authority on whether text fits.
enum BrowserOverlayTypography {
    static func sourceSize(text: String, rect: CGRect) -> CGFloat? {
        let units = text.unicodeScalars.reduce(CGFloat.zero) { sum, c in
            if CharacterSet.whitespacesAndNewlines.contains(c) { return sum }
            return sum + (c.value < 0x3000 ? 0.55 : 1)
        }
        guard units >= 2, rect.width > 0, rect.height > 0 else { return nil }
        return min(min(rect.width, rect.height), sqrt(rect.width * rect.height / units))
    }

    // Large functions keep each outermost loop in `(()=>{...})();` (see BrowserOverlayView.renderScript).
    static let script = #"""
    // Last geometry-only polish: never refit text or change translation content.
    // Work is bounded by the existing 256-region page limit, with no pixel buffers.
    const aidokuPolishCaptionPanels = (root, items, opacity, keptItems = [], readSource = null, keptZones = []) => {
      if(opacity!==1||items.length>256)return;
      const rect=n=>{const r=n.getBoundingClientRect();return {l:r.left,t:r.top,r:r.right,b:r.bottom};};
      const union=rs=>({l:Math.min(...rs.map(r=>r.l)),t:Math.min(...rs.map(r=>r.t)),
        r:Math.max(...rs.map(r=>r.r)),b:Math.max(...rs.map(r=>r.b))});
      const hit=(a,b)=>Math.min(a.r,b.r)-Math.max(a.l,b.l)>.25&&Math.min(a.b,b.b)-Math.max(a.t,b.t)>.25;
      const contains=(a,b)=>b.l>=a.l-.25&&b.r<=a.r+.25&&b.t>=a.t-.25&&b.b<=a.b+.25;
      const pad=(r,p)=>({l:r.l-p,t:r.t-p,r:r.r+p,b:r.b+p});
      const area=r=>Math.max(0,r.r-r.l)*Math.max(0,r.b-r.t);
      const coveredArea=rs=>{
        const xs=[...new Set(rs.flatMap(r=>[r.l,r.r]))].sort((a,b)=>a-b);let total=0;
        for(let i=1;i<xs.length;i++){
          const spans=rs.filter(r=>r.l<xs[i]&&r.r>xs[i-1]).map(r=>[r.t,r.b]).sort((a,b)=>a[0]-b[0]);
          let end=-Infinity,height=0;
          for(const [t,b] of spans){height+=Math.max(0,b-Math.max(t,end));end=Math.max(end,b);}
          total+=(xs[i]-xs[i-1])*height;
        }return total;
      };
      const ink=n=>{const q=document.createRange();q.selectNodeContents(n);const r=q.getBoundingClientRect();
        return {l:r.left,t:r.top,r:r.right,b:r.bottom};};
      const flat=(n,allowCaptionClip=false)=>{const s=getComputedStyle(n);return (!s.transform||s.transform==='none')&&
        (!s.scale||s.scale==='none')&&(!s.rotate||s.rotate==='none')&&(!s.translate||s.translate==='none')&&
        (!s.clipPath||s.clipPath==='none'||allowCaptionClip&&n.dataset.captionUnionClipped==='true')&&(!s.backgroundImage||s.backgroundImage==='none')&&
        !n.dataset.foreignFills&&(!s.opacity||Number(s.opacity)===1);};
      const nodes=new Map(Array.from(root.querySelectorAll('[data-aidoku-image-ocr-overlay="item"]'))
        .filter(n=>getComputedStyle(n).visibility!=='hidden').map(n=>[n.dataset.aidokuRegion,n]));
      const panels=Array.from(root.querySelectorAll('[data-aidoku-image-ocr-overlay="source-readability-panel"]'));
      const entries=items.flatMap(item=>{
        const node=nodes.get(String(item.id)),f=item.sourceFrame,b=item.sourceBounds;
        if(!node||!f||!b)return [];
        const sources=[b,...(item.auxiliaryInkRects||[])].filter(a=>a?.length===4&&a.every(Number.isFinite))
          .map(a=>({l:f[0]+a[0]*f[2],t:f[1]+a[1]*f[3],r:f[0]+(a[0]+a[2])*f[2],b:f[1]+(a[1]+a[3])*f[3]}));
        return [{item,node,sources,ink:ink(node),panels:panels.filter(p=>p.dataset.aidokuRegion===String(item.id))}];
      });
      const kept=keptZones.length?keptZones.map(z=>({l:z.left,t:z.top,r:z.right,b:z.bottom})):keptItems.flatMap(item=>{
        const f=item.sourceFrame,b=item.sourceBounds;
        return f&&b?[{l:f[0]+b[0]*f[2],t:f[1]+b[1]*f[3],r:f[0]+(b[0]+b[2])*f[2],b:f[1]+(b[1]+b[3])*f[3]}]:[];
      });
      const eligible=(e,allowPiece=false)=>e.item.sourceTextOnly===false&&!e.item.rotation&&!e.item.vertical&&
        (!e.item.sourceLettering||allowPiece&&e.item.sourceLettering==='piece')&&e.item.wrappingScript==='korean'&&flat(e.node);
      const place=(n,r)=>Object.assign(n.style,{left:`${r.l+scrollX}px`,top:`${r.t+scrollY}px`,
        width:`${r.r-r.l}px`,height:`${r.b-r.t}px`});
      const detach=e=>{if(e.node.parentElement!==root){const r=rect(e.node);root.appendChild(e.node);place(e.node,r);e.node.style.zIndex='3';}};
      const rgb=value=>(String(value||'').match(/[\d.]+/g)||[]).slice(0,3).map(Number);
      const luminance=c=>c.reduce((sum,v,i)=>{v/=255;return sum+[.2126,.7152,.0722][i]*(v<=.04045?v/12.92:((v+.055)/1.055)**2.4);},0);
      // A sampled outline can be thicker than the Hangul counters. Keep an
      // outside outline, but cap ordinary dialogue independently of source SFX.
      for(const e of entries){
        if(!eligible(e))continue;
        const s=getComputedStyle(e.node),size=parseFloat(s.fontSize),width=parseFloat(s.webkitTextStrokeWidth);
        const cap=Math.max(.6,Math.min(1.5,size*.075));
        const fill=rgb(s.color),outline=rgb(s.webkitTextStrokeColor),background=rgb(e.node.dataset.sourceAppliedBackgroundRGB);
        // A light ring may be the only contrast on a dark fill/dark plate.
        // Preserve that readability aid; dark outlines around light dialogue
        // and fills already legible against their plate can safely be thinner.
        const contrast=fill.length===3&&background.length===3?
          (Math.max(luminance(fill),luminance(background))+.05)/(Math.min(luminance(fill),luminance(background))+.05):0;
        const safe=fill.length===3&&outline.length===3&&(luminance(outline)<luminance(fill)||contrast>=4.5);
        if(width>cap&&s.webkitTextStrokeColor!==s.color&&safe){
          e.node.style.webkitTextStrokeWidth=`${cap}px`;e.node.style.paintOrder='stroke fill';
          e.node.dataset.dialogueStrokeCapped='true';e.ink=ink(e.node);
        }
      }
      // The pixel gate already certified each balanced column's top. Later
      // centering must not stagger short and long replies within that row.
      for(const e of entries){
        const c=e.item.columnLayout;
        if(!eligible(e)||!e.item.balancedColumn||!c)continue;
        const dy=c.y+(c.paddingTop||0)-e.ink.t;
        const moved={...e.ink,t:e.ink.t+dy,b:e.ink.b+dy};
        const slot={l:c.x,t:c.y,r:c.x+c.width,b:c.y+c.height};
        if(Math.abs(dy)<.25||!contains(slot,moved)||
          entries.some(o=>o!==e&&hit(moved,pad(o.ink,1)))||kept.some(o=>hit(moved,o))||
          e.panels.length&&!e.panels.some(p=>contains(rect(p),moved)))continue;
        detach(e);e.node.style.top=`${parseFloat(e.node.style.top)+dy}px`;
        e.ink=ink(e.node);e.node.dataset.captionRowAligned='true';
      }
      // Merge only the same caption's opaque, plain plates. Keep all source
      // erasure coverage; refuse unions reaching another source or its glyphs.
      for(const e of entries){
        if(!eligible(e,true)||!e.panels.length||e.panels.some(p=>!flat(p,true)))continue;
        const boxes=e.panels.map(rect),u=union(boxes),frame=e.item.sourceFrame;
        const bounds={l:frame[0],t:frame[1],r:frame[0]+frame[2],b:frame[1]+frame[3]};
        const main=e.panels.find(p=>p.dataset.sourceErasure!=='true')||e.panels[0];
        const colors=e.panels.map(p=>getComputedStyle(p).backgroundColor.match(/[\d.]+/g)?.map(Number));
        if(colors.some(c=>!c||c.length<3||(c.length>3&&c[3]!==1))||
          colors.some(c=>c.slice(0,3).some((v,i)=>Math.abs(v-colors[0][i])>24)))continue;
        const obstacles=entries.filter(o=>o!==e).flatMap(o=>[pad(o.ink,1),...o.sources]).concat(kept);
        // Only discard empty horizontal padding when it conflicts. Source and
        // translated ink (including a small antialiasing margin) remain covered.
        const required=pad(union([e.ink,...e.sources]),4);
        let target=u;
        if(obstacles.some(o=>hit(u,o))&&contains(u,required))target={...u,l:required.l,r:required.r};
        if(kept.some(o=>hit(target,o))){
          const bottom=Math.max(e.ink.b+2,...e.sources.map(s=>s.b+1));
          if(bottom<target.b)target={...target,b:bottom};
        }
        const clipped=e.panels.some(p=>getComputedStyle(p).clipPath!=='none'&&getComputedStyle(p).clipPath);
        if(e.panels.length>1||clipped){
          let coverage=[];
          try {coverage=e.panels.flatMap(p=>p.dataset.panelCoverage?
            JSON.parse(p.dataset.panelCoverage).map(a=>({l:a[0],t:a[1],r:a[0]+a[2],b:a[1]+a[3]})):[rect(p)]);}
          catch(_){continue;}
          if(!coverage.length||coverage.length>64||coverage.some(r=>!Object.values(r).every(Number.isFinite)))continue;
          const intersection=(a,b)=>({l:Math.max(a.l,b.l),t:Math.max(a.t,b.t),r:Math.min(a.r,b.r),b:Math.min(a.b,b.b)});
          // Existing source margins may already touch a neighbor. Filling an
          // empty corner is allowed only if it adds no coverage over its ink.
          // OCR kept-lettering boxes include blank margins. Only a small,
          // pixel-certified uniform margin may be covered by the solid plate.
          const blankKept=new Set(kept.filter(o=>{
            if(!hit(target,o)||!readSource)return false;
            const r=intersection(target,o);
            if(Math.min(r.r-r.l,r.b-r.t)>6)return false;
            try {
              const pixels=readSource(pad(r,1),frame);
              if(!pixels?.length)return false;
              const low=[255,255,255],high=[0,0,0];
              for(let i=0;i<pixels.length;i+=4){
                if(pixels[i+3]<250)return false;
                for(let k=0;k<3;k++){
                  low[k]=Math.min(low[k],pixels[i+k]);high[k]=Math.max(high[k],pixels[i+k]);
                  const w=pixels.captionWidth;
                  if(w&&((i/4)%w>0&&Math.abs(pixels[i+k]-pixels[i-4+k])>12||
                    i>=w*4&&Math.abs(pixels[i+k]-pixels[i-w*4+k])>12))return false;
                }
              }
              return high.every((v,k)=>v-low[k]<=48);
            }catch(_){return false;}
          }));
          const addsCollision=obstacles.some(o=>{
            if(blankKept.has(o))return false;
            const existing=coverage.map(r=>intersection(r,o)).filter(r=>r.r>r.l&&r.b>r.t);
            return area(intersection(target,o))>coveredArea(existing)+.05;
          });
          if(area(target)>coveredArea(coverage)*1.35||!contains(bounds,target)||addsCollision||kept.some(o=>hit(target,o)&&!blankKept.has(o)))continue;
          detach(e);place(main,target);main.style.borderRadius='2px';main.style.clipPath='none';
          main.dataset.panelCoverage=JSON.stringify([[target.l,target.t,target.r-target.l,target.b-target.t]]);
          e.node.dataset.sourcePanelCoverage=main.dataset.panelCoverage;
          for(const p of e.panels)if(p!==main)p.remove();
          e.panels=[main];main.dataset.captionUnified='true';
          if(blankKept.size)main.dataset.captionBlankKept='true';
          delete main.dataset.captionUnionClipped;delete main.dataset.sourceBridgeClipped;
          e.node.style.backgroundColor='transparent';e.node.style.backgroundImage='none';
        }else if(target!==u){
          detach(e);place(main,target);main.dataset.captionTrimmed='true';
        }
      }
      // Resolve remaining text/card incursions by the shortest legal shift.
      // The source plate is fixed; the complete lettering must still fit it.
      for(const e of entries){
        if(!eligible(e)||e.item.balancedColumn||e.panels.length!==1||!flat(e.panels[0],true))continue;
        const panel=e.panels[0],own=rect(panel),before=ink(e.node);
        if(getComputedStyle(panel).clipPath!=='none'&&getComputedStyle(panel).clipPath){
          let coverage=[];try {coverage=JSON.parse(panel.dataset.panelCoverage||'[]')
            .map(a=>({l:a[0],t:a[1],r:a[0]+a[2],b:a[1]+a[3]}));}catch(_){continue;}
          if(!coverage.length||coverage.length>64||coveredArea(coverage)<area(own)*.995)continue;
        }
        const obstacles=entries.filter(o=>o!==e).flatMap(o=>[pad(o.ink,1),...o.panels.map(rect)]).concat(kept);
        const collisions=obstacles.filter(o=>hit(before,o));if(!collisions.length)continue;
        const xs=[0],ys=[0];
        for(const o of collisions){xs.push(o.l-before.r-.75,o.r-before.l+.75);ys.push(o.t-before.b-.75,o.b-before.t+.75);}
        const limit=Math.min(24,Math.max(4,parseFloat(getComputedStyle(e.node).fontSize)*1.5));
        // At most 289 trials even on a pathological crowded page.
        const axis=values=>[...new Set(values)].filter(v=>Math.abs(v)<=limit)
          .sort((a,b)=>Math.abs(a)-Math.abs(b)).slice(0,17);
        const trials=axis(xs).flatMap(dx=>axis(ys).map(dy=>({dx,dy,d:Math.hypot(dx,dy)})))
          .filter(p=>p.d>0&&p.d<=limit).sort((a,b)=>a.d-b.d);
        const chosen=trials.find(p=>{const r={l:before.l+p.dx,r:before.r+p.dx,t:before.t+p.dy,b:before.b+p.dy};
          if(obstacles.some(o=>hit(r,o)))return false;
          const grown=union([own,pad(r,.5)]),f=e.item.sourceFrame;
          const overlap=(a,b)=>Math.max(0,Math.min(a.r,b.r)-Math.max(a.l,b.l))*Math.max(0,Math.min(a.b,b.b)-Math.max(a.t,b.t));
          // A sub-glyph extra margin can resolve the collision without a font
          // change. Never extend more than two pixels or cover a new neighbor.
          const allowance=Math.min(2,parseFloat(getComputedStyle(e.node).fontSize)*.25);
          if(Math.max(own.l-grown.l,own.t-grown.t,grown.r-own.r,grown.b-own.b)>allowance||
            !contains({l:f[0],t:f[1],r:f[0]+f[2],b:f[1]+f[3]},grown)||
            obstacles.some(o=>overlap(grown,o)>overlap(own,o)+.01))return false;
          p.grown=grown;return true;});
        if(!chosen)continue;
        detach(e);place(panel,chosen.grown);panel.style.clipPath='none';
        panel.dataset.panelCoverage=JSON.stringify([[chosen.grown.l,chosen.grown.t,
          chosen.grown.r-chosen.grown.l,chosen.grown.b-chosen.grown.t]]);
        e.node.dataset.sourcePanelCoverage=panel.dataset.panelCoverage;
        e.node.style.left=`${parseFloat(e.node.style.left)+chosen.dx}px`;
        e.node.style.top=`${parseFloat(e.node.style.top)+chosen.dy}px`;
        e.ink=ink(e.node);e.node.dataset.captionMinimalShift=JSON.stringify([chosen.dx,chosen.dy]);
      }
      // Solid owner plates replace the text-only backing too. Leaving that
      // clipped clone behind recreates the two-panel silhouette on the page.
      for(const e of entries){
        if(e.panels.length!==1||!flat(e.panels[0]))continue;
        const main=e.panels[0],frame=rect(main),color=getComputedStyle(main).backgroundColor;
        for(const layer of root.querySelectorAll('[data-aidoku-image-ocr-overlay="source-readability-backing"]')){
          if(layer.dataset.aidokuRegion===String(e.item.id)&&contains(frame,rect(layer))&&
            getComputedStyle(layer).backgroundColor===color)layer.remove();
        }
      }
      // Give neighboring solid cards real space. Trim unused margins first;
      // if their lettering still crowds the seam, translate it without reflow.
      const gap=1,margin=.5;
      const cards=entries.filter(e=>e.item.sourceTextOnly===false&&!e.item.rotation&&(!e.item.sourceLettering||e.item.sourceLettering==='piece')&&
        e.item.wrappingScript==='korean'&&flat(e.node)&&e.panels.length===1&&flat(e.panels[0],true)&&(()=>{
          const p=e.panels[0];if(!getComputedStyle(p).clipPath||getComputedStyle(p).clipPath==='none')return true;
          try {return coveredArea(JSON.parse(p.dataset.panelCoverage||'[]').map(r=>({l:r[0],t:r[1],r:r[0]+r[2],b:r[1]+r[3]})))>=area(rect(p))*.995;}catch(_){return false;}
        })())
        .map(e=>({e,p:e.panels[0],base:rect(e.panels[0]),r:rect(e.panels[0])}))
        .sort((a,b)=>a.r.l-b.r.l);
      const overlapY=(a,b)=>Math.min(a.b,b.b)-Math.max(a.t,b.t)>.5;
      const commit=c=>{
        detach(c.e);place(c.p,c.r);c.p.style.clipPath='none';
        c.p.dataset.panelCoverage=JSON.stringify([[c.r.l,c.r.t,c.r.r-c.r.l,c.r.b-c.r.t]]);
        c.e.node.dataset.sourcePanelCoverage=c.p.dataset.panelCoverage;
        c.p.dataset.captionSpaced='true';
      };
      for(const resolve of [false,true])for(let i=0;i<cards.length;i++)for(let j=i+1;j<cards.length;j++){
        const a=cards[i],b=cards[j];
        if(!overlapY(a.r,b.r)||b.r.l-a.r.r>=gap||a.r.l>=b.r.l||a.r.r>=b.r.r)continue;
        const ar=pad(union([a.e.ink,...a.e.sources]),margin),br=pad(union([b.e.ink,...b.e.sources]),margin);
        // These changes remove empty padding only and retain the source boxes.
        const right=Math.max(a.r.l+1,Math.min(a.r.r,ar.r));
        const left=Math.min(b.r.r-1,Math.max(b.r.l,br.l));
        if(right<a.r.r){a.r={...a.r,r:right};commit(a);}
        if(left>b.r.l){b.r={...b.r,l:left};commit(b);}
        if(!resolve||b.r.l-a.r.r>=gap)continue;
        if(!eligible(a.e)||!eligible(b.e)||a.e.item.balancedColumn||b.e.item.balancedColumn)continue;
        const af=a.e.item.sourceFrame,bf=b.e.item.sourceFrame;
        let outerLeft=Math.max(af[0],a.base.l-3),outerRight=Math.min(bf[0]+bf[2],b.base.r+3);
        for(const other of cards){
          if(other===a||other===b)continue;
          if(overlapY(a.r,other.r)&&other.r.l<a.r.l)outerLeft=Math.max(outerLeft,other.r.r+gap);
          if(overlapY(b.r,other.r)&&other.r.r>b.r.r)outerRight=Math.min(outerRight,other.r.l-gap);
        }
        const as=union(a.e.sources),bs=union(b.e.sources),ai=a.e.ink,bi=b.e.ink;
        const lo=Math.max(as.r+margin,outerLeft+ai.r-ai.l+2*margin);
        const hi=Math.min(bs.l-margin-gap,outerRight-(bi.r-bi.l)-2*margin-gap);
        if(lo>hi)continue;
        const seam=Math.max(lo,Math.min(hi,(a.r.r+b.r.l-gap)/2));
        const ad=Math.min(0,seam-margin-ai.r),bd=Math.max(0,seam+gap+margin-bi.l);
        const limit=e=>Math.min(8,parseFloat(getComputedStyle(e.node).fontSize));
        if(Math.abs(ad)>limit(a.e)||Math.abs(bd)>limit(b.e))continue;
        const moved=(r,d)=>({...r,l:r.l+d,r:r.r+d});
        const an=moved(ai,ad),bn=moved(bi,bd);
        const ap={...a.r,l:Math.min(a.r.l,an.l-margin),r:seam};
        const bp={...b.r,l:seam+gap,r:Math.max(b.r.r,bn.r+margin)};
        const overlap=(r,o)=>area({l:Math.max(r.l,o.l),t:Math.max(r.t,o.t),r:Math.min(r.r,o.r),b:Math.min(r.b,o.b)});
        const safe=(c,ink,plate)=>{
          if(plate.l<outerLeft||plate.r>outerRight||!contains(plate,pad(ink,margin)))return false;
          const obstacles=entries.filter(e=>e!==a.e&&e!==b.e).flatMap(e=>[pad(e.ink,.5),...e.sources]).concat(kept);
          return !obstacles.some(o=>hit(ink,o)||overlap(plate,o)>overlap(c.r,o)+.05);
        };
        if(!safe(a,an,ap)||!safe(b,bn,bp))continue;
        for(const [c,d,plate] of [[a,ad,ap],[b,bd,bp]]){
          detach(c.e);c.e.node.style.left=`${parseFloat(c.e.node.style.left)+d}px`;
          c.e.ink=ink(c.e.node);c.e.node.dataset.captionSpacingShift=String(d);
          c.r=plate;commit(c);
        }
      }
      // A crowded row needs a joint solution: moving its middle caption alone
      // can be impossible even though the outer caption has spare space.
      // Search bounded quarter-pixel translations, keeping every glyph and
      // source box inside its own disjoint rectangle; never scale or rewrap.
      const groups=[];
      for(const c of cards){
        const g=groups[groups.length-1],previous=g?.[g.length-1];
        if(previous&&overlapY(previous.r,c.r)&&c.r.l-previous.r.r<=12)g.push(c);
        else groups.push([c]);
      }
      for(const group of groups){
        if(group.length<2||group.length>12||group.some(c=>!eligible(c.e,true)||c.e.item.balancedColumn)||
          !group.some((c,i)=>i&&c.r.l-group[i-1].r.r<gap-.05))continue;
        const owners=new Set(group.map(c=>c.e));
        const obstacles=entries.filter(e=>!owners.has(e)).flatMap(e=>[pad(e.ink,.5),...e.sources,...e.panels.map(rect)]).concat(kept);
        const overlap=(r,o)=>area({l:Math.max(r.l,o.l),t:Math.max(r.t,o.t),r:Math.min(r.r,o.r),b:Math.min(r.b,o.b)});
        let states=[];
        for(let index=0;index<group.length;index++){
          const c=group[index],f=c.e.item.sourceFrame,original=c.e.ink;
          const limit=Math.min(8,parseFloat(getComputedStyle(c.e.node).fontSize));
          const next=[];
          for(let step=-Math.floor(limit*4);step<=Math.floor(limit*4);step++){
            const dx=step/4,moved={...original,l:original.l+dx,r:original.r+dx};
            const required=pad(union([moved,...c.e.sources]),margin);
            const r={...c.r,l:required.l,r:required.r};
            if(r.l<Math.max(f[0],c.base.l-3)||r.r>Math.min(f[0]+f[2],c.base.r+3)||
              !contains(r,pad(moved,margin))||obstacles.some(o=>hit(moved,o)||overlap(r,o)>overlap(c.r,o)+.05))continue;
            let parent=null;
            if(index){
              for(const state of states)if(state.r.r+gap<=r.l&&(!parent||state.cost<parent.cost))parent=state;
              if(!parent)continue;
            }
            next.push({r,dx,c,parent,cost:(parent?.cost||0)+Math.abs(dx)});
          }
          states=next;if(!states.length)break;
        }
        if(!states.length)continue;
        let chosen=states.reduce((a,b)=>a.cost<=b.cost?a:b);
        const solution=[];while(chosen){solution.push(chosen);chosen=chosen.parent;}
        if(solution.length!==group.length)continue;
        for(const {c,r,dx} of solution){
          detach(c.e);c.e.node.style.left=`${parseFloat(c.e.node.style.left)+dx}px`;
          c.e.ink=ink(c.e.node);c.e.node.dataset.captionGroupShift=String(dx);
          c.r=r;commit(c);
        }
      }
    };
    // Opaque caption packing must not use the more aggressive restoration
    // floor: that can merge cards into long, narrowly rewrapped paragraphs.
    const aidokuCaptionFontFloor = (original, minimum = 5) => {
      if(!Number.isFinite(original)||original<=0||!Number.isFinite(minimum)||minimum<=0)return null;
      return Math.max(minimum,Math.min(original,8.5),original*.8);
    };
    // Removing a plate or protecting artwork must not trade away legibility:
    // at phone size 8pt or 75% of the original type is the floor. A caption
    // already below 8pt can rewrap but never becomes smaller. Every caller
    // still measures the complete text and honors the user minimum.
    const aidokuRestoredFontFloor = (original, minimum = 5) => {
      if(!Number.isFinite(original)||original<=0||!Number.isFinite(minimum)||minimum<=0)return null;
      return Math.max(minimum,Math.min(original,8),original*.75);
    };
    const aidokuArtworkFontSizes = (font, minimum = 5) => {
      const bound=aidokuRestoredFontFloor(font,minimum);
      if(bound===null||bound>=font)return [];
      const floor=Math.ceil(bound*4)/4;
      return [...new Set([.9,.8,.7,.65].map(scale=>Math.max(floor,Math.floor(font*scale*4)/4)))]
        .filter(size=>size<font);
    };
    // Cover the full permitted interval within nine probes. A quarter-point
    // walk with a fixed cap previously never reached the floor for large type.
    const aidokuBalloonFontSizes = (font, minimum = 5) => {
      const bound=aidokuRestoredFontFloor(font,minimum);
      if(bound===null||bound>font)return [];
      const floor=Math.ceil(bound*4)/4;
      if(floor>=font)return [font];
      const steps=Math.ceil((font-floor)*4),count=Math.min(8,steps),sizes=[font];
      for(let i=1;i<=count;i++){
        const size=Math.max(floor,Math.floor((font-(font-floor)*i/count)*4)/4);
        if(size<sizes[sizes.length-1])sizes.push(size);
      }
      return sizes;
    };
    // Larger type must not turn a sentence into a stack of one- or two-syllable
    // lines. Short utterances may stack in a round balloon; longer text is
    // rejected when lines average under 2.5 characters and get shorter than
    // the committed layout's lines.
    const aidokuGrowthKeepsLineLength = (text, originalLines, lines) => {
      const count=String(text||'').replace(/\s/gu,'').length;
      if(!count||!Number.isFinite(lines)||lines<1)return false;
      if(lines<3||count<8)return true;
      const before=count/Math.max(1,originalLines||1),after=count/lines;
      return after>=2.5||after>=before;
    };
    // Line-flow defects of a measured layout: stranded syllables, punctuation
    // lines and kinsoku violations outrank mid-word breaks; 0 is clean.
    const aidokuKoreanFlowRank = profile =>
      (profile.hangulFragments+profile.punctuationOnly+profile.badStarts.length+profile.badEnds.length)*100+
        profile.breaks.length;
    // Narrowest width that keeps the longest word on one line (same letter
    // spacing correction as the Korean line breaker).
    const aidokuKoreanWordWidth = (text, size, measure) => {
      const words=String(text||'').split(/\s+/u).filter(Boolean);
      if(!words.length||!Number.isFinite(size)||size<=0)return 0;
      return Math.max(...words.map(word=>measure(word)+Math.max(0,Array.from(word).length-1)*size*(-.012)))+1;
    };
    // Condensed Korean width (장평): a caption whose size is bound by the width
    // of its longest word may set it at 90 % width (a horizontal scale about
    // the box centre), never narrower.
    const aidokuCondensedWidth = .9;
    // Readability floor (CSS px = pt at the phone's page width). Korean type
    // follows its source at 0.9x the source glyph, but source lettering of a
    // spread or dense narration can itself be under 9 px at phone width: a
    // Hangul syllable packs up to ~12 strokes into one em, and below 9 px
    // (27 device px at 3x) its strokes merge. Such a caption may take this
    // size, but only on free room its growth search already verifies (its
    // restored surface or balloon interior, its plate or the flat paper of the
    // plate's colour), never over art, another caption or another source.
    const aidokuReadableFontSize = 9;
    // Harmony and cohort passes never take a lifted caption below this size
    // (the smallest readable one); the growth itself aims at the floor.
    const aidokuReadableMinimum = 8.5;
    // A caption whose source-proportional size (0.9x glyph) is below the floor.
    const aidokuBelowReadableSource = glyph => Number.isFinite(glyph) && glyph > 0 && glyph * .9 < aidokuReadableFontSize;
    // Word-bound: the longest word overflows the measure at full width but
    // fits it condensed. The one test for every condensed path (axis-aligned
    // plates, rotated plates, slanted restored lettering).
    const aidokuCondensedWordBound = (longest, available) =>
      longest > available && longest * aidokuCondensedWidth <= available;
    // Sizes a condensed caption tries, largest first: at least 1.06x and at
    // most 1.25x its full-width size, never above its target.
    const aidokuCondensedSizes = (base, target) => {
      if(!(base>0)||!(target>0))return [];
      const sizes=[];
      for(const gain of [1.25,1.17,1.11,1.06]){
        const size=Math.floor(Math.min(target,base*gain)*4)/4;
        if(size>=base*1.06&&!sizes.includes(size))sizes.push(size);
      }
      return sizes;
    };
    // Only a fully restored balloon may try these after the preferred sizes
    // fail. Its caller commits smaller lettering only when the panel is removed.
    const aidokuEmergencyBalloonFontSizes = (font, minimum, preferred) => {
      if(!Number.isFinite(font)||!Number.isFinite(minimum)||minimum<=0||font<=Math.max(6.5,minimum)||!preferred.length)return [];
      const last=preferred[preferred.length-1];
      // Sizes below 7pt are unreadable on a phone; keep the plate instead.
      return [...new Set([7,minimum].map(size=>Math.max(minimum,size)))].filter(size=>size>=7&&size<last&&size<font);
    };
    // A successful mask may still exclude an unannotated ruby character.
    // Keep the old erasure plate around small surviving ink components near
    // the source; a continuous balloon contour is not a leftover character.
    const aidokuHasResidualLettering = (safe,w,h,regions,glyphSize) => {
      const n=w*h;
      if(!Number.isInteger(w)||!Number.isInteger(h)||w<1||h<1||n>262144||safe?.length!==n||
          !Array.isArray(regions)||!regions.length||!Number.isFinite(glyphSize)||glyphSize<=0||
          !regions.every(r=>Array.isArray(r)&&r.length===4&&r.every(Number.isFinite)))return true;
      const seen=new Uint8Array(n),queue=new Int32Array(n),limit=Math.max(12,glyphSize*2);
      for(let start=0;start<n;start++){
        if(safe[start]||seen[start])continue;
        let head=0,tail=1,l=w,t=h,r=0,b=0;queue[0]=start;seen[start]=1;
        while(head<tail){
          const i=queue[head++],x=i%w,y=i/w|0;l=Math.min(l,x);r=Math.max(r,x);t=Math.min(t,y);b=Math.max(b,y);
          for(let yy=Math.max(0,y-1);yy<=Math.min(h-1,y+1);yy++)for(let xx=Math.max(0,x-1);xx<=Math.min(w-1,x+1);xx++){
            const j=yy*w+xx;if(!safe[j]&&!seen[j]){seen[j]=1;queue[tail++]=j;}
          }
        }
        if(tail>=2&&Math.max(r-l+1,b-t+1)<=limit&&regions.some(q=>
            r>=q[0]-glyphSize&&l<=q[0]+q[2]+glyphSize&&b>=q[1]-glyphSize&&t<=q[1]+q[3]+glyphSize))return true;
      }
      return false;
    };
    // Clipped leading letters can remain connected to an adjacent panel rule.
    // Look for repeated glyph-sized inward protrusions along that rule. A
    // straight/sloping/curved contour alone is not evidence of missed text.
    const aidokuHasAttachedLeadingInk = (safe,w,h,core,glyph) => {
      if(!Number.isInteger(w)||!Number.isInteger(h)||w<1||h<1||w*h>262144||safe?.length!==w*h||
          !Number.isFinite(glyph)||glyph<=0||!Array.isArray(core))return true;
      const radius=Math.max(4,Math.min(64,Math.ceil(glyph*.9))),depth=Math.max(2,glyph*.22);
      let budget=w*h*2;
      for(const r of core){
        if(!Array.isArray(r)||r.length!==4||!r.every(Number.isFinite)||r[2]<=0||r[3]<=0)return true;
        const edge=Math.max(0,Math.ceil(r[0]+r[2])),right=Math.min(w,Math.ceil(edge+glyph*1.5));
        const top=Math.max(0,Math.floor(r[1])),bottom=Math.min(h,Math.ceil(r[1]+r[3]));
        budget-=Math.max(0,bottom-top)*(Math.max(0,right-edge)+radius*2);
        if(budget<0)return true;
        const first=[];
        for(let y=top;y<bottom;y++){
          let x=edge;while(x<right&&safe[y*w+x])x++;
          first.push(x);
        }
        const runs=[];let start=-1;
        for(let y=0;y<=first.length;y++){
          let before=0,after=0;
          for(let k=Math.max(0,y-radius);k<y-1;k++)before=Math.max(before,first[k]);
          for(let k=y+2;k<Math.min(first.length,y+radius+1);k++)after=Math.max(after,first[k]);
          const protrudes=y<first.length&&first[y]-edge<=glyph&&Math.min(before,after)-first[y]>=depth;
          if(protrudes&&start<0)start=y;
          if(!protrudes&&start>=0){
            const length=y-start;
            if(length>=2&&length<=glyph*1.5)runs.push([start,y]);
            start=-1;
          }
        }
        for(let i=1;i<runs.length;i++)if(runs[i][0]-runs[i-1][1]<=glyph*2&&
            runs[i][1]-runs[i][0]+runs[i-1][1]-runs[i-1][0]>=glyph*.5)return true;
      }
      return false;
    };
    // A clean reconstruction can replace the erasure part of a card even if
    // translated text still needs an opaque backing. Certify the whole area
    // being released (including source-size fringes), never an extrapolation
    // beyond the reconstructed crop. Surviving small ink vetoes release.
    const aidokuRestoredErasureCovers = (safe,w,h,regions,glyphSize,core) => {
      const valid=regions=>Array.isArray(regions)&&regions.length&&regions.every(r=>
          Array.isArray(r)&&r.length===4&&r.every(Number.isFinite)&&r[2]>0&&r[3]>0&&
          r[0]>=0&&r[1]>=0&&r[0]+r[2]<=w&&r[1]+r[3]<=h);
      if(!Number.isInteger(w)||!Number.isInteger(h)||w<1||h<1||w*h>262144||safe?.length!==w*h||
          !valid(regions)||!valid(core))return false;
      // Bold lettering can join a panel rule and cease to look like a small
      // component. Unlike the fringe, the original text core must be entirely
      // clear even when the surviving component is large or edge-connected.
      let budget=w*h*2;
      for(const r of core){
        const l=Math.floor(r[0]),t=Math.floor(r[1]),right=Math.ceil(r[0]+r[2]),bottom=Math.ceil(r[1]+r[3]);
        budget-=(right-l)*(bottom-t);if(budget<0)return false;
        for(let y=t;y<bottom;y++)for(let x=l;x<right;x++)if(!safe[y*w+x])return false;
      }
      return !aidokuHasResidualLettering(safe,w,h,regions,glyphSize);
    };
    // Keep only final lettering and still-unerased source footprints. Rects
    // are intersected with the old opaque card: this can uncover empty corners,
    // but cannot cover any new artwork or move a glyph. Round outward on the
    // WebKit layout grid so subpixel rounding cannot expose source remnants.
    const aidokuCompactPanel = (panel, ink, required, neighbors, pad = 3) => {
      const valid=r=>Array.isArray(r)&&r.length===4&&r.every(Number.isFinite)&&r[2]>0&&r[3]>0;
      if(!valid(panel)||!valid(ink)||!Array.isArray(required)||!required.every(valid)||
          !Array.isArray(neighbors)||!neighbors.every(valid)||!Number.isFinite(pad)||pad<0)return null;
      const intersect=(r,padding)=>{
        let l=Math.max(panel[0],Math.floor((r[0]-padding)*64)/64);
        let t=Math.max(panel[1],Math.floor((r[1]-padding)*64)/64);
        let rr=Math.min(panel[0]+panel[2],Math.ceil((r[0]+r[2]+padding)*64)/64);
        let b=Math.min(panel[1]+panel[3],Math.ceil((r[1]+r[3]+padding)*64)/64);
        // Sub-point erosion can expose only the edge of an unannotated glyph.
        // It saves no useful space; retain the prior edge instead of a sliver.
        if(l-panel[0]<1)l=panel[0];if(t-panel[1]<1)t=panel[1];
        if(panel[0]+panel[2]-rr<1)rr=panel[0]+panel[2];
        if(panel[1]+panel[3]-b<1)b=panel[1]+panel[3];
        return rr>l&&b>t?[l,t,rr-l,b-t]:null;
      };
      if(ink[0]<panel[0]-.04||ink[1]<panel[1]-.04||
          ink[0]+ink[2]>panel[0]+panel[2]+.04||ink[1]+ink[3]>panel[1]+panel[3]+.04)return null;
      const regions=[ink,...required].map(r=>intersect(r,pad));
      // Preserve this card's existing contribution underneath nearby lettering.
      // Otherwise trimming one caption can silently destroy another's contrast.
      regions.push(...neighbors.map(r=>intersect(r,2)));
      const coverage=regions.filter(Boolean).filter((r,i,a)=>!a.some((q,j)=>j!==i&&q&&
        q[0]<=r[0]&&q[1]<=r[1]&&q[0]+q[2]>=r[0]+r[2]&&q[1]+q[3]>=r[1]+r[3]&&
        (q.some((v,k)=>v!==r[k])||j<i)));
      const l=Math.min(...coverage.map(r=>r[0])),t=Math.min(...coverage.map(r=>r[1]));
      const right=Math.max(...coverage.map(r=>r[0]+r[2])),bottom=Math.max(...coverage.map(r=>r[1]+r[3]));
      // One rectangle around every footprint. A union of separate text and
      // source rectangles leaves a cross-shaped plate.
      const frame=[l,t,right-l,bottom-t];
      return {frame,coverage:[frame]};
    };
    // Resolve visible surfaces in paint order, including clipped cards and local
    // backings. Hidden cards must not dictate the final foreground contrast.
    const aidokuVisiblePanelColors = (ink, layers, fallback) => {
      let remaining=[ink];const colors=[];
      for(const layer of [...layers].reverse()){
        let visible=false;
        for(const cover of layer.coverage){
          const next=[];
          for(const r of remaining){
            const l=Math.max(r[0],cover[0]),t=Math.max(r[1],cover[1]);
            const right=Math.min(r[0]+r[2],cover[0]+cover[2]),bottom=Math.min(r[1]+r[3],cover[1]+cover[3]);
            if(right-l<=.04||bottom-t<=.04){next.push(r);continue;}
            visible=true;
            if(t>r[1])next.push([r[0],r[1],r[2],t-r[1]]);
            if(bottom<r[1]+r[3])next.push([r[0],bottom,r[2],r[1]+r[3]-bottom]);
            if(l>r[0])next.push([r[0],t,l-r[0],bottom-t]);
            if(right<r[0]+r[2])next.push([right,t,r[0]+r[2]-right,bottom-t]);
          }
          remaining=next;
        }
        if(visible)colors.push(layer.color);
        if(!remaining.length)break;
      }
      if(remaining.length)colors.push(fallback);
      return colors.filter((c,i,a)=>Array.isArray(c)&&c.length===3&&c.every(Number.isFinite)&&
        a.findIndex(other=>other?.join(',')===c.join(','))===i);
    };
    // Overlapping opaque cards can form a stacking cycle: putting either whole
    // card on top changes the other caption's backing. Paint only the protected
    // text footprint last, within its own existing card and clear of other ink.
    const aidokuTextBackingRect = (ink, panel, neighbors) => {
      const valid=r=>Array.isArray(r)&&r.length===4&&r.every(Number.isFinite)&&r[2]>0&&r[3]>0;
      if(!valid(ink)||!valid(panel)||!Array.isArray(neighbors)||!neighbors.every(valid))return null;
      if(ink[0]<panel[0]-.04||ink[1]<panel[1]-.04||ink[0]+ink[2]>panel[0]+panel[2]+.04||
          ink[1]+ink[3]>panel[1]+panel[3]+.04)return null;
      for(const pad of [2,1,0]){
        const left=Math.max(panel[0],ink[0]-pad),top=Math.max(panel[1],ink[1]-pad);
        const right=Math.min(panel[0]+panel[2],ink[0]+ink[2]+pad),bottom=Math.min(panel[1]+panel[3],ink[1]+ink[3]+pad);
        if(neighbors.some(r=>Math.max(0,Math.min(right,r[0]+r[2])-Math.max(left,r[0]))*
            Math.max(0,Math.min(bottom,r[1]+r[3])-Math.max(top,r[1]))>.04))continue;
        return [left,top,right-left,bottom-top];
      }
      return null;
    };
    const aidokuNeedsTextBacking = (ink, owner, panels) => {
      if(!ink||owner<0||owner>=panels.length)return false;
      return panels.slice(owner+1).some(p=>p.color!==panels[owner].color&&
        Math.min(ink[0]+ink[2],p.rect[0]+p.rect[2])-Math.max(ink[0],p.rect[0])>.04&&
        Math.min(ink[1]+ink[3],p.rect[1]+p.rect[3])-Math.max(ink[1],p.rect[1])>.04);
    };
    // A panel's ownership is not proof of readable color. Do not replace a
    // higher-contrast overlapping surface, or move away from it, merely to
    // recover the source anchor. The callback uses the final clustered ink.
    const aidokuTextBackingKeepsContrast = (ink, owner, panels, contrast) => {
      if(!ink||owner<0||owner>=panels.length)return false;
      const own=contrast(panels[owner].color);
      if(!Number.isFinite(own)||own<1)return false;
      return panels.slice(owner+1).every(p=>{
        if(Math.min(ink[0]+ink[2],p.rect[0]+p.rect[2])-Math.max(ink[0],p.rect[0])<=.04||
            Math.min(ink[1]+ink[3],p.rect[1]+p.rect[3])-Math.max(ink[1],p.rect[1])<=.04)return true;
        const other=contrast(p.color);
        return Number.isFinite(other)&&own+1e-6>=other;
      });
    };
    // Packing uses padded cards, which can displace the actual lettering even
    // when its original position is free. Restore only transparent lettering
    // inside an already frozen opaque plate: no resizing or new artwork cover.
    const aidokuSourceAnchorShift = (ink, source, plate, obstacles, leavesOverlap = false) => {
      const valid=r=>Array.isArray(r)&&r.length===4&&r.every(Number.isFinite)&&r[2]>0&&r[3]>0;
      if(!valid(ink)||!valid(source)||!valid(plate)||!Array.isArray(obstacles)||
          !obstacles.every(valid))return null;
      const pad=3,tolerance=.04;
      const inside=r=>r[0]>=plate[0]+pad-tolerance&&r[1]>=plate[1]+pad-tolerance&&
        r[0]+r[2]<=plate[0]+plate[2]-pad+tolerance&&r[1]+r[3]<=plate[1]+plate[3]-pad+tolerance;
      if(!inside(ink))return null;
      const wantedX=source[0]+source[2]/2-ink[0]-ink[2]/2;
      const wantedY=source[1]+source[3]/2-ink[1]-ink[3]/2;
      // Ignore normal optical/subpixel differences. The limit is relative to
      // the source, so narrow manga columns cannot hide a substantial drift.
      if(Math.abs(wantedX)<=Math.max(2,source[2]*.2)&&
          Math.abs(wantedY)<=Math.max(2,source[3]*.2))return null;
      const clamp=(v,lo,hi)=>Math.min(hi,Math.max(lo,v));
      // Whole WebKit layout units, toward zero: rounding at commit must not
      // turn a collision-free probe into a new edge overlap.
      const snap=v=>Math.trunc(v*64)/64;
      const dx=snap(clamp(ink[0]+wantedX,plate[0]+pad,plate[0]+plate[2]-pad-ink[2])-ink[0]);
      const dy=snap(clamp(ink[1]+wantedY,plate[1]+pad,plate[1]+plate[3]-pad-ink[3])-ink[1]);
      const overlap=(a,b)=>Math.max(0,Math.min(a[0]+a[2],b[0]+b[2])-Math.max(a[0],b[0]))*
        Math.max(0,Math.min(a[1]+a[3],b[1]+b[3])-Math.max(a[1],b[1]));
      const distance=(x,y)=>Math.pow((wantedX-x)/source[2],2)+Math.pow((wantedY-y)/source[3],2);
      let best=null,bestDistance=distance(0,0);
      for(const [x,y] of [[dx,dy],[dx,0],[0,dy]]){
        if(Math.hypot(x,y)<1||Math.abs(wantedX-x)>Math.abs(wantedX)+.001||
            Math.abs(wantedY-y)>Math.abs(wantedY)+.001)continue;
        const moved=[ink[0]+x,ink[1]+y,ink[2],ink[3]];
        // Check the whole path as well as the destination, preventing a jump
        // across another dialogue/source even if the far side happens to fit.
        // With leavesOverlap, lettering which a shared caption cell already
        // placed over another source may leave it toward its own source: that
        // overlap must only not grow at the destination.
        const swept=[Math.min(ink[0],moved[0]),Math.min(ink[1],moved[1]),
          ink[2]+Math.abs(x),ink[3]+Math.abs(y)];
        if(!inside(moved)||obstacles.some(o=>{
          const current=overlap(ink,o);
          return leavesOverlap&&current>tolerance?overlap(moved,o)>current+tolerance:overlap(swept,o)>current+tolerance;
        }))continue;
        const score=distance(x,y);
        if(score<bestDistance-.0001){best={dx:x,dy:y};bestDistance=score;}
      }
      return best;
    };
    // Rectangle difference {left,top,right,bottom} minus one rectangle, as at
    // most four disjoint pieces per input rectangle.
    const aidokuSubtractRects = (rects, cut) => rects.flatMap(a => {
      if(Math.min(a.right,cut.right)<=Math.max(a.left,cut.left)||Math.min(a.bottom,cut.bottom)<=Math.max(a.top,cut.top))return [a];
      const top=Math.max(a.top,cut.top),bottom=Math.min(a.bottom,cut.bottom);
      return [{...a,bottom:cut.top},{...a,top:cut.bottom},{...a,right:cut.left,top,bottom},{...a,left:cut.right,top,bottom}]
        .filter(r=>r.right-r.left>0&&r.bottom-r.top>0);
    });
    // Page area owned by source lettering that stays visible: each kept box
    // [x,y,w,h] plus a halo of 15% of its glyph (1-3 px) for glyph edges past
    // the OCR box, minus the painted captions' source boxes, which those
    // captions still erase. Pieces under half a pixel are dropped.
    const aidokuKeptLetteringZones = (kept, painted) => {
      if(!Array.isArray(kept)||!Array.isArray(painted)||kept.length>256)return [];
      const valid=r=>Array.isArray(r)&&r.length===4&&r.every(Number.isFinite)&&r[2]>0&&r[3]>0;
      const cuts=painted.filter(valid).slice(0,512).map(r=>({left:r[0],top:r[1],right:r[0]+r[2],bottom:r[1]+r[3]}));
      return kept.flatMap(k=>{
        const r=[k.x,k.y,k.width,k.height];
        if(!valid(r))return [];
        const glyph=Number(k.sourceFontSize)>0?Number(k.sourceFontSize):Math.min(r[2],r[3]);
        const pad=Math.max(1,Math.min(3,glyph*.15));
        let pieces=[{left:r[0]-pad,top:r[1]-pad,right:r[0]+r[2]+pad,bottom:r[1]+r[3]+pad}];
        for(const cut of cuts){pieces=aidokuSubtractRects(pieces,cut);if(pieces.length>64)break;}
        return pieces.filter(p=>p.right-p.left>=.5&&p.bottom-p.top>=.5).map(p=>({...p,id:String(k.id)}));
      });
    };
    // Gloss placement at kept source lettering (titles, sound effects, logos). A gloss is always
    // attached to its source, like a scanlator's note: centred directly below or directly above the
    // lettering's ink (a gap of about a fifth of the gloss size, at most half a line), else directly
    // beside it (right or left, vertically centred; along a tall column also level with its ends).
    // Below and above compete on the art under them; beside costs more. The block of translated
    // nodes is tried at every size from `start` down to `minimum`, wrapped at the ink width, the
    // frame width, the side room, and 1/2 or 1/3 of the ink width; each node takes at most `lines`
    // lines. A spot must stay in the frame and in the lettering's panel (no frame line between
    // them), off the `blocked` rects and the lettering's ink, and on flat page. Flatness comes from
    // one sample grid (about 2 css px per sample) of the page band around the lettering: luminance
    // steps, the lettering's own fill and the sampled background colour, as prefix sums. Cost: side
    // + 12x edge share + 6x the relative size loss; a smaller size is tried only while its size
    // penalty stays below the best cost. Returns {cost,size,width,lh,moves,edge,rank,side,gap,ink} or null.
    const aidokuGlossPlacer = ({frame:f,band,fill,ground,image:glossImage,reasons}) => {
      let grid;
      const intersects=(a,b)=>a.left-3<b.right&&a.right+3>b.left&&a.top-3<b.bottom&&a.bottom+3>b.top;
      const sampleGrid=()=>{
        if(grid!==undefined)return grid;grid=null;
        if(!glossImage?.complete||!(glossImage.naturalWidth>0))return grid;
        const reach=26*1.2*3+40,top=Math.max(f[1],band.top-reach),bottom=Math.min(f[1]+f[3],band.bottom+reach);
        const k=Math.max(2,f[2]/200,(bottom-top)/400),gw=Math.max(2,Math.round(f[2]/k)),gh=Math.max(2,Math.round((bottom-top)/k));
        const canvas=document.createElement('canvas'),context=canvas.getContext?.('2d',{willReadFrequently:true});
        if(!context)return grid;
        canvas.width=gw;canvas.height=gh;
        let data;
        try {
          context.drawImage(glossImage,0,(top-f[1])/f[3]*glossImage.naturalHeight,glossImage.naturalWidth,(bottom-top)/f[3]*glossImage.naturalHeight,0,0,gw,gh);
          data=context.getImageData(0,0,gw,gh).data;
        } catch(_){return grid;}
        const lum=new Float32Array(gw*gh),W=gw+1,sum=()=>new Int32Array(W*(gh+1));
        const edges=sum(),pairs=sum(),own=sum(),paper=sum(),rows=new Int32Array(W*gh),columns=new Int32Array((gh+1)*gw);
        for(let i=0;i<gw*gh;i++){const p=i*4;lum[i]=data[p]*.299+data[p+1]*.587+data[p+2]*.114;}
        for(let y=0;y<gh;y++)for(let x=0;x<gw;x++){
          const i=y*gw+x,p=i*4,step=x+1<gw&&Math.abs(lum[i]-lum[i+1])>32?1:0,drop=y+1<gh&&Math.abs(lum[i]-lum[i+gw])>32?1:0;
          const o=Math.max(Math.abs(data[p]-fill[0]),Math.abs(data[p+1]-fill[1]),Math.abs(data[p+2]-fill[2]))<=24?1:0;
          const a=ground&&Math.max(Math.abs(data[p]-ground[0]),Math.abs(data[p+1]-ground[1]),Math.abs(data[p+2]-ground[2]))<=64?1:0;
          const j=(y+1)*W+x+1;
          edges[j]=step+drop+edges[j-1]+edges[j-W]-edges[j-W-1];
          pairs[j]=(x+1<gw?1:0)+(y+1<gh?1:0)+pairs[j-1]+pairs[j-W]-pairs[j-W-1];
          own[j]=o+own[j-1]+own[j-W]-own[j-W-1];paper[j]=a+paper[j-1]+paper[j-W]-paper[j-W-1];
          rows[y*W+x+1]=rows[y*W+x]+drop;columns[x*(gh+1)+y+1]=columns[x*(gh+1)+y]+step;
        }
        const area=(t,x0,y0,x1,y1)=>t[y1*W+x1]-t[y0*W+x1]-t[y1*W+x0]+t[y0*W+x0];
        grid={k,top,gw,gh,area,edges,pairs,own,paper,rows,columns,W};
        return grid;
      };
      const underneath=(r,inset=0)=>{
        const g=sampleGrid();
        if(!g)return {rule:0,edge:0,edgeMax:0,own:0,paper:1};
        reasons.reads++;
        const x0=Math.max(0,Math.floor((r.left-f[0])/g.k)),x1=Math.min(g.gw,Math.ceil((r.right-f[0])/g.k));
        const y0=Math.max(0,Math.floor((r.top-g.top)/g.k)),y1=Math.min(g.gh,Math.ceil((r.bottom-g.top)/g.k));
        if(x1-x0<2||y1-y0<2)return {rule:1,edge:1,edgeMax:1,own:1,paper:0};
        // Square cells (one line tall): a spot is judged by its worst cell, so a glyph
        // stem or a face at one end is not averaged away by flat surface elsewhere.
        const cell=Math.max(2,y1-y0);let edgeMax=0,own=0,paper=1;
        for(let c=x0;c<x1;c+=cell){
          const c1=Math.min(x1,c+cell),n=(c1-c)*(y1-y0),p=g.area(g.pairs,c,y0,c1,y1);
          edgeMax=Math.max(edgeMax,p?g.area(g.edges,c,y0,c1,y1)/p:0);
          own=Math.max(own,g.area(g.own,c,y0,c1,y1)/n);paper=Math.min(paper,g.area(g.paper,c,y0,c1,y1)/n);
        }
        // A frame line or panel border: one row (column) with steps along most of its length.
        // Only lines through the text itself count; the clearance margin may touch one.
        const iy=Math.round(inset/g.k)+1,ix=iy;let rule=0;
        for(let y=y0+iy;y<y1-iy-1;y++)rule=Math.max(rule,(g.rows[y*g.W+x1]-g.rows[y*g.W+x0])/(x1-x0));
        for(let x=x0+ix;x<x1-ix-1;x++)rule=Math.max(rule,(g.columns[x*(g.gh+1)+y1]-g.columns[x*(g.gh+1)+y0])/(y1-y0));
        const p=g.area(g.pairs,x0,y0,x1,y1);
        return {rule,edge:p?g.area(g.edges,x0,y0,x1,y1)/p:0,edgeMax,own,paper};
      };
      // A frame line or panel border between the lettering and a spot: a row (column) with steps along
      // 80 % of a band 1.5x the lettering's width (height), from the spot to the lettering's middle.
      // Lettering strokes stay inside their box, so they cover at most two thirds of the band; the box
      // itself may reach over a border into the next panel.
      const divided=(r,wide)=>{
        const g=sampleGrid();
        if(!g)return false;
        const x0=Math.max(0,Math.floor((r.left-f[0])/g.k)),x1=Math.min(g.gw,Math.ceil((r.right-f[0])/g.k));
        const y0=Math.max(0,Math.floor((r.top-g.top)/g.k)),y1=Math.min(g.gh,Math.ceil((r.bottom-g.top)/g.k));
        if(x1-x0<2||y1-y0<2)return false;
        if(wide)for(let y=y0;y<y1;y++)if(g.rows[y*g.W+x1]-g.rows[y*g.W+x0]>(x1-x0)*.8)return true;
        if(!wide)for(let x=x0;x<x1;x++)if(g.columns[x*(g.gh+1)+y1]-g.columns[x*(g.gh+1)+y0]>(y1-y0)*.8)return true;
        return false;
      };
      // The lettering's ink box: the rows and columns of the OCR box that hold its fill (only when the
      // fill stands out from the page ground; else the OCR box). OCR boxes carry padding, so a gloss
      // measured from the ink sits closer; ink past the box is caught by the spot's fill test below.
      const figure=Boolean(ground)&&Math.max(...fill.map((v,k)=>Math.abs(v-ground[k])))>48;
      const inkOf=s=>{
        const g=figure?sampleGrid():null;
        if(!g)return s;
        const toX=x=>Math.max(0,Math.min(g.gw,Math.round((x-f[0])/g.k))),toY=y=>Math.max(0,Math.min(g.gh,Math.round((y-g.top)/g.k)));
        const bx0=toX(s.left),bx1=toX(s.right),by0=toY(s.top),by1=toY(s.bottom);
        if(bx1-bx0<3||by1-by0<3||g.area(g.own,bx0,by0,bx1,by1)<(bx1-bx0)*(by1-by0)*.03)return s;
        const row=y=>g.area(g.own,bx0,y,bx1,y+1)>=Math.max(2,(bx1-bx0)*.08);
        let top=by0,bottom=by1-1;
        while(top<bottom&&!row(top))top++;
        while(bottom>top&&!row(bottom))bottom--;
        const column=x=>g.area(g.own,x,top,x+1,bottom+1)>=Math.max(2,(bottom+1-top)*.08);
        let left=bx0,right=bx1-1;
        while(left<right&&!column(left))left++;
        while(right>left&&!column(right))right--;
        // A partial fill match (a two-tone effect) must not shrink the box to one of its parts.
        const ink={left:Math.max(s.left,f[0]+left*g.k),right:Math.min(s.right,f[0]+(right+1)*g.k),
          top:Math.max(s.top,g.top+top*g.k),bottom:Math.min(s.bottom,g.top+(bottom+1)*g.k)};
        if(ink.right-ink.left<(s.right-s.left)*.5){ink.left=s.left;ink.right=s.right;}
        if(ink.bottom-ink.top<(s.bottom-s.top)*.5){ink.top=s.top;ink.bottom=s.bottom;}
        return ink;
      };
      const search=(s,blocked,nodes,before,{start,minimum,lines=2,texture=false})=>{
        // An unsampled page cannot prove a spot flat: no gloss rather than one over the art.
        if(!sampleGrid())return null;
        const ink=inkOf(s),inside=r=>r.left<ink.right&&r.right>ink.left&&r.top<ink.bottom&&r.bottom>ink.top,frameWidth=f[2]-8;
        const sourceWidth=Math.min(ink.right-ink.left,frameWidth),sideWidth=Math.max(ink.left-f[0]-8,f[0]+f[2]-ink.right-8);
        const cx=(ink.left+ink.right)/2,cy=(ink.top+ink.bottom)/2;
        let placed=null;
        // With `texture`, a lettering set on even texture (hatching, screentone) with no flat spot next to
        // it takes a note of at least 11 px on the texture itself (up to twice the edge share); its
        // heavier outline keeps it readable, and it hides far less art than a plate would.
        const pass=relaxed=>{(()=>{for(let size=relaxed?Math.max(start,11):start,floor=relaxed?Math.max(minimum,11):minimum;
          size>=floor;size=size>floor?Math.max(floor,Math.round(size*.9*4)/4):0){
          const lh=Math.round(size*1.2*100)/100;
          for(const width of [...new Set([sourceWidth,frameWidth,sideWidth,sourceWidth/2,sourceWidth/3].map(Math.round))].filter(w=>w>=size*4)){
            const texts=nodes.map(n=>{
              Object.assign(n.style,{fontSize:`${size}px`,lineHeight:`${lh}px`,width:`${width}px`,height:`${Math.ceil(lh*3)}px`,textAlign:'center'});
              const r=document.createRange();r.selectNodeContents(n);return r.getBoundingClientRect();
            });
            if(texts.some(t=>t.height>lh*(lines+.6)||t.width>width+1))continue;
            const tw=Math.max(...texts.map(t=>t.width)),th=texts.reduce((sum,t)=>sum+t.height,0),spots=[];
            // A small gap (about a fifth of the size), else at most half a line.
            const near=Math.max(2,Math.round(size*.22*4)/4),far=Math.max(near,Math.round(lh*.5*4)/4);
            for(const [gap,extra] of [[near,0],[far,.5]]){
              if(extra&&far<=near)continue;
              spots.push({rank:0,side:'below',gap,cost:extra,left:cx-tw/2,top:ink.bottom+gap});
              spots.push({rank:1,side:'above',gap,cost:.25+extra,left:cx-tw/2,top:ink.top-gap-th});
              spots.push({rank:2,side:'right',gap,cost:2+extra,left:ink.right+gap,top:cy-th/2,beside:true});
              spots.push({rank:2,side:'left',gap,cost:2.25+extra,left:ink.left-gap-tw,top:cy-th/2,beside:true});
              // Alongside a tall column, level with its top or bottom end.
              if(ink.bottom-ink.top>=th*2)for(const [side,left] of [['right',ink.right+gap],['left',ink.left-gap-tw]])
                for(const top of [ink.top,ink.bottom-th])spots.push({rank:3,side,gap,cost:2.5+extra,left,top,beside:true});
            }
            for(const spot of spots){
              // Centred on the ink; the frame may push a block below or above by a quarter of its width.
              const left=spot.beside?spot.left:Math.max(f[0]+4,Math.min(f[0]+f[2]-4-tw,spot.left)),top=spot.top;
              const next={left,right:left+tw,top,bottom:top+th};
              if(next.top<f[1]+4||next.bottom>f[1]+f[3]-4||next.left<f[0]+4||next.right>f[0]+f[2]-4||
                 Math.abs(left-spot.left)>tw*.25+1){reasons.frame++;continue;}
              if(inside(next)){reasons.source++;continue;}
              if(blocked.some(r=>intersects(next,r))){reasons.blocked++;continue;}
              // The clearance margin never reaches back into the lettering it is attached to.
              const m=Math.max(3,size*.2),pad={left:next.left-m,right:next.right+m,top:next.top-m,bottom:next.bottom+m};
              if(spot.side==='below')pad.top=Math.max(pad.top,ink.bottom+1);
              if(spot.side==='above')pad.bottom=Math.min(pad.bottom,ink.top-1);
              if(spot.beside&&spot.side==='right')pad.left=Math.max(pad.left,ink.right+1);
              if(spot.beside&&spot.side==='left')pad.right=Math.min(pad.right,ink.left-1);
              const under=underneath(pad,m);
              // Over art or lettering (dense edges), a rule through the text, or the lettering's own fill
              // (when that fill differs from the page ground).
              if(under.edge>(relaxed?.32:.16)||under.edgeMax>(relaxed?.5:.3)||under.rule>.6||figure&&under.own>.2){reasons.edge++;continue;}
              // The spot stays in the lettering's panel: no frame line in the gap between them.
              const w=ink.right-ink.left,h=ink.bottom-ink.top,wide=!spot.beside;
              const between=wide?{left:ink.left-w*.25,right:ink.right+w*.25,top:Math.min(next.top,ink.top+h*.5),bottom:Math.max(next.bottom,ink.top+h*.5)}:
                {left:Math.min(next.left,ink.left+w*.5),right:Math.max(next.right,ink.left+w*.5),top:ink.top-h*.25,bottom:ink.bottom+h*.25};
              if(divided(between,wide)){reasons.panel=(reasons.panel||0)+1;continue;}
              const cost=spot.cost+under.edge*12+(start-size)/start*6+(relaxed?3:0);
              if(!placed||cost<placed.cost){
                // Lines stack in source order, each centred in the block.
                let y=top;const order=before?[1,0]:[0,1],moves=[];
                for(const k of order.filter(k=>k<texts.length)){
                  moves[k]={dx:left+(tw-texts[k].width)/2-texts[k].left,dy:y-texts[k].top};y+=texts[k].height;
                }
                placed={cost,size,width,lh,moves,edge:under.edge,rank:spot.rank,side:spot.side,gap:spot.gap,ink,texture:relaxed};
              }
            }
          }
          // Smaller sizes only pay off while their size penalty is below the best cost.
          if(placed&&(start-size)/start*6>=placed.cost)break;
        }})();};
        pass(false);
        if(!placed&&texture)pass(true);
        return placed;
      };
      // Tilted lettering (see searchTilted): a frame {cx,cy,angle,hw,hh} is the lettering's box in its own
      // axes (u along its baseline, v along its local down), centred on (cx,cy). `at` maps local to page.
      const at=(q,u,v)=>{const c=Math.cos(q.angle),n=Math.sin(q.angle);return [q.cx+u*c-v*n,q.cy+u*n+v*c];};
      const cornersOf=(q,r)=>[[r.u0,r.v0],[r.u1,r.v0],[r.u1,r.v1],[r.u0,r.v1]].map(([u,v])=>at(q,u,v));
      // Separating axes: an oriented block (page corners) against an axis-aligned rect grown by 3 px.
      const meets=(corners,b,q)=>{
        const xs=corners.map(p=>p[0]),ys=corners.map(p=>p[1]);
        if(Math.max(...xs)<=b.left-3||Math.min(...xs)>=b.right+3||Math.max(...ys)<=b.top-3||Math.min(...ys)>=b.bottom+3)return false;
        const c=Math.cos(q.angle),n=Math.sin(q.angle),box=[[b.left-3,b.top-3],[b.right+3,b.top-3],[b.right+3,b.bottom+3],[b.left-3,b.bottom+3]];
        for(const [ax,ay] of [[c,n],[-n,c]]){
          const a=corners.map(p=>p[0]*ax+p[1]*ay),d=box.map(p=>p[0]*ax+p[1]*ay);
          if(Math.max(...a)<=Math.min(...d)||Math.max(...d)<=Math.min(...a))return false;
        }
        return true;
      };
      // Page samples (grid cells) of a local rect, one per grid step: [x, y] grid indices, or null off the grid.
      const samplesOf=(q,r,g)=>{
        const out=[];
        for(let v=r.v0+g.k/2;v<r.v1;v+=g.k)for(let u=r.u0+g.k/2;u<r.u1;u+=g.k){
          const [px,py]=at(q,u,v),x=Math.floor((px-f[0])/g.k),y=Math.floor((py-g.top)/g.k);
          out.push(x<0||y<0||x>=g.gw||y>=g.gh?null:[x,y,u,v]);
        }
        return out;
      };
      const cellOf=(g,t,x,y)=>g.area(t,x,y,x+1,y+1);
      // `underneath` for an oriented block: the same measures over the samples of the rotated rect.
      const underneathTilted=(q,r,inset)=>{
        const g=sampleGrid();
        if(!g)return {rule:0,edge:0,edgeMax:0,own:0,paper:1};
        reasons.reads++;
        const list=samplesOf(q,r,g);
        if(!list.length||list.some(p=>!p))return {rule:1,edge:1,edgeMax:1,own:1,paper:0};
        const cell=Math.max(2*g.k,r.v1-r.v0),cells=new Map(),rows=new Map(),columns=new Map();
        let e=0,p=0,edgeMax=0,own=0,paper=1;
        for(const [x,y,u,v] of list){
          const ce=cellOf(g,g.edges,x,y),cp=cellOf(g,g.pairs,x,y);e+=ce;p+=cp;
          const key=Math.floor((u-r.u0)/cell),c=cells.get(key)||{e:0,p:0,o:0,a:0,n:0};
          c.e+=ce;c.p+=cp;c.o+=cellOf(g,g.own,x,y);c.a+=cellOf(g,g.paper,x,y);c.n++;cells.set(key,c);
          if(u>r.u0+inset+g.k&&u<r.u1-inset-g.k&&v>r.v0+inset+g.k&&v<r.v1-inset-g.k){
            const rw=rows.get(y)||[0,0],cl=columns.get(x)||[0,0];
            rw[0]++;rw[1]+=g.rows[y*g.W+x+1]-g.rows[y*g.W+x];rows.set(y,rw);
            cl[0]++;cl[1]+=g.columns[x*(g.gh+1)+y+1]-g.columns[x*(g.gh+1)+y];columns.set(x,cl);
          }
        }
        for(const c of cells.values()){edgeMax=Math.max(edgeMax,c.p?c.e/c.p:0);own=Math.max(own,c.o/c.n);paper=Math.min(paper,c.a/c.n);}
        // A rule is a long line: only page rows (columns) holding at least 60 % of the longest run count.
        let rule=0;
        for(const lines of [rows,columns]){
          const longest=Math.max(0,...[...lines.values()].map(l=>l[0]));
          for(const [n,d] of lines.values())if(n>=Math.max(4,longest*.6))rule=Math.max(rule,d/n);
        }
        return {rule,edge:p?e/p:0,edgeMax,own,paper};
      };
      // `divided` for a local band: a page row (column) whose samples in the band nearly all step.
      const dividedTilted=(q,r,wide)=>{
        const g=sampleGrid();
        if(!g)return false;
        const lines=new Map();
        for(const s of samplesOf(q,r,g)){
          if(!s)continue;
          const [x,y]=s,key=wide?y:x,l=lines.get(key)||[0,0];l[0]++;
          l[1]+=wide?g.rows[y*g.W+x+1]-g.rows[y*g.W+x]:g.columns[x*(g.gh+1)+y+1]-g.columns[x*(g.gh+1)+y];lines.set(key,l);
        }
        const longest=Math.max(0,...[...lines.values()].map(l=>l[0]));
        for(const [n,d] of lines.values())if(n>=Math.max(6,longest*.6)&&d>n*.8)return true;
        return false;
      };
      // The ink box in local axes: the rows and columns (along u, v) of the frame that hold the fill.
      const inkOfTilted=q=>{
        const r={u0:-q.hw,u1:q.hw,v0:-q.hh,v1:q.hh},g=figure?sampleGrid():null;
        if(!g)return r;
        const nu=Math.max(1,Math.ceil(q.hw*2/g.k)),nv=Math.max(1,Math.ceil(q.hh*2/g.k)),hu=new Array(nu).fill(0),hv=new Array(nv).fill(0);
        let total=0;
        for(const s of samplesOf(q,r,g)){
          if(!s||!cellOf(g,g.own,s[0],s[1]))continue;
          const iu=Math.min(nu-1,Math.floor((s[2]-r.u0)/g.k)),iv=Math.min(nv-1,Math.floor((s[3]-r.v0)/g.k));hu[iu]++;hv[iv]++;total++;
        }
        if(nu<3||nv<3||total<nu*nv*.03)return r;
        let a=0,b=nv-1,c=0,d=nu-1;
        while(a<b&&hv[a]<Math.max(2,nu*.08))a++;
        while(b>a&&hv[b]<Math.max(2,nu*.08))b--;
        while(c<d&&hu[c]<Math.max(2,nv*.08))c++;
        while(d>c&&hu[d]<Math.max(2,nv*.08))d--;
        const ink={u0:r.u0+c*g.k,u1:Math.min(r.u1,r.u0+(d+1)*g.k),v0:r.v0+a*g.k,v1:Math.min(r.v1,r.v0+(b+1)*g.k)};
        if(ink.u1-ink.u0<(r.u1-r.u0)*.5){ink.u0=r.u0;ink.u1=r.u1;}
        if(ink.v1-ink.v0<(r.v1-r.v0)*.5){ink.v0=r.v0;ink.v1=r.v1;}
        return ink;
      };
      // Attached placement for tilted lettering (the note turns with it): below, above and beside are
      // taken along the lettering's own axes, centred on its ink, with the same gaps and costs as
      // `search`. Every test uses the rotated block: frame corners, separating axes against blocked
      // rects, and samples of the rotated rect for art, rules, fill and frame lines between them.
      const searchTilted=(q,blocked,nodes,before,{start,minimum,lines=2,texture=false})=>{
        // An unsampled page cannot prove a spot flat: no gloss rather than one over the art.
        if(!sampleGrid())return null;
        const ink=inkOfTilted(q),frameWidth=f[2]-8,sourceWidth=Math.min(ink.u1-ink.u0,frameWidth);
        const mu=(ink.u0+ink.u1)/2,mv=(ink.v0+ink.v1)/2;
        let placed=null;
        const pass=relaxed=>{(()=>{for(let size=relaxed?Math.max(start,11):start,floor=relaxed?Math.max(minimum,11):minimum;
          size>=floor;size=size>floor?Math.max(floor,Math.round(size*.9*4)/4):0){
          const lh=Math.round(size*1.2*100)/100;
          for(const width of [...new Set([sourceWidth,frameWidth*.75,sourceWidth/2,sourceWidth/3].map(Math.round))].filter(w=>w>=size*4)){
            const texts=nodes.map(n=>{
              Object.assign(n.style,{fontSize:`${size}px`,lineHeight:`${lh}px`,width:`${width}px`,height:`${Math.ceil(lh*3)}px`,textAlign:'center'});
              const r=document.createRange();r.selectNodeContents(n);return r.getBoundingClientRect();
            });
            if(texts.some(t=>t.height>lh*(lines+.6)||t.width>width+1))continue;
            const tw=Math.max(...texts.map(t=>t.width)),th=texts.reduce((sum,t)=>sum+t.height,0),spots=[];
            const near=Math.max(2,Math.round(size*.22*4)/4),far=Math.max(near,Math.round(lh*.5*4)/4);
            for(const [gap,extra] of [[near,0],[far,.5]]){
              if(extra&&far<=near)continue;
              spots.push({rank:0,side:'below',gap,cost:extra,u:mu,v:ink.v1+gap+th/2});
              spots.push({rank:1,side:'above',gap,cost:.25+extra,u:mu,v:ink.v0-gap-th/2});
              spots.push({rank:2,side:'right',gap,cost:2+extra,u:ink.u1+gap+tw/2,v:mv,beside:true});
              spots.push({rank:2,side:'left',gap,cost:2.25+extra,u:ink.u0-gap-tw/2,v:mv,beside:true});
              if(ink.v1-ink.v0>=th*2)for(const [side,u] of [['right',ink.u1+gap+tw/2],['left',ink.u0-gap-tw/2]])
                for(const v of [ink.v0+th/2,ink.v1-th/2])spots.push({rank:3,side,gap,cost:2.5+extra,u,v,beside:true});
            }
            for(const spot of spots){
              const r={u0:spot.u-tw/2,u1:spot.u+tw/2,v0:spot.v-th/2,v1:spot.v+th/2},corners=cornersOf(q,r);
              if(corners.some(([x,y])=>x<f[0]+4||x>f[0]+f[2]-4||y<f[1]+4||y>f[1]+f[3]-4)){reasons.frame++;continue;}
              if(blocked.some(b=>meets(corners,b,q))){reasons.blocked++;continue;}
              const m=Math.max(3,size*.2),pad={u0:r.u0-m,u1:r.u1+m,v0:r.v0-m,v1:r.v1+m};
              if(spot.side==='below')pad.v0=Math.max(pad.v0,ink.v1+1);
              if(spot.side==='above')pad.v1=Math.min(pad.v1,ink.v0-1);
              if(spot.beside&&spot.side==='right')pad.u0=Math.max(pad.u0,ink.u1+1);
              if(spot.beside&&spot.side==='left')pad.u1=Math.min(pad.u1,ink.u0-1);
              const under=underneathTilted(q,pad,m);
              if(under.edge>(relaxed?.32:.16)||under.edgeMax>(relaxed?.5:.3)||under.rule>.6||figure&&under.own>.2){reasons.edge++;continue;}
              const w=ink.u1-ink.u0,h=ink.v1-ink.v0,wide=!spot.beside;
              const between=wide?{u0:ink.u0-w*.25,u1:ink.u1+w*.25,v0:Math.min(r.v0,mv),v1:Math.max(r.v1,mv)}:
                {u0:Math.min(r.u0,mu),u1:Math.max(r.u1,mu),v0:ink.v0-h*.25,v1:ink.v1+h*.25};
              // Beside: also no frame line across the note's own rows between the ink and the note's far edge
              // (a border running past lettering that is cut by the page edge).
              const gapBand=spot.side==='right'?{u0:ink.u1,u1:r.u1,v0:r.v0,v1:r.v1}:{u0:r.u0,u1:ink.u0,v0:r.v0,v1:r.v1};
              if(dividedTilted(q,between,wide)||spot.beside&&dividedTilted(q,gapBand,false)){reasons.panel=(reasons.panel||0)+1;continue;}
              const cost=spot.cost+under.edge*12+(start-size)/start*6+(relaxed?3:0);
              if(!placed||cost<placed.cost){
                // The block is set upright around its centre, then turned about it (see `transform`).
                const [cx,cy]=at(q,spot.u,spot.v);let y=cy-th/2;const order=before?[1,0]:[0,1],moves=[];
                for(const k of order.filter(k=>k<texts.length)){
                  moves[k]={dx:cx-tw/2+(tw-texts[k].width)/2-texts[k].left,dy:y-texts[k].top};y+=texts[k].height;
                }
                placed={cost,size,width,lh,moves,edge:under.edge,rank:spot.rank,side:spot.side,gap:spot.gap,texture:relaxed,
                  angle:q.angle,center:[cx,cy],block:[tw,th]};
              }
            }
          }
          if(placed&&(start-size)/start*6>=placed.cost)break;
        }})();};
        pass(false);
        if(!placed&&texture)pass(true);
        return placed;
      };
      return {search,searchTilted,underneath,divided,inkOf,setBand:next=>{band=next;grid=undefined;}};
    };
    // Turns a placed gloss node with its lettering: rotation about the text block's centre.
    const aidokuTurnGloss = (node, placed) => {
      if (!placed?.angle) return;
      const left = parseFloat(node.style.left) - scrollX, top = parseFloat(node.style.top) - scrollY;
      node.style.transformOrigin = `${placed.center[0] - left}px ${placed.center[1] - top}px`;
      node.style.transform = `rotate(${placed.angle}rad)`;
    };
    // Complete-link clusters cannot bridge two distinct styles through a chain
    // of intermediate samples. Sorting also makes them independent of OCR order.
    const aidokuStyleGroups = (values, compatible, compare) => {
      const groups=[];
      for(const value of [...values].sort(compare)) {
        const group=groups.find(g=>g.every(other=>compatible(value,other)));
        if(group)group.push(value);else groups.push([value]);
      }
      return groups;
    };
    const aidokuFontClusters = entries => {
      if(entries.length>256)return [];
      return aidokuStyleGroups(entries.filter(e=>Number.isFinite(e.source)&&e.source>0&&Number.isFinite(e.font)&&e.font>=5),
        (a,b)=>a.script===b.script&&a.vertical===b.vertical&&a.column===b.column&&
          Math.max(a.source,b.source)/Math.min(a.source,b.source)<=1.22,
        (a,b)=>a.source-b.source||a.font-b.font||String(a.id).localeCompare(String(b.id)))
        .filter(g=>g.length>=2).map(group=>{
          const sizes=group.map(e=>e.font).sort((a,b)=>a-b);
          // Even cohorts must not let the roomier half dictate every caption.
          // Both central observations contribute, retaining the source-derived
          // readability recovery below for tightly packed dialogue.
          const middle=Math.floor(sizes.length/2);
          const median=(sizes[middle]+sizes[Math.floor((sizes.length-1)/2)])/2;
          const sourceSizes=group.map(e=>e.source).sort((a,b)=>a-b);
          const readable=Math.min(sourceSizes[Math.floor(sourceSizes.length/2)]*.9,median*1.15,10.5);
          return {members:group,font:Math.round(Math.max(median,readable)*4)/4};
        });
    };
    // One target per clustered caption. Kept source lettering (entries with
    // the same fields, font = the size a caption of its source would take)
    // joins the clusters too, so keeping a watermark or logo does not re-form
    // the clusters of other captions; it only ever raises the target of a
    // caption `raisable` accepts, never lowers one, and receives none itself.
    // Without kept lettering the targets are exactly aidokuFontClusters'.
    const aidokuFontClusterTargets = (entries, kept = [], raisable = () => true) => {
      const targets=new Map();
      for(const group of aidokuFontClusters(entries))for(const entry of group.members)targets.set(entry,group.font);
      if(!Array.isArray(kept)||!kept.length)return targets;
      for(const group of aidokuFontClusters([...entries,...kept.map(k=>({...k,kept:true}))])){
        if(!group.members.some(entry=>entry.kept))continue;
        for(const entry of group.members){
          if(entry.kept||!raisable(entry))continue;
          const own=targets.get(entry);
          if(own===undefined?group.font>entry.font:group.font>own)targets.set(entry,group.font);
        }
      }
      return targets;
    };
    // Same-row and same-column captions: source boxes of one lettering style
    // (script, orientation, style key, glyph size within 1.25x) that sit side by side on a
    // shared line, or stack on a shared column edge with a small gap. Groups
    // never span more than 1.3x in glyph size. Links record the axis they
    // share ('y': one line, 'x': one column) and the aligned edge (0 start,
    // .5 centre, 1 end), or edge null when only the size is shared.
    const aidokuAlignedGroups = boxes => {
      if(!Array.isArray(boxes)||boxes.length<2||boxes.length>256)return [];
      const valid=b=>b&&[b.x,b.y,b.w,b.h,b.glyph].every(Number.isFinite)&&b.w>0&&b.h>0&&b.glyph>0;
      const parent=boxes.map((_,i)=>i),low=boxes.map(b=>b?.glyph),high=boxes.map(b=>b?.glyph),links=[];
      const find=i=>parent[i]===i?i:(parent[i]=find(parent[i]));
      const edge=(a,b,axis,tolerance)=>{
        const [p,s]=axis==='x'?['x','w']:['y','h'];
        const best=[.5,0,1].map(e=>[Math.abs(a[p]+e*a[s]-b[p]-e*b[s]),e]).sort((u,v)=>u[0]-v[0])[0];
        return best[0]<=tolerance?best[1]:null;
      };
      for(let i=0;i<boxes.length;i++)for(let j=i+1;j<boxes.length;j++){
        const a=boxes[i],b=boxes[j];
        if(!valid(a)||!valid(b)||a.script!==b.script||Boolean(a.vertical)!==Boolean(b.vertical)||(a.style||'')!==(b.style||''))continue;
        const small=Math.min(a.glyph,b.glyph),large=Math.max(a.glyph,b.glyph);
        if(large/small>1.25)continue;
        const xOverlap=Math.min(a.x+a.w,b.x+b.w)-Math.max(a.x,b.x),yOverlap=Math.min(a.y+a.h,b.y+b.h)-Math.max(a.y,b.y);
        const tolerance=Math.max(2,small*.25);
        let link=null;
        const nested=Math.max(0,xOverlap)*Math.max(0,yOverlap)>=.5*Math.min(a.w*a.h,b.w*b.h);
        // An OCR fragment inside or across another box of the same style is
        // a split line of one sentence: it shares the size only.
        if(nested)link={axis:a.vertical?'x':'y',edge:null,gap:0};
        else if(!a.vertical){
          if(yOverlap>=.6*Math.min(a.h,b.h)&&-xOverlap>=-.25*small&&-xOverlap<=6*large)
            link={axis:'y',edge:edge(a,b,'y',tolerance),gap:-xOverlap};
          else if(xOverlap>=.5*Math.min(a.w,b.w)&&-yOverlap>=-.25*small&&-yOverlap<=2*large){
            const e=edge(a,b,'x',tolerance);if(e!==null)link={axis:'x',edge:e,gap:-yOverlap};
          }
        } else if(xOverlap>=.6*Math.min(a.w,b.w)&&-yOverlap>=-.25*small&&-yOverlap<=3*large)
          link={axis:'x',edge:edge(a,b,'x',tolerance)===.5?.5:null,gap:-yOverlap};
        else if(yOverlap>=.5*Math.min(a.h,b.h)&&-xOverlap>=-.25*small&&-xOverlap<=2*large&&edge(a,b,'y',tolerance)!==null)
          link={axis:'y',edge:null,gap:-xOverlap};
        if(link)links.push({a:i,b:j,...link});
      }
      links.sort((u,v)=>u.gap-v.gap||u.a-v.a||u.b-v.b);
      for(const link of links){
        const ra=find(link.a),rb=find(link.b);
        if(ra===rb)continue;
        const lo=Math.min(low[ra],low[rb]),hi=Math.max(high[ra],high[rb]);
        if(hi/lo>1.3)continue;
        parent[rb]=ra;low[ra]=lo;high[ra]=hi;
      }
      const groups=new Map();
      for(let i=0;i<boxes.length;i++){
        if(!valid(boxes[i]))continue;
        const r=find(i);if(!groups.has(r))groups.set(r,{members:[],links:[]});
        groups.get(r).members.push(i);
      }
      for(const link of links){const r=find(link.a);if(r===find(link.b))groups.get(r).links.push(link);}
      return [...groups.values()].filter(g=>g.members.length>=2);
    };
    // Side-by-side vertical source columns (neighbouring balloons, or column
    // blocks of one balloon) that share a top, centre or bottom line. Set as
    // horizontal Korean blocks, they keep that line. Same script and style,
    // glyphs within 1.25x, heights overlapping by half, a gap of at most three
    // glyphs, the edge aligned within max(2, 0.25 glyph); the top wins a tie
    // (a vertical column starts at its top). Links carry the shared edge
    // (0 top, .5 centre, 1 bottom) and the gap.
    const aidokuColumnRowLinks = boxes => {
      if(!Array.isArray(boxes)||boxes.length<2||boxes.length>256)return [];
      const valid=b=>b&&b.vertical&&[b.x,b.y,b.w,b.h,b.glyph].every(Number.isFinite)&&b.w>0&&b.h>0&&b.glyph>0;
      const links=[];
      for(let i=0;i<boxes.length;i++)for(let j=i+1;j<boxes.length;j++){
        const a=boxes[i],b=boxes[j];
        if(!valid(a)||!valid(b)||a.script!==b.script||(a.style||'')!==(b.style||''))continue;
        const small=Math.min(a.glyph,b.glyph),large=Math.max(a.glyph,b.glyph);
        if(large/small>1.25)continue;
        const xOverlap=Math.min(a.x+a.w,b.x+b.w)-Math.max(a.x,b.x),yOverlap=Math.min(a.y+a.h,b.y+b.h)-Math.max(a.y,b.y);
        if(yOverlap<.5*Math.min(a.h,b.h)||-xOverlap<-.25*small||-xOverlap>3*large)continue;
        if(Math.max(0,xOverlap)*yOverlap>=.5*Math.min(a.w*a.h,b.w*b.h))continue;
        const best=[0,.5,1].map(e=>[Math.abs(a.y+e*a.h-b.y-e*b.h),e]).sort((u,v)=>u[0]-v[0])[0];
        if(best[0]<=Math.max(2,small*.25))links.push({a:i,b:j,axis:'y',edge:best[1],gap:-xOverlap});
      }
      return links;
    };
    // Colour class of a sampled source colour for page style keys: a hue
    // sector for chromatic colours, otherwise dark, mid or light.
    const aidokuStyleColorClass = rgb => {
      if(!Array.isArray(rgb)||rgb.length<3||!rgb.slice(0,3).every(v=>Number.isFinite(v)&&v>=0&&v<=255))return '?';
      const [r,g,b]=rgb.slice(0,3).map(v=>v/255),max=Math.max(r,g,b),min=Math.min(r,g,b);
      if((max-min)*255>60){
        const h=max===r?((g-b)/(max-min)+6)%6:max===g?(b-r)/(max-min)+2:(r-g)/(max-min)+4;
        return 'h'+Math.floor(((h*60+30)%360)/60);
      }
      const l=.299*r+.587*g+.114*b;
      return l<.3?'dark':l>.72?'light':'mid';
    };
    // Page lettering styles: captions with one style key (orientation and
    // colour classes) whose source glyphs are all within 15% of each other.
    // Complete-link, so a chain of sizes never merges two styles. The target
    // is the typical size of the members that fit well: the lower median of
    // the larger half of the sizes (one roomy outlier never sets it).
    const aidokuPageStyleGroups = (records, tolerance = 1.15) => {
      if(!Array.isArray(records)||records.length>256)return [];
      return aidokuStyleGroups(records.map((r,index)=>({...r,index})).filter(r=>Number.isFinite(r.glyph)&&r.glyph>0&&
          Number.isFinite(r.font)&&r.font>0&&typeof r.key==='string'),
        (a,b)=>a.key===b.key&&Math.max(a.glyph,b.glyph)/Math.min(a.glyph,b.glyph)<=tolerance,
        (a,b)=>a.key.localeCompare(b.key)||a.glyph-b.glyph||a.index-b.index)
        .filter(g=>g.length>=2).map(group=>{
          const fonts=group.map(r=>r.font).sort((a,b)=>a-b),upper=fonts.slice(Math.floor(fonts.length/2));
          return {members:group.map(r=>r.index),font:upper[Math.floor((upper.length-1)/2)]};
        });
    };
    const aidokuInkLab = rgb => {
      const [r,g,b]=rgb.map(v=>v/255).map(v=>v<=.04045?v/12.92:Math.pow((v+.055)/1.055,2.4));
      const l=Math.cbrt(.4122214708*r+.5363325363*g+.0514459929*b);
      const m=Math.cbrt(.2119034982*r+.6806995451*g+.1073969566*b);
      const s=Math.cbrt(.0883024619*r+.2817188376*g+.6299787005*b);
      return [.2104542553*l+.793617785*m-.0040720468*s,
        1.9779984951*l-2.428592205*m+.4505937099*s,
        .0259040371*l+.7827717662*m-.808675766*s];
    };
    const aidokuInkClusters = entries => {
      if(entries.length>256)return [];
      const valid=entries.filter(e=>e.confidence>=.5&&Array.isArray(e.rgb)&&e.rgb.length===3&&
        e.rgb.every(v=>Number.isFinite(v)&&v>=0&&v<=255))
        .map(e=>({...e,lab:aidokuInkLab(e.rgb),chroma:Math.max(...e.rgb)-Math.min(...e.rgb)}));
      const distance=(a,b)=>Math.hypot(...a.lab.map((v,i)=>v-b.lab[i]));
      return aidokuStyleGroups(valid,(a,b)=>(a.chroma<24)===(b.chroma<24)&&
        Math.max(...a.rgb.map((v,i)=>Math.abs(v-b.rgb[i])))<=20&&distance(a,b)<=.035,
        (a,b)=>a.rgb[0]-b.rgb[0]||a.rgb[1]-b.rgb[1]||a.rgb[2]-b.rgb[2]||String(a.id).localeCompare(String(b.id)))
        .filter(g=>g.length>=2).map(group=>{
          // Choose an observed medoid, never an average of different ink colors.
          let representative=group[0],score=Infinity;
          for(const candidate of group){
            const cost=group.reduce((n,e)=>n+distance(candidate,e)*e.confidence,0);
            if(cost<score){score=cost;representative=candidate;}
          }
          return {members:group,rgb:representative.rgb};
        });
    };
    const aidokuKoreanFragments = (text, breaks) => {
      let count=0;
      for(const match of text.matchAll(/[\p{Script=Hangul}]+/gu)){
        const start=match.index,end=start+match[0].length;
        const cuts=breaks.filter(p=>p>start&&p<end).sort((a,b)=>a-b);
        if(!cuts.length)continue;
        const boundaries=[start,...new Set(cuts),end];
        for(let i=1;i<boundaries.length;i++)if(boundaries[i]-boundaries[i-1]===1)count++;
      }
      return count;
    };
    // A break inside a Korean word is mild when the second half is only
    // particles or a copula form after a noun of two or more syllables
    // (경찰관 / 이라니, 천수각 / 에서의): readers still see two units. It is bad
    // inside a stem or an ending (습 / 니다, 여유 / 로운, 당연하 / 잖아). Bare
    // endings (라고, 니까, 잖아) follow verb stems too and count as bad; a stem
    // ending in 하/되/으/시 is a verb or connective.
    const aidokuMildBreakParticles = ('이 가 은 는 을 를 의 에 에서 에게 에게서 께 께서 한테 한테서 으로 로 으로서 로서 으로써 로써 '+
      '와 과 랑 이랑 하고 도 만 까지 부터 마저 조차 밖에 처럼 보다 같이 이나 이든 이든지 이라도 들 님 씨 이야 이다 이에요 입니다 '+
      '이죠 이지 이고 이며 인데 인가 인지 이라 이라는 이라고 이라니 이란 이니까 이잖아 이었 이었다 이었어 였다 였어 이네 이군 이구나 이래')
      .split(' ').sort((a,b)=>b.length-a.length);
    const aidokuBadBreak = (text, offset) => {
      const t=String(text||''),hangul=c=>/^[가-힣]$/u.test(c||'');
      if(!(offset>0)||!hangul(t[offset-1])||!hangul(t[offset]))return false;
      let start=offset;while(start>0&&hangul(t[start-1]))start--;
      const prefix=t.slice(start,offset);
      let end=offset;while(end<t.length&&!/\s/u.test(t[end]))end++;
      let rest=t.slice(offset,end);
      if(prefix.length<2||'하되으시해돼게지'.includes(prefix[prefix.length-1])||/^(가는|가고|에이|이는|는데|가지)/u.test(rest))return true;
      let matched=false;
      while(rest&&hangul(rest[0])){
        const particle=aidokuMildBreakParticles.find(p=>rest.startsWith(p));
        if(!particle)return true;
        rest=rest.slice(particle.length);matched=true;
      }
      return !matched||hangul(rest[0])||/[\p{L}\p{N}]/u.test(rest);
    };
    // A caption that is only one reduplicated exclamation, scream or mimetic
    // word (아아아아, 으아아아악!, 두근두근) may break between repeats of its
    // unit (아아|아아, 두근|두근): the lines follow a stacked source run and the
    // break is not a split word. A one-syllable unit needs three repeats around
    // the break and two syllables on each side, so no syllable is stranded.
    // Inside a sentence the run stays one word.
    const aidokuReduplicationBreak = (text, offset) => {
      if(!text||!(offset>1)||offset>=text.length)return false;
      if((String(text).match(/\p{Script=Hangul}+/gu)||[]).length!==1||/[\p{L}\p{N}]/u.test(String(text).replace(/\p{Script=Hangul}/gu,'')))
        return false;
      const hangul=c=>Boolean(c)&&/^\p{Script=Hangul}$/u.test(c);
      const at=i=>text[i];
      if(at(offset-1)===at(offset)&&hangul(at(offset))&&hangul(at(offset-2))&&hangul(at(offset+1))&&
          (at(offset-2)===at(offset)||at(offset+1)===at(offset)))return true;
      for(let unit=2;unit<=3;unit++){
        if(offset<unit||offset+unit>text.length)continue;
        const token=text.slice(offset,offset+unit);
        if(Array.from(token).every(hangul)&&text.slice(offset-unit,offset)===token)return true;
      }
      return false;
    };
    // Interface rows (game or visual-novel button bars, menus, credit rows)
    // in the top or bottom band of the page: at least three one-line
    // captions of short words on one line, or one widely spaced line of four
    // or more short labels. They keep the interface's scale; returns member index groups.
    const aidokuInterfaceRows = (boxes, frame) => {
      if(!Array.isArray(boxes)||boxes.length>256||!Array.isArray(frame)||frame.length!==4||
          !frame.every(Number.isFinite)||!(frame[3]>0))return [];
      const top=frame[1],height=frame[3];
      const words=t=>String(t||'').split(/[\s,，、·・|/]+/u).filter(Boolean);
      const label=b=>b&&!b.vertical&&[b.x,b.y,b.w,b.h,b.glyph].every(Number.isFinite)&&b.w>0&&b.h>0&&b.glyph>0&&
        b.glyph<=height*.06&&b.h<=b.glyph*2.2&&!/[.!?。！？…‥~～]["'」』）)]*$/u.test(String(b.text||'').trim())&&
        (y=>y>=top+height*.82||y<=top+height*.12)(b.y+b.h/2);
      const short=b=>{const w=words(b.text);return w.length>=1&&w.every(v=>Array.from(v).length<=6);};
      const letters=b=>Array.from(String(b.text||'').replace(/[\s,，、·・|/]+/gu,'')).length;
      const rows=[];
      boxes.forEach((b,i)=>{
        if(!label(b))return;
        const w=words(b.text);
        if(w.length>=4&&w.every(v=>Array.from(v).length<=4)&&b.w>=1.2*b.glyph*letters(b))rows.push([i]);
      });
      const candidates=boxes.map((b,i)=>label(b)&&short(b)?i:-1).filter(i=>i>=0).sort((i,j)=>boxes[i].x-boxes[j].x);
      const parent=new Map(candidates.map(i=>[i,i]));
      const find=i=>parent.get(i)===i?i:find(parent.get(i));
      for(let p=0;p<candidates.length;p++)for(let q=p+1;q<candidates.length;q++){
        const a=boxes[candidates[p]],b=boxes[candidates[q]],large=Math.max(a.glyph,b.glyph);
        if(large/Math.min(a.glyph,b.glyph)>1.4||Math.abs(a.y+a.h/2-b.y-b.h/2)>.6*large)continue;
        const gap=Math.max(a.x,b.x)-Math.min(a.x+a.w,b.x+b.w);
        if(gap>8*large)continue;
        parent.set(find(candidates[q]),find(candidates[p]));
      }
      const groups=new Map();
      for(const i of candidates){const r=find(i);if(!groups.has(r))groups.set(r,[]);groups.get(r).push(i);}
      for(const group of groups.values())if(group.length>=3)rows.push(group.sort((i,j)=>i-j));
      return rows;
    };
    const aidokuCaptionInkFrame = (ink, font) => ink?.length ? {
      left:Math.min(...ink.map(r=>r[0])),top:Math.min(...ink.map(r=>r[1])),
      right:Math.max(...ink.map(r=>r[0]+r[2])),bottom:Math.max(...ink.map(r=>r[1]+r[3])),
      pad:Math.max(3,Math.min(6,font*.3))
    } : null;
    const aidokuCohortFontCandidates = (original, target, minimum) => {
      if(![original,target,minimum].every(Number.isFinite)||original<=0)return [];
      const desired=Math.round(Math.max(original*.75,Math.min(original,7.5),Math.min(target,original+3))*4)/4;
      if(desired<minimum||Math.abs(desired-original)<.01)return [];
      if(desired<original){
        // A smaller target can create a different bad line ending. Recover
        // toward the old size instead of abandoning the entire cohort.
        const sizes=[];
        for(let size=desired;size<original&&sizes.length<13;size+=.25)sizes.push(size);
        return sizes;
      }
      // Search the entire bounded recovery interval. Five probes near the
      // target can miss a readable intermediate size and leave an outlier tiny.
      const sizes=[];
      for(let size=desired;size>original&&size>=minimum&&sizes.length<13;size-=.25)sizes.push(size);
      return sizes;
    };
    const aidokuFontFlowFits = (candidate, baseline, extraWordBreaks=0) =>
      Boolean(candidate&&baseline&&candidate.breaks.length<=baseline.breaks.length+extraWordBreaks&&
        candidate.badStarts.length<=baseline.badStarts.length&&candidate.badEnds.length<=baseline.badEnds.length&&
        candidate.hangulFragments<=baseline.hangulFragments&&candidate.punctuationOnly<=baseline.punctuationOnly);
    const aidokuKoreanWrapImproves = (candidate, baseline) => {
      if(!candidate||!baseline||candidate.lines>baseline.lines)return false;
      const counts=p=>[p.breaks.length,p.hangulFragments,p.punctuationOnly,p.badStarts.length,p.badEnds.length];
      const next=counts(candidate),previous=counts(baseline);
      // Fixing one orphan is not an improvement if intact neighboring words
      // must be split to make room (expanded-comic-5054).
      return next.every((v,i)=>v<=previous[i])&&next.some((v,i)=>v<previous[i]);
    };
    // Fixed-font Korean line breaking for narrow columns. Preserve the exact
    // text; penalize splitting an eojeol and especially stranding one syllable.
    // The longest strings/explicit newlines retain WebKit's regular wrapping.
    // `quotes` (1 or 2): curly quotes and straight quotes (closing after ink,
    // else opening) follow the same rule as brackets: none closes a line start
    // or opens a line end. 2 also keeps dependent nouns with their modifier.
    // `unit` ({advance, tracking}): a line's width is the sum of its code
    // points' advances plus tracking per gap (prefix sums; no string measures).
    const aidokuKoreanLines = (text, width, maxLines, measure, quotes = false, unit = null) => {
      if(!text||text.length>180||/[\r\n]/u.test(text)||width<=0||maxLines<1)return null;
      const chars=Array.from(text),n=chars.length;
      const opening=quotes?/^[（(\[「『【《〈“‘]$/u:/^[（(\[「『【《〈]$/u;
      const closing=quotes?/^[、。，．,.！？!?…‥）)\]」』】》〉:;”’]$/u:/^[、。，．,.！？!?…‥）)\]」』】》〉:;]$/u;
      const hangul=c=>c&&/^[\p{Script=Hangul}]$/u.test(c);
      const whitespace=c=>!c||/\s/u.test(c);
      // Per code point: its offset in `text`, its classes, the nearest
      // whitespace on either side and prefix counts, so each candidate line
      // (the trimmed text between two breaks) needs no string rebuilding.
      const offsets=new Int32Array(n+1),space=new Uint8Array(n),korean=new Uint8Array(n);
      const opens=new Uint8Array(n),closes=new Uint8Array(n),koreanBefore=new Int32Array(n+1),letterBefore=new Int32Array(n+1);
      const nextSpace=new Int32Array(n+1),previousSpace=new Int32Array(n),previousInk=new Int32Array(n);
      (()=>{for(let i=0;i<n;i++){
        const c=chars[i];offsets[i+1]=offsets[i]+c.length;
        space[i]=whitespace(c)?1:0;korean[i]=hangul(c)?1:0;opens[i]=opening.test(c)?1:0;closes[i]=closing.test(c)?1:0;
        if(quotes&&(c==='"'||c==="'")){
          const after=i>0&&!whitespace(chars[i-1])&&!opening.test(chars[i-1]);
          closes[i]=after?1:0;opens[i]=after?0:1;
        }
        koreanBefore[i+1]=koreanBefore[i]+korean[i];letterBefore[i+1]=letterBefore[i]+(/[\p{L}\p{N}]/u.test(c)?1:0);
        previousSpace[i]=space[i]?i:i?previousSpace[i-1]:-1;previousInk[i]=space[i]?(i?previousInk[i-1]:-1):i;
      }})();
      nextSpace[n]=n;
      (()=>{for(let i=n-1;i>=0;i--)nextSpace[i]=space[i]?i:nextSpace[i+1];})();
      const advanceBefore=unit?new Float64Array(n+1):null;
      if(unit)(()=>{for(let i=0;i<n;i++)advanceBefore[i+1]=advanceBefore[i]+unit.advance(chars[i]);})();
      // `quotes` 2 layouts also keep a dependent noun on the line of the
      // modifier it completes (만드는 게, 있을 때, 할 수): a line starting with
      // one after a word ending in ㄴ/ㄹ costs as much as a short line.
      const dependent=new Uint8Array(n);
      if(quotes===2)(()=>{for(let i=1;i<n;i++){
        if(space[i]||!space[i-1]||previousInk[i-1]<0)continue;
        const word=text.slice(offsets[i],offsets[nextSpace[i]]).replace(/[\p{P}\p{S}]+$/u,'');
        const tail=chars[previousInk[i-1]].codePointAt(0)-0xAC00;
        if(tail>=0&&tail<11172&&(tail%28===4||tail%28===8)&&/^(것|거|게|걸|건|수|줄|때|데|뿐|듯|적|척|만큼|대로|중|채|김|바|법|리)$/u.test(word))
          dependent[i]=1;
      }})();
      // Keep a solution for each line count. A cheap suffix using more lines
      // must not discard the tighter suffix needed to fit the whole caption.
      const limit=Math.min(n,Math.floor(maxLines));
      const dp=Array.from({length:limit+1},()=>new Float64Array(n+1).fill(Infinity));
      const next=Array.from({length:limit+1},()=>new Int32Array(n+1).fill(-1));
      dp[0][n]=0;
      (()=>{for(let start=n-1;start>=0;start--){
        // The line text is chars[first..last] (whitespace trimmed).
        let first=start;
        while(first<n&&space[first])first++;
        for(let end=start+1;end<=n;end++){
          if(end<n&&space[end])continue;
          const last=previousInk[end-1];
          if(last<first)continue;
          const used=unit?advanceBefore[last+1]-advanceBefore[first]+(last-first)*unit.tracking:
            measure(text.slice(offsets[first],offsets[last+1]));
          if(used>width+.1)break;
          // Ellipses already at the start of the dialogue are intentional.
          // Only newly created line starts must reject closing punctuation;
          // keep a leading ellipsis attached to some dialogue on its first line.
          if((closes[first]&&(start>0||letterBefore[last+1]===letterBefore[first]))||opens[last])continue;
          const split=end<n&&!space[end-1]&&!space[end];
          // Count orphaned word fragments even when another word shares the
          // line ("는 거야"). Genuine one-syllable words such as "왜" are fine.
          const firstWord=koreanBefore[Math.min(nextSpace[first],last+1)]-koreanBefore[first];
          const lastWord=koreanBefore[last+1]-koreanBefore[Math.max(previousSpace[last]+1,first)];
          const fragment=(firstWord===1&&start>0&&korean[start-1]&&korean[first])||
            (lastWord===1&&split&&korean[last]&&korean[end]);
          const cost=12+(split?36:0)+(fragment?90:0)+(start>0&&dependent[first]?24:0)+
            Math.pow(1-used/width,2)*(end===n?5:16);
          // The suffix has at most n-end nonempty lines; larger states are
          // unreachable. Avoid visiting them for every candidate break.
          for(let lines=1;lines<=Math.min(limit,n-end+1);lines++){
            const total=cost+dp[lines-1][end];
            if(total<dp[lines][start]){dp[lines][start]=total;next[lines][start]=end;}
          }
        }
      }})();
      let remaining=1;
      (()=>{for(let lines=2;lines<=limit;lines++)if(dp[lines][0]<dp[remaining][0])remaining=lines;})();
      if(next[remaining][0]<0)return null;
      const lines=[];
      (()=>{for(let i=0;i<n;remaining--){
        const end=next[remaining][i];lines.push(text.slice(offsets[i],offsets[end]));i=end;
      }})();
      return lines;
    };
    """#
}
