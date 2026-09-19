// Model-free source fill, stroke and surface estimation over the local reader image.
// Return observed source colors with role confidence; never recolor them for readability.
enum BrowserSourceTextColor {
    static let script = """
    const aidokuResolveDirectionalStrokeRole = (rgba,width,height,result) => {
     if(!result?.stroke||!result.background||result.confidence.reason!=='observed fill with glyph-following third-color outer band')return result;
     const fg=result.foreground,stroke=result.stroke,bg=result.background,n=width*height;
     const dist=(a,b)=>Math.max(Math.abs(a[0]-b[0]),Math.abs(a[1]-b[1]),Math.abs(a[2]-b[2]));
     const distanceAt=(i,c)=>{const p=i*4;return Math.max(Math.abs(rgba[p]-c[0]),Math.abs(rgba[p+1]-c[1]),Math.abs(rgba[p+2]-c[2]));};
     if(dist(fg,bg)<=32||dist(stroke,bg)<=32)return result;
     const mask=new Uint8Array(n),seen=new Uint8Array(n),valid=new Uint8Array(n),queue=new Int32Array(n);
     let total=0,kept=0,components=0;
     for(let i=0;i<n;i++)if(distanceAt(i,stroke)<=24){mask[i]=1;total++;}
     for(let start=0;start<n;start++){
      if(!mask[start]||seen[start])continue;
      let head=0,tail=1,minX=width,minY=height,maxX=0,maxY=0,edge=false;queue[0]=start;seen[start]=1;
      while(head<tail){const i=queue[head++],x=i%width,y=Math.floor(i/width);minX=Math.min(minX,x);maxX=Math.max(maxX,x);minY=Math.min(minY,y);maxY=Math.max(maxY,y);edge ||= !x||!y||x===width-1||y===height-1;
       for(const q of [x>0?i-1:-1,x+1<width?i+1:-1,y>0?i-width:-1,y+1<height?i+width:-1])if(q>=0&&mask[q]&&!seen[q]){seen[q]=1;queue[tail++]=q;}
      }
      const w=maxX-minX+1,h=maxY-minY+1;
      if(edge||tail<3||h<Math.max(3,result.widthEvidence.glyphPixels*.5)||w>h*3||h>=height*.9||tail/(w*h)<.15)continue;
      components++;kept+=tail;for(let k=0;k<tail;k++)valid[queue[k]]=1;
     }
     if(components<2||kept<total*.5)return result;
     const dirs=[[1,0],[-1,0],[0,1],[0,-1],[1,1],[1,-1],[-1,1],[-1,-1]];
     const enclosure=(color,other,restrict)=>{
      let sum=0,samples=0;
      for(let i=0;i<n;i++){
       if(restrict&&!restrict[i]||distanceAt(i,color)>16)continue;
       const x=i%width,y=Math.floor(i/width);let ink=0,surface=0;
       for(const [dx,dy] of dirs)for(let step=1;step<=6;step++){
        const xx=x+dx*step,yy=y+dy*step;if(xx<0||xx>=width||yy<0||yy>=height)break;
        const q=yy*width+xx,di=distanceAt(q,other),db=distanceAt(q,bg),ds=distanceAt(q,color);
        if(di+16<db&&di+16<ds){ink++;break;}if(db+16<di&&db+16<ds){surface++;break;}
       }
       if(ink+surface>=5){sum+=ink/(ink+surface);samples++;}
      }
      return {ratio:sum/Math.max(1,samples),samples};
     };
     const candidate=enclosure(stroke,fg,valid),current=enclosure(fg,stroke,null);
     if(candidate.samples>=6&&current.samples>=6&&candidate.ratio>.5&&candidate.ratio>current.ratio){
      result.foreground=stroke;result.stroke=fg;result.outline=fg;
      result.confidence.reason='directional enclosure of repeated source ink fragments distinguishes fill from outline';
      result.confidence.foreground=.6;result.confidence.stroke=.6;
     }
     return result;
    };
    const aidokuEstimateSourceColors = (rgba, width, height, preferredSurfaceKey = null, exteriorSurface = null, inner = null, trustedSurface = false) => {
      const count = width * height;
      if (!Number.isInteger(width) || !Number.isInteger(height) || width < 8 || height < 8 ||
          count > 24576 || !rgba || rgba.length !== count * 4) return null;
      const distance = (a, b) => Math.max(Math.abs(a[0] - b[0]), Math.abs(a[1] - b[1]), Math.abs(a[2] - b[2]));
      const validInner = Array.isArray(inner) && inner.length === 4 && inner.every(Number.isFinite) &&
        inner[0] >= 0 && inner[1] >= 0 && inner[2] > 0 && inner[3] > 0 &&
        inner[0] + inner[2] <= width + 0.5 && inner[1] + inner[3] <= height + 0.5;
      const inkPadding = validInner ? Math.max(2, Math.min(6, Math.ceil(Math.min(inner[2], inner[3]) * 0.12))) : 0;
      const inInkDomain = (x, y) => !validInner ||
        (x >= inner[0] - inkPadding && x < inner[0] + inner[2] + inkPadding &&
         y >= inner[1] - inkPadding && y < inner[1] + inner[3] + inkPadding);
      const binInkCount = bin => validInner ? (bin.inkCount || 0) : bin[0];
      const bins = new Map(), rim = new Map();
      const keyAt = p => (rgba[p] >> 4) * 256 + (rgba[p + 1] >> 4) * 16 + (rgba[p + 2] >> 4);
      let rimCount = 0;
      for (let i = 0; i < count; i++) {
        const p = i * 4, x = i % width, y = Math.floor(i / width);
        if (rgba[p + 3] < 250) return null;
        const key = keyAt(p);
        let bin = bins.get(key);
        if (!bin) { bin = [0, 0, 0, 0]; bins.set(key, bin); }
        bin[0]++; for (let c = 0; c < 3; c++) bin[c + 1] += rgba[p + c];
        if (inInkDomain(x, y)) bin.inkCount = (bin.inkCount || 0) + 1;
        if (x < 2 || y < 2 || x >= width - 2 || y >= height - 2) {
          rim.set(key, (rim.get(key) || 0) + 1); rimCount++;
        }
      }
      // Bins are complete before their mean is read; hole bins are local and final.
      const mean = bin => bin.rgbMean || (bin.rgbMean = [bin[1] / bin[0], bin[2] / bin[0], bin[3] / bin[0]]);
      const mostPopulated = values => { let best = null; for (const bin of values) if (!best || bin[0] > best[0]) best = bin; return best; };
      const backgroundKey = preferredSurfaceKey ?? [...rim].sort((a, b) => b[1] - a[1])[0][0];
      const background = mean(bins.get(backgroundKey));
      const backgroundDistance = bin => bin.backgroundDistance ?? (bin.backgroundDistance = distance(mean(bin), background));
      let backgroundCount = 0, backgroundRim = 0, candidateCount = 0;
      let winner = null;
      let solidCount = 0, solidRim = 0;
      for (const [key, bin] of bins) {
        if (backgroundDistance(bin) <= 12) {
          solidCount += bin[0]; solidRim += rim.get(key) || 0;
        }
        if (backgroundDistance(bin) <= 32) {
          backgroundCount += bin[0]; backgroundRim += rim.get(key) || 0;
        } else if (backgroundDistance(bin) >= 60) {
          const support = binInkCount(bin);
          candidateCount += support;
          if (support > 0 && (!winner || support > binInkCount(winner))) winner = bin;
        }
      }
      const colors = {foreground: null, background: background.map(Math.round), stroke: null, outline: null,
        widthEvidence: null, confidence: {foreground: 0, background: Math.min(1, solidRim / rimCount), stroke: 0,
          reason: 'dominant observed rim; no validated glyph yet'}};
      const resolveSurface = result => {
        if (preferredSurfaceKey !== null || result.foreground) return result;
        let dominantKey = null;
        for (const [key, bin] of bins) {
          if (backgroundDistance(bin) >= 60 && (dominantKey === null || bin[0] > bins.get(dominantKey)[0])) dominantKey = key;
        }
        if (dominantKey === null) return result;
        const competing = aidokuEstimateSourceColors(rgba, width, height, dominantKey, background, inner);
        if (!competing?.foreground) return result;
        if (competing.background && distance(competing.background, mean(bins.get(dominantKey))) > 32) return result;
        competing.confidence.reason = 'competing interior surface with validated ink; ' + competing.confidence.reason;
        return competing;
      };
      // A uniform background must dominate both the crop and its perimeter.
      if (!winner || candidateCount < Math.max(6, count * 0.004)) return resolveSurface(colors);
      // Antialiasing blends ink toward the background. Use the distant tail
      // rather than the most frequent gray edge as the ink-color seed.
      const inkBins = [...bins.values()].filter(bin => backgroundDistance(bin) >= 60 && binInkCount(bin) > 0)
        .sort((a, b) => backgroundDistance(b) - backgroundDistance(a));
      const tailTarget = Math.max(6, candidateCount * 0.12), tailSum = [0, 0, 0];
      let tailCount = 0;
      for (const bin of inkBins) {
        const take = Math.min(binInkCount(bin), tailTarget - tailCount), rgb = mean(bin);
        for (let c = 0; c < 3; c++) tailSum[c] += rgb[c] * take;
        tailCount += take;
        if (tailCount >= tailTarget) break;
      }
      const seedColor = tailSum.map(v => v / tailCount);
      const direction = seedColor.map((v, c) => v - background[c]);
      const lengthSquared = direction.reduce((sum, v) => sum + v * v, 0);
      const mask = new Uint8Array(count), core = new Uint8Array(count);
      let selected = 0, aligned = 0;
      // Identical neutral RGB values have identical classification within this crop.
      // Cache the exact result, not a quantized color or relaxed decision boundary.
      const grayClassification = new Uint8Array(256);
      const classifyRGB = (red, green, blue) => {
        const r = red - background[0], g = green - background[1], b = blue - background[2];
        if (Math.max(Math.abs(r), Math.abs(g), Math.abs(b)) < 60) return 1;
        const t = (r * direction[0] + g * direction[1] + b * direction[2]) / lengthSquared;
        if (t < 0.15 || t > 1.2 || Math.max(Math.abs(r - t * direction[0]),
            Math.abs(g - t * direction[1]), Math.abs(b - t * direction[2])) > 24) return 1;
        return Math.max(Math.abs(red - seedColor[0]), Math.abs(green - seedColor[1]),
          Math.abs(blue - seedColor[2])) <= 24 ? 3 : 2;
      };
      for (let i = 0; i < count; i++) {
        const p = i * 4, red = rgba[p], green = rgba[p + 1], blue = rgba[p + 2];
        let flag;
        if (red === green && green === blue) {
          flag = grayClassification[red];
          if (!flag) { flag = classifyRGB(red, green, blue); grayClassification[red] = flag; }
        } else flag = classifyRGB(red, green, blue);
        if (flag < 2 || !inInkDomain(i % width, Math.floor(i / width))) continue;
        mask[i] = 1; aligned++;
        if (flag === 3) { core[i] = 1; selected++; }
      }
      if (selected < 3) return resolveSurface(colors);
      const seen = new Uint8Array(count), queue = new Int32Array(count);
      const acceptedInk = new Uint16Array(count), closedInterior = new Uint8Array(count), componentHeights = [];
      const possibleFill = true;
      const enclosedFill = []; let fillBudget = count; const sum = [0, 0, 0]; let coreCount = 0, components = 0, retained = 0;
      for (let start = 0; start < count; start++) {
        if (!mask[start] || seen[start]) continue;
        let head = 0, tail = 1, boundary = false;
        let minX = width, minY = height, maxX = 0, maxY = 0;
        queue[0] = start; seen[start] = 1;
        while (head < tail) {
          const i = queue[head++], x = i % width, y = Math.floor(i / width);
          minX = Math.min(minX, x); maxX = Math.max(maxX, x);
          minY = Math.min(minY, y); maxY = Math.max(maxY, y);
          if (!x || !y || x === width - 1 || y === height - 1) boundary = true;
          if (x > 0 && mask[i - 1] && !seen[i - 1]) { seen[i - 1] = 1; queue[tail++] = i - 1; }
          if (x + 1 < width && mask[i + 1] && !seen[i + 1]) { seen[i + 1] = 1; queue[tail++] = i + 1; }
          if (y > 0 && mask[i - width] && !seen[i - width]) { seen[i - width] = 1; queue[tail++] = i - width; }
          if (y + 1 < height && mask[i + width] && !seen[i + width]) { seen[i + width] = 1; queue[tail++] = i + width; }
        }
        const boxWidth = maxX - minX + 1, boxHeight = maxY - minY + 1;
        // Exclude border art, specks and filled rectangles/panel rules.
        if (boundary || tail < 3 || boxWidth > width * 0.9 || boxHeight > height * 0.9 ||
            (tail > 12 && tail / (boxWidth * boxHeight) > 0.9)) continue;
        components++; retained += tail; componentHeights.push(boxHeight);
        for (let j=0;j<tail;j++) acceptedInk[queue[j]]=components;
        const boxArea = boxWidth * boxHeight;
        if (possibleFill && boxArea <= fillBudget && boxWidth >= 3 && boxHeight >= 3) {
          fillBudget -= boxArea;
          const ownedInk = new Uint8Array(boxArea);
          for (let j = 0; j < tail; j++) {
            const point = queue[j];
            ownedInk[(Math.floor(point / width) - minY) * boxWidth + point % width - minX] = 1;
          }
          const visited = new Uint8Array(boxArea), flood = new Int32Array(boxArea);
          for (let local = 0; local < boxArea; local++) {
            const lx = local % boxWidth, ly = Math.floor(local / boxWidth);
            if (visited[local] || ownedInk[local]) continue;
            let read = 0, length = 1, open = false, sampled = 0;
            const sums = [0, 0, 0], holeBins=new Map(); let hx0=boxWidth,hy0=boxHeight,hx1=0,hy1=0,foreign=0;
            visited[local] = 1; flood[0] = local;
            while (read < length) {
              const v = flood[read++], x = v % boxWidth, y = Math.floor(v / boxWidth);
              if (!x || !y || x === boxWidth - 1 || y === boxHeight - 1) open = true;
              if (x > 0 && !visited[v - 1] && !ownedInk[v - 1]) { visited[v - 1] = 1; flood[length++] = v - 1; }
              if (x + 1 < boxWidth && !visited[v + 1] && !ownedInk[v + 1]) { visited[v + 1] = 1; flood[length++] = v + 1; }
              if (y > 0 && !visited[v - boxWidth] && !ownedInk[v - boxWidth]) { visited[v - boxWidth] = 1; flood[length++] = v - boxWidth; }
              if (y + 1 < boxHeight && !visited[v + boxWidth] && !ownedInk[v + boxWidth]) { visited[v + boxWidth] = 1; flood[length++] = v + boxWidth; }
            }
            // Only closed interiors contribute color statistics. Outside whitespace
            // still floods in the same order, but needs no RGB histogram or extrema.
            if (!open) {
              for (let k=0;k<length;k++) {
                const v=flood[k],x=v%boxWidth,y=Math.floor(v/boxWidth);
              const p = ((y + minY) * width + x + minX) * 4;
              if (!mask[p / 4]) {
                for (let c = 0; c < 3; c++) sums[c] += rgba[p + c];
                const key=keyAt(p);let hb=holeBins.get(key);if(!hb){hb=[0,0,0,0];holeBins.set(key,hb);}hb[0]++;for(let c=0;c<3;c++)hb[c+1]+=rgba[p+c]; sampled++; hx0=Math.min(hx0,x);hy0=Math.min(hy0,y);hx1=Math.max(hx1,x);hy1=Math.max(hy1,y);
              } else { foreign++;
              }
              }
            }
            if (!open && sampled >= 2) { for(let k=0;k<length;k++){const point=flood[k],global=(Math.floor(point/boxWidth)+minY)*width+point%boxWidth+minX;if(!mask[global])closedInterior[global]=1;} enclosedFill.push({component:start, count:sampled, rgb:mean(mostPopulated(holeBins.values())), foreign, compactness:sampled/Math.max(1,(hx1-hx0+1)*(hy1-hy0+1)),interiorWidth:hx1-hx0+1,interiorHeight:hy1-hy0+1,glyphHeight:boxHeight,band:tail/(2*(boxWidth+boxHeight))}); };
          }
        }

        for (let j = 0; j < tail; j++) {
          const i = queue[j];
          const neighbors = (mask[i - 1] || 0) + (mask[i + 1] || 0) +
                            (mask[i - width] || 0) + (mask[i + width] || 0);
          if (!core[i] || neighbors < 3) continue;
          for (let c = 0; c < 3; c++) sum[c] += rgba[i * 4 + c];
          coreCount++;
        }
      }
      const recoverHalo = () => {
        if (preferredSurfaceKey === null || !exteriorSurface || components < 2 || coreCount < 3) return colors;
        const sortedHeights = [...componentHeights].sort((a, b) => a - b);
        const glyphPixels = sortedHeights[Math.floor((sortedHeights.length - 1) * 0.75)];
        const near = new Uint8Array(count), owner = new Uint16Array(count);
        const reach = Math.min(24, Math.max(6, Math.ceil(glyphPixels * 0.8)));
        let read = 0, length = 0;
        for (let i = 0; i < count; i++) if (acceptedInk[i]) { near[i] = 1; owner[i] = acceptedInk[i]; queue[length++] = i; }
        while (read < length) {
          const i = queue[read++], x = i % width, y = Math.floor(i / width);
          if (near[i] > reach) continue;
          for (const j of [x ? i - 1 : -1, x + 1 < width ? i + 1 : -1, y ? i - width : -1, y + 1 < height ? i + width : -1]) {
            if (j >= 0 && !near[j]) { near[j] = near[i] + 1; owner[j] = owner[i]; queue[length++] = j; }
          }
        }
        const bandMask = new Uint8Array(count), seenBand = new Uint8Array(count);
        for (let i = 0; i < count; i++) if (!acceptedInk[i] && !closedInterior[i] &&
          Math.max(Math.abs(rgba[i * 4] - background[0]), Math.abs(rgba[i * 4 + 1] - background[1]), Math.abs(rgba[i * 4 + 2] - background[2])) <= 24) bandMask[i] = 1;
        const bands = [], strokeOwners = new Set(); let strokePixels = 0;
        for (let start = 0; start < count; start++) {
          if (!bandMask[start] || seenBand[start]) continue;
          let head = 0, tail = 1; queue[0] = start; seenBand[start] = 1;
          const outer = [], localOwners = new Set();
          while (head < tail) {
            const i = queue[head++], x = i % width, y = Math.floor(i / width);
            if (owner[i]) localOwners.add(owner[i]);
            let exterior = false;
            for (const j of [x ? i - 1 : -1, x + 1 < width ? i + 1 : -1, y ? i - width : -1, y + 1 < height ? i + width : -1]) {
              if (j < 0) continue;
              if (bandMask[j]) { if (!seenBand[j]) { seenBand[j] = 1; queue[tail++] = j; } continue; }
              if (!acceptedInk[j] && Math.max(Math.abs(rgba[j * 4] - exteriorSurface[0]),
                Math.abs(rgba[j * 4 + 1] - exteriorSurface[1]), Math.abs(rgba[j * 4 + 2] - exteriorSurface[2])) <= 32) exterior = true;
            }
            if (exterior) outer.push(near[i] ? near[i] - 1 : reach + 1);
          }
          if (outer.length < 4 || tail < 6) continue;
          outer.sort((a, b) => a - b);
          const median = outer[Math.floor(outer.length / 2)], p90 = outer[Math.floor((outer.length - 1) * 0.9)];
          if (median > Math.max(2, Math.ceil(glyphPixels * 0.30)) || p90 > Math.max(3, Math.ceil(glyphPixels * 0.45))) continue;
          strokePixels += tail; bands.push(Math.max(0.5, median - 0.5));
          for (const id of localOwners) strokeOwners.add(id);
        }
        if (strokePixels < 6 || strokeOwners.size < 2) return colors;
        const inkSum = [0, 0, 0]; let inkPixels = 0;
        for (let i = 0; i < count; i++) {
          if (!core[i] || !strokeOwners.has(acceptedInk[i])) continue;
          const neighbors = (mask[i - 1] || 0) + (mask[i + 1] || 0) + (mask[i - width] || 0) + (mask[i + width] || 0);
          if (neighbors < 3) continue;
          for (let c = 0; c < 3; c++) inkSum[c] += rgba[i * 4 + c]; inkPixels++;
        }
        if (inkPixels < 3) return colors;
        const observedFill = inkSum.map(v => v / inkPixels);
        // A counter matching the outside surface is not independently observed fill.
        if (distance(observedFill, exteriorSurface) <= 12) return colors;
        bands.sort((a, b) => a - b); const band = bands[Math.floor(bands.length / 2)], stroke = background.map(Math.round);
        return {foreground: inkSum.map(v => Math.round(v / inkPixels)), background: null, stroke, outline: stroke,
          widthEvidence: {samplePixels: band, relativeToGlyph: band / glyphPixels, glyphPixels,
            method: 'alternative observed ink with glyph-following halo; exterior surface unverified'},
          confidence: {foreground: Math.min(0.9, 0.5 + strokeOwners.size * 0.08), background: 0,
            stroke: Math.min(0.9, 0.5 + strokeOwners.size * 0.08), reason: 'observed glyph fill and following halo; no validated flat exterior surface'}};
      };
      let broadlySupportedSurface = Boolean(trustedSurface);
      if (preferredSurfaceKey !== null && !broadlySupportedSurface) {
        let surfacePixels = 0;
        for (const bin of bins.values()) if (backgroundDistance(bin) <= 24) surfacePixels += bin[0];
        broadlySupportedSurface = surfacePixels > count / 2 && retained >= aligned * 0.35 && coreCount >= 3;
      }
      if (preferredSurfaceKey !== null && !broadlySupportedSurface) {
        // An alternative surface must be a shared, connected backing for a glyph
        // group. Its local coverage excludes unrelated border art from the ink
        // denominator, while thin halos do not occupy most of that group's box.
        if (components < 2) return recoverHalo();
        const surfaceLabels = new Uint16Array(count), surfaces = [null];
        const surfacePixel = i => Math.max(Math.abs(rgba[i * 4] - background[0]),
          Math.abs(rgba[i * 4 + 1] - background[1]), Math.abs(rgba[i * 4 + 2] - background[2])) <= 32;
        for (let start = 0; start < count; start++) {
          if (surfaceLabels[start] || !surfacePixel(start)) continue;
          const label = surfaces.length; let read = 0, length = 1;
          queue[0] = start; surfaceLabels[start] = label;
          while (read < length) {
            const i = queue[read++], x = i % width, y = Math.floor(i / width);
            for (const next of [x ? i - 1 : -1, x + 1 < width ? i + 1 : -1,
                                y ? i - width : -1, y + 1 < height ? i + width : -1]) {
              if (next >= 0 && !surfaceLabels[next] && surfacePixel(next)) {
                surfaceLabels[next] = label; queue[length++] = next;
              }
            }
          }
          surfaces.push({label, owners: [], ink: 0, area: length});
        }
        const owners = Array.from({length: components + 1}, () =>
          ({adjacent: new Map(), count: 0, left: width, top: height, right: 0, bottom: 0}));
        for (let i = 0; i < count; i++) {
          if (!acceptedInk[i]) continue;
          const owner = owners[acceptedInk[i]], x = i % width, y = Math.floor(i / width);
          owner.count++; owner.left = Math.min(owner.left, x); owner.top = Math.min(owner.top, y);
          owner.right = Math.max(owner.right, x); owner.bottom = Math.max(owner.bottom, y);
          for (let dy = -2; dy <= 2; dy++) for (let dx = -2; dx <= 2; dx++) {
            if (x + dx < 0 || x + dx >= width || y + dy < 0 || y + dy >= height) continue;
            const label = surfaceLabels[(y + dy) * width + x + dx];
            if (label) owner.adjacent.set(label, (owner.adjacent.get(label) || 0) + 1);
          }
        }
        for (let id = 1; id < owners.length; id++) {
          const owner = owners[id]; if (owner.count < 6) continue;
          let bestLabel = 0, bestCount = 0;
          for (const [label, adjacent] of owner.adjacent) if (adjacent > bestCount) { bestLabel = label; bestCount = adjacent; }
          if (bestLabel) { surfaces[bestLabel].owners.push(id); surfaces[bestLabel].ink += owner.count; }
        }
        let best = null;
        for (const surface of surfaces.slice(1)) {
          if (surface.owners.length < 2) continue;
          let left = width, top = height, right = 0, bottom = 0;
          for (const id of surface.owners) { const o = owners[id]; left = Math.min(left, o.left);
            top = Math.min(top, o.top); right = Math.max(right, o.right); bottom = Math.max(bottom, o.bottom); }
          let supported = 0, localAligned = 0;
          for (let y = top; y <= bottom; y++) for (let x = left; x <= right; x++) {
            const i = y * width + x;
            if (surfaceLabels[i] === surface.label) supported++;
            if (mask[i]) localAligned++;
          }
          if (supported <= (right - left + 1) * (bottom - top + 1) / 2 || surface.ink < localAligned * 0.35) continue;
          if (!best || surface.ink > best.ink) best = {...surface, localAligned, left, top, right, bottom};
        }
        if (!best) return recoverHalo();
        let extendedSurface = 0;
        for (let i = 0; i < count; i++) {
          if (surfaceLabels[i] !== best.label) continue;
          const x = i % width, y = Math.floor(i / width);
          if (x < best.left - 2 || x > best.right + 2 || y < best.top - 2 || y > best.bottom + 2) extendedSurface++;
        }
        if (extendedSurface < Math.max(6, best.area * 0.2)) return recoverHalo();
        const keptOwners = new Map(best.owners.map((id, index) => [id, index + 1]));
        sum.fill(0); coreCount = 0;
        for (let i = 0; i < count; i++) {
          const label = keptOwners.get(acceptedInk[i]) || 0; acceptedInk[i] = label;
          if (!label || !core[i]) continue;
          const neighbors = (mask[i - 1] || 0) + (mask[i + 1] || 0) + (mask[i - width] || 0) + (mask[i + width] || 0);
          if (neighbors < 3) continue;
          for (let c = 0; c < 3; c++) sum[c] += rgba[i * 4 + c]; coreCount++;
        }
        componentHeights.splice(0, componentHeights.length, ...best.owners.map(id => owners[id].bottom - owners[id].top + 1));
        components = best.owners.length; retained = best.ink; aligned = best.localAligned;
      }
      if (components < 1 || retained < aligned * 0.35 || coreCount < 3) return resolveSurface(colors);
      colors.foreground = sum.map(v => Math.round(v / coreCount));
      colors.confidence.foreground = Math.min(1, retained / Math.max(1, aligned)) * Math.min(1, components / 3);
      colors.confidence.reason = 'observed validated ink components';
      componentHeights.sort((a,b)=>a-b);
      const glyphHeight = componentHeights[Math.floor((componentHeights.length-1)*0.75)];
      // A repeated, closed interior color beyond the exterior-background side
      // of the outline/background axis can be the glyph fill, not a counter.
      let observedBandPixels=0, independentSurface=false;
      // A third color must not be an antialias blend between the selected ink
      // and panel. It may be neutral white or an independently colored stroke.
      const outsideStroke = rgb => {
        if (distance(rgb, background) <= 12 || distance(rgb, colors.foreground) < 24) return false;
        const delta=rgb.map((v,c)=>v-background[c]);
        const t=delta.reduce((a,v,c)=>a+v*direction[c],0)/Math.max(1,lengthSquared);
        return t < -0.03 || t > 1.1 || Math.max(...delta.map((v,c)=>Math.abs(v-t*direction[c]))) > 24;
      };
      const strokeBins=[...bins.values()].filter(bin=>bin[0]>=3 && outsideStroke(mean(bin)))
        .sort((a,b)=>b[0]-a[0]);
      if (strokeBins.length) {
        const strokeSeed=mean(strokeBins[0]);
        const near=new Uint8Array(count), owner=new Uint16Array(count);
        let read=0,length=0;
        const reach=Math.min(24,Math.max(6,Math.ceil(glyphHeight*0.8)));
        for(let i=0;i<count;i++)if(acceptedInk[i]){near[i]=1;owner[i]=acceptedInk[i];queue[length++]=i;}
        while(read<length){
          const i=queue[read++],x=i%width,y=Math.floor(i/width);
          if(near[i]>reach)continue;
          for(const next of [x>0?i-1:-1,x+1<width?i+1:-1,y>0?i-width:-1,y+1<height?i+width:-1]){
            if(next>=0&&!near[next]){near[next]=near[i]+1;owner[next]=owner[i];queue[length++]=next;}
          }
        }
        const strokeMask=new Uint8Array(count), strokeSeen=new Uint8Array(count);
        for(let i=0;i<count;i++){
          const rgb=[rgba[i*4],rgba[i*4+1],rgba[i*4+2]];
          if(!acceptedInk[i]&&!closedInterior[i]&&distance(rgb,strokeSeed)<=24&&outsideStroke(rgb))strokeMask[i]=1;
        }
        const bands=[],strokeSums=[0,0,0];let strokePixels=0,strokeOwners=new Set(),surface=null;
        for(let start=0;start<count;start++){
          if(!strokeMask[start]||strokeSeen[start])continue;
          let head=0,tail=1;queue[0]=start;strokeSeen[start]=1;
          const outer=[],inner=[],localOwners=new Set(),sums=[0,0,0];
          while(head<tail){
            const i=queue[head++],x=i%width,y=Math.floor(i/width);
            for(let c=0;c<3;c++)sums[c]+=rgba[i*4+c];
            if(owner[i])localOwners.add(owner[i]);
            let exterior=false,interior=false;
            for(const next of [x>0?i-1:-1,x+1<width?i+1:-1,y>0?i-width:-1,y+1<height?i+width:-1]){
              if(next<0)continue;
              if(acceptedInk[next])interior=true;
              if(strokeMask[next]){if(!strokeSeen[next]){strokeSeen[next]=1;queue[tail++]=next;}continue;}
              if(!acceptedInk[next]&&distance([rgba[next*4],rgba[next*4+1],rgba[next*4+2]],background)<=32)exterior=true;
            }
            if(interior)inner.push(i);
            if(exterior)outer.push(near[i]?near[i]-1:reach+1);
          }
          if(outer.length<4||tail<6)continue;
          outer.sort((a,b)=>a-b);
          const median=outer[Math.floor(outer.length/2)],p90=outer[Math.floor((outer.length-1)*0.9)];
          // Outer band, not only selected near-ink pixels, must track the glyph.
          // A white paper/ellipse has a remote outer edge and stays a surface.
          const followsInk=median<=Math.max(2,Math.ceil(glyphHeight*0.30))&&p90<=Math.max(3,Math.ceil(glyphHeight*0.45));
          if(followsInk){
            strokePixels+=tail;for(let c=0;c<3;c++)strokeSums[c]+=sums[c];
            bands.push(Math.max(0.5,median-0.5));for(const id of localOwners)strokeOwners.add(id);
          }else if(tail>=count*0.1&&(!surface||tail>surface.count)){
            surface={count:tail,rgb:strokeSeed.map(Math.round)};
          }
        }
        if(strokePixels>=6&&strokeOwners.size>=2){
          colors.stroke=strokeSeed.map(Math.round);colors.outline=colors.stroke;
          bands.sort((a,b)=>a-b);const band=bands[Math.floor(bands.length/2)];
          colors.widthEvidence={samplePixels:band,relativeToGlyph:band/glyphHeight,glyphPixels:glyphHeight,
            method:'outer stroke boundary distance to validated ink; external Manhattan band'};
          colors.confidence.stroke=Math.min(0.9,0.5+strokeOwners.size*0.08);
          colors.confidence.reason='observed fill with glyph-following third-color outer band';
          observedBandPixels=strokePixels;
        }else if(surface){
          colors.background=surface.rgb;colors.confidence.background=0.8;
          colors.confidence.reason='independent surrounding text surface, not a glyph stroke';
          independentSurface=true;
        }
      }

      if(independentSurface)return resolveSurface(colors);
      const fillCandidates = enclosedFill.filter(hole => {
        if(distance(hole.rgb, colors.foreground)<24 || (hole.compactness>=0.8 && hole.foreign<3))return false;
        const delta=hole.rgb.map((v,c)=>v-background[c]);
        const t=delta.reduce((a,v,c)=>a+v*direction[c],0)/Math.max(1,lengthSquared);
        // Counter antialiasing follows the foreground/background line. A real
        // independent fill must depart from that line, unless equal to panel.
        return distance(hole.rgb,background)<=12 || t<0 ||
          Math.max(...delta.map((v,c)=>Math.abs(v-t*direction[c])))>24;
      });
      const fillClusters = [];
      for (const hole of fillCandidates) {
        let cluster = fillClusters.find(c => distance(c.rgb, hole.rgb) <= 12);
        if (!cluster) { cluster = {rgb:hole.rgb, count:0, sums:[0,0,0], components:new Set(), holes:[]}; fillClusters.push(cluster); }
        cluster.holes.push(hole); cluster.count += hole.count; cluster.components.add(hole.component);
        for (let c=0;c<3;c++) cluster.sums[c] += hole.rgb[c] * hole.count;
        cluster.rgb = cluster.sums.map(v => v / cluster.count);
      }
      fillClusters.sort((a,b) => b.count - a.count);
      const fill = fillClusters[0], fillTotal = fillCandidates.reduce((sum,hole) => sum + hole.count, 0);
      const fillIsBackground = fill && distance(fill.rgb, background) <= 12;
      const shapedFill = fill && fill.holes.some(h=>h.compactness < 0.7 || h.foreign >= 3);
      // Adjacent outline bands can join several glyphs into one component.
      // Repeated shaped interiors still provide independent fill evidence.
      const joinedGlyphFill = fill && fill.holes.filter(h => h.count >= 6 &&
        (h.compactness < 0.7 || h.foreign >= 3)).length >= 3 && fill.count >= retained * 0.5;
      // A narrow rendered fill can be split by antialiasing into long hairlines.
      // Require that morphology in three separate glyph components; a compact
      // counter alone never establishes fill or changes the source palette.
      const thinInteriorOwners = new Set(enclosedFill.filter(h =>
        h.interiorHeight >= h.glyphHeight * 0.65 && h.interiorWidth <= h.glyphHeight * 0.15 &&
        h.interiorHeight >= h.interiorWidth * 4 &&
        distance(h.rgb, background) < distance(colors.foreground, background) * 0.3).map(h => h.component));
      const repeatedThinFill = fill && fillIsBackground && thinInteriorOwners.size >= 3;
      if (fill && (fill.components.size >= 2 || joinedGlyphFill || repeatedThinFill) && fill.count >= 6 &&
          fill.count >= fillTotal * 0.5 && fill.count >= observedBandPixels * 0.5 &&
          (!fillIsBackground || (Math.max(...colors.foreground)-Math.min(...colors.foreground)>20 &&
            ((fill.components.size >= 3 && fill.components.size >= components * 0.6 && shapedFill) ||
              joinedGlyphFill || repeatedThinFill)))) {
        colors.stroke = colors.foreground; colors.outline = colors.stroke;
        colors.foreground = fill.rgb.map(Math.round);
        const bands=fill.holes.map(h=>h.band).sort((a,b)=>a-b);
        const band=bands[Math.floor(bands.length/2)];
        colors.widthEvidence={samplePixels:band,relativeToGlyph:band/glyphHeight,glyphPixels:glyphHeight,
          method:'own-component enclosure stroke area over bounding perimeter; external band'};
        colors.confidence.stroke=fillIsBackground?0.55:0.85;
        colors.confidence.foreground=colors.confidence.stroke;
        colors.confidence.reason='enclosed glyph fill and distinct enclosing source stroke';
        return resolveSurface(colors);
      }
      // Thick glyphs and their antialiasing occupy the crop, but are not
      // evidence of a varying panel. Judge uniformity on the remaining area
      // only after the disconnected letter components have been validated.
      // Keep the perimeter gate: a gradient or nearby artwork still abstains.
      if (!colors.background && solidRim >= rimCount * 0.85 &&
          solidCount >= (count - retained) * 0.65) colors.background = background.map(Math.round);
      // Compete against a broad surface mistaken for foreground ink. This only
      // examines unproven outer-band roles; closed glyph-fill evidence returned earlier.
      if (colors.stroke && colors.confidence.reason === 'observed fill with glyph-following third-color outer band') {
        const candidate = colors.stroke, surfaceSeed = colors.foreground;
        let inkEnergy=0,surfaceEnergy=0,inkSamples=0,surfaceSamples=0;
        const candidateMask=new Uint8Array(count);
        for(let y=0;y<height;y++)for(let x=0;x<width;x++){
          const i=y*width+x,p=i*4,rgb=[rgba[p],rgba[p+1],rgba[p+2]];
          const isInk=distance(rgb,candidate)<=24,isSurface=distance(rgb,surfaceSeed)<=24;
          if(isInk)candidateMask[i]=1;
          if(x<2||y<2||x>=width-2||y>=height-2)continue;
          if(!isInk&&!isSurface)continue;
          const offsets=[i-2,i+2,i-width*2,i+width*2];
          let energy=0;for(let c=0;c<3;c++){let average=0;for(const q of offsets)average+=rgba[q*4+c]/4;energy=Math.max(energy,Math.abs(rgb[c]-average));}
          if(isInk){inkEnergy+=energy;inkSamples++;}if(isSurface){surfaceEnergy+=energy;surfaceSamples++;}
        }
        inkEnergy/=Math.max(1,inkSamples);surfaceEnergy/=Math.max(1,surfaceSamples);
        if(inkEnergy>=12&&surfaceEnergy<inkEnergy*0.6){
          const visited=new Uint8Array(count);let glyphs=0,inkPixels=0,gx0=width,gy0=height,gx1=0,gy1=0;
          for(let start=0;start<count;start++){
            if(!candidateMask[start]||visited[start])continue;
            let head=0,tail=1,boundary=false,minX=width,minY=height,maxX=0,maxY=0;queue[0]=start;visited[start]=1;
            while(head<tail){const i=queue[head++],x=i%width,y=Math.floor(i/width);minX=Math.min(minX,x);maxX=Math.max(maxX,x);minY=Math.min(minY,y);maxY=Math.max(maxY,y);if(!x||!y||x===width-1||y===height-1)boundary=true;
              for(const n of [x>0?i-1:-1,x+1<width?i+1:-1,y>0?i-width:-1,y+1<height?i+width:-1])if(n>=0&&candidateMask[n]&&!visited[n]){visited[n]=1;queue[tail++]=n;}
            }
            const bw=maxX-minX+1,bh=maxY-minY+1;
            if(boundary||tail<9||bh<glyphHeight*0.5||bw>bh*3||bw>width*.9||bh>height*.9||tail/(bw*bh)<0.15||(tail>12&&tail/(bw*bh)>.9))continue;
            glyphs++;inkPixels+=tail;gx0=Math.min(gx0,minX);gy0=Math.min(gy0,minY);gx1=Math.max(gx1,maxX);gy1=Math.max(gy1,maxY);

          }
          let beyondGlyphs=0;
          for(let y=0;y<height;y++)for(let x=0;x<width;x++){
            if(x>=gx0-2&&x<=gx1+2&&y>=gy0-2&&y<=gy1+2)continue;
            const q=(y*width+x)*4;if(distance([rgba[q],rgba[q+1],rgba[q+2]],surfaceSeed)<=24)beyondGlyphs++;
          }
          if(glyphs>=2&&inkPixels>=6&&beyondGlyphs>=Math.max(6,surfaceSamples*0.2)){
            colors.foreground=candidate;colors.background=surfaceSeed;
            colors.stroke=null;colors.outline=null;colors.widthEvidence=null;
            colors.confidence.foreground=0.65;colors.confidence.background=0.5;colors.confidence.stroke=0;
            colors.confidence.reason='observed glyph topology and local contrast distinguish the broader source surface';
          }
        }
      }
      const resolved=resolveSurface(colors);
      return preferredSurfaceKey === null ? aidokuResolveDirectionalStrokeRole(rgba,width,height,resolved) : resolved;
    };
    const aidokuEstimateTextColor = (rgba, width, height) => aidokuEstimateSourceColors(rgba, width, height)?.foreground ?? null;
    const aidokuSourceColorContrast = (color, light, opacity, panel = null) => {
      if (!Array.isArray(color) || color.length !== 3 ||
          !color.every(v => Number.isFinite(v) && v >= 0 && v <= 255) || !Number.isFinite(opacity)) return 0;
      const luminance = rgb => rgb.reduce((sum, v, i) => {
        const s = v / 255, linear = s <= 0.04045 ? s / 12.92 : Math.pow((s + 0.055) / 1.055, 2.4);
        return sum + linear * [0.2126, 0.7152, 0.0722][i];
      }, 0);
      const surface = panel || (light ? [255, 254, 249] : [7, 9, 13]);
      const veil = light ? [255, 255, 255] : [7, 9, 13], alpha = panel ? 0 : (light ? 0.42 : 0.64);
      const text = luminance(color), a = Math.min(1, Math.max(0, opacity));
      // Contrast against the whole possible background-luminance interval,
      // including the existing translucent surface and veil, not just white.
      const backgrounds = [0, 255].map(base => luminance(surface.map((v, i) =>
        veil[i] * alpha + (v * a + base * (1 - a)) * (1 - alpha))));
      if (text >= backgrounds[0] && text <= backgrounds[1]) return 1;
      const contrast = bg => (Math.max(text, bg) + 0.05) / (Math.min(text, bg) + 0.05);
      return Math.min(...backgrounds.map(contrast));
    };
    // A caption is a replacement for the observed surface, not a contrast
    // theme. Never turn a pale balloon black merely because its ink is blue.
    const aidokuCaptionPalette = (sample, ink) => {
      const valid = rgb => Array.isArray(rgb) && rgb.length === 3 &&
        rgb.every(v => Number.isFinite(v) && v >= 0 && v <= 255);
      const observed = valid(sample?.surface?.color) ? sample.surface.color :
        (sample?.confidence?.background >= .5 && valid(sample?.background) ? sample.background : null);
      const background = observed || [242, 240, 235];
      let foreground = valid(ink) ? ink : [17, 18, 23];
      const contrast = rgb => aidokuSourceColorContrast(rgb, true, 1, background);
      if (contrast(foreground) < 4.5) {
        const endpoint = contrast([0,0,0]) >= contrast([255,255,255]) ? 0 : 255;
        let low = 0, high = 1;
        const blend = t => foreground.map(v => Math.round(v + (endpoint-v)*t));
        for (let i=0;i<12;i++) {
          const mid=(low+high)/2;
          if (contrast(blend(mid)) >= 4.5) high=mid; else low=mid;
        }
        foreground = blend(high);
      }
      return {background,foreground,observed:Boolean(observed)};
    };
    const aidokuReadableSourceColor = (color, light, opacity, panel = null) => {
      if (!Array.isArray(color) || color.length !== 3 ||
          !color.every(v => Number.isFinite(v) && v >= 0 && v <= 255)) return null;
      // Preservation means keeping the source ink. The overlay can adjust its
      // surface polarity or add a small contrast outline without recoloring it.
      return color;
    };
    const aidokuPanelForeground = (panel, opacity) => {
      if (!Array.isArray(panel) || panel.length !== 3 ||
          !panel.every(v => Number.isFinite(v) && v >= 0 && v <= 255)) return null;
      const dark = [17, 18, 23], white = [255, 255, 255];
      const darkContrast = aidokuSourceColorContrast(dark, true, opacity, panel);
      const whiteContrast = aidokuSourceColorContrast(white, false, opacity, panel);
      return darkContrast >= whiteContrast ? dark : white;
    };
    // Ink topology can identify a white halo while losing a translucent panel,
    // or mistake connected halos for a white panel. Verify the surface outside
    // the OCR box independently, on both sides of the text. Never borrow one
    // neighbouring artwork patch or change the observed foreground/stroke.
    const aidokuRecoverSourcePanel = (rgba, width, height, inner, result) => {
      // Panel preservation is independent of ink recognition. Low-contrast or
      // merged OCR can lose the foreground while both exterior surfaces agree.
      if (!result || !inner) return result;
      const vertical = inner[3] >= inner[2];
      const sides = [[], []];
      const rows = new Map();
      for (let y = 0; y < height; y++) for (let x = 0; x < width; x++) {
        // Ignore the immediate antialiased halo and the far crop boundary.
        const along = vertical ? y : x, across = vertical ? x : y;
        const start = vertical ? inner[1] : inner[0];
        const end = start + (vertical ? inner[3] : inner[2]);
        const near = vertical ? inner[0] : inner[1];
        const far = near + (vertical ? inner[2] : inner[3]);
        if (along < start || along >= end) continue;
        const side = across >= 1 && across < near - 2 ? 0 :
          across > far + 2 && across < (vertical ? width : height) - 1 ? 1 : -1;
        if (side < 0) continue;
        const p = (y * width + x) * 4;
        if (rgba[p + 3] < 250) return result;
        const rgb = [rgba[p], rgba[p + 1], rgba[p + 2]];
        sides[side].push(rgb);
        if (!rows.has(along)) rows.set(along, [[], []]);
        rows.get(along)[side].push(rgb);
      }
      if (sides.some(side => side.length < 8)) return result;
      const pixels = sides.flat();
      const median = values => values.sort((a,b) => a-b)[Math.floor(values.length / 2)];
      let candidate = [0,1,2].map(c => median(pixels.map(rgb => rgb[c])));
      const distance = (a,b) => Math.max(...a.map((v,c) => Math.abs(v-b[c])));
      const support = sides.map(side => side.filter(rgb => distance(rgb,candidate) <= 18).length / side.length);
      let confidence = Math.min(...support);
      if (confidence < 0.6 || (support[0] + support[1]) / 2 < 0.75) {
        // A translucent balloon may vary along the column. Agreement across
        // the text at the same height still proves a shared backing surface.
        const paired = [];
        for (const row of rows.values()) {
          if (row.some(side => side.length < 2)) continue;
          const rgb = row.map(side => [0,1,2].map(c => median(side.map(p => p[c]))));
          if (distance(rgb[0],rgb[1]) <= 18) paired.push(rgb[0],rgb[1]);
        }
        confidence = paired.length / (rows.size * 2);
        if (confidence < 0.5) return result;
        // Both edges agree, but their brightness varies down a translucent
        // balloon. A median collapses that gradient to its bright half and
        // recreates a white card; average only these corroborated row pairs.
        candidate = [0,1,2].map(c => Math.round(paired.reduce((sum,rgb) => sum+rgb[c],0) / paired.length));
      }
      if (result.background && distance(result.background,candidate) <= 8) return result;
      // A colored backing inside the OCR box may legitimately differ from its
      // exterior. Preserve it unless the observed side surface strongly
      // contradicts it and also dominates the OCR box itself.
      if (result.background && Math.min(...result.background) < 235) {
        const sideSupport = color => Math.min(...sides.map(side =>
          side.filter(rgb => distance(rgb,color) <= 18).length / side.length));
        const innerSupport = color => {
          const x0=Math.max(0,Math.floor(inner[0])),y0=Math.max(0,Math.floor(inner[1]));
          const x1=Math.min(width,Math.ceil(inner[0]+inner[2])),y1=Math.min(height,Math.ceil(inner[1]+inner[3]));
          let matched=0,total=0;
          for(let y=y0;y<y1;y++)for(let x=x0;x<x1;x++){
            const p=(y*width+x)*4,rgb=[rgba[p],rgba[p+1],rgba[p+2]];
            total++;if(distance(rgb,color)<=18)matched++;
          }
          return matched/Math.max(1,total);
        };
        const existingSide=sideSupport(result.background),existingInner=innerSupport(result.background);
        const candidateInner=innerSupport(candidate);
        if (!(confidence >= 0.75 && existingSide <= 0.25 &&
              candidateInner >= Math.max(0.25, existingInner + 0.15))) return result;
      }
      return {...result, background:candidate, confidence:{...result.confidence,
        background:confidence, panelReason:'matching observed surfaces on opposite sides of OCR'}};
    };
    // Recover only repeated colored interiors enclosed by observed white ink.
    const aidokuRecoverOutlinedColor = (rgba,w,h,result) => {
     if(result?.foreground && (result.confidence?.foreground||0)>=.6)return null;
     const n=w*h;
     if(!Number.isInteger(w)||!Number.isInteger(h)||w<8||h<8||n>24576||!rgba||rgba.length!==n*4)return null;
     for(let i=3;i<rgba.length;i+=4)if(rgba[i]<250)return null;
     const seen=new Uint8Array(n),queue=new Int32Array(n),groups=[];
     const white=i=>Math.min(rgba[4*i],rgba[4*i+1],rgba[4*i+2])>=230;
     const distance=(a,b)=>Math.max(...a.map((v,c)=>Math.abs(v-b[c])));
     for(let s=0;s<n;s++){
      if(seen[s]||white(s))continue;
      let head=0,tail=1,edge=false,x0=w,y0=h,x1=0,y1=0;seen[s]=1;queue[0]=s;
      while(head<tail){const i=queue[head++],x=i%w,y=i/w|0;x0=Math.min(x0,x);y0=Math.min(y0,y);x1=Math.max(x1,x);y1=Math.max(y1,y);edge||=!x||!y||x===w-1||y===h-1;
       for(const j of [x?i-1:-1,x+1<w?i+1:-1,y?i-w:-1,y+1<h?i+w:-1])if(j>=0&&!seen[j]&&!white(j)){seen[j]=1;queue[tail++]=j;}
      }
      if(edge||tail<3||tail>n*.12||x1-x0>w*.75||y1-y0>h*.4||
      (tail>12&&tail/((x1-x0+1)*(y1-y0+1))>.9))continue;
      const bins=new Map(),edgeSum=[0,0,0];let edgeCount=0;
      for(let k=0;k<tail;k++){const i=queue[k],rgb=[rgba[4*i],rgba[4*i+1],rgba[4*i+2]];
       const x=i%w,y=i/w|0;
       for(const j of [x?i-1:-1,x+1<w?i+1:-1,y?i-w:-1,y+1<h?i+w:-1])if(j>=0&&white(j)){edgeCount++;for(let c=0;c<3;c++)edgeSum[c]+=rgba[4*j+c];}
       if(Math.max(...rgb)-Math.min(...rgb)<40)continue;
       const key=rgb.map(v=>v>>4).join(',');let b=bins.get(key);if(!b){b={count:0,sum:[0,0,0]};bins.set(key,b);}b.count++;rgb.forEach((v,c)=>b.sum[c]+=v);
      }
      const top=[...bins.values()].sort((a,b)=>b.count-a.count)[0];if(!top||top.count<2||top.count<tail*.15)continue;
      const rgb=top.sum.map(v=>v/top.count);
      if(result?.background&&distance(rgb,result.background)<48)continue;
      if(edgeCount>=4)groups.push({rgb,count:top.count,stroke:edgeSum.map(v=>v/edgeCount)});
      if(groups.length>=128)return null;
     }
     let best=[];for(const g of groups){const same=groups.filter(v=>distance(v.rgb,g.rgb)<=28);if(same.length>best.length)best=same;}
     if(best.length<3||best.length<groups.length*.8)return null;
     const count=best.reduce((s,g)=>s+g.count,0),foreground=[0,1,2].map(c=>Math.round(best.reduce((s,g)=>s+g.rgb[c]*g.count,0)/count));
     return {foreground,stroke:[0,1,2].map(c=>Math.round(best.reduce((s,g)=>s+g.stroke[c]*g.count,0)/count)),confidence:.75,components:best.length};
    };
    // A non-flat illustration has no single validated panel RGB. Retain an
    // observed, low-frequency surface for display only; it must never become
    // evidence for erasing source ink or accepting a flat-panel restoration.
    const aidokuObservedSourceSurface = (rgba, w, h, inner, palette) => {
      if (!Array.isArray(inner) || inner.length!==4 || !inner.every(Number.isFinite) || inner[2]<=0 || inner[3]<=0 ||
          !Number.isInteger(w) || !Number.isInteger(h) || w<1 || h<1 || !rgba || rgba.length !== w*h*4 || w*h > 24576) return null;
      const vertical = inner[3] >= inner[2], bands = Array.from({length:6}, () => []);
      const distance = (a,b) => Math.max(...a.map((v,c) => Math.abs(v-b[c])));
      for (let y=0;y<h;y++) for (let x=0;x<w;x++) {
        const p=(y*w+x)*4;
        if (rgba[p+3] < 250) return null;
        const along=vertical?y:x, across=vertical?x:y;
        const start=vertical?inner[1]:inner[0], length=vertical?inner[3]:inner[2];
        const near=vertical?inner[0]:inner[1], far=near+(vertical?inner[2]:inner[3]);
        if (along<start || along>=start+length || (across>=near-1 && across<=far+1)) continue;
        const rgb=[rgba[p],rgba[p+1],rgba[p+2]];
        if ([palette?.foreground,palette?.stroke].some(color => color && distance(rgb,color)<28)) continue;
        bands[Math.min(5,Math.floor((along-start)*6/length))].push(rgb);
      }
      const median = values => values.sort((a,b)=>a-b)[Math.floor(values.length/2)];
      const stops = bands.map(values => values.length>=4 ? [0,1,2].map(c=>median(values.map(v=>v[c]))) : null);
      if (stops.filter(Boolean).length<3) return null;
      const observed=stops.filter(Boolean),color=[0,1,2].map(c=>median(observed.map(v=>v[c])));
      for(let i=0;i<stops.length;i++) if(!stops[i]) {
        let nearest=0;
        for(let j=0;j<stops.length;j++) if(stops[j] && (!stops[nearest] || Math.abs(j-i)<Math.abs(nearest-i)))nearest=j;
        stops[i]=stops[nearest];
      }
      return {color,stops,vertical};
    };
    const aidokuSourceSurfaceSeed = (rgba, width, height, inner) => {
      if (!Array.isArray(inner) || inner.length !== 4 || !inner.every(Number.isFinite) ||
          !Number.isInteger(width) || !Number.isInteger(height) || width < 4 || height < 4 ||
          !rgba || rgba.length !== width * height * 4 || width * height > 24576) return null;
      const x0=Math.max(0,Math.floor(inner[0])),y0=Math.max(0,Math.floor(inner[1]));
      const x1=Math.min(width,Math.ceil(inner[0]+inner[2])),y1=Math.min(height,Math.ceil(inner[1]+inner[3]));
      if(x1-x0<4||y1-y0<4)return null;
      const ring=Math.max(1,Math.min(4,Math.ceil(Math.min(x1-x0,y1-y0)*0.12)));
      const bins=new Map(),sideBins=Array.from({length:4},()=>new Map()),sideTotals=[0,0,0,0];
      let samples=0;
      const addSide=(side,key)=>{sideTotals[side]++;const map=sideBins[side];map.set(key,(map.get(key)||0)+1);};
      for(let y=y0;y<y1;y++)for(let x=x0;x<x1;x++){
        const left=x<x0+ring,right=x>=x1-ring,top=y<y0+ring,bottom=y>=y1-ring;
        if(!left&&!right&&!top&&!bottom)continue;
        const p=(y*width+x)*4;if(rgba[p+3]<250)return null;
        const key=(rgba[p]>>4)*256+(rgba[p+1]>>4)*16+(rgba[p+2]>>4);
        let bin=bins.get(key);if(!bin){bin=[0,0,0,0];bins.set(key,bin);}
        bin[0]++;bin[1]+=rgba[p];bin[2]+=rgba[p+1];bin[3]+=rgba[p+2];samples++;
        if(left)addSide(0,key);if(right)addSide(1,key);if(top)addSide(2,key);if(bottom)addSide(3,key);
      }
      let key=null,bin=null;
      for(const [candidate,value] of bins)if(!bin||value[0]>bin[0]){key=candidate;bin=value;}
      if(!bin||bin[0]<Math.max(6,samples*0.38))return null;
      const agreeingSides=sideBins.reduce((count,map,index)=>count+
        (sideTotals[index]>=2&&(map.get(key)||0)/sideTotals[index]>=0.35?1:0),0);
      if(agreeingSides<2)return null;
      const color=[Math.round(bin[1]/bin[0]),Math.round(bin[2]/bin[0]),Math.round(bin[3]/bin[0])];
      const confidence=Math.min(0.9,Math.max(bin[0]/samples,agreeingSides>=3?0.7:0.55));
      return {key,color,confidence};
    };
    const aidokuSourceColorSampler = (image, enabled, phase = 'ocr', budget = {pixels:393216, detailPixels:98304}) => {
      const stats = {pixels: 0, hits: 0, samples: 0, milliseconds: 0};
      if (!enabled || !image?.complete || !image.naturalWidth) return {sample: () => null, stats};
      // Image-object identity invalidates estimates when the page or split crop changes.
      // OCR and translated text each sample the original image once. Revisions
      // within the same phase reuse their own palette, without sampling overlays.
      const caches = phase === 'translation'
        ? (globalThis.__aidokuTranslatedSourceTextColorsV12 ||= new WeakMap())
        : (globalThis.__aidokuSourceTextColorsV12 ||= new WeakMap());
      let cache = caches.get(image);
      if (!cache) { cache = new Map(); caches.set(image, cache); }
      let canvas, context, unavailable = false;
      return {stats, sample: bounds => {
        if (unavailable || !Array.isArray(bounds) || bounds.length !== 4 || !bounds.every(Number.isFinite) ||
            bounds[0] < 0 || bounds[1] < 0 || bounds[2] <= 0 || bounds[3] <= 0 ||
            bounds[0] + bounds[2] > 1.000001 || bounds[1] + bounds[3] > 1.000001) return null;
        const key = bounds.join(',');
        if (cache.has(key)) { stats.hits++; return cache.get(key); }
        const iw = image.naturalWidth, ih = image.naturalHeight;
        // Tight OCR boxes can end inside a white glyph outline. Two source
        // pixels then sample the halo as the panel, especially after reduction.
        // Include half a glyph width of surrounding surface, with a small cap
        // so neighbouring balloons/art cannot dominate the sample.
        const verticalColumn = bounds[3] * ih >= bounds[2] * iw * 1.5;
        const margin = verticalColumn ? Math.max(4, Math.min(16, Math.ceil(bounds[2] * iw * 0.5))) : 8;
        const x = Math.max(0, Math.floor(bounds[0] * iw) - margin);
        const y = Math.max(0, Math.floor(bounds[1] * ih) - margin);
        const sw = Math.min(iw, Math.ceil((bounds[0] + bounds[2]) * iw) + margin) - x;
        const sh = Math.min(ih, Math.ceil((bounds[1] + bounds[3]) * ih) + margin) - y;
        const scale = Math.min(1, (verticalColumn ? 256 : 192) / Math.max(sw, sh), Math.sqrt(24576 / (sw * sh)));
        const w = Math.max(1, Math.floor(sw * scale)), h = Math.max(1, Math.floor(sh * scale));
        if (w * h > budget.pixels) return null;
        budget.pixels -= w * h; stats.pixels += w * h; stats.samples++;
        let result = null;
        const started = performance.now();
        try {
          if (!canvas) { canvas = document.createElement('canvas'); context = canvas.getContext('2d', {willReadFrequently: true}); }
          if (!context) { unavailable = true; return null; }
          canvas.width = w; canvas.height = h;
          context.drawImage(image, x, y, sw, sh, 0, 0, w, h);
          const rgba = context.getImageData(0, 0, w, h).data;
          const inner=[(bounds[0]*iw-x)*w/sw, (bounds[1]*ih-y)*h/sh,
            bounds[2]*iw*w/sw, bounds[3]*ih*h/sh];
          const surfaceSeed=aidokuSourceSurfaceSeed(rgba,w,h,inner);
          result = aidokuEstimateSourceColors(rgba, w, h, surfaceSeed?.key ?? null, surfaceSeed?.color ?? null,
            inner, Boolean(surfaceSeed));
          if(result&&surfaceSeed&&Array.isArray(result.background)){
            const delta=Math.max(...result.background.map((v,c)=>Math.abs(v-surfaceSeed.color[c])));
            if(delta<=24){
              result.background=surfaceSeed.color;
              result.confidence.background=Math.max(result.confidence?.background||0,surfaceSeed.confidence);
              result.confidence.panelReason='dominant observed surface on OCR-box perimeter';
            }
          }
          result = aidokuRecoverSourcePanel(rgba, w, h, inner, result);
          if (result?.widthEvidence) result.widthEvidence.sampleScale = scale;
          // Long columns can downsample a colored fill into its white outline.
          // Retry at most three small native-detail strips, sharing the original
          // per-page pixel budget. Require independent agreeing observations.
          if (verticalColumn && scale<.65 && (!result?.foreground || result.confidence?.foreground<.6)) {
            const candidates=[];
            for(const fraction of [0,.5,1]) {
              const stripHeight=Math.min(sh,192),stripY=y+fraction*(sh-stripHeight);
              const stripScale=Math.min(1,Math.sqrt(24576/(sw*stripHeight)));
              const cw=Math.floor(sw*stripScale),ch=Math.floor(stripHeight*stripScale),pixels=cw*ch;
              if(cw<8 || ch<8 || pixels>budget.pixels || pixels>budget.detailPixels)break;
              budget.pixels-=pixels;budget.detailPixels-=pixels;stats.pixels+=pixels;
              canvas.width=cw;canvas.height=ch;
              context.drawImage(image,x,stripY,sw,stripHeight,0,0,cw,ch);
              const candidate=aidokuRecoverOutlinedColor(context.getImageData(0,0,cw,ch).data,cw,ch,result);
              if(candidate)candidates.push(candidate);
              if(candidates.length>=2 && Math.max(...candidates[0].foreground.map((v,i)=>
                Math.abs(v-candidates[candidates.length-1].foreground[i])))<=28)break;
            }
            const agreeing=candidates.filter(c=>candidates.filter(other=>
              Math.max(...c.foreground.map((v,i)=>Math.abs(v-other.foreground[i])))<=28).length>=2);
            if(agreeing.length>=2) {
              const average=key=>[0,1,2].map(c=>Math.round(agreeing.reduce((sum,v)=>sum+v[key][c],0)/agreeing.length));
              result={...result,foreground:average('foreground'),stroke:average('stroke'),outline:average('stroke'),
                confidence:{...result?.confidence,foreground:.75,stroke:.75,
                  reason:'matching colored glyph interiors inside observed white outlines in independent strips'}};
            }
          }
          if (result) {
            // Bright glyph halos can look like a confident white background.
            // Observe the exterior independently before accepting that white.
            const surface=aidokuObservedSourceSurface(rgba,w,h,
              [(bounds[0]*iw-x)*w/sw,(bounds[1]*ih-y)*h/sh,bounds[2]*iw*w/sw,bounds[3]*ih*h/sh],result);
            if(surface && (!result.background || result.confidence?.background<.5 ||
                (Math.min(...result.background)>=230 && Math.max(...surface.color)-Math.min(...surface.color)<35)))
              result.surface=surface;
          }
        } catch (_) { unavailable = true; }
        finally { stats.milliseconds += performance.now() - started; }
        if (cache.size >= 256) cache.delete(cache.keys().next().value);
        cache.set(key, result);
        return result;
      }};
    };

    """
}
