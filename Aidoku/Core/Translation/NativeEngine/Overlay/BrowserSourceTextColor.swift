// Model-free, conservative foreground/background estimation over the local reader image.
// Failed/ambiguous estimates leave the existing palette intact.
enum BrowserSourceTextColor {
    static let script = """
    const aidokuEstimateSourceColors = (rgba, width, height) => {
      const count = width * height;
      if (!Number.isInteger(width) || !Number.isInteger(height) || width < 8 || height < 8 ||
          count > 24576 || !rgba || rgba.length !== count * 4) return null;
      const distance = (a, b) => Math.max(...a.map((v, i) => Math.abs(v - b[i])));
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
      const mean = bin => bin.slice(1).map(v => v / bin[0]);
      const backgroundKey = [...rim].sort((a, b) => b[1] - a[1])[0][0];
      const background = mean(bins.get(backgroundKey));
      let backgroundCount = 0, backgroundRim = 0, candidateCount = 0;
      let winner = null;
      let solidCount = 0, solidRim = 0;
      for (const [key, bin] of bins) {
        if (distance(mean(bin), background) <= 12) {
          solidCount += bin[0]; solidRim += rim.get(key) || 0;
        }
        if (distance(mean(bin), background) <= 32) {
          backgroundCount += bin[0]; backgroundRim += rim.get(key) || 0;
        } else if (distance(mean(bin), background) >= 60) {
          candidateCount += bin[0];
          if (!winner || bin[0] > winner[0]) winner = bin;
        }
      }
      const colors = {foreground: null, background:
        solidCount >= count * 0.65 && solidRim >= rimCount * 0.85 ? background.map(Math.round) : null};
      // A uniform background must dominate both the crop and its perimeter.
      if (backgroundCount < count * 0.55 || backgroundRim < rimCount * 0.7 ||
          !winner || candidateCount < Math.max(12, count * 0.008) || candidateCount > count * 0.4) return colors;
      // Antialiasing blends ink toward the background. Use the distant tail
      // rather than the most frequent gray edge as the ink-color seed.
      const inkBins = [...bins.values()].filter(bin => distance(mean(bin), background) >= 60)
        .sort((a, b) => distance(mean(b), background) - distance(mean(a), background));
      const tailTarget = Math.max(6, candidateCount * 0.12), tailSum = [0, 0, 0];
      let tailCount = 0;
      for (const bin of inkBins) {
        const take = Math.min(bin[0], tailTarget - tailCount), rgb = mean(bin);
        for (let c = 0; c < 3; c++) tailSum[c] += rgb[c] * take;
        tailCount += take;
        if (tailCount >= tailTarget) break;
      }
      const seedColor = tailSum.map(v => v / tailCount);
      const direction = seedColor.map((v, c) => v - background[c]);
      const lengthSquared = direction.reduce((sum, v) => sum + v * v, 0);
      const mask = new Uint8Array(count), core = new Uint8Array(count);
      let selected = 0, aligned = 0;
      for (let i = 0; i < count; i++) {
        const p = i * 4;
        const r = rgba[p] - background[0], g = rgba[p + 1] - background[1], b = rgba[p + 2] - background[2];
        if (Math.max(Math.abs(r), Math.abs(g), Math.abs(b)) < 60) continue;
        const t = (r * direction[0] + g * direction[1] + b * direction[2]) / lengthSquared;
        // Allow edge blends of one ink color, reject unrelated colors.
        if (t < 0.15 || t > 1.2 || Math.max(Math.abs(r - t * direction[0]),
            Math.abs(g - t * direction[1]), Math.abs(b - t * direction[2])) > 24) continue;
        mask[i] = 1; aligned++;
        if (Math.max(Math.abs(rgba[p] - seedColor[0]), Math.abs(rgba[p + 1] - seedColor[1]),
                     Math.abs(rgba[p + 2] - seedColor[2])) <= 24) { core[i] = 1; selected++; }
      }
      if (aligned < candidateCount * 0.85 || selected < Math.max(8, candidateCount * 0.15)) return colors;
      const seen = new Uint8Array(count), queue = new Int32Array(count);
      const sum = [0, 0, 0]; let coreCount = 0, components = 0, retained = 0;
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
          for (const next of [x > 0 ? i - 1 : -1, x + 1 < width ? i + 1 : -1,
                              y > 0 ? i - width : -1, y + 1 < height ? i + width : -1]) {
            if (next >= 0 && mask[next] && !seen[next]) { seen[next] = 1; queue[tail++] = next; }
          }
        }
        const boxWidth = maxX - minX + 1, boxHeight = maxY - minY + 1;
        // Exclude border art, specks and filled rectangles/panel rules.
        if (boundary || tail < 3 || boxWidth > width * 0.9 || boxHeight > height * 0.9 ||
            (tail > 12 && tail / (boxWidth * boxHeight) > 0.9)) continue;
        components++; retained += tail;
        for (let j = 0; j < tail; j++) {
          const i = queue[j];
          const neighbors = (mask[i - 1] || 0) + (mask[i + 1] || 0) +
                            (mask[i - width] || 0) + (mask[i + width] || 0);
          if (!core[i] || neighbors < 3) continue;
          for (let c = 0; c < 3; c++) sum[c] += rgba[i * 4 + c];
          coreCount++;
        }
      }
      if (components < 2 || retained < aligned * 0.7 || coreCount < 6) return colors;
      colors.foreground = sum.map(v => Math.round(v / coreCount));
      return colors;
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
    const aidokuReadableSourceColor = (color, light, opacity, panel = null) => {
      if (aidokuSourceColorContrast(color, light, opacity, panel) >= 4.5) return color;
      if (!Array.isArray(color) || color.length !== 3 ||
          !color.every(v => Number.isFinite(v) && v >= 0 && v <= 255) ||
          Math.max(...color) - Math.min(...color) < 24) return null;
      // Keep the estimated hue; only correct luminance when the source ink
      // would otherwise be replaced with the generic monochrome palette.
      const endpoint = light ? 0 : 255;
      const blend = amount => color.map(v => Math.round(v + (endpoint - v) * amount));
      let low = 0, high = 0.5, best = blend(high);
      if (aidokuSourceColorContrast(best, light, opacity, panel) < 4.5) return null;
      for (let step = 0; step < 8; step++) {
        const middle = (low + high) / 2, candidate = blend(middle);
        if (aidokuSourceColorContrast(candidate, light, opacity, panel) >= 4.5) {
          high = middle; best = candidate;
        } else { low = middle; }
      }
      return best;
    };
    const aidokuPanelForeground = (panel, opacity) => {
      if (!panel) return null;
      const dark = [17, 18, 23], white = [255, 255, 255];
      const darkContrast = aidokuSourceColorContrast(dark, true, opacity, panel);
      const whiteContrast = aidokuSourceColorContrast(white, false, opacity, panel);
      if (Math.max(darkContrast, whiteContrast) < 4.5) return null;
      return darkContrast >= whiteContrast ? dark : white;
    };
    const aidokuSourceColorSampler = (image, enabled) => {
      const stats = {pixels: 0, hits: 0, samples: 0, milliseconds: 0};
      if (!enabled || !image?.complete || !image.naturalWidth) return {sample: () => null, stats};
      // Image-object identity invalidates estimates when the page or split crop changes.
      const caches = globalThis.__aidokuSourceTextColorsV2 ||= new WeakMap();
      let cache = caches.get(image);
      if (!cache) { cache = new Map(); caches.set(image, cache); }
      let canvas, context, budget = 393216, unavailable = false;
      return {stats, sample: bounds => {
        if (unavailable || !Array.isArray(bounds) || bounds.length !== 4 || !bounds.every(Number.isFinite) ||
            bounds[0] < 0 || bounds[1] < 0 || bounds[2] <= 0 || bounds[3] <= 0 ||
            bounds[0] + bounds[2] > 1.000001 || bounds[1] + bounds[3] > 1.000001) return null;
        const key = bounds.join(',');
        if (cache.has(key)) { stats.hits++; return cache.get(key); }
        const iw = image.naturalWidth, ih = image.naturalHeight;
        // Small margin keeps tight OCR glyphs away from the component boundary.
        const x = Math.max(0, Math.floor(bounds[0] * iw) - 2);
        const y = Math.max(0, Math.floor(bounds[1] * ih) - 2);
        const sw = Math.min(iw, Math.ceil((bounds[0] + bounds[2]) * iw) + 2) - x;
        const sh = Math.min(ih, Math.ceil((bounds[1] + bounds[3]) * ih) + 2) - y;
        const scale = Math.min(1, 192 / Math.max(sw, sh), Math.sqrt(24576 / (sw * sh)));
        const w = Math.max(1, Math.floor(sw * scale)), h = Math.max(1, Math.floor(sh * scale));
        if (w * h > budget) return null;
        budget -= w * h; stats.pixels += w * h; stats.samples++;
        let result = null;
        const started = performance.now();
        try {
          if (!canvas) { canvas = document.createElement('canvas'); context = canvas.getContext('2d', {willReadFrequently: true}); }
          if (!context) { unavailable = true; return null; }
          canvas.width = w; canvas.height = h;
          context.drawImage(image, x, y, sw, sh, 0, 0, w, h);
          result = aidokuEstimateSourceColors(context.getImageData(0, 0, w, h).data, w, h);
        } catch (_) { unavailable = true; }
        finally { stats.milliseconds += performance.now() - started; }
        if (cache.size >= 256) cache.delete(cache.keys().next().value);
        cache.set(key, result);
        return result;
      }};
    };
    """
}
