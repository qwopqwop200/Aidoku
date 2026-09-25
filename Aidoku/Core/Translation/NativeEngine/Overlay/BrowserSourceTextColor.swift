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
    const aidokuEstimateSourceColors = (rgba, width, height, preferredSurfaceKey = null, exteriorSurface = null,
        inkSeed = null, minimumInkDistance = 60) => {
      const count = width * height;
      if (!Number.isInteger(width) || !Number.isInteger(height) || width < 8 || height < 8 ||
          count > 24576 || !rgba || rgba.length !== count * 4) return null;
      const distance = (a, b) => Math.max(Math.abs(a[0] - b[0]), Math.abs(a[1] - b[1]), Math.abs(a[2] - b[2]));
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
        }
        if (backgroundDistance(bin) >= minimumInkDistance) {
          candidateCount += bin[0];
          if (!winner || bin[0] > winner[0]) winner = bin;
        }
      }
      const colors = {foreground: null, background: background.map(Math.round), stroke: null, outline: null,
        widthEvidence: null, confidence: {foreground: 0, background: Math.min(1, solidRim / rimCount), stroke: 0,
          reason: 'dominant observed rim; no validated glyph yet'}};
      const resolveSurface = result => {
        // A dark border or unrelated colored art can contaminate the distant
        // tail before component validation rejects it. Retry actual observed
        // color modes independently; never average different ink hues together.
        // A seeded pass cannot recurse: at most four retries per surface,
        // for the original rim and the single competing interior surface.
        if (inkSeed !== null) return result;
        // Uncertain nested panels/gradients need surface topology first. Ink
        // retries are safe only against a broadly supported observed backing.
        if (!result.foreground && solidCount >= count * 0.5 && solidRim >= rimCount * 0.5) {
          const stableSurface = solidRim >= rimCount * 0.75 && solidCount >= count * 0.5;
          const modes = [...bins.values()].filter(bin => bin[0] >= Math.max(3, count * 0.0005) &&
            backgroundDistance(bin) >= (stableSurface ? 24 : 60)).sort((a, b) => b[0] - a[0]).slice(0, 32);
          const seeds = [];
          for (const mode of modes) {
            let seed = mean(mode);
            const vector = seed.map((v, c) => v - background[c]);
            const squared = vector.reduce((sum, v) => sum + v * v, 0);
            // Recover the solid end of this mode's antialias ramp without
            // admitting a distant color on a different background/ink axis.
            for (const bin of modes) {
              const rgb = mean(bin), delta = rgb.map((v, c) => v - background[c]);
              const t = delta.reduce((sum, v, c) => sum + v * vector[c], 0) / squared;
              if (t >= 1 && bin[0] >= Math.max(3, mode[0] * 0.05) &&
                  Math.max(...delta.map((v, c) => Math.abs(v - t * vector[c]))) <= 12 &&
                  distance(rgb, background) > distance(seed, background)) seed = rgb;
            }
            if (seeds.some(previous => distance(previous, seed) < 24)) continue;
            seeds.push(seed);
            // Only a stable surface allows faint ink. Repeated validated glyphs
            // are still required; relaxing RGB separation alone is not evidence.
            const threshold = distance(seed, background) < 60 ? 24 : 60;
            const candidate = aidokuEstimateSourceColors(rgba, width, height,
              preferredSurfaceKey, exteriorSurface, seed, threshold);
            // An independent backing may have been mistaken for an outer
            // stroke. Let surface competition re-evaluate that topology;
            // accepting its ink here can return an outline as the glyph fill.
            if (candidate?.foreground && candidate.confidence.foreground >= 0.6 &&
                (!candidate.background || distance(candidate.background, background) <= 32)) {
              candidate.confidence.reason = 'independent observed ink mode; ' + candidate.confidence.reason;
              return candidate;
            }
            if (seeds.length >= 4) break;
          }
        }
        if (preferredSurfaceKey !== null || result.foreground) return result;
        let dominantKey = null;
        for (const [key, bin] of bins) {
          if (backgroundDistance(bin) >= 60 && (dominantKey === null || bin[0] > bins.get(dominantKey)[0])) dominantKey = key;
        }
        if (dominantKey === null) return result;
        const competing = aidokuEstimateSourceColors(rgba, width, height, dominantKey, background);
        if (!competing?.foreground) return result;
        if (competing.background && distance(competing.background, mean(bins.get(dominantKey))) > 32) return result;
        competing.confidence.reason = 'competing interior surface with validated ink; ' + competing.confidence.reason;
        return competing;
      };
      // A uniform background must dominate both the crop and its perimeter.
      if (!winner || candidateCount < Math.max(6, count * 0.004)) return resolveSurface(colors);
      // Antialiasing blends ink toward the background. Use the distant tail
      // rather than the most frequent gray edge as the ink-color seed.
      const inkBins = [...bins.values()].filter(bin => backgroundDistance(bin) >= minimumInkDistance)
        .sort((a, b) => backgroundDistance(b) - backgroundDistance(a));
      const tailTarget = Math.max(6, candidateCount * 0.12), tailSum = [0, 0, 0];
      let tailCount = 0;
      for (const bin of inkBins) {
        const take = Math.min(bin[0], tailTarget - tailCount), rgb = mean(bin);
        for (let c = 0; c < 3; c++) tailSum[c] += rgb[c] * take;
        tailCount += take;
        if (tailCount >= tailTarget) break;
      }
      const seedColor = inkSeed || tailSum.map(v => v / tailCount);
      const direction = seedColor.map((v, c) => v - background[c]);
      const lengthSquared = direction.reduce((sum, v) => sum + v * v, 0);
      const mask = new Uint8Array(count), core = new Uint8Array(count);
      let selected = 0, aligned = 0;
      // Identical neutral RGB values have identical classification within this crop.
      // Cache the exact result, not a quantized color or relaxed decision boundary.
      const grayClassification = new Uint8Array(256);
      const classifyRGB = (red, green, blue) => {
        const r = red - background[0], g = green - background[1], b = blue - background[2];
        if (Math.max(Math.abs(r), Math.abs(g), Math.abs(b)) < minimumInkDistance) return 1;
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
        if (flag < 2) continue;
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
            (minimumInkDistance < 60 && Math.max(boxWidth, boxHeight) < 5) ||
            ((tail > 12 || minimumInkDistance < 60) && tail / (boxWidth * boxHeight) > 0.9)) continue;
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
      let broadlySupportedSurface = false;
      if (preferredSurfaceKey !== null) {
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
    const aidokuSourceColorLuminance = rgb => rgb.reduce((sum, v, i) => {
      const s = v / 255, linear = s <= 0.04045 ? s / 12.92 : Math.pow((s + 0.055) / 1.055, 2.4);
      return sum + linear * [0.2126, 0.7152, 0.0722][i];
    }, 0);
    const aidokuLuminanceContrast = (text, low, high) => {
      if (text >= low && text <= high) return 1;
      const contrast = bg => (Math.max(text, bg) + 0.05) / (Math.min(text, bg) + 0.05);
      return Math.min(contrast(low), contrast(high));
    };
    const aidokuSourceColorContrast = (color, light, opacity, panel = null) => {
      if (!Array.isArray(color) || color.length !== 3 ||
          !color.every(v => Number.isFinite(v) && v >= 0 && v <= 255) || !Number.isFinite(opacity)) return 0;
      const surface = panel || (light ? [255, 254, 249] : [7, 9, 13]);
      const veil = light ? [255, 255, 255] : [7, 9, 13], alpha = panel ? 0 : (light ? 0.42 : 0.64);
      const text = aidokuSourceColorLuminance(color), a = Math.min(1, Math.max(0, opacity));
      // Contrast against the whole possible background-luminance interval,
      // including the existing translucent surface and veil, not just white.
      const backgrounds = [0, 255].map(base => aidokuSourceColorLuminance(surface.map((v, i) =>
        veil[i] * alpha + (v * a + base * (1 - a)) * (1 - alpha))));
      return aidokuLuminanceContrast(text, backgrounds[0], backgrounds[1]);
    };
    // Keep an already readable color. Otherwise make the smallest luminance
    // correction toward black/white instead of surrounding it with a harsh ring.
    const aidokuAdjustInkForContrast = (color, contrast) => {
      if (contrast(color) >= 4.5) return [...color];
      // Both directions can satisfy the target on a middle-tone surface.
      // Select the smallest RGB correction, not the endpoint with the highest
      // possible contrast: the latter unnecessarily destroys pale source ink.
      const candidates=[];
      for(const endpoint of [0,255]){
        if(contrast([endpoint,endpoint,endpoint])<4.5)continue;
        let low=0,high=1;
        const blend=t=>color.map(v=>Math.round(v+(endpoint-v)*t));
        for(let i=0;i<12;i++){
          const mid=(low+high)/2;
          if(contrast(blend(mid))>=4.5)high=mid;else low=mid;
        }
        const rgb=blend(high);
        candidates.push({rgb,distance:rgb.reduce((sum,v,i)=>sum+(v-color[i])**2,0)});
      }
      if(candidates.length)return candidates.sort((a,b)=>a.distance-b.distance)[0].rgb;
      // A high-variation surface may have no feasible fill. The caller retains
      // its plate in this case; do not claim that an extreme solved contrast.
      return contrast([0,0,0])>=contrast([255,255,255])?[0,0,0]:[255,255,255];
    };
    // A verified source outline can retain the original fill without a large
    // backing plate. The caller must first inspect the entire expanded glyph
    // footprint, including this outline, for safe restored background pixels.
    // This helper is display-only and never changes the source erasure palette.
    const aidokuReadableSourceOutline = (sample, ink, range, fontSize) => {
      const valid=rgb=>Array.isArray(rgb)&&rgb.length===3&&rgb.every(v=>Number.isFinite(v)&&v>=0&&v<=255);
      if(!valid(ink)||!valid(sample?.stroke)||(sample?.confidence?.stroke||0)<.55||
          !Array.isArray(range)||range.length!==2||!range.every(Number.isFinite)||
          range[0]<0||range[1]>1||range[0]>range[1]||!Number.isFinite(fontSize)||fontSize<12)return null;
      const stroke=sample.stroke;
      const contrast=rgb=>aidokuLuminanceContrast(aidokuSourceColorLuminance(rgb),...range);
      if(contrast(ink)>=4.5)return null;
      const pair=aidokuSourceColorContrast(ink,true,1,stroke),edge=contrast(stroke);
      if(pair<4.5||edge<4.5)return null;
      const width=Math.min(1.15,fontSize*.035);
      // paint-order:stroke fill preserves the glyph's inner counters. The CSS
      // stroke straddles its path, so the external expansion is width / 2.
      return {foreground:[...ink],stroke:[...stroke],width,
        expansion:width/2,minimumContrast:Math.min(pair,edge)};
    };
    // Outline-free display keeps chromatic source ink. For white lettering
    // defined by a colored outline, flatten the observed outline into the fill
    // instead of inventing gray ink. Sampling roles remain unchanged.
    const aidokuSourceDisplayInk = sample => {
      const valid=rgb=>Array.isArray(rgb)&&rgb.length===3&&rgb.every(v=>Number.isFinite(v)&&v>=0&&v<=255);
      if(valid(sample?.displayEvidence?.color))return [...sample.displayEvidence.color];
      if(valid(sample?.lettering?.color))return [...sample.lettering.color];
      const fg=sample?.foreground,stroke=sample?.stroke;
      if(!valid(fg))return valid(sample?.displayForeground)?[...sample.displayForeground]:null;
      const background=valid(sample?.surface?.color)?sample.surface.color:
        valid(sample?.background)?sample.background:null;
      if(Math.min(...fg)>=225 && valid(stroke) && (sample.confidence?.stroke||0)>=.55 &&
          Math.max(...stroke)-Math.min(...stroke)>=40 && background &&
          aidokuSourceColorContrast(stroke,true,1,background)>
            aidokuSourceColorContrast(fg,true,1,background)) return [...stroke];
      return [...fg];
    };
    // The background remains an observed surface, not an inverted contrast theme.
    const aidokuCaptionPalette = (sample, ink, preserveSourceTextColor = false) => {
      const valid = rgb => Array.isArray(rgb) && rgb.length === 3 &&
        rgb.every(v => Number.isFinite(v) && v >= 0 && v <= 255);
      const observed = valid(sample?.captionBackground) ? sample.captionBackground :
        valid(sample?.surface?.color) ? sample.surface.color :
        (valid(sample?.background) ? sample.background : null);
      const background = observed || [242, 240, 235];
      const preserved = preserveSourceTextColor && Boolean(aidokuSourceDisplayInk(sample));
      const inkColor = preserved ? aidokuSourceDisplayInk(sample) : valid(ink) ? ink : [17,18,23];
      const foreground = preserved ? inkColor :
        aidokuAdjustInkForContrast(inkColor, rgb => aidokuSourceColorContrast(rgb, true, 1, background));
      return {background,foreground,observed:Boolean(observed),preserved};
    };
    const aidokuReadableSourceColor = (color, light, opacity, panel = null) => {
      if (!Array.isArray(color) || color.length !== 3 ||
          !color.every(v => Number.isFinite(v) && v >= 0 && v <= 255)) return null;
      return [...color];
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
      // Only correct missing surfaces or bright halos, not intentional coloured
      // text backing whose exterior can legitimately be another colour.
      if (result.background && Math.min(...result.background) < 235) return result;
      return {...result, background:candidate, confidence:{...result.confidence,
        background:confidence, panelReason:'matching observed surfaces on opposite sides of OCR'}};
    };
    // Recover only repeated colored interiors enclosed by observed white ink.
    const aidokuRecoverOutlinedColor = (rgba,w,h,result,allowDark=false) => {
     if(!allowDark && result?.foreground && (result.confidence?.foreground||0)>=.6)return null;
     const n=w*h;
     if(!Number.isInteger(w)||!Number.isInteger(h)||w<8||h<8||n>24576||!rgba||rgba.length!==n*4)return null;
     for(let i=3;i<rgba.length;i+=4)if(rgba[i]<250)return null;
     if(allowDark&&w>h){
       const transposed=new Uint8ClampedArray(rgba.length);
       for(let y=0;y<h;y++)for(let x=0;x<w;x++)
         for(let c=0;c<4;c++)transposed[(x*h+y)*4+c]=rgba[(y*w+x)*4+c];
       rgba=transposed;[w,h]=[h,w];
     }
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
       if(Math.max(...rgb)-Math.min(...rgb)<40 && !(allowDark&&Math.max(...rgb)<80))continue;
       const key=rgb.map(v=>v>>4).join(',');let b=bins.get(key);if(!b){b={count:0,sum:[0,0,0]};bins.set(key,b);}b.count++;rgb.forEach((v,c)=>b.sum[c]+=v);
      }
      const top=[...bins.values()].sort((a,b)=>b.count-a.count)[0];if(!top||top.count<2||top.count<tail*.15)continue;
      const rgb=top.sum.map(v=>v/top.count);
      if(result?.background&&distance(rgb,result.background)<48)continue;
      if(edgeCount>=4)groups.push({rgb,count:top.count,stroke:edgeSum.map(v=>v/edgeCount)});
      if(groups.length>=128)return null;
     }
     let best=[];for(const g of groups){const same=groups.filter(v=>distance(v.rgb,g.rgb)<=28);if(same.length>best.length)best=same;}
     if(best.length<3)return null;
     if(allowDark){
       if(best.reduce((n,g)=>n+g.count,0)<groups.reduce((n,g)=>n+g.count,0)*.6)return null;
     }else if(best.length<groups.length*.8)return null;
     const count=best.reduce((s,g)=>s+g.count,0),foreground=[0,1,2].map(c=>Math.round(best.reduce((s,g)=>s+g.rgb[c]*g.count,0)/count));
     return {foreground,stroke:[0,1,2].map(c=>Math.round(best.reduce((s,g)=>s+g.stroke[c]*g.count,0)/count)),confidence:.75,components:best.length,fillPixels:count};
    };
    // A non-flat illustration has no single validated panel RGB. Retain an
    // observed, low-frequency surface for display only; it must never become
    // evidence for erasing source ink or accepting a flat-panel restoration.
    const aidokuObservedSourceSurface = (rgba, w, h, inner, palette) => {
      if (!Array.isArray(inner) || inner.length!==4 || !inner.every(Number.isFinite) || inner[2]<=0 || inner[3]<=0 ||
          !Number.isInteger(w) || !Number.isInteger(h) || w<1 || h<1 || !rgba || rgba.length !== w*h*4 || w*h > 24576) return null;
      const vertical = inner[3] >= inner[2], bands = Array.from({length:6}, () => [[], []]);
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
        const side = across < near - 1 ? 0 : 1;
        bands[Math.min(5,Math.floor((along-start)*6/length))][side].push(rgb);
      }
      const median = values => values.sort((a,b)=>a-b)[Math.floor(values.length/2)];
      // Opposite sides must corroborate the surface. Pooling both sides makes
      // a one-pixel crop imbalance choose unrelated artwork as the panel color.
      const stops = bands.map(sides => {
        if (sides.some(values => values.length < 4)) return null;
        const colors = sides.map(values => [0,1,2].map(c => median(values.map(v => v[c]))));
        if (distance(colors[0], colors[1]) > 18) return null;
        if (sides.some((values, side) =>
            values.filter(rgb => distance(rgb, colors[side]) <= 18).length < values.length * 0.6)) return null;
        return colors[0].map((v, c) => Math.round((v + colors[1][c]) / 2));
      });
      if (stops.filter(Boolean).length<3) return null;
      const observed=stops.filter(Boolean),color=[0,1,2].map(c=>median(observed.map(v=>v[c])));
      for(let i=0;i<stops.length;i++) if(!stops[i]) {
        let nearest=0;
        for(let j=0;j<stops.length;j++) if(stops[j] && (!stops[nearest] || Math.abs(j-i)<Math.abs(nearest-i)))nearest=j;
        stops[i]=stops[nearest];
      }
      return {color,stops,vertical};
    };
    // Display-only estimate: an uncertain surface still needs an observed color.
    // Do not confuse glyph-validation confidence with permission to paint a box.
    const aidokuObservedCaptionPalette = (rgba,w,h,inner,result) => {
      if(!rgba||rgba.length!==w*h*4||!Array.isArray(inner))return result;
      const bins=new Map(),distance=(a,b)=>Math.max(...a.map((v,c)=>Math.abs(v-b[c])));
      const valid=c=>Array.isArray(c)&&c.length===3&&c.every(Number.isFinite);
      let insideCount=0,outsideCount=0;
      for(let y=0;y<h;y++)for(let x=0;x<w;x++){
        const p=(y*w+x)*4;if(rgba[p+3]<128)continue;
        const rgb=[rgba[p],rgba[p+1],rgba[p+2]],key=rgb.map(v=>v>>5).join(',');
        let bin=bins.get(key);if(!bin){bin={count:0,inside:0,outside:0,sum:[0,0,0]};bins.set(key,bin);}
        const inside=x>=inner[0]&&y>=inner[1]&&x<inner[0]+inner[2]&&y<inner[1]+inner[3];
        bin.count++;bin[inside?'inside':'outside']++;if(inside)insideCount++;else outsideCount++;
        for(let c=0;c<3;c++)bin.sum[c]+=rgb[c];
      }
      const modes=[...bins.values()].map(b=>({...b,rgb:b.sum.map(v=>Math.round(v/b.count))}));
      if(!modes.length)return result;
      const ink=result?.foreground||result?.displayForeground,stroke=result?.stroke;
      const surface=result?.surface?.color||result?.background;
      const bright=c=>valid(c)&&Math.min(...c)>=230;
      const exteriorSupport=c=>modes.reduce((n,b)=>n+(distance(b.rgb,c)<=32?b.outside:0),0)/Math.max(1,outsideCount);
      // White glyph halos have interior support, but are not exposed backing.
      const haloSurface=bright(surface)&&(result?.confidence?.background||0)<.5&&exteriorSupport(surface)<.25;
      const supported=!haloSurface&&valid(surface)&&modes.reduce((n,b)=>n+(distance(b.rgb,surface)<=32?b.inside:0),0)>=Math.max(1,insideCount*.08);
      if(supported)return result;
      const candidates=modes.filter(b=>(!haloSurface||!bright(b.rgb)||exteriorSupport(b.rgb)>=.25)&&(!valid(ink)||distance(b.rgb,ink)>32)&&(!valid(stroke)||distance(b.rgb,stroke)>32));
      // With known ink/halo roles, observe the exposed surface around them.
      // Otherwise use the interior: an outer page margin is not a label's panel.
      const score=b=>valid(ink)?b.outside+b.inside*.25:b.inside;
      const ranked=(candidates.length?candidates:modes).sort((a,b)=>score(b)-score(a)||b.count-a.count);
      const background=ranked[0].rgb;
      let displayForeground=result?.displayForeground;
      if(!valid(ink)){
        const foreground=modes.filter(b=>b.inside>=Math.max(2,insideCount*.02)&&distance(b.rgb,background)>=48)
          .sort((a,b)=>b.inside-a.inside)[0];
        if(foreground)displayForeground=foreground.rgb;
      }
      return {...result,background,surface:null,displayForeground,
        observedBackground:true,confidence:{...result?.confidence,background:0,
          panelReason:'best available observed pixels; display only, no erasure'}};
    };
    // Estimate a single opaque caption from the exposed interior, not the
    // brightest histogram mode. Remove ink and its immediate halo locally;
    // globally rejecting white would also reject genuine white balloon paper.
    // This is display-only evidence and never authorizes source restoration.
    const aidokuInteriorCaptionSurface = (rgba,w,h,inner,result) => {
      const backing=result?.surface?.color||result?.background;
      const ink=result?.foreground||result?.displayForeground;
      if(!backing||!ink||Math.min(...backing)<225||Math.min(...ink)>=220)return result;
      const distance=(a,b)=>Math.max(...a.map((v,c)=>Math.abs(v-b[c])));
      const mask=new Uint8Array(w*h),radius=2;
      for(let y=0;y<h;y++)for(let x=0;x<w;x++) {
        const p=(y*w+x)*4;
        if(rgba[p+3]<250||distance([rgba[p],rgba[p+1],rgba[p+2]],ink)>40)continue;
        for(let yy=Math.max(0,y-radius);yy<=Math.min(h-1,y+radius);yy++)
          for(let xx=Math.max(0,x-radius);xx<=Math.min(w-1,x+radius);xx++)mask[yy*w+xx]=1;
      }
      const pixels=[];let total=0;
      for(let y=Math.max(0,Math.ceil(inner[1]));y<Math.min(h,inner[1]+inner[3]);y++)
        for(let x=Math.max(0,Math.ceil(inner[0]));x<Math.min(w,inner[0]+inner[2]);x++) {
          total++;const i=y*w+x,p=i*4;
          if(mask[i]||rgba[p+3]<250)continue;
          pixels.push([rgba[p],rgba[p+1],rgba[p+2]]);
        }
      if(pixels.length<32||pixels.length<total*.35)return result;
      pixels.sort((a,b)=>a[0]+a[1]+a[2]-b[0]-b[1]-b[2]);
      // Retain the spatial mixture, while suppressing isolated artwork edges.
      const trim=Math.floor(pixels.length*.1),kept=pixels.slice(trim,pixels.length-trim);
      const color=[0,1,2].map(c=>Math.round(kept.reduce((n,rgb)=>n+rgb[c],0)/kept.length));
      // A genuinely flat white panel stays white. Only replace a bright mode
      // when a substantial amount of the exposed interior contradicts it.
      const disagreement=pixels.filter(rgb=>distance(rgb,backing)>18).length/pixels.length;
      if(disagreement<.3||distance(color,backing)<5)return result;
      return {...result,background:color,surface:null,observedBackground:true,
        captionInterior:{color,coverage:pixels.length/Math.max(1,total),disagreement},
        confidence:{...result.confidence,panelReason:'trimmed exposed interior excluding local ink and halo; display only'}};
    };
    // Estimate the displayed caption from exposed pixels INSIDE its OCR box.
    // Rim colors may belong to page margins, button borders or neighboring art.
    // This display-only field never changes source ink or restoration evidence.
    const aidokuObservedCaptionBackground = (rgba,w,h,inner,result) => {
      if(!result||!Number.isInteger(w)||!Number.isInteger(h)||w<1||h<1||w*h>24576||
          !rgba||rgba.length!==w*h*4||!Array.isArray(inner)||inner.length!==4||
          !inner.every(Number.isFinite)||inner[2]<=0||inner[3]<=0)return result;
      let ink=aidokuSourceDisplayInk(result);
      if(!ink)return result;
      const distance=(a,b)=>Math.max(Math.abs(a[0]-b[0]),Math.abs(a[1]-b[1]),Math.abs(a[2]-b[2]));
      // Display can flatten pale lettering to its colored outline. Independent
      // native detail still identifies the physical fill; use that fill when
      // excluding glyphs, rather than masking similarly colored artwork.
      if(result.foreground&&result.stroke&&(result.confidence?.foreground||0)>=.8&&
          result.confidence.reason==='agreeing native detail palettes preserve fill and outline roles'&&
          distance(ink,result.stroke)<=24&&distance(result.foreground,result.stroke)>=48)
        ink=result.foreground;
      const vertical=inner[3]>=inner[2],start=inner[vertical?1:0],length=inner[vertical?3:2];
      const collect=(tolerance,radius)=>{
        const near=new Uint8Array(w*h),mask=new Uint8Array(w*h),dots=new Uint8Array(w*h),dotHalo=new Uint8Array(w*h);
        let dotCount=0,dotInside=0,dotOutside=0,nearCount=0;
        for(let i=0;i<w*h;i++) {
          const p=i*4;if(rgba[p+3]<250)return null;
          if(distance([rgba[p],rgba[p+1],rgba[p+2]],ink)<=tolerance){near[i]=1;nearCount++;}
        }
        // Color alone cannot distinguish a dark glyph from dark artwork.
        // Preserve large connected surfaces that continue through crop edges;
        // narrow, enclosed glyph components still receive their local halo.
        const seen=new Uint8Array(w*h),queue=new Int32Array(w*h);
        for(let seed=0;seed<w*h;seed++) {
          if(!near[seed]||seen[seed])continue;
          let read=0,count=1,edges=0,interior=0,x0=w,y0=h,x1=0,y1=0;queue[0]=seed;seen[seed]=1;
          while(read<count){
            const i=queue[read++],x=i%w,y=Math.floor(i/w);
            x0=Math.min(x0,x);x1=Math.max(x1,x);y0=Math.min(y0,y);y1=Math.max(y1,y);
            if(x===0)edges|=1;if(x===w-1)edges|=2;if(y===0)edges|=4;if(y===h-1)edges|=8;
            if(x>=inner[0]&&x<inner[0]+inner[2]&&y>=inner[1]&&y<inner[1]+inner[3])interior++;
            for(const next of [x>0?i-1:-1,x<w-1?i+1:-1,y>0?i-w:-1,y<h-1?i+w:-1])
              if(next>=0&&near[next]&&!seen[next]){seen[next]=1;queue[count++]=next;}
          }
          // Bright edge-connected pixels also contain white margins and glyph
          // halos. Connectivity alone cannot recover their physical roles.
          const surface=Math.max(...ink)<128&&interior>=Math.max(48,inner[2]*inner[3]*.1)&&
            (edges&(edges-1))!==0;
          const dot=count<=4&&x1-x0<=2&&y1-y0<=2;
          if(dot){dotCount++;dotInside+=interior;dotOutside+=count-interior;}
          const target=dot?dotHalo:mask;
          for(let j=0;j<count;j++){
            if(dot)dots[queue[j]]=1;
            const x=queue[j]%w,y=Math.floor(queue[j]/w),p=queue[j]*4;
            if(surface&&distance([rgba[p],rgba[p+1],rgba[p+2]],ink)>12)continue;
            const reach=surface?Math.min(radius,1):radius;
            for(let yy=Math.max(0,y-reach);yy<=Math.min(h-1,y+reach);yy++)
              for(let xx=Math.max(0,x-reach);xx<=Math.min(w-1,x+reach);xx++)target[yy*w+xx]=1;
          }
        }
        // Tiny marks are texture only when they repeat along both axes and
        // continue outside the OCR box. Otherwise retain their ordinary ink mask.
        // This avoids deleting halftone dots as if they were glyph strokes.
        const area=inner[2]*inner[3],outside=Math.max(1,w*h-area);
        const periodic=axis=>{
          let best=0,worst=1;
          for(let lag=2;lag<=8;lag++){
            let hits=0,total=0;
            for(let y=0;y<h-(axis?lag:0);y++)for(let x=0;x<w-(axis?0:lag);x++){
              const i=y*w+x;if(!dots[i])continue;total++;if(dots[i+lag*(axis?w:1)])hits++;
            }
            const score=hits/Math.max(1,total);best=Math.max(best,score);worst=Math.min(worst,score);
          }
          return best>=.35&&best-worst>=.2;
        };
        const textured=Math.max(...ink)<96&&dotCount>=80&&dotInside>=32&&dotOutside>=40&&
          dotInside+dotOutside>=nearCount*.8&&dotInside/Math.max(1,area)>=.03&&
          dotInside/Math.max(1,area)<=.25&&dotOutside/outside>=dotInside/area*.5&&
          dotOutside/outside<=dotInside/area*2.5&&periodic(0)&&periodic(1);
        if(!textured)for(let i=0;i<w*h;i++)if(dotHalo[i])mask[i]=1;
        const pixels=[],bands=new Set();let total=0;
        for(let y=Math.max(0,Math.ceil(inner[1]));y<Math.min(h,inner[1]+inner[3]);y++)
          for(let x=Math.max(0,Math.ceil(inner[0]));x<Math.min(w,inner[0]+inner[2]);x++) {
            total++;const i=y*w+x,p=i*4;
            if(mask[i])continue;
            const band=Math.min(7,Math.floor(((vertical?y:x)-start)*8/length));
            const rgb=[rgba[p],rgba[p+1],rgba[p+2]];rgb.band=band;pixels.push(rgb);bands.add(band);
          }
        return {pixels,bands,total,textured};
      };
      const enough=s=>s&&s.pixels.length>=24&&s.pixels.length>=s.total*.15&&s.bands.size>=4;
      let samples=collect(40,2),narrowed=false;
      if(!samples)return result;
      // On dark low-contrast panels a broad color threshold can mask the
      // surface itself. Retry only if broad exclusion leaves too little data.
      if(!enough(samples)){samples=collect(12,1);narrowed=true;}
      if(!enough(samples))return result;
      const {pixels,bands,total,textured}=samples;
      pixels.sort((a,b)=>a[0]+a[1]+a[2]-b[0]-b[1]-b[2]);
      const trim=Math.floor(pixels.length*.1),kept=pixels.slice(trim,pixels.length-trim);
      const bins=new Map();
      for(const rgb of pixels){
        const key=rgb.map(v=>v>>4).join(',');let bin=bins.get(key);
        if(!bin){bin={count:0,sum:[0,0,0]};bins.set(key,bin);}
        bin.count++;rgb.forEach((v,c)=>bin.sum[c]+=v);
      }
      const modes=[...bins.values()].sort((a,b)=>b.count-a.count).slice(0,8)
        .map(b=>b.sum.map(v=>v/b.count));
      let supported=[];
      for(const mode of modes){const near=pixels.filter(rgb=>distance(rgb,mode)<=28);if(near.length>supported.length)supported=near;}
      // A broad populated surface wins over small frame/artwork incursions.
      // Without a dominant surface, retain a trimmed spatial mixture.
      const range=Math.max(...[0,1,2].map(c=>{
        const values=pixels.map(rgb=>rgb[c]).sort((a,b)=>a-b);
        return values[Math.floor((values.length-1)*.9)]-values[Math.floor((values.length-1)*.1)];
      }));
      const mode=supported.length?[0,1,2].map(c=>supported.reduce((n,rgb)=>n+rgb[c],0)/supported.length):ink;
      const brighter=pixels.filter(rgb=>{
        const delta=rgb.map((v,c)=>v-mode[c]);
        return Math.min(...delta)>=32&&Math.max(...delta)-Math.min(...delta)<=20;
      });
      // An additive light gradient preserves chroma while lifting all channels.
      // Its lighter span is part of the panel, not an unrelated white border.
      const lightGradient=Math.max(...mode)-Math.min(...mode)>=30&&brighter.length>=pixels.length*.15&&
        new Set(brighter.map(rgb=>rgb.band)).size>=2;
      const exposed=textured?pixels:range>64&&supported.length>=pixels.length*.45&&!lightGradient?supported:kept;
      const color=[0,1,2].map(c=>Math.round(exposed.reduce((n,rgb)=>n+rgb[c],0)/exposed.length));
      // Narrow exclusion is only evidence for a nearby, lighter surface.
      // Otherwise it may expose alternate ink colors inside outlined glyphs.
      if(distance(color,ink)<12||
          (narrowed&&(Math.min(...color.map((v,c)=>v-ink[c]))<12||distance(color,ink)>80)))return result;
      return {...result,captionBackground:color,
        captionBackgroundEvidence:{color,coverage:pixels.length/Math.max(1,total),
          reason:textured?'periodic halftone retained across OCR and surrounding pixels; display only':'trimmed exposed OCR interior excluding displayed ink and local halo; display only'}};
    };
    // Thin chromatic strokes may leak through a one-pixel gap in their white
    // halo. Require local enclosure, repeated positions and majority support;
    // isolated skin/artwork or the inner half of a colored outline is rejected.
    const aidokuRecoverHaloInk = (rgba,w,h,inner) => {
      const bins=new Map(),vertical=inner[3]>=inner[2];
      const dirs=[[1,0],[-1,0],[0,1],[0,-1],[1,1],[1,-1],[-1,1],[-1,-1]];
      const white=i=>Math.min(rgba[i*4],rgba[i*4+1],rgba[i*4+2])>=220;
      const distance=(a,b)=>Math.max(...a.map((v,c)=>Math.abs(v-b[c])));
      const reach=Math.max(2,Math.min(6,Math.ceil(Math.min(inner[2],inner[3])*.2)));
      for(let y=Math.max(0,Math.floor(inner[1]));y<Math.min(h,Math.ceil(inner[1]+inner[3]));y++)
        for(let x=Math.max(0,Math.floor(inner[0]));x<Math.min(w,Math.ceil(inner[0]+inner[2]));x++) {
          const i=y*w+x,rgb=[rgba[i*4],rgba[i*4+1],rgba[i*4+2]];
          if(rgba[i*4+3]<250||Math.max(...rgb)-Math.min(...rgb)<40||white(i))continue;
          const key=rgb.map(v=>v>>5).join(',');let bin=bins.get(key);
          if(!bin){bin={count:0,kept:0,sum:[0,0,0],core:[],bands:new Set()};bins.set(key,bin);}
          bin.count++;for(let c=0;c<3;c++)bin.sum[c]+=rgb[c];
          let enclosed=0;
          for(const [dx,dy] of dirs)for(let step=1;step<=reach;step++) {
            const xx=x+dx*step,yy=y+dy*step;if(xx<0||yy<0||xx>=w||yy>=h)break;
            const q=yy*w+xx;if(white(q)){enclosed++;break;}
          }
          if(enclosed>=5){bin.kept++;bin.core.push(rgb);bin.bands.add(Math.min(5,Math.max(0,Math.floor(((vertical?y:x)-(vertical?inner[1]:inner[0]))/(vertical?inner[3]:inner[2])*6))));}
        }
      const modes=[...bins.values()].map(b=>({...b,rgb:b.sum.map(v=>v/b.count)}));
      let winner=null;
      // Include antialiased tints of the same hue in the denominator. Otherwise
      // a pale inner edge of a colored outline can masquerade as enclosed fill.
      const hue=c=>{const lo=Math.min(...c),span=Math.max(...c)-lo;return c.map(v=>(v-lo)/Math.max(1,span));};
      for(const seed of modes){
        const same=modes.filter(b=>distance(hue(b.rgb),hue(seed.rgb))<=.18);
        const count=same.reduce((n,b)=>n+b.count,0),kept=same.reduce((n,b)=>n+b.kept,0);
        const bands=new Set(same.flatMap(b=>[...b.bands]));
        if(kept<6||kept<count*.65||bands.size<3)continue;
        if(!winner||kept>winner.kept) {
          // White antialias fringes share the ink hue but dilute its RGB.
          // Use the strongest observed interior third, after (not before)
          // the enclosure and hue-majority checks that reject artwork.
          const core=same.flatMap(b=>b.core).sort((a,b)=>
            (Math.max(...b)-Math.min(...b))-(Math.max(...a)-Math.min(...a)));
          const selected=core.slice(0,Math.max(3,Math.ceil(core.length/3)));
          winner={kept,foreground:[0,1,2].map(c=>Math.round(selected.reduce((n,rgb)=>n+rgb[c],0)/selected.length))};
        }
      }
      return winner;
    };
    // Candidate glyph colors must form repeated, bounded strokes within the
    // OCR region. Counters in a broad panel and frame-connected art are not ink.
    // Display only: preserve erasure roles and reuse the existing bounded reads.
    // At most 12 modes, six competing colors and 128 enclosure probes per pair.
    const aidokuObservedGlyphPalette = (rgba,w,h,inner,hint=null) => {
      if(!Number.isInteger(w)||!Number.isInteger(h)||w<8||h<8||w*h>24576||!rgba||rgba.length!==w*h*4||
          !Array.isArray(inner)||inner.length!==4||!inner.every(Number.isFinite)||inner[2]<=0||inner[3]<=0)return null;
      const n=w*h,dist=(a,b)=>Math.max(Math.abs(a[0]-b[0]),Math.abs(a[1]-b[1]),Math.abs(a[2]-b[2]));
      const rgb=i=>[rgba[i*4],rgba[i*4+1],rgba[i*4+2]];
      const inside=(x,y)=>x>=inner[0]&&x<inner[0]+inner[2]&&y>=inner[1]&&y<inner[1]+inner[3];
      const bins=new Map();let area=0;
      for(let y=0;y<h;y++)for(let x=0;x<w;x++){
        const i=y*w+x;if(rgba[i*4+3]<250)return null;if(!inside(x,y))continue;area++;
        const c=rgb(i),key=(c[0]>>4)*256+(c[1]>>4)*16+(c[2]>>4);let b=bins.get(key);
        if(!b){b={count:0,sum:[0,0,0]};bins.set(key,b);}b.count++;for(let c=0;c<3;c++)b.sum[c]+=rgba[i*4+c];
      }
      const seeds=[];
      for(const b of [...bins.values()].sort((a,b)=>b.count-a.count)){
        if(b.count<Math.max(4,area*.002))continue;
        const c=b.sum.map(v=>Math.round(v/b.count));if(seeds.some(s=>dist(s,c)<32))continue;
        seeds.push(c);if(seeds.length>=12)break;
      }
      const candidates=[],queue=new Int32Array(n),vertical=inner[3]>=inner[2];
      for(const color of seeds){
        const mask=new Uint8Array(n),seen=new Uint8Array(n),core=[];
        for(let i=0;i<n;i++)if(dist(rgb(i),color)<=24)mask[i]=1;
        let total=0;for(let i=0;i<n;i++)if(mask[i]&&inside(i%w,Math.floor(i/w)))total++;
        let retained=0,components=0,energy=0;const bands=new Set();
        for(let start=0;start<n;start++){
          if(!mask[start]||seen[start])continue;
          let head=0,tail=1,x0=w,y0=h,x1=0,y1=0,edge=false,local=0;queue[0]=start;seen[start]=1;
          while(head<tail){const i=queue[head++],x=i%w,y=Math.floor(i/w);x0=Math.min(x0,x);x1=Math.max(x1,x);y0=Math.min(y0,y);y1=Math.max(y1,y);edge||=x===0||x===w-1||y===0||y===h-1;if(inside(x,y))local++;
            for(const q of [x?i-1:-1,x+1<w?i+1:-1,y?i-w:-1,y+1<h?i+w:-1])if(q>=0&&mask[q]&&!seen[q]){seen[q]=1;queue[tail++]=q;}
          }
          const bw=x1-x0+1,bh=y1-y0+1,density=tail/(bw*bh);
          if(edge||tail<3||local<tail*.85||bw>w*.9||bh>h*.9||density>.88||Math.max(bw,bh)<4)continue;
          components++;retained+=local;
          for(let k=0;k<tail;k++){
            const i=queue[k],x=i%w,y=Math.floor(i/w);if(!inside(x,y))continue;
            core.push(i);bands.add(Math.min(7,Math.max(0,Math.floor(((vertical?y:x)-(vertical?inner[1]:inner[0]))/Math.max(1,vertical?inner[3]:inner[2])*8))));
            let e=0;for(const q of [x>=2?i-2:-1,x+2<w?i+2:-1,y>=2?i-2*w:-1,y+2<h?i+2*w:-1])
              if(q>=0)e=Math.max(e,dist(rgb(i),rgb(q)));energy+=e;
          }
        }
        if(components<3||bands.size<3||retained<Math.max(8,area*.004)||retained>area*.6)continue;
        const average=energy/retained;if(average<12)continue;
        candidates.push({color,pixels:retained,components,bands:bands.size,energy:average,coverage:retained/Math.max(1,total),core,score:retained*(.5+Math.min(1,average/80))});
      }
      candidates.sort((a,b)=>b.score-a.score);
      const dirs=[[1,0],[-1,0],[0,1],[0,-1],[1,1],[-1,-1],[1,-1],[-1,1]];
      for(const c of candidates.slice(0,6)){
        c.enclosure=[];
        for(const other of candidates.slice(0,6)){
          if(c===other||dist(c.color,other.color)<48)continue;
          let kept=0,total=0;const stride=Math.max(1,Math.ceil(c.core.length/128));
          for(let k=0;k<c.core.length;k+=stride){
            const i=c.core[k],x=i%w,y=Math.floor(i/w);let hit=0;
            for(const [dx,dy] of dirs)for(let step=1;step<=5;step++){
              const xx=x+dx*step,yy=y+dy*step;if(xx<0||xx>=w||yy<0||yy>=h)break;
              const p=rgb(yy*w+xx);if(dist(p,other.color)<=24){hit++;break;}
            }
            total++;if(hit>=5)kept++;
          }
          c.enclosure.push({color:other.color,ratio:kept/Math.max(1,total)});
        }
      }
      // Recover disconnected pale centers only beside already bounded glyphs.
      // Median local peaks reject isolated highlights and never invent a color.
      if(hint&&Math.min(...hint.foreground.map((v,i)=>v-hint.background[i]))>=32){
        const direction=hint.foreground.map((v,i)=>v-hint.background[i]);
        const squared=direction.reduce((sum,v)=>sum+v*v,0);
        for(const c of candidates.filter(c=>dist(c.color,hint.foreground)<=32)){
          const peaks=[],stride=Math.max(1,Math.ceil(c.core.length/128));
          for(let k=0;k<c.core.length;k+=stride){
            const i=c.core[k],x=i%w,y=Math.floor(i/w);let best=null,bestT=.8;
            for(let dy=-1;dy<=1;dy++)for(let dx=-1;dx<=1;dx++){
              const xx=x+dx,yy=y+dy;if(xx<0||yy<0||xx>=w||yy>=h||!inside(xx,yy))continue;
              const p=rgb(yy*w+xx),delta=p.map((v,j)=>v-hint.background[j]);
              const t=delta.reduce((sum,v,j)=>sum+v*direction[j],0)/squared;
              if(t>bestT&&delta.every((v,j)=>Math.abs(v-t*direction[j])<=16)){best=p;bestT=t;}
            }
            if(best)peaks.push(best);
          }
          if(peaks.length>=8)c.endpoint=[0,1,2].map(j=>peaks.map(p=>p[j]).sort((a,b)=>a-b)[Math.floor(peaks.length/2)]);
        }
      }
      if(hint&&Math.max(...hint.foreground)<80&&Math.min(...hint.background)>=225){
        const delta=hint.foreground.map((v,i)=>v-hint.background[i]),squared=delta.reduce((s,v)=>s+v*v,0);
        for(const c of candidates.filter(c=>c.pixels<=64&&c.coverage<.5)){
          const mix=c.color.map((v,i)=>v-hint.background[i]);
          const t=mix.reduce((s,v,i)=>s+v*delta[i],0)/Math.max(1,squared);
          if(t<.1||t>.8||mix.some((v,i)=>Math.abs(v-t*delta[i])>12))continue;
          let supported=0;
          for(const i of c.core){
            const x=i%w,y=i/w|0;let found=false;
            for(let yy=Math.max(0,y-2);yy<=Math.min(h-1,y+2);yy++)for(let xx=Math.max(0,x-2);xx<=Math.min(w-1,x+2);xx++)
              if(inside(xx,yy)&&dist(rgb(yy*w+xx),hint.foreground)<=64)found=true;
            if(found)supported++;
          }
          if(supported>=8&&supported>=c.core.length*.4)c.darkEndpoint=hint.foreground;
        }
      }
      for(const c of candidates)delete c.core;
      return candidates;
    };
    const aidokuResolveDisplayGlyphs = (result,glyphs) => {
      const distance=(a,b)=>Math.max(...a.map((v,i)=>Math.abs(v-b[i])));
      const valid=c=>Array.isArray(c)&&c.length===3;
      const foreground=result?.foreground||result?.displayForeground;
      const background=result?.surface?.color||result?.background,lettering=result?.lettering?.color;
      if(!glyphs?.length)return foreground||null;
      const match=(c,tolerance=32)=>valid(c)&&glyphs.find(g=>distance(g.color,c)<=tolerance);
      const current=match(foreground),outlined=match(lettering,40);
      const light=glyphs.filter(g=>Math.min(...g.color)>=175&&Math.max(...g.color)>=225).sort((a,b)=>b.pixels-a.pixels)[0];
      const colorful=c=>Math.max(...c)-Math.min(...c)>=100;
      // Sparse antialias bands can outnumber their brighter ink cores on a
      // dark backing. Retain independently observed ink when bounded glyphs
      // corroborate that same color ramp and the leading mode is the backing.
      if(valid(foreground)&&valid(background)&&!result.stroke&&
          (result.foreground?(result.confidence?.foreground||0)>=.7:!!result.displayForeground)&&
          Math.min(...foreground.map((v,c)=>v-background[c]))>=32&&
          aidokuSourceColorContrast(foreground,true,1,background)>=3&&
          aidokuSourceColorContrast(glyphs[0].color,true,1,background)<2){
        const direction=foreground.map((v,c)=>v-background[c]);
        const squared=direction.reduce((sum,v)=>sum+v*v,0);
        if(squared>=3600&&glyphs.some(g=>{
          if(g.coverage<.08||g.bands<3||g.components<3)return false;
          const delta=g.color.map((v,c)=>v-background[c]);
          const t=delta.reduce((sum,v,c)=>sum+v*direction[c],0)/squared;
          return t>=.5&&t<=1.2&&delta.every((v,c)=>Math.abs(v-t*direction[c])<=16);
        })){
          const endpoint=!result.foreground&&current?.endpoint;
          if(endpoint&&endpoint.every((v,c)=>v>=foreground[c]))return endpoint;
          return foreground;
        }
      }
      // An independently observed dark inscription can sit inside bounded
      // light counters. The enclosing candidate agrees with the local backing,
      // while the inscription is enclosed in only that direction.
      if(!result.foreground&&result.displayForeground&&current&&current.coverage>=.2&&valid(background)&&
          distance(glyphs[0].color,background)<=24&&aidokuSourceColorContrast(current.color,true,1,background)>=3&&
          (current.enclosure||[]).some(e=>distance(e.color,glyphs[0].color)<=24&&e.ratio>=.85)&&
          (glyphs[0].enclosure||[]).some(e=>distance(e.color,current.color)<=24&&e.ratio<.2))return current.color;
      // Use the directly observed saturated core when the initial estimate is
      // weak and its blue/red endpoint was diluted by textured neighbors.
      if(current&&current.coverage>=.4&&current.bands>=5&&current.energy>=120&&
          colorful(foreground)&&(result.confidence?.foreground||0)<.7&&
          distance(current.color,foreground)>16)return current.color;
      if(result?.foreground&&current&&current.coverage>=.25&&current.bands>=3&&
          (!outlined||outlined===current||outlined.coverage<.5||outlined.pixels<current.pixels)&&
          (result.confidence?.foreground||0)>=.85&&valid(background)&&!result.stroke&&
          Math.min(...foreground)>=175&&Math.max(...foreground)-Math.min(...foreground)<40&&
          aidokuSourceColorContrast(foreground,true,1,background)>=
            aidokuSourceColorContrast(glyphs[0].color,true,1,background)*2.5)return foreground;
      // Agreement between two independently observed ink paths should survive
      // a sparse component mask, including gray antialias cores and joined outlines.
      if((result?.foreground||current?.coverage>=.5)&&valid(foreground)&&valid(lettering)&&distance(foreground,lettering)<=24&&
          (current?.coverage>=.5||current?.coverage>=.2&&current.bands>=3&&distance(foreground,lettering)<=16||colorful(foreground)||
            (Math.min(...lettering)>=40&&valid(background)&&Math.min(...background)>=225)))return foreground;
      // A small amount of black artwork must not displace a much larger, bounded
      // gray word merely because its source endpoint is darker.
      const dominant=glyphs[0];
      if(result?.foreground&&(result.confidence?.foreground||0)>=.5&&dominant.darkEndpoint&&
          dominant.bands>=3)return dominant.darkEndpoint;
      // A weak native estimate can select the low-energy interior of a sign.
      // Repeated brighter components with stronger edges are its inscription.
      if(!result?.foreground&&current&&dominant!==current&&current.coverage>=.65&&
          dominant.coverage>=.65&&dominant.bands>=4&&Math.min(...dominant.color)>=175&&
          dominant.energy>=current.energy*1.8&&distance(dominant.color,current.color)>=48){
        const bright=glyphs.find(g=>g!==dominant&&g.coverage>=.25&&g.bands>=3&&
          g.pixels>=dominant.pixels*.25&&g.energy>=dominant.energy*1.2&&
          g.color.every((v,c)=>v>=dominant.color[c])&&distance(g.color,dominant.color)<=48);
        return bright?dominant.color.map((v,c)=>Math.round((v+bright.color[c])/2)):dominant.color;
      }

      if(current&&dominant!==current&&dominant.coverage>=.75&&dominant.score>current.score*2.5&&
          distance(dominant.color,foreground)<=96)return dominant.color;
      const enclosedBy=(a,b)=>(a?.enclosure||[]).find(e=>distance(e.color,b.color)<=24)?.ratio||0;
      // Thin glyph interiors can own few pixels while their thick halo dominates
      // the component histogram. Independent foreground/stroke roles plus a
      // one-way enclosure establish the interior without a majority-size test.
      if(current&&light&&current!==light&&current.coverage>=.15&&current.pixels>=24&&
          current.bands>=3&&(result.confidence?.foreground||0)>=.7&&valid(result.stroke)&&
          distance(result.stroke,light.color)<=24&&enclosedBy(current,light)>=.85&&
          enclosedBy(light,current)<=.15)return foreground;
      const coloredCore=glyphs.find(g=>g.coverage>=.65&&g.bands>=3&&g.components>=3&&
        Math.max(...g.color)-Math.min(...g.color)>=60&&light&&g.pixels>=light.pixels*.2&&
        enclosedBy(g,light)>=.7&&enclosedBy(light,g)<=.15);
      if(coloredCore&&valid(foreground)&&distance(coloredCore.color,foreground)<=48&&
          (result.confidence?.foreground||0)>=.6)return coloredCore.color;
      if(!result?.foreground&&outlined&&Math.max(...lettering)<80&&outlined.coverage>=.6&&
          light&&enclosedBy(outlined,light)>=.6&&enclosedBy(light,outlined)<.15&&
          outlined.energy>=100)return lettering;
      // Glyph interiors retain their color inside a darker edge. Promoting a
      // pale core needs contrast on the observed backing: the outline-free
      // caption otherwise loses the dark edge that makes the source legible.
      const core=glyphs.find(g=>g.coverage>=.2&&g.pixels>=glyphs[0].pixels*.5&&
        glyphs.some(other=>other!==g&&other.coverage>=.25&&enclosedBy(g,other)>=.85&&
          enclosedBy(g,other)-enclosedBy(other,g)>=.3));
      if(core&&(Math.min(...core.color)<175||
          (valid(background)&&aidokuSourceColorContrast(core.color,true,1,background)>=3))&&
          (!light||Math.min(...core.color)<175||distance(core.color,light.color)<=24)&&
          (!outlined||Math.max(...lettering)-Math.min(...lettering)<40||Math.min(...core.color)<175))return core.color;
      // A defining colored outline is itself repeated, bounded ink and visibly
      // surrounds the pale core; a panel has neither ownership nor this relation.
      if(outlined&&colorful(lettering)&&outlined.coverage>=.6&&light&&
          (!valid(background)||aidokuSourceColorContrast(lettering,true,1,background)>=1.75)&&
          outlined.pixels>=light.pixels&&enclosedBy(light,outlined)>=.6&&
          enclosedBy(outlined,light)<.3)return lettering;
      // The defining outline must dominate the pale glyph core and belong to
      // bounded ink. A surrounding panel or a thin subtitle shadow fails this.
      if(outlined&&(outlined.coverage>=.5||colorful(lettering))&&
          (!light||outlined.pixels>=light.pixels*1.8||
            (colorful(lettering)&&current&&Math.min(...foreground)<175&&outlined.score>current.score*1.8))&&
          (!valid(background)||aidokuSourceColorContrast(lettering,true,1,background)>=1.75)){
        if(!colorful(lettering)&&current&&current.coverage>=.25&&Math.max(...foreground)<100&&distance(foreground,lettering)>25&&outlined.score<current.score)return foreground;
        return lettering;
      }
      // A gray observed core need not be an antialias tint of black. Require
      // poor ownership before using the separately observed dark endpoint.
      if(current&&current.coverage<.25&&valid(lettering)&&(result.lettering?.pixels||0)>=32&&Math.max(...lettering)<100&&
          Math.max(...foreground)<100&&valid(background)&&Math.min(...background)>=225)return lettering;
      if(current&&current.coverage>=.4&&colorful(foreground)&&Math.min(...foreground)<150)return foreground;
      // A thin pale glyph can have disconnected solid cores while its larger
      // antialias band forms the repeated components. Do not replace a validated
      // ink endpoint with a blend toward an independently supported backing.
      if(valid(foreground)&&valid(background)&&
          ((!result.stroke&&(result.confidence?.foreground||0)>=.8&&(result.confidence?.background||0)>=.75)||
          (result.stroke&&Math.max(...foreground)-Math.min(...foreground)>=40&&distance(result.stroke,background)<=40&&
            (result.confidence?.foreground||0)>=.75&&(result.confidence?.background||0)>=.5))){
        const direction=foreground.map((v,c)=>v-background[c]);
        const squared=direction.reduce((sum,v)=>sum+v*v,0);
        const best=glyphs.find(g=>g.coverage>=.25);
        if(best&&squared>=3600){
          const delta=best.color.map((v,c)=>v-background[c]);
          const t=delta.reduce((sum,v,c)=>sum+v*direction[c],0)/squared;
          if(t>=.25&&t<.9&&delta.every((v,c)=>Math.abs(v-t*direction[c])<=12))return foreground;
        }
      }
      if(current&&current.coverage>=.5){
        if(Math.min(...foreground)>=175){
          const interior=glyphs.find(g=>g.coverage>=.5&&g.pixels>=current.pixels*.2&&
            (g.enclosure||[]).some(e=>distance(e.color,current.color)<=24&&e.ratio>=.6)&&
            (current.enclosure||[]).some(e=>distance(e.color,g.color)<=24&&e.ratio<.3));
          if(interior)return interior.color;
        }
        return foreground;
      }
      const reliableSurface=valid(background)&&(result?.confidence?.background||0)>=.75;
      const backdropCounter=g=>valid(background)&&distance(g.color,background)<=24&&g.coverage<.5&&
        glyphs.some(other=>other!==g&&other.coverage>=.6&&distance(other.color,background)>=80);
      const eligible=g=>g.coverage>=(valid(foreground) ? .25 : .2)&&!backdropCounter(g)&&
        (!reliableSurface||distance(g.color,background)>=80);
      const best=glyphs.find(eligible);
      if(!best)return foreground||null;
      // A locally repeated backing or shadow cannot displace the observed pale
      // interiors merely because it contributes more total pixels.
      if(current&&current.coverage>=.35&&current.bands>=3&&valid(background)&&
          distance(best.color,background)<=48&&distance(foreground,background)>=80&&
          aidokuSourceColorContrast(foreground,true,1,background)>=3)return foreground;
      // Prefer the sharp corroborated endpoint over a broad, low-energy tint
      // on the same ink-to-paper ramp. Genuine dominant gray words were handled
      // above; this fallback cannot invent an unseen darker color.
      if(current&&current.pixels>=24&&current.bands>=3&&current.energy>=100&&
          best.energy<current.energy*.6&&valid(background)){
        const axis=foreground.map((v,c)=>v-background[c]),length=axis.reduce((s,v)=>s+v*v,0);
        const delta=best.color.map((v,c)=>v-background[c]);
        const t=delta.reduce((s,v,c)=>s+v*axis[c],0)/Math.max(1,length);
        if(t>=.25&&t<=.85&&delta.every((v,c)=>Math.abs(v-t*axis[c])<=12))return foreground;
      }
      if(current&&distance(foreground,best.color)<=32)return foreground;
      // A bright interior split into tiny cores by downsampling still has
      // directional enclosure; the gray antialias fringe does not own it.
      const enclosed=glyphs.find(g=>g.pixels>=best.pixels*.25&&Math.min(...g.color)>=175&&
        (g.enclosure||[]).some(e=>distance(e.color,best.color)<=24&&e.ratio>=.6)&&
        (best.enclosure||[]).some(e=>distance(e.color,g.color)<=24&&e.ratio<.3));
      if(enclosed)return enclosed.color;
      return best.color;
    };
    // For an outline-free caption, observe the ink that defines repeated pale
    // glyphs. Opposing rays must meet the same color in several text bands,
    // and that color must be concentrated inside OCR bounds, not in the art.
    // This is display evidence only: never change fill/stroke erasure roles.
    const aidokuObservedLetteringInk = (rgba,w,h,inner) => {
      if(!Number.isInteger(w)||!Number.isInteger(h)||w<8||h<8||w*h>24576||!rgba||rgba.length!==w*h*4||
          !Array.isArray(inner)||inner.length!==4||!inner.every(Number.isFinite)||inner[2]<=0||inner[3]<=0)return null;
      for(let p=3;p<rgba.length;p+=4)if(rgba[p]<250)return null;
      const distance=(a,b)=>Math.max(Math.abs(a[0]-b[0]),Math.abs(a[1]-b[1]),Math.abs(a[2]-b[2]));
      const span=c=>Math.max(...c)-Math.min(...c);
      const hue=c=>c.map(v=>(v-Math.min(...c))/Math.max(1,span(c)));
      const pixel=i=>[rgba[i*4],rgba[i*4+1],rgba[i*4+2]];
      const pale=i=>{const c=pixel(i);return Math.min(...c)>=190&&Math.max(...c)>=230&&span(c)<=70;};
      const dirs=[[1,0],[-1,0],[0,1],[0,-1],[1,1],[-1,-1],[1,-1],[-1,1]];
      const vertical=inner[3]>=inner[2],modes=new Map();
      const alongStart=Math.max(0,vertical?inner[1]:inner[0]);
      const alongEnd=Math.min(vertical?h:w,vertical?inner[1]+inner[3]:inner[0]+inner[2]);
      const inside=(x,y)=>x>=inner[0]&&x<inner[0]+inner[2]&&y>=inner[1]&&y<inner[1]+inner[3];
      for(let y=Math.max(1,Math.ceil(inner[1]));y<Math.min(h-1,inner[1]+inner[3]);y++)
        for(let x=Math.max(1,Math.ceil(inner[0]));x<Math.min(w-1,inner[0]+inner[2]);x++) {
          const i=y*w+x;if(!pale(i))continue;
          const hits=dirs.map(([dx,dy])=>{
            for(let step=1;step<=5;step++) {
              const xx=x+dx*step,yy=y+dy*step;
              if(xx<0||yy<0||xx>=w||yy>=h)break;
              const rgb=pixel(yy*w+xx);
              if(Math.min(...rgb)<185)return rgb;
            }
            return null;
          });
          for(let d=0;d<8;d+=2) {
            const a=hits[d],b=hits[d+1];if(!a||!b||distance(a,b)>28)continue;
            const near=hits.filter(c=>c&&distance(c,a)<=28);if(near.length<5)continue;
            const rgb=near.reduce((best,c)=>Math.min(...c)<Math.min(...best)?c:best,a);
            const key=rgb.map(v=>v>>5).join(',');
            let mode=modes.get(key);
            if(!mode){mode={rgb:[],bands:new Set(),points:[]};modes.set(key,mode);}
            mode.rgb.push(rgb);mode.points.push(i);
            mode.bands.add(Math.min(7,Math.floor(((vertical?y:x)-alongStart)*8/Math.max(1,alongEnd-alongStart))));
            break;
          }
        }
      const candidates=[];
      for(const mode of [...modes.values()].sort((a,b)=>b.points.length-a.points.length).slice(0,4)) {
        if(mode.points.length<8||mode.bands.size<3)continue;
        // A single white slit inside a frame is not repeated lettering.
        const remaining=new Set(mode.points);let components=0;
        for(const start of mode.points) {
          if(!remaining.delete(start))continue;
          components++;const queue=[start];
          for(let head=0;head<queue.length;head++) {
            const i=queue[head],x=i%w,y=Math.floor(i/w);
            for(const [dx,dy] of dirs) {
              const xx=x+dx,yy=y+dy;
              if(xx>=0&&xx<w&&yy>=0&&yy<h&&remaining.delete(yy*w+xx))queue.push(yy*w+xx);
            }
          }
        }
        if(components<3)continue;
        const rgb=[0,1,2].map(c=>mode.rgb.map(p=>p[c]).sort((a,b)=>a-b)[Math.floor(mode.rgb.length/2)]);
        let inkInside=0,inkOutside=0,insideCount=0,outsideCount=0;
        for(let y=0;y<h;y++)for(let x=0;x<w;x++) {
          const local=inside(x,y);if(local)insideCount++;else outsideCount++;
          if(distance(pixel(y*w+x),rgb)<=28){if(local)inkInside++;else inkOutside++;}
        }
        const support=inkInside/Math.max(1,insideCount),exterior=inkOutside/Math.max(1,outsideCount);
        if(outsideCount<8||support<.025||support>.55||exterior>support*.6||exterior>.16)continue;
        // Antialias edges mix the ink with its pale fill or artwork. Recover
        // a populated observed endpoint of the same hue, not an average tint.
        const bins=new Map(),chromatic=span(rgb)>=40,seedHue=hue(rgb);
        for(let y=Math.max(0,Math.ceil(inner[1]));y<Math.min(h,inner[1]+inner[3]);y++)
          for(let x=Math.max(0,Math.ceil(inner[0]));x<Math.min(w,inner[0]+inner[2]);x++) {
            const c=pixel(y*w+x);
            if(chromatic ? span(c)<40||distance(hue(c),seedHue)>.18 : span(c)>24||Math.max(...c)>Math.max(...rgb))continue;
            const key=c.map(v=>v>>4).join(',');let bin=bins.get(key);
            if(!bin){bin={count:0,sum:[0,0,0]};bins.set(key,bin);}
            bin.count++;c.forEach((v,i)=>bin.sum[i]+=v);
          }
        const endpoints=[...bins.values()].filter(b=>b.count>=Math.max(4,inkInside*.025))
          .map(b=>b.sum.map(v=>Math.round(v/b.count)))
          .sort((a,b)=>chromatic?span(b)-span(a):Math.max(...a)-Math.max(...b));
        candidates.push({color:endpoints[0]||rgb,pixels:mode.points.length,bands:mode.bands.size,components,support,exterior});
      }
      return candidates.sort((a,b)=>b.pixels-a.pixels)[0]||null;
    };
    // Require a local fill -> stroke -> exterior transition. A broad backing
    // can surround letters too, but is not a thin, repeated enclosing band.
    const aidokuObservedStrokePalette = (rgba,w,h,inner,glyphs,display,result) => {
      if(!Number.isInteger(w)||!Number.isInteger(h)||w<8||h<8||w*h>24576||!rgba||rgba.length!==w*h*4||
          !Array.isArray(inner)||inner.length!==4||!inner.every(Number.isFinite)||inner[2]<=0||inner[3]<=0)return null;
      const n=w*h,dist=(a,b)=>Math.max(Math.abs(a[0]-b[0]),Math.abs(a[1]-b[1]),Math.abs(a[2]-b[2]));
      for(let i=3;i<rgba.length;i+=4)if(rgba[i]<250)return null;
      // Independently agreeing native strips already resolved a band which
      // disappeared in the reduced crop; do not replace its scale with this raster.
      if(result?.stroke&&result.foreground&&dist(result.foreground,result.stroke)>=48&&
          result.confidence?.reason==='matching colored glyph interiors inside observed white outlines in independent strips')
        return {foreground:result.foreground,stroke:result.stroke,widthEvidence:result.widthEvidence};
      if(result?.stroke&&result.foreground&&result.widthEvidence&&
          (result.confidence?.foreground||0)>=.8&&Math.min(...result.foreground)>=175&&
          Math.max(...result.stroke)<130&&
          ((result.confidence.reason||'').includes('agreeing native detail')||(result.confidence.reason||'').includes('enclosed glyph fill')))
        return {foreground:result.foreground,stroke:result.stroke,widthEvidence:result.widthEvidence};
      // A white interior can share the page background. Independent repeated
      // lettering still corroborates its colored enclosing band even when
      // that band, rather than the white interior, supplies the display color.
      if(result?.confidence?.reason==='enclosed glyph fill and distinct enclosing source stroke'&&
          result.foreground&&Math.min(...result.foreground)>=225&&result.background&&Math.min(...result.background)>=225&&
          result.stroke&&Math.max(...result.stroke)-Math.min(...result.stroke)>=40&&
          result.widthEvidence?.samplePixels>=1&&result.widthEvidence.relativeToGlyph<=.3&&
          result.lettering?.components>=3&&result.lettering.bands>=3&&result.lettering.exterior<.02&&
          dist(result.lettering.color,result.stroke)<=24&&display&&dist(display,result.stroke)<=24)
        return {foreground:result.foreground,stroke:result.stroke,widthEvidence:result.widthEvidence};
      // Corroborated native/enclosed bands outrank a color from a reduced crop.
      if(result?.stroke&&result.foreground&&result.background&&result.widthEvidence?.samplePixels>=1&&
          result.widthEvidence.relativeToGlyph<=.3&&(result.confidence?.foreground||0)>=.8&&
          result.lettering?.components>=3&&result.lettering.bands>=3&&
          dist(result.lettering.color,result.stroke)<=24&&dist(result.foreground,result.stroke)>=48&&
          ((result.confidence.reason==='agreeing native detail palettes preserve fill and outline roles'&&
            Math.min(...result.foreground)>=225&&(result.confidence.background||0)>=.5)||
           (result.confidence.reason==='enclosed glyph fill and distinct enclosing source stroke'&&
            Math.max(...result.stroke)<130&&result.lettering.exterior<.02&&dist(result.foreground,result.background)>=48)||
           ((result.confidence.reason||'').includes('observed glyph fill and following halo')&&
            Math.min(...result.foreground)>=225&&dist(result.stroke,result.background)>=48&&
            glyphs?.some(g=>g.coverage>=.6&&dist(g.color,result.foreground)<=24&&
              (g.enclosure||[]).some(e=>dist(e.color,result.stroke)<=24&&e.ratio>=.7)))))
        return {foreground:result.foreground,stroke:result.stroke,widthEvidence:result.widthEvidence};
      if(!glyphs?.length)return null;
      const rgb=i=>[rgba[i*4],rgba[i*4+1],rgba[i*4+2]];
      const inside=(x,y)=>x>=inner[0]&&x<inner[0]+inner[2]&&y>=inner[1]&&y<inner[1]+inner[3];
      const bins=new Map();
      for(let i=0;i<n;i++) {if(!inside(i%w,Math.floor(i/w)))continue;const c=rgb(i),key=c.map(v=>v>>4).join(',');let b=bins.get(key);if(!b){b={n:0,sum:[0,0,0]};bins.set(key,b);}b.n++;c.forEach((v,j)=>b.sum[j]+=v);}
      const seeds=[];
      for(const b of [...bins.values()].sort((a,b)=>b.n-a.n)) {if(b.n<4)continue;const c=b.sum.map(v=>Math.round(v/b.n));if(seeds.some(s=>dist(s,c)<32))continue;seeds.push(c);if(seeds.length>=12)break;}
      const dirs=[[1,0],[-1,0],[0,1],[0,-1],[1,1],[-1,-1],[1,-1],[-1,1]],pairs=[];
      for(const glyph of glyphs.slice(0,6)) {
        const surroundedPale=Math.min(...glyph.color)>=225&&glyph.coverage>=.5&&
          (glyph.enclosure||[]).some(e=>e.ratio>=.6&&glyphs.some(g=>dist(g.color,e.color)<=24&&g.coverage>=.5&&
            !(g.enclosure||[]).some(back=>dist(back.color,glyph.color)<=24&&back.ratio>e.ratio-.3)));
        // Display can flatten an outline into the text color. Keep the
        // physical interior when ownership or directional enclosure supports it.
        const enclosedByOwnedEdge=(glyph.enclosure||[]).some(e=>e.ratio>=.65&&
          glyphs.some(g=>dist(g.color,e.color)<=24&&g.coverage>=.65));
        if(glyph.coverage<.15)continue;
        if(glyph.coverage<.5&&display&&dist(glyph.color,display)>24&&
            (!result?.foreground||dist(glyph.color,result.foreground)>24)&&!enclosedByOwnedEdge)continue;
        const supportedFill=surroundedPale||enclosedByOwnedEdge||glyph.coverage>=.5||
          (result?.foreground&&dist(glyph.color,result.foreground)<=40);
        if(display&&dist(glyph.color,display)>40&&!supportedFill)continue;
        const fill=glyph.color,core=[],mask=new Uint8Array(n),seen=new Uint8Array(n),exteriorFill=new Uint8Array(n),queue=new Int32Array(n),heights=[];
        for(let i=0;i<n;i++)if(dist(rgb(i),fill)<=20)mask[i]=1;
        for(let start=0;start<n;start++){
          if(!mask[start]||seen[start])continue;
          let head=0,tail=1,x0=w,x1=0,y0=h,y1=0,edge=false,local=0;seen[start]=1;queue[0]=start;
          while(head<tail){const i=queue[head++],x=i%w,y=Math.floor(i/w);x0=Math.min(x0,x);x1=Math.max(x1,x);y0=Math.min(y0,y);y1=Math.max(y1,y);edge||=!x||!y||x===w-1||y===h-1;if(inside(x,y))local++;
            for(const q of [x?i-1:-1,x+1<w?i+1:-1,y?i-w:-1,y+1<h?i+w:-1])if(q>=0&&mask[q]&&!seen[q]){seen[q]=1;queue[tail++]=q;}}
          if(edge)for(let k=0;k<tail;k++)exteriorFill[queue[k]]=1;
          if(edge||tail<3||local<tail*.85||tail/((x1-x0+1)*(y1-y0+1))>.9||Math.max(x1-x0,y1-y0)<3)continue;
          heights.push(Math.max(x1-x0+1,y1-y0+1));for(let k=0;k<tail;k++)if(inside(queue[k]%w,Math.floor(queue[k]/w)))core.push(queue[k]);
        }
        if(heights.length<3||core.length<8)continue;
        heights.sort((a,b)=>a-b);const size=heights[Math.floor(heights.length*.75)],reach=Math.min(16,Math.max(4,Math.ceil(size*.6)));
        const stride=Math.max(1,Math.ceil(core.length/128));
        const adjacent=new Map();
        for(let k=0;k<core.length;k+=stride){const i=core[k],x=i%w,y=Math.floor(i/w);
          for(const [dx,dy] of dirs)for(const step of [1,2]){const xx=x+dx*step,yy=y+dy*step;if(xx<0||xx>=w||yy<0||yy>=h)continue;
            const c=rgb(yy*w+xx);if(dist(c,fill)<48)continue;const key=c.map(v=>v>>4).join(',');let b=adjacent.get(key);if(!b){b={n:0,sum:[0,0,0]};adjacent.set(key,b);}b.n++;c.forEach((v,j)=>b.sum[j]+=v);
          }
        }
        const localSeeds=seeds.slice();
        let added=0;for(const b of [...adjacent.values()].sort((a,b)=>b.n-a.n)) {if(b.n<4)continue;const c=b.sum.map(v=>Math.round(v/b.n));if(localSeeds.some(s=>dist(s,c)<24))continue;localSeeds.push(c);if(++added>=4)break;}
        for(const stroke of localSeeds){
          if(dist(fill,stroke)<48)continue;
          // Dark text can share the exterior color. Only an independently owned
          // enclosing edge permits re-entry into the boundary-connected fill.
          // White counters in ordinary dark lettering must not invert its roles.
          const rejoinsExterior=Math.min(...fill)<160&&glyph.coverage>=.15&&
            glyphs.some(g=>dist(g.color,stroke)<=24&&g.coverage>=.7);
          let rays=0,hits=0,exits=0,points=0,enclosed=0,backgroundExits=0;const bands=[],exitsByDirection=new Array(8).fill(0);
          for(let k=0;k<core.length;k+=stride){const i=core[k],x=i%w,y=Math.floor(i/w);let localRays=0,localHits=0,localExits=0;
            for(let di=0;di<dirs.length;di++){const [dx,dy]=dirs[di];let hit=0,exit=0,blocked=false;
              for(let step=1;step<=reach;step++){
                const xx=x+dx*step,yy=y+dy*step;if(xx<0||xx>=w||yy<0||yy>=h)break;
                const c=rgb(yy*w+xx),df=dist(c,fill),ds=dist(c,stroke);
                if(!hit){
                  if(df<=24)continue;
                  if(ds<=28&&df>=48){hit=step;continue;}
                  // Allow only the antialias ramp between this pair.
                  const v=stroke.map((v,j)=>v-fill[j]),d=c.map((v,j)=>v-fill[j]),t=d.reduce((s,v,j)=>s+v*(stroke[j]-fill[j]),0)/v.reduce((s,v)=>s+v*v,0);
                  if(t>0&&t<1&&Math.max(...d.map((d,j)=>Math.abs(d-t*v[j])))<=24)continue;
                  blocked=true;break;
                } else if(ds>24){
                  if(df<=40){if(exteriorFill[yy*w+xx]&&rejoinsExterior){exit=step;bands.push(step-hit);backgroundExits++;}break;}
                  const xx2=xx+dx,yy2=yy+dy,xx3=xx+2*dx,yy3=yy+2*dy;
                  const v=stroke.map((v,j)=>v-fill[j]),delta=c.map((v,j)=>v-fill[j]);
                  const t=delta.reduce((s,v,j)=>s+v*(stroke[j]-fill[j]),0)/v.reduce((s,v)=>s+v*v,0);
                  const offAxis=Math.max(...delta.map((d,j)=>Math.abs(d-t*v[j])));
                  if(t>1.05&&offAxis<=24)break;
                  if(t<-.12||offAxis>24){exit=step;bands.push(step-hit);break;}
                  if(xx3>=0&&xx3<w&&yy3>=0&&yy3<h&&xx2>=0&&xx2<w&&yy2>=0&&yy2<h&&
                    dist(c,rgb(yy2*w+xx2))<=8&&dist(c,rgb(yy3*w+xx3))<=8){exit=step;bands.push(step-hit);break;}
                }
              }
              if(hit||blocked){localRays++;if(hit)localHits++;if(exit){localExits++;exitsByDirection[di]++;}}
            }
            rays+=localRays;hits+=localHits;exits+=localExits;points++;if(localHits>=5&&localExits>=2)enclosed++;
          }
          const hitRatio=hits/Math.max(1,rays),exitRatio=exits/Math.max(1,hits),coverage=enclosed/Math.max(1,points);
          if(hitRatio<.8||exitRatio<.15||coverage<.3||bands.length<12)continue;
          bands.sort((a,b)=>a-b);const band=bands[Math.floor(bands.length/2)],p90=bands[Math.floor(bands.length*.9)];
          if((band<2&&(hitRatio<.97||(glyph.coverage<.8&&backgroundExits/Math.max(1,exits)<.6)))||band>size*.3||p90>size*.5)continue;
          if(exitsByDirection[0]+exitsByDirection[1]<4||exitsByDirection[2]+exitsByDirection[3]<4)continue;
          pairs.push({foreground:fill,stroke,band,glyphPixels:size,hitRatio,exitRatio,coverage,backgroundExits,exits,score:glyph.score*hitRatio*coverage});
        }
      }
      const best=pairs.filter(p=>{
        const surface=result?.captionBackground;
        if(!surface||p.backgroundExits/Math.max(1,p.exits)>=.6)return true;
        // A repeated narrow black band can meet a dark caption background.
        // One-pixel fringes and broad backing regions do not establish it.
        const closedDarkBand=Math.max(...p.stroke)<=32&&p.hitRatio>=.97&&p.band>=2&&p.coverage>=.3&&p.exitRatio>=.18;
        if(closedDarkBand)return true;
        // Without independent fill validation, a weak color difference from
        // the local backing can be texture/antialiasing rather than a stroke.
        // A white band can meet a white surface or a second outer outline.
        // Require agreement with the separately observed physical fill/edge.
        const closedWhiteBand=Math.min(...p.stroke)>=225&&p.hitRatio>=.97&&p.band>=2&&p.coverage>=.3&&Math.min(...p.foreground)<160&&
          ((!result?.foreground)||(result.stroke&&dist(result.stroke,p.stroke)<=24&&dist(result.foreground,p.foreground)<=24));
        if(dist(p.stroke,surface)<=40&&Math.min(...p.stroke)<245&&!closedWhiteBand&&!glyphs.some(g=>dist(g.color,p.foreground)<=24&&
            (g.enclosure||[]).some(e=>dist(e.color,p.stroke)<=24&&e.ratio>=.5)))return false;
        if(!(result.confidence?.foreground>0)&&dist(p.stroke,surface)<=40&&!closedWhiteBand)return false;
        const vector=surface.map((v,c)=>v-p.foreground[c]),delta=p.stroke.map((v,c)=>v-p.foreground[c]);
        const squared=vector.reduce((sum,v)=>sum+v*v,0);
        const t=delta.reduce((sum,v,c)=>sum+v*vector[c],0)/Math.max(1,squared);
        // A point on the ink/surface antialias ramp is not a third source color.
        if(t>.12&&t<1.08&&Math.max(...delta.map((v,c)=>Math.abs(v-t*vector[c])))<=24&&!closedWhiteBand)return false;
        return Math.min(...p.foreground)<160||dist(p.stroke,surface)>24;
      }).sort((a,b)=>b.score-a.score)[0];
      if(best)return best;
      // A pale core can be flattened to its defining colored outline for display.
      // Keep physical roles distinct when reciprocal enclosure strongly favors
      // the pale interior and both colors own repeated bounded glyph components.
      for(const fill of glyphs){
        if(Math.min(...fill.color)<225||fill.coverage<.75)continue;
        for(const edge of glyphs){
          if(Math.max(...edge.color)-Math.min(...edge.color)<40||edge.coverage<.8||fill.pixels<edge.pixels*.4)continue;
          const enclosed=(fill.enclosure||[]).find(e=>dist(e.color,edge.color)<=24)?.ratio||0;
          const reverse=(edge.enclosure||[]).find(e=>dist(e.color,fill.color)<=24)?.ratio||0;
          if(enclosed>=.6&&enclosed-reverse>=.3)
            return {foreground:fill.color,stroke:edge.color,widthEvidence:null};
        }
      }

      // Repeated enclosed colored interiors already establish their white edge.
      // A nearly white exposed background cannot disprove that local topology.
      if(result?.stroke && result.foreground && dist(result.foreground,result.stroke)>=48 && (result.confidence?.foreground||0)>=.6 &&
          (result.confidence?.reason==='repeated colored interiors enclosed by source white outlines'||
           (result.confidence?.reason==='repeated dark glyph interiors enclosed by white source outlines'&&
            result.background&&dist(result.stroke,result.background)>12&&
            (result.confidence?.background||0)>=.5&&((result.widthEvidence?.samplePixels||0)>=1||
              (dist(result.stroke,result.background)>=24&&glyphs.some(g=>g.coverage>=.6&&dist(g.color,result.foreground)<=24&&
                (g.enclosure||[]).some(e=>dist(e.color,result.stroke)<=24&&e.ratio>=.65)))))||
           (result.confidence?.reason==='enclosed glyph fill and distinct enclosing source stroke'&&
            display&&dist(display,result.foreground)<=32)))
        return {foreground:result.foreground,stroke:result.stroke,widthEvidence:result.widthEvidence};
      const evidence=result?.widthEvidence;
      // A width estimate alone can describe a caption panel or nearby art.
      // Retain it only with enclosure and exterior contrast, or independent
      // native lettering agreement. This also supports subpixel source bands.
      const ownedEdge=result?.stroke&&glyphs.some(g=>g.coverage>=.65&&dist(g.color,result.stroke)<=24);
      const enclosingFill=result?.foreground&&result.stroke&&glyphs.find(g=>(g.coverage>=.25||(g.coverage>=.15&&ownedEdge))&&dist(g.color,result.foreground)<=32&&
        (g.enclosure||[]).some(e=>dist(e.color,result.stroke)<=24&&e.ratio>=.65));
      const distinctExterior=result?.background&&result.stroke&&dist(result.background,result.stroke)>=24;
      const paleEndpoint=enclosingFill?.coverage>=.8&&result?.foreground&&
        Math.max(...result.foreground)-Math.min(...result.foreground)>=40&&Math.min(...result.stroke)>=245;
      const corroboratedNative=result?.foreground&&result.stroke&&result.confidence?.reason==='agreeing native detail palettes preserve fill and outline roles'&&
        Math.min(...result.foreground)>=225&&Math.max(...result.stroke)<80&&
        ((result.lettering?.components>=3&&result.lettering.bands>=3&&dist(result.lettering.color,result.stroke)<=40)||
          (distinctExterior&&evidence?.relativeToGlyph<=.2));
      if(result?.stroke && result.foreground && evidence?.samplePixels>=.5 &&
          evidence.relativeToGlyph<=.3 && ((result.confidence?.foreground||0)>=.6||
            (enclosingFill&&glyphs.some(g=>g.coverage>=.65&&dist(g.color,result.stroke)<=24))) &&
          ((enclosingFill&&(distinctExterior||paleEndpoint))||corroboratedNative) &&
          dist(result.foreground,result.stroke)>=48 &&
          (evidence.method==='outer stroke boundary distance to validated ink; external Manhattan band'||
           evidence.method==='alternative observed ink with glyph-following halo; exterior surface unverified'))
        return {foreground:result.foreground,stroke:result.stroke,band:evidence.samplePixels,glyphPixels:evidence.glyphPixels,method:'validated full outer boundary'};
      return null;
    };

    const aidokuSourceColorSampler = (image, enabled, phase = 'ocr', budget = {pixels:393216, detailPixels:98304}) => {
      const stats = {pixels: 0, hits: 0, samples: 0, milliseconds: 0};
      if (!enabled || !image?.complete || !image.naturalWidth) return {sample: () => null, stats};
      // A reused image element can load another page without changing identity.
      const identities=(globalThis.__aidokuSourceColorImageIdentitiesV1 ||= new WeakMap());
      const identity=[image.currentSrc||image.src||'',image.naturalWidth,image.naturalHeight];
      const previous=identities.get(image);
      if(previous && identity.some((value,index)=>value!==previous[index])) {
        globalThis.__aidokuSourceTextColorsV27?.delete(image);
        globalThis.__aidokuTranslatedSourceTextColorsV27?.delete(image);
      }
      identities.set(image,identity);
      // OCR and translated text each sample the original image once. Revisions
      // within the same phase reuse their own palette, without sampling overlays.
      const caches = phase === 'translation'
        ? (globalThis.__aidokuTranslatedSourceTextColorsV27 ||= new WeakMap())
        : (globalThis.__aidokuSourceTextColorsV27 ||= new WeakMap());
      let cache = caches.get(image);
      if (!cache) { cache = new Map(); caches.set(image, cache); }
      let canvas, context, unavailable = false;
      return {stats, sample: bounds => {
        if (unavailable || !Array.isArray(bounds) || bounds.length !== 4 || !bounds.every(Number.isFinite) ||
            bounds[0] < 0 || bounds[1] < 0 || bounds[2] <= 0 || bounds[3] <= 0 ||
            bounds[0] + bounds[2] > 1.000001 || bounds[1] + bounds[3] > 1.000001) return null;
        const key = bounds.join(',');
        if (cache.has(key)) { stats.hits++; return cache.get(key); }
        const detailLimit=Math.floor(budget.detailPixels/Math.max(1,budget.remainingSamples||1));
        if(Number.isFinite(budget.remainingSamples))budget.remainingSamples=Math.max(0,budget.remainingSamples-1);
        let detailSpent=0;
        const iw = image.naturalWidth, ih = image.naturalHeight;
        // Tight OCR boxes can end inside a white glyph outline. Two source
        // pixels then sample the halo as the panel, especially after reduction.
        // Include half a glyph width of surrounding surface, with a small cap
        // so neighbouring balloons/art cannot dominate the sample.
        const sourceWidth = bounds[2] * iw, sourceHeight = bounds[3] * ih;
        const vertical = sourceHeight >= sourceWidth;
        const longText = Math.max(sourceWidth, sourceHeight) >= Math.min(sourceWidth, sourceHeight) * 1.5;
        const margin = Math.max(4, Math.min(16, Math.ceil(Math.min(sourceWidth, sourceHeight) * 0.5)));
        const x = Math.max(0, Math.floor(bounds[0] * iw) - margin);
        const y = Math.max(0, Math.floor(bounds[1] * ih) - margin);
        const sw = Math.min(iw, Math.ceil((bounds[0] + bounds[2]) * iw) + margin) - x;
        const sh = Math.min(ih, Math.ceil((bounds[1] + bounds[3]) * ih) + margin) - y;
        // Bound the sampled area, not the longest side. A 64 x 1600 line
        // reduced to 192 pixels tall loses almost all glyph/outline detail
        // even though most of the 24576-pixel allowance remains unused.
        const sampleLimit=Math.min(24576,Math.floor(budget.pixels/Math.max(1,(budget.remainingSamples||0)+1)));
        if(sampleLimit<1)return null;
        const scale = Math.min(1, Math.sqrt(sampleLimit / (sw * sh)));
        const w = Math.min(sampleLimit,Math.max(1,Math.floor(sw*scale)));
        const h = Math.min(Math.floor(sampleLimit/w),Math.max(1,Math.floor(sh*scale)));
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
          result = aidokuEstimateSourceColors(rgba, w, h);
          result = aidokuRecoverSourcePanel(rgba, w, h,
            [(bounds[0]*iw-x)*w/sw, (bounds[1]*ih-y)*h/sh, bounds[2]*iw*w/sw, bounds[3]*ih*h/sh], result);
          if (result?.widthEvidence) result.widthEvidence.sampleScale = scale;
          const inner=[(bounds[0]*iw-x)*w/sw,(bounds[1]*ih-y)*h/sh,bounds[2]*iw*w/sw,bounds[3]*ih*h/sh];
          let lettering=aidokuObservedLetteringInk(rgba,w,h,inner);
          const nativeGlyphs=[];
          // Long lines can downsample a colored fill into its white outline.
          // Retry at most three small native-detail strips, sharing the original
          // per-page pixel budget. Require independent agreeing observations.
          // A confident white silhouette can still be an aliased halo. Verify
          // its enclosed colored interiors only on a separately observed dark
          // surface; white panels can contain legitimate colored outline rings.
          // A thin colored outline can disappear at one Canvas reduction ratio.
          // Validate a second bounded raster before falling back to neutral ink.
          const chromatic=c=>Array.isArray(c)&&Math.max(...c)-Math.min(...c)>=40;
          const hasColor=chromatic(result?.foreground)||
            (chromatic(result?.stroke)&&(result?.confidence?.stroke||0)>=.55);
          if(!hasColor&&(!result?.foreground||Math.min(...result.foreground)>=225||
              ((result?.confidence?.background||0)<.5&&(result?.confidence?.foreground||0)<=.7))) {
            for(const factor of [.5,.75]) {
              const cw=Math.floor(w*factor),ch=Math.floor(h*factor),pixels=cw*ch;
              const reserved=Math.max(0,budget.remainingSamples||0)*64;
              if(cw<8||ch<8||pixels>budget.pixels-reserved||pixels>budget.detailPixels||detailSpent+pixels>detailLimit)continue;
              budget.pixels-=pixels;budget.detailPixels-=pixels;detailSpent+=pixels;stats.pixels+=pixels;
              canvas.width=cw;canvas.height=ch;context.drawImage(image,x,y,sw,sh,0,0,cw,ch);
              const candidate=aidokuEstimateSourceColors(context.getImageData(0,0,cw,ch).data,cw,ch);
              if(!candidate?.foreground||(candidate.confidence?.foreground||0)<.6)continue;
              if(!chromatic(candidate.foreground)&&!(Math.min(...candidate.foreground)>=225&&
                  chromatic(candidate.stroke)&&(candidate.confidence?.stroke||0)>=.55))continue;
              result={...result,foreground:candidate.foreground,stroke:candidate.stroke,outline:candidate.stroke,
                widthEvidence:null,confidence:{...result?.confidence,foreground:candidate.confidence.foreground,
                  stroke:candidate.confidence.stroke,reason:'validated chromatic glyphs at an independent reduction ratio'}};
              break;
            }
          }
          const verifyWhiteHalo = result?.foreground && (result.confidence?.foreground||0)>=.6 && Math.min(...result.foreground)>=230 &&
            result.background && Math.min(...result.background)<245;
          // Native-size short exclamations need the same enclosed-fill recovery;
          // crop reduction is not a prerequisite for losing the colored interior.
          const enclosedDark=aidokuRecoverOutlinedColor(rgba,w,h,result,true);
          // A white counter in black lettering can look like a filled glyph.
          // Let the independently observed light panel support the opposite role
          // only when most dark pixels belong to repeated white-enclosed shapes.
          // True white text has an exterior dark outline, which fails coverage.
          let panelSupportedDark=false;
          if(enclosedDark&&result?.background&&Math.min(...result.background)>=175&&
              (result.confidence?.background||0)>=.5&&Math.max(...enclosedDark.foreground)<80){
            let darkPixels=0;
            for(let i=0;i<rgba.length;i+=4)if(Math.max(rgba[i],rgba[i+1],rgba[i+2])<80)darkPixels++;
            panelSupportedDark=darkPixels>0&&enclosedDark.fillPixels>=darkPixels*.65;
          }
          if(enclosedDark&&Math.max(...enclosedDark.foreground)<80&&
              (!result?.foreground||Math.min(...result.foreground)<225||panelSupportedDark)) {
            result={...result,foreground:enclosedDark.foreground,stroke:enclosedDark.stroke,
              outline:enclosedDark.stroke,confidence:{...result?.confidence,foreground:.75,stroke:.75,
                reason:'repeated dark glyph interiors enclosed by white source outlines'}};
          }
          const protectedDarkInk=result?.foreground && (result.confidence?.foreground||0)>0 &&
            Math.max(...result.foreground)<80 && Math.max(...result.foreground)-Math.min(...result.foreground)<24;
          const localFill = aidokuRecoverOutlinedColor(rgba,w,h,verifyWhiteHalo?{...result,foreground:null}:result);
          if(localFill && localFill.confidence>=.6 && !verifyWhiteHalo && !protectedDarkInk) result={...result,foreground:localFill.foreground,
            stroke:localFill.stroke,outline:localFill.stroke,widthEvidence:null,
            confidence:{...result?.confidence,foreground:localFill.confidence,stroke:localFill.confidence,
              reason:'repeated colored interiors enclosed by source white outlines'}};
          const needsRoleDetails=!result?.foreground||result.confidence?.foreground<.6||verifyWhiteHalo||
            (scale<1&&result?.stroke&&result?.foreground&&Math.max(...result.foreground.map((v,i)=>Math.abs(v-result.stroke[i])))<80);
          const needsLetteringDetails=scale<1&&result?.foreground&&Math.max(...result.foreground)>=225&&Math.min(...result.foreground)>=180;
          if (longText && !protectedDarkInk && (needsRoleDetails||needsLetteringDetails)) {
            const candidates=[], nativeCandidates=[], letteringCandidates=[];
            const detailPalette=verifyWhiteHalo?{...result,foreground:null}:result;
            const stripLength=Math.min(192,Math.floor((vertical?sh:sw)/2),Math.floor((detailLimit-detailSpent)/(2*(vertical?sw:sh))));
            for(const fraction of [0,1,.5]) {
              const stripWidth=vertical?sw:stripLength,stripHeight=vertical?stripLength:sh;
              const stripX=x+(vertical?0:fraction*(sw-stripWidth));
              const stripY=y+(vertical?fraction*(sh-stripHeight):0);
              const stripScale=Math.min(1,Math.sqrt(24576/(stripWidth*stripHeight)));
              const cw=Math.floor(stripWidth*stripScale),ch=Math.floor(stripHeight*stripScale),pixels=cw*ch;
              const reserved=Math.min(budget.pixels,Math.max(0,budget.remainingSamples||0)*64);
              if(cw<8 || ch<8 || pixels>budget.pixels-reserved || pixels>budget.detailPixels || detailSpent+pixels>detailLimit)break;
              budget.pixels-=pixels;budget.detailPixels-=pixels;detailSpent+=pixels;stats.pixels+=pixels;
              canvas.width=cw;canvas.height=ch;
              context.drawImage(image,stripX,stripY,stripWidth,stripHeight,0,0,cw,ch);
              let detail=context.getImageData(0,0,cw,ch).data;
              if(fraction!==.5) {
                const glyphs=aidokuObservedGlyphPalette(detail,cw,ch,
                  [(bounds[0]*iw-stripX)*cw/stripWidth,(bounds[1]*ih-stripY)*ch/stripHeight,
                    bounds[2]*iw*cw/stripWidth,bounds[3]*ih*ch/stripHeight]);
                if(glyphs)nativeGlyphs.push(glyphs);
                const observed=aidokuObservedLetteringInk(detail,cw,ch,
                  [(bounds[0]*iw-stripX)*cw/stripWidth,(bounds[1]*ih-stripY)*ch/stripHeight,
                    bounds[2]*iw*cw/stripWidth,bounds[3]*ih*ch/stripHeight]);
                if(observed)letteringCandidates.push(observed);
              }
              if(!needsRoleDetails)continue;
              // The enclosed-component filter uses a column's geometry.
              // Transpose horizontal lines so the same evidence rules apply.
              if(!vertical) {
                const transposed=new Uint8ClampedArray(detail.length);
                for(let yy=0;yy<ch;yy++)for(let xx=0;xx<cw;xx++) {
                  const from=(yy*cw+xx)*4,to=(xx*ch+yy)*4;
                  for(let c=0;c<4;c++)transposed[to+c]=detail[from+c];
                }
                detail=transposed;
              }
              const native=aidokuEstimateSourceColors(detail,vertical?cw:ch,vertical?ch:cw);
              if(native?.foreground && native.confidence?.foreground>=.6) nativeCandidates.push(native);
              let candidate=aidokuRecoverOutlinedColor(detail,vertical?cw:ch,vertical?ch:cw,detailPalette);
              if(candidate && verifyWhiteHalo) {
                // A white O with colored outlines has colored ink inside its
                // counter too. Most candidate ink must actually be enclosed;
                // a matching exterior outline contradicts the proposed fill.
                let observed=0;
                for(let p=0;p<detail.length;p+=4)if(Math.max(...candidate.foreground.map((v,c)=>Math.abs(detail[p+c]-v)))<=28)observed++;
                if(!observed || candidate.fillPixels<observed*.7)candidate=null;
              }
              if(candidate)candidates.push(candidate);
              if(candidates.length>=2 && Math.max(...candidates[0].foreground.map((v,i)=>
                Math.abs(v-candidates[candidates.length-1].foreground[i])))<=28)break;
            }
            // Native strips retain thin outlines lost to crop reduction. Require
            // independent agreeing observations, sharing the existing detail reads.
            const matchingLettering=letteringCandidates.filter(c=>letteringCandidates.filter(other=>
              Math.max(...c.color.map((v,i)=>Math.abs(v-other.color[i])))<=24).length>=2);
            if(matchingLettering.length>=2)lettering=matchingLettering.sort((a,b)=>b.pixels-a.pixels)[0];
            const agreeing=candidates.filter(c=>candidates.filter(other=>
              Math.max(...c.foreground.map((v,i)=>Math.abs(v-other.foreground[i])))<=28).length>=2);
            if(!result?.foreground && nativeCandidates.length){
              const best=[...nativeCandidates].sort((a,b)=>b.confidence.foreground-a.confidence.foreground)[0];
              result={...result,displayForeground:best.foreground};
            }
            const nativeAgreement=nativeCandidates.filter(c=>(!verifyWhiteHalo||Math.min(...c.foreground)>=225)&&nativeCandidates.filter(other=>
              Math.max(...c.foreground.map((v,i)=>Math.abs(v-other.foreground[i])))<=20).length>=2);
            if(nativeAgreement.length>=2 && agreeing.length<2) {
              const best=nativeAgreement.find(c=>c.stroke)||nativeAgreement[0];
              result={...result,foreground:best.foreground,stroke:best.stroke||result?.stroke,outline:best.stroke||result?.stroke,
                widthEvidence:best.widthEvidence,confidence:{...result?.confidence,
                  foreground:best.confidence.foreground,stroke:best.stroke?best.confidence.stroke:result?.confidence?.stroke,
                  reason:'agreeing native detail palettes preserve fill and outline roles'}};
            }
            if(agreeing.length>=2) {
              const average=key=>[0,1,2].map(c=>Math.round(agreeing.reduce((sum,v)=>sum+v[key][c],0)/agreeing.length));
              result={...result,foreground:average('foreground'),stroke:average('stroke'),outline:average('stroke'),widthEvidence:null,
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
          result=aidokuObservedCaptionPalette(rgba,w,h,
            [(bounds[0]*iw-x)*w/sw,(bounds[1]*ih-y)*h/sh,bounds[2]*iw*w/sw,bounds[3]*ih*h/sh],result);
          const displayed=aidokuSourceDisplayInk(result);
          if(!chromatic(displayed)&&!(chromatic(result?.stroke)&&(result?.confidence?.stroke||0)>=.55)&&
              (!result?.foreground||Math.min(...result.foreground)>=225||
              (Math.max(...result.foreground)>40&&(result?.confidence?.background||0)<.5))) {
            const recovered=aidokuRecoverHaloInk(rgba,w,h,
              [(bounds[0]*iw-x)*w/sw,(bounds[1]*ih-y)*h/sh,bounds[2]*iw*w/sw,bounds[3]*ih*h/sh]);
            if(recovered)result={...result,foreground:recovered.foreground,stroke:null,outline:null,widthEvidence:null,
              confidence:{...result?.confidence,foreground:.7,stroke:0,reason:'repeated chromatic strokes locally enclosed by white source halos'}};
          }
          if(lettering)result={...result,lettering};
          const glyphs=aidokuObservedGlyphPalette(rgba,w,h,inner, result?.background&&(result?.foreground&&(result.confidence?.foreground||0)>=.5||!result?.foreground&&result?.displayForeground) ? {foreground:result.foreground||result.displayForeground,background:result.background} : null);
          let display=aidokuResolveDisplayGlyphs(result,glyphs);
          // Only agreeing native strips refine a pale antialiased core. Dark
          // and chromatic source endpoints must not be diluted back into gray.
          if(display&&Math.min(...display)>=160&&Math.max(...display)-Math.min(...display)<40&&nativeGlyphs.length>=2){
            const supportedMain=(result?.confidence?.foreground||0)>=.85&&glyphs?.some(g=>g.coverage>=.75&&
              Math.max(...g.color.map((v,c)=>Math.abs(v-display[c])))<=16);
            const near=(a,b)=>Math.max(...a.map((v,i)=>Math.abs(v-b[i])));
            const candidates=nativeGlyphs[0].filter(c=>c.coverage>=.35&&near(c.color,display)<=64&&
              (!supportedMain||c.color.every((v,i)=>v>=display[i]-8))&&
              nativeGlyphs[1].some(other=>other.coverage>=.35&&near(c.color,other.color)<=20));
            if(candidates.length)display=candidates.sort((a,b)=>b.score-a.score)[0].color;
          }
          result={...result,displayEvidence:{color:display}};
          result=aidokuInteriorCaptionSurface(rgba,w,h,
            [(bounds[0]*iw-x)*w/sw,(bounds[1]*ih-y)*h/sh,bounds[2]*iw*w/sw,bounds[3]*ih*h/sh],result);
          result=aidokuObservedCaptionBackground(rgba,w,h,inner,result);
          // A display outline needs a distinct physical band. Erasure also
          // needs the observed halo/antialias colors even when that band cannot
          // be established. Keep this evidence independent of display roles.
          const sourceInk=result?.foreground&&result.background?{
            foreground:[...result.foreground],background:[...result.background],
            stroke:result.stroke?[...result.stroke]:null,
            widthEvidence:result.widthEvidence?{...result.widthEvidence}:null,
            confidence:{...result.confidence}}:null;
          const strokeEvidence=aidokuObservedStrokePalette(rgba,w,h,inner,glyphs,display,result);
          // Keep display/background decisions above independent from erasure roles.
          // Color rejection must not widen an already measured cleanup fringe.
          result={...result,sourceInk,stroke:strokeEvidence?.stroke||null,outline:strokeEvidence?.stroke||null,
            widthEvidence:strokeEvidence?(strokeEvidence.widthEvidence!==undefined?strokeEvidence.widthEvidence:
              (result?.stroke&&Math.max(...result.stroke.map((v,c)=>Math.abs(v-strokeEvidence.stroke[c])))<=25?result.widthEvidence:{samplePixels:strokeEvidence.band,
              relativeToGlyph:strokeEvidence.band/strokeEvidence.glyphPixels,
              glyphPixels:strokeEvidence.glyphPixels,sampleScale:scale,
              method:strokeEvidence.method||'bounded fill to stroke to exterior transitions'})):result?.widthEvidence,
            confidence:{...result?.confidence,stroke:strokeEvidence ? .7 : 0,
              strokeReason:strokeEvidence?'observed narrow enclosing band':'no independent enclosing band'}};
          if(strokeEvidence)result.foreground=strokeEvidence.foreground;

        } catch (_) { unavailable = true; }
        finally { stats.milliseconds += performance.now() - started; }
        if (cache.size >= 256) cache.delete(cache.keys().next().value);
        cache.set(key, result);
        return result;
      }};
    };

    """
}
