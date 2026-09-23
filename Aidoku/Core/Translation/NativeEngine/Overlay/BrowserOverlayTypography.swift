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

    static let script = #"""
    // Artwork protection may give up at most one fifth of the current type
    // size. Already-small captions never subsidize a smaller background.
    const aidokuArtworkFontSizes = font => {
      if(!Number.isFinite(font)||font<=8.5)return [];
      const floor=Math.max(8.5,Math.ceil(font*.8*4)/4);
      return [...new Set([.95,.9,.85,.8].map(scale=>Math.max(floor,Math.floor(font*scale*4)/4)))]
        .filter(size=>size<font);
    };
    // Only a verified balloon fit may trade up to 15% for restoring its outline.
    // Already-small captions keep their font; their wrapping may still improve.
    const aidokuBalloonFontSizes = font => {
      if(!Number.isFinite(font)||font<7.5)return [];
      const floor=Math.max(7.5,Math.ceil(font*.85*4)/4),sizes=[font];
      for(let size=Math.floor((font-.25)*4)/4;size>=floor&&sizes.length<9;size-=.25)sizes.push(size);
      return sizes;
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
      return {frame:[l,t,right-l,bottom-t],coverage};
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
    const aidokuSourceAnchorShift = (ink, source, plate, obstacles) => {
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
        const swept=[Math.min(ink[0],moved[0]),Math.min(ink[1],moved[1]),
          ink[2]+Math.abs(x),ink[3]+Math.abs(y)];
        if(!inside(moved)||obstacles.some(o=>overlap(swept,o)>overlap(ink,o)+tolerance))continue;
        const score=distance(x,y);
        if(score<bestDistance-.0001){best={dx:x,dy:y};bestDistance=score;}
      }
      return best;
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
      return aidokuStyleGroups(entries.filter(e=>Number.isFinite(e.source)&&e.source>0&&e.font>=5),
        (a,b)=>a.script===b.script&&a.vertical===b.vertical&&a.column===b.column&&
          Math.max(a.source,b.source)/Math.min(a.source,b.source)<=1.22,
        (a,b)=>a.source-b.source||a.font-b.font||String(a.id).localeCompare(String(b.id)))
        .filter(g=>g.length>=2).map(group=>{
          const sizes=group.map(e=>e.font).sort((a,b)=>a-b);
          const median=sizes[Math.floor(sizes.length/2)];
          const sourceSizes=group.map(e=>e.source).sort((a,b)=>a-b);
          const readable=Math.min(sourceSizes[Math.floor(sourceSizes.length/2)]*.9,median*1.15,10.5);
          return {members:group,font:Math.round(Math.max(median,readable)*4)/4};
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
    const aidokuCaptionInkFrame = (ink, font) => ink?.length ? {
      left:Math.min(...ink.map(r=>r[0])),top:Math.min(...ink.map(r=>r[1])),
      right:Math.max(...ink.map(r=>r[0]+r[2])),bottom:Math.max(...ink.map(r=>r[1]+r[3])),
      pad:Math.max(3,Math.min(6,font*.3))
    } : null;
    const aidokuCohortFontCandidates = (original, target, minimum) => {
      if(![original,target,minimum].every(Number.isFinite)||original<=0)return [];
      const desired=Math.round(Math.max(original*.75,Math.min(target,original+3))*4)/4;
      if(desired<minimum||Math.abs(desired-original)<.01)return [];
      if(desired<original)return [desired];
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
    const aidokuKoreanLines = (text, width, maxLines, measure) => {
      if(!text||text.length>180||/[\r\n]/u.test(text)||width<=0||maxLines<1)return null;
      const chars=Array.from(text),n=chars.length;
      const opening=/^[（(\[「『【《〈]$/u,closing=/^[、。，．,.！？!?…‥）)\]」』】》〉:;]$/u;
      const hangul=c=>c&&/^[\p{Script=Hangul}]$/u.test(c);
      const whitespace=c=>!c||/\s/u.test(c);
      // Keep a solution for each line count. A cheap suffix using more lines
      // must not discard the tighter suffix needed to fit the whole caption.
      const limit=Math.min(n,Math.floor(maxLines));
      const dp=Array.from({length:limit+1},()=>Array(n+1).fill(Infinity));
      const next=Array.from({length:limit+1},()=>Array(n+1).fill(-1));
      dp[0][n]=0;
      for(let start=n-1;start>=0;start--){
        for(let end=start+1;end<=n;end++){
          if(end<n&&whitespace(chars[end]))continue;
          const part=chars.slice(start,end).join('').trim();
          if(!part)continue;
          const used=measure(part);
          if(used>width+.1)break;
          const visible=Array.from(part),first=visible[0],last=visible[visible.length-1];
          // Ellipses already at the start of the dialogue are intentional.
          // Only newly created line starts must reject closing punctuation;
          // keep a leading ellipsis attached to some dialogue on its first line.
          if((closing.test(first)&&(start>0||!/[\p{L}\p{N}]/u.test(part)))||opening.test(last))continue;
          const split=end<n&&!whitespace(chars[end-1])&&!whitespace(chars[end]);
          // Count orphaned word fragments even when another word shares the
          // line ("는 거야"). Genuine one-syllable words such as "왜" are fine.
          const firstWord=Array.from(part.split(/\s+/u)[0]).filter(hangul).length;
          const lastWord=Array.from(part.split(/\s+/u).at(-1)).filter(hangul).length;
          const fragment=(firstWord===1&&start>0&&hangul(chars[start-1])&&hangul(first))||
            (lastWord===1&&split&&hangul(last)&&hangul(chars[end]));
          const cost=12+(split?36:0)+(fragment?90:0)+
            Math.pow(1-used/width,2)*(end===n?5:16);
          for(let lines=1;lines<=Math.min(limit,n-start);lines++){
            const total=cost+dp[lines-1][end];
            if(total<dp[lines][start]){dp[lines][start]=total;next[lines][start]=end;}
          }
        }
      }
      let remaining=1;
      for(let lines=2;lines<=limit;lines++)if(dp[lines][0]<dp[remaining][0])remaining=lines;
      if(next[remaining][0]<0)return null;
      const lines=[];
      for(let i=0;i<n;remaining--){
        const end=next[remaining][i];lines.push(chars.slice(i,end).join(''));i=end;
      }
      return lines;
    };
    """#
}
