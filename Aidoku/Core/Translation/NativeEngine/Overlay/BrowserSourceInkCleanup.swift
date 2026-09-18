import Foundation

// Conservative source-pixel cleanup. Integration owns source coordinates, image
// decoding, page budgets and opacity; this helper never invents background art.
enum BrowserSourceInkCleanup {
    // Matches the frozen cleanup applicability gate after Unicode NFKC normalization.
    // This authorizes pixel inspection only; it never filters OCR or translated dialogue.
    private static let coloredCleanupLetters = try? NSRegularExpression(
        pattern: #"[\p{script=Han}\p{script=Hiragana}\p{script=Katakana}\p{script=Hangul}A-Za-z]"#
    )

    static func hasColoredCleanupText(_ source: String) -> Bool {
        guard !source.isEmpty, let expression = coloredCleanupLetters else { return false }
        let normalized = source.precomposedStringWithCompatibilityMapping as NSString
        var cjkCount = 0
        var latinCount = 0
        var firstLetter: String?
        var hasDistinctLetters = false
        var eligible = false
        expression.enumerateMatches(
            in: normalized as String, range: NSRange(location: 0, length: normalized.length)
        ) { match, _, stop in
            guard let match else { return }
            var letter = normalized.substring(with: match.range)
            let scalar = normalized.character(at: match.range.location)
            if (65...90).contains(scalar) || (97...122).contains(scalar) {
                latinCount += 1
                letter = letter.lowercased()
            } else {
                cjkCount += 1
            }
            if let firstLetter {
                if firstLetter != letter { hasDistinctLetters = true }
            } else {
                firstLetter = letter
            }
            if hasDistinctLetters && (cjkCount >= 3 || latinCount >= 4) {
                eligible = true
                stop.pointee = true
            }
        }
        return eligible
    }

    static let script = """
    const aidokuSourceInkMask = (rgba, width, height, vertical) => {
      // Input includes an unscaled two-pixel margin on every side.
      // Orientation is reserved; this version applies identical gates to both.
      if (!Number.isInteger(width) || !Number.isInteger(height) ||
          width < 14 || height < 14 || width * height > 262144 ||
          !rgba || rgba.length !== width * height * 4) return null;
      const count = width * height;
      const coreWidth = width - 5, coreHeight = height - 5;
      let whiteCount = 0, coloredCount = 0, insideCount = 0, rimWhite = 0, rimTotal = 0;
      for (let y = 0; y < height; y++) {
        for (let x = 0; x < width; x++) {
          const p = (y * width + x) * 4;
          const low = Math.min(rgba[p], rgba[p + 1], rgba[p + 2]);
          const high = Math.max(rgba[p], rgba[p + 1], rgba[p + 2]);
          const white = low >= 245 && high - low <= 10;
          // Transparent pixels are unknown, never assumed white.
          if (rgba[p + 3] !== 255) return null;
          if (x < 2 || y < 2 || x >= width - 2 || y >= height - 2) {
            rimTotal++; if (white) rimWhite++;
            // Keep border-connected components intact below without rejecting
            // unrelated interior lettering because a frame enters this margin.
          } else {
            insideCount++;
            if (white) whiteCount++;
            if (high - low > 20) coloredCount++;
          }
        }
      }
      const denseRecovery = whiteCount / insideCount < 0.75;
      if (coloredCount / insideCount > 0.02 || (denseRecovery && rimWhite / rimTotal < 0.98)) return null;
      const dark = new Uint8Array(count);
      for (let y = 2; y < height - 2; y++) {
        for (let x = 2; x < width - 2; x++) {
          const i = y * width + x, p = i * 4;
          const lo = Math.min(rgba[p], rgba[p + 1], rgba[p + 2]);
          const hi = Math.max(rgba[p], rgba[p + 1], rgba[p + 2]);
          if (hi <= 180 && hi - lo <= 20) dark[i] = 1;
        }
      }
      const seen = new Uint8Array(count), mask = new Uint8Array(count);
      const queue = new Int32Array(count);
      let kept = 0, shapedComponents = 0;
      for (let seed = 0; seed < count; seed++) {
        if (!dark[seed] || seen[seed]) continue;
        let head = 0, tail = 1, touchesBoundary = false;
        queue[0] = seed; seen[seed] = 1;
        let minX = width, minY = height, maxX = 0, maxY = 0;
        while (head < tail) {
          const i = queue[head++], y = Math.floor(i / width), x = i % width;
          minX = Math.min(minX, x); maxX = Math.max(maxX, x);
          minY = Math.min(minY, y); maxY = Math.max(maxY, y);
          for (let dy = -1; dy <= 1; dy++) {
            for (let dx = -1; dx <= 1; dx++) {
              const nx = x + dx, ny = y + dy;
              if (nx < 2 || ny < 2 || nx >= width - 2 || ny >= height - 2) {
                touchesBoundary = true; continue;
              }
              const next = ny * width + nx;
              if (dark[next] && !seen[next]) {
                seen[next] = 1; queue[tail++] = next;
              }
            }
          }
        }
        const cw = maxX - minX + 1, ch = maxY - minY + 1;
        if (touchesBoundary || tail < 2 || tail > 0.25 * coreWidth * coreHeight ||
            cw > 0.8 * coreWidth || ch > 0.8 * coreHeight ||
            Math.max(cw, ch) > 8 * Math.min(cw, ch)) continue;
        for (let j = 0; j < tail; j++) mask[queue[j]] = 255;
        kept += tail;
        if (cw >= 3 && ch >= 3 && tail >= 6 && tail / (cw * ch) < 0.85) shapedComponents++;
      }
      if (!kept) return null;
      // Remove only the neutral one-pixel antialias fringe adjoining accepted
      // source ink. Read the original mask so the fringe cannot grow recursively.
      // Crop acceptance and the border/drawing component gates stay unchanged.
      const cleaned = mask.slice();
      for (let y = 3; y < height - 3; y++) {
        for (let x = 3; x < width - 3; x++) {
          const i = y * width + x, p = i * 4;
          if (mask[i]) continue;
          const low = Math.min(rgba[p], rgba[p + 1], rgba[p + 2]);
          const high = Math.max(rgba[p], rgba[p + 1], rgba[p + 2]);
          if (low <= 180 || high >= 245 || high - low > 10) continue;
          let adjacent = false;
          for (let dy = -1; dy <= 1 && !adjacent; dy++) {
            for (let dx = -1; dx <= 1; dx++) {
              if (mask[i + dy * width + dx]) { adjacent = true; break; }
            }
          }
          if (adjacent) cleaned[i] = 255;
        }
      }
      if (denseRecovery) {
        if (shapedComponents < 3) return null;
        let remaining = 0, remainingWhite = 0, nonwhite = 0, explained = 0;
        for (let y = 2; y < height - 2; y++) for (let x = 2; x < width - 2; x++) {
          const i = y * width + x, p = i * 4;
          const low = Math.min(rgba[p], rgba[p + 1], rgba[p + 2]);
          const high = Math.max(rgba[p], rgba[p + 1], rgba[p + 2]);
          const white = low >= 245 && high - low <= 10;
          if (!white) { nonwhite++; if (cleaned[i]) explained++; }
          if (!cleaned[i]) {
            remaining++;
            let supported = white;
            if (!supported && low > 180 && high - low <= 10) {
              for (let dy = -2; dy <= 2 && !supported; dy++) {
                for (let dx = -2; dx <= 2; dx++) {
                  if (cleaned[i + dy * width + dx]) { supported = true; break; }
                }
              }
            }
            if (supported) remainingWhite++;
          }
        }
        if (!remaining || remainingWhite / remaining < 0.99 || !nonwhite || explained / nonwhite < 0.95) return null;
      }
      if (denseRecovery) cleaned.denseSurfaceRecovered = true;
      return cleaned;
    };

    // A capped Chebyshev distance transform follows the original mask without
    // recursively growing newly repaired pixels. Work and scratch space are O(n).
    // The caller must first prove the unmasked surface is flat.
    function aidokuRecoverInkHalo(rgba, width, height, mask, foreground, background, stroke, protectedInk) {
      const count = width * height, distance = new Uint8Array(count);
      for (let i = 0; i < count; i++) distance[i] = mask[i] ? 0 : 3;
      for (let y = 1; y < height; y++) for (let x = 1; x < width - 1; x++) {
        const i = y * width + x;
        distance[i] = Math.min(distance[i], 1 + Math.min(
          distance[i - 1], distance[i - width - 1], distance[i - width], distance[i - width + 1]));
      }
      for (let y = height - 2; y >= 0; y--) for (let x = width - 2; x > 0; x--) {
        const i = y * width + x;
        distance[i] = Math.min(distance[i], 1 + Math.min(
          distance[i + 1], distance[i + width - 1], distance[i + width], distance[i + width + 1]));
      }
      const alignedWith = color => {
        if (!color) return () => false;
        const d = color.map((value, channel) => value - background[channel]);
        const norm = d[0] * d[0] + d[1] * d[1] + d[2] * d[2];
        return i => {
          if (norm < 64) return false;
          const z = i * 4, a0 = rgba[z] - background[0],
            a1 = rgba[z + 1] - background[1], a2 = rgba[z + 2] - background[2];
          const t = (a0 * d[0] + a1 * d[1] + a2 * d[2]) / norm;
          return t >= -.02 && t <= 1.05 && Math.max(
            Math.abs(a0 - t * d[0]), Math.abs(a1 - t * d[1]), Math.abs(a2 - t * d[2])) <= 5;
        };
      };
      const followsFill = alignedWith(foreground), followsStroke = alignedWith(stroke);
      let added = 0;
      for (let y = 3; y < height - 3; y++) for (let x = 3; x < width - 3; x++) {
        const i = y * width + x;
        if (distance[i] === 0 || distance[i] > 2) continue;
        const up = i - width, down = i + width;
        if (protectedInk[up - 1] || protectedInk[up] || protectedInk[up + 1] ||
            protectedInk[i - 1] || protectedInk[i] || protectedInk[i + 1] ||
            protectedInk[down - 1] || protectedInk[down] || protectedInk[down + 1]) continue;
        if (!followsFill(i) && !followsStroke(i)) continue;
        mask[i] = 1; added++;
      }
      return added;
    }

    function aidokuColoredSourceInkMask(a){
    const w=a.width,h=a.height,n=w*h,p=a.rgba,sourceFG=a.palette?.foreground,bg=a.palette?.background,sourceStroke=a.palette?.stroke;
    const outlineInterior=Boolean(sourceFG&&bg&&sourceStroke&&Math.max(...sourceFG.map((v,k)=>Math.abs(v-bg[k])))<48&&Math.max(...sourceStroke.map((v,k)=>Math.abs(v-bg[k])))>55),fg=outlineInterior?sourceStroke:sourceFG,stroke=outlineInterior?null:sourceStroke;
    if(!fg||!bg||n>262144)return{reason:'missing-palette/budget'};
    const dist=(a,b)=>Math.max(Math.abs(a[0]-b[0]),Math.abs(a[1]-b[1]),Math.abs(a[2]-b[2]));
    const pixelDistance=(i,target)=>{const z=i*4;return Math.max(Math.abs(p[z]-target[0]),Math.abs(p[z+1]-target[1]),Math.abs(p[z+2]-target[2]));};
    const near=(i,target,t=18)=>pixelDistance(i,target)<=t;
    const makeAlignment=(start,end)=>{if(!start||!end)return()=>false;const d0=end[0]-start[0],d1=end[1]-start[1],d2=end[2]-start[2],norm=d0*d0+d1*d1+d2*d2;return i=>{if(norm<64)return false;const z=i*4,a0=p[z]-start[0],a1=p[z+1]-start[1],a2=p[z+2]-start[2],t=(a0*d0+a1*d1+a2*d2)/norm;return t>=.08&&t<=1.15&&Math.max(Math.abs(a0-t*d0),Math.abs(a1-t*d1),Math.abs(a2-t*d2))<=18;};};
    const alignedBgFG=makeAlignment(bg,fg),alignedStrokeFG=makeAlignment(stroke,fg),alignedBgStroke=makeAlignment(bg,stroke),alignedFGStroke=makeAlignment(fg,stroke);
    const cacheableRGB=v=>Number.isInteger(v)&&v>=0&&v<=255;
    const cacheDistances=bg.every(cacheableRGB)&&fg.every(cacheableRGB);
    const bgDistance=cacheDistances?new Uint8Array(n):null,fgDistance=cacheDistances?new Uint8Array(n):null;
    const raw=new Uint8Array(n),seen=new Uint8Array(n),queue=new Int32Array(n),comps=[];
    for(let i=0;i<n;i++){if(p[i*4+3]!==255)return{reason:'alpha'};const c=i;const bd=pixelDistance(i,bg),fd=pixelDistance(i,fg);if(cacheDistances){bgDistance[i]=bd;fgDistance[i]=fd;}if(bd>18&&(fd<=48||alignedBgFG(c)||(stroke&&alignedStrokeFG(c))))raw[i]=1;}
    for(let i=0;i<n;i++){if(!raw[i]||seen[i])continue;let head=0,tail=1,x0=w,y0=h,x1=0,y1=0,core=0,edge=false;queue[0]=i;seen[i]=1;while(head<tail){const z=queue[head++],x=z%w,y=z/w|0;if(x<x0)x0=x;if(x>x1)x1=x;if(y<y0)y0=y;if(y>y1)y1=y;if(x<2||y<2||x>=w-2||y>=h-2)edge=true;if((fgDistance?fgDistance[z]:pixelDistance(z,fg))<=48)core++;if(y>0&&x>0){const t=z-w-1;if(raw[t]&&!seen[t]){seen[t]=1;queue[tail++]=t;}}if(y>0){const t=z-w;if(raw[t]&&!seen[t]){seen[t]=1;queue[tail++]=t;}}if(y>0&&x+1<w){const t=z-w+1;if(raw[t]&&!seen[t]){seen[t]=1;queue[tail++]=t;}}if(x>0){const t=z-1;if(raw[t]&&!seen[t]){seen[t]=1;queue[tail++]=t;}}if(x+1<w){const t=z+1;if(raw[t]&&!seen[t]){seen[t]=1;queue[tail++]=t;}}if(y+1<h&&x>0){const t=z+w-1;if(raw[t]&&!seen[t]){seen[t]=1;queue[tail++]=t;}}if(y+1<h){const t=z+w;if(raw[t]&&!seen[t]){seen[t]=1;queue[tail++]=t;}}if(y+1<h&&x+1<w){const t=z+w+1;if(raw[t]&&!seen[t]){seen[t]=1;queue[tail++]=t;}}}comps.push({x:x0,y:y0,w:x1-x0+1,h:y1-y0+1,pixels:queue.slice(0,tail),core,edge});}
    const plausible=comps.filter(c=>!c.edge&&c.core>=2&&c.pixels.length>=3&&Math.max(c.w,c.h)<=8*Math.min(c.w,c.h)&&c.w<w*.85&&c.h<h*.85);
    if(plausible.length<3)return{reason:'few-independent-ink-components'};
    const horizontal=w>h;const dimensions=plausible.filter(c=>c.pixels.length>=12).map(c=>horizontal?c.w:c.h).sort((a,b)=>a-b);const median=dimensions[Math.floor(dimensions.length/2)]||0;
    // Repeated enclosed fill islands can identify letters joined by an outline.
    // Uses only this component's boundary, never nearby frame/art components.
    const joinedOutlineEvidence = c => {
     if(!outlineInterior || !sourceFG || c.edge || c.pixels.length<24)return false;
     const cw=c.w+2,ch=c.h+2,localN=cw*ch,wall=new Uint8Array(localN),outside=new Uint8Array(localN),work=new Int32Array(localN);
     for(const z of c.pixels)wall[((z/w|0)-c.y+1)*cw+(z%w-c.x+1)]=1;
     let head=0,tail=1;outside[0]=1;work[0]=0;
     while(head<tail){const z=work[head++],x=z%cw,y=z/cw|0;for(let dir=0;dir<4;dir++){const t=dir===0?(x?z-1:-1):dir===1?(x+1<cw?z+1:-1):dir===2?(y?z-cw:-1):(y+1<ch?z+cw:-1);if(t<0||outside[t]||wall[t])continue;outside[t]=1;work[tail++]=t;}}
     const islands=new Uint8Array(localN);let count=0;
     for(let ly=1;ly<ch-1;ly++)for(let lx=1;lx<cw-1;lx++){const li=ly*cw+lx,gi=(c.y+ly-1)*w+c.x+lx-1;if(!outside[li]&&!wall[li]&&pixelDistance(gi,sourceFG)<=8&&pixelDistance(gi,sourceFG)+4<pixelDistance(gi,bg))islands[li]=1;}
     for(let seed=0;seed<localN;seed++){if(!islands[seed])continue;head=0;tail=1;work[0]=seed;islands[seed]=0;let minX=cw,maxX=0,minY=ch,maxY=0;
      while(head<tail){const z=work[head++],x=z%cw,y=z/cw|0;minX=Math.min(minX,x);maxX=Math.max(maxX,x);minY=Math.min(minY,y);maxY=Math.max(maxY,y);for(let yy=Math.max(0,y-1);yy<=Math.min(ch-1,y+1);yy++)for(let xx=Math.max(0,x-1);xx<=Math.min(cw-1,x+1);xx++){const t=yy*cw+xx;if(islands[t]){islands[t]=0;work[tail++]=t;}}}
      const iw=maxX-minX+1,ih=maxY-minY+1;if(tail>=4&&iw>=2&&ih>=2&&tail<=c.w*c.h*.35)count++;
     }
     return count>=3;
    };
    const plausibleSet=new Set(plausible);
    const owned=new Uint8Array(n),protectedInk=new Uint8Array(n);let accepted=[];
    for(const c of comps){const keep=plausibleSet.has(c)&&((horizontal?c.w:c.h)<=median*1.8||joinedOutlineEvidence(c));for(const i of c.pixels)(keep?owned:protectedInk)[i]=1;if(keep)accepted.push(c);}
    if(accepted.length<3)return{reason:'few-glyph-scale-components'};
    const mask=owned.slice();let strokeAdded=0;
    if(stroke&&dist(stroke,bg)>18){const distance=new Int16Array(n);distance.fill(-1);let head=0,tail=0;for(let i=0;i<n;i++)if(owned[i]){queue[tail++]=i;distance[i]=0;}const radius=Math.min(12,Math.max(2,Math.round(median*.35)));
    while(head<tail){const z=queue[head++],x=z%w,y=z/w|0;if(distance[z]>=radius)continue;for(let direction=0;direction<4;direction++){const t=direction===0?(x?z-1:-1):direction===1?(x+1<w?z+1:-1):direction===2?(y?z-w:-1):(y+1<h?z+w:-1);if(t<0||distance[t]>=0||protectedInk[t])continue;const c=t;if((bgDistance?bgDistance[c]:pixelDistance(c,bg))<=18)continue;if(!near(c,stroke,30)&&!alignedBgStroke(c)&&!alignedFGStroke(c))continue;distance[t]=distance[z]+1;queue[tail++]=t;mask[t]=1;strokeAdded++;}}
    }
    // Similar fill/background: authorize fill only inside each accepted outline component.
    let enclosedFill=0;
    if(outlineInterior){
     const componentID=new Int32Array(n); componentID.fill(-1);
     accepted.forEach((c,id)=>{for(const z of c.pixels)componentID[z]=id;});
     for(let id=0;id<accepted.length;id++){
      const c=accepted[id],cw=c.w+2,ch=c.h+2,localSeen=new Uint8Array(cw*ch),localQueue=new Int32Array(cw*ch);let head=0,tail=1;localQueue[0]=0;localSeen[0]=1;
      const globalIndex=z=>{const x=c.x-1+z%cw,y=c.y-1+(z/cw|0);return x>=0&&y>=0&&x<w&&y<h?y*w+x:-1;};
      while(head<tail){const z=localQueue[head++],x=z%cw,y=z/cw|0;for(let direction=0;direction<4;direction++){const t=direction===0?(x?z-1:-1):direction===1?(x+1<cw?z+1:-1):direction===2?(y?z-cw:-1):(y+1<ch?z+cw:-1);if(t<0||localSeen[t])continue;const gi=globalIndex(t);if(gi>=0&&componentID[gi]===id)continue;localSeen[t]=1;localQueue[tail++]=t;}}
      for(let ly=1;ly<ch-1;ly++)for(let lx=1;lx<cw-1;lx++){const li=ly*cw+lx,z=globalIndex(li);if(localSeen[li]||z<0||mask[z]||protectedInk[z])continue;const color=z;if(pixelDistance(color,sourceFG)<=18&&pixelDistance(color,sourceFG)+4<pixelDistance(color,bg)){mask[z]=1;enclosedFill++;}}
     }
    }
    // Pixel erase authorization needs actual flat remaining source, not palette confidence alone.
    let clean=0,total=0,rimClean=0,rimTotal=0;const hist0=new Uint32Array(256),hist1=new Uint32Array(256),hist2=new Uint32Array(256);for(let i=0;i<n;i++){const x=i%w,y=i/w|0,c=i,solid=(bgDistance?bgDistance[i]:pixelDistance(i,bg))<=18;if(x<3||y<3||x>=w-3||y>=h-3){rimTotal++;if(solid)rimClean++;}if(mask[i]||protectedInk[i])continue;total++;if(solid){clean++;hist0[p[i*4]]++;hist1[p[i*4+1]]++;hist2[p[i*4+2]]++;}}
    if(clean/total<.94||(rimClean/rimTotal<.9&&clean/total<.98))return{reason:'not-flat-after-owned-mask',solid:clean/total,rim:rimClean/rimTotal,accepted:accepted.length,strokeAdded};
    const medianHistogram=hist=>{let cumulative=0;const target=clean>>1;for(let value=0;value<256;value++){cumulative+=hist[value];if(cumulative>target)return value;}return undefined;};const fill=[medianHistogram(hist0),medianHistogram(hist1),medianHistogram(hist2)];let fringeAdded=0;
    if(outlineInterior&&dist(sourceFG,bg)<=24&&sourceStroke){
     const beforeFringe=mask.slice(),s0=sourceStroke[0]-bg[0],s1=sourceStroke[1]-bg[1],s2=sourceStroke[2]-bg[2],norm=s0*s0+s1*s1+s2*s2;
     if(norm>=64)for(let y=3;y<h-3;y++)for(let x=3;x<w-3;x++){
      const i=y*w+x;if(beforeFringe[i]||protectedInk[i])continue;
      const u=i-w,v=i+w;
      if(!(beforeFringe[u-1]||beforeFringe[u]||beforeFringe[u+1]||beforeFringe[i-1]||beforeFringe[i+1]||beforeFringe[v-1]||beforeFringe[v]||beforeFringe[v+1]))continue;
      if((!beforeFringe[i]&&(raw[i]||protectedInk[i]))||(!beforeFringe[u-1]&&(raw[u-1]||protectedInk[u-1]))||(!beforeFringe[u]&&(raw[u]||protectedInk[u]))||(!beforeFringe[u+1]&&(raw[u+1]||protectedInk[u+1]))||(!beforeFringe[i-1]&&(raw[i-1]||protectedInk[i-1]))||(!beforeFringe[i+1]&&(raw[i+1]||protectedInk[i+1]))||(!beforeFringe[v-1]&&(raw[v-1]||protectedInk[v-1]))||(!beforeFringe[v]&&(raw[v]||protectedInk[v]))||(!beforeFringe[v+1]&&(raw[v+1]||protectedInk[v+1])))continue;
      const z=i*4,d0=p[z]-bg[0],d1=p[z+1]-bg[1],d2=p[z+2]-bg[2],t=(d0*s0+d1*s1+d2*s2)/norm;
      if(t<-.005||t>.6||Math.max(Math.abs(d0-t*s0),Math.abs(d1-t*s1),Math.abs(d2-t*s2))>4)continue;
      mask[i]=1;fringeAdded++;
     }
    }
    // Repair detached antialias islands only on an already authorized flat
    // surface. Real ink, long rules and crop-connected art remain protected.
    const acceptedSet=new Set(accepted),haloProtection=new Uint8Array(n);
    for(const c of comps)if(!acceptedSet.has(c)&&
      (c.edge||c.core>0||c.pixels.length>12||Math.max(c.w,c.h)>median*.5))
      for(const z of c.pixels)haloProtection[z]=1;
    const haloAdded=aidokuRecoverInkHalo(p,w,h,mask,sourceFG,fill,sourceStroke,haloProtection);
    let erased=0;for(let i=0;i<n;i++)if(mask[i])erased++;
    return{reason:'accepted',mask,fill,erased,strokeAdded,outlineInterior,enclosedFill,fringeAdded,haloAdded,accepted:accepted.map(c=>({box:[c.x,c.y,c.w,c.h],pixels:c.pixels.length})),rejected:comps.filter(c=>!accepted.includes(c)).map(c=>({box:[c.x,c.y,c.w,c.h],pixels:c.pixels.length})),solid:clean/total,rim:rimClean/rimTotal};
    }
    """
}
